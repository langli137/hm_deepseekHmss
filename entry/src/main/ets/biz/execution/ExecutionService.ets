/**
 * 评测任务执行应用服务（spec 5.3，tasks.md 5）。
 * - 单例入口：ExecutionService.getInstance()
 * - 承载执行编排、单例并发控制、断点续跑、暂停/恢复/终止、后台执行与通知。
 * - 状态驻留在 AbilityStage 级单例，UI 通过观察者模式订阅进度（design.md 2.1.2）。
 * - 持久化：case_result + task_progress 在同一事务内提交（design.md 2.1.3(3)）。
 *
 * 跨模块契约：
 * - ServiceConfigService.getConfig / revealSecret
 * - TaskConfigService.getTask
 * - RunRecordService.archive（通过 archiveProvider 注入）
 * - AppSettingsService.isNotificationEnabled（通过 notificationEnabledProvider 注入）
 * - MetricCalculator.compute（通过 metricsProvider 注入）
 */
import { AppContainer } from '../../entrystage/AppContainer';
import { ensureSchema, TABLE_CASE_RESULT, TABLE_EVAL_TASK, TABLE_TASK_PROGRESS } from '../../infra/adapters/DbSchema';
import { RelationalStorePort } from '../../infra/ports/RelationalStorePort';
import { ModelClientPort } from '../../infra/ports/ModelClientPort';
import { NetworkMonitorPort } from '../../infra/ports/NetworkMonitorPort';
import { BackgroundTaskPort } from '../../infra/ports/BackgroundTaskPort';
import { NotificationPort } from '../../infra/ports/NotificationPort';
import { LoggerPort } from '../../infra/ports/LoggerPort';
import {
  BackgroundTaskHandle, CancellationToken, ExecSpec, NetworkState, QuerySpec, TxContext, Unsubscribe
} from '../../common/types/InfraTypes';
import {
  ExecutionFlag, InterruptReason, LogEvent, LogLevel, RunRecordStatus, TaskStatus, Verdict
} from '../../common/types/Enums';
import {
  CaseResult, CaseSnapshot, ChatChunk, ChatMessage, ChatRequest, DatasetSnapshot, EvaluationTask,
  ExecutionObserver, ExecutionProgress, Metrics, ModelServiceConfig, RunParameters, UsageSummary
} from '../../common/types/DomainTypes';
import { AppError, asAppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { DEFAULT_MAX_RETRY, MODEL_VERSION } from '../../common/types/Constants';
import { newId, nowMs } from '../../common/utils/IdGen';
import { TaskStateMachine } from '../../domain/statemachine/TaskStateMachine';
import { ResumePlanner } from '../../domain/scheduler/ResumePlanner';
import { StreamAssembler } from '../../domain/scheduler/StreamAssembler';
import { CaseScheduler } from '../../domain/scheduler/CaseScheduler';
import { DefaultJudgeStrategy, JudgeStrategy } from '../../domain/strategy/JudgeStrategy';
import { ServiceConfigService } from '../serviceconfig/ServiceConfigService';
import { TaskConfigService } from '../taskconfig/TaskConfigService';

// ============ 跨模块契约类型（RunRecordService 尚未实现，此处定义兼容类型） ============

export interface RunRecordArchiveInput {
  taskId: string;
  taskName: string;
  targetModel: string;
  status: RunRecordStatus;
  startedAt: number;
  endedAt: number;
  datasetUri: string;
  modelVersion: number;
  caseResults: CaseResult[];
  usage: UsageSummary;
}

// ============ CancellationToken 实现 ============

class CancellationTokenImpl implements CancellationToken {
  private _cancelled: boolean = false;
  private callbacks: Array<() => void> = [];

  get cancelled(): boolean {
    return this._cancelled;
  }

  onCancel(callback: () => void): void {
    if (this._cancelled) {
      callback();
    } else {
      this.callbacks.push(callback);
    }
  }

  cancel(): void {
    if (!this._cancelled) {
      this._cancelled = true;
      for (let i = 0; i < this.callbacks.length; i++) {
        this.callbacks[i]();
      }
      this.callbacks = [];
    }
  }
}

// ============ 依赖注入 ============

export interface ExecutionDeps {
  store: RelationalStorePort;
  modelClient: ModelClientPort;
  network: NetworkMonitorPort;
  backgroundTask: BackgroundTaskPort;
  notification: NotificationPort;
  logger: LoggerPort;
  /** 获取模型服务配置（跨模块契约 ServiceConfigService.getConfig） */
  getConfig: (configId: string) => Promise<ModelServiceConfig>;
  /** 解密密钥明文（跨模块契约 ServiceConfigService.revealSecret） */
  revealSecret: (configId: string) => Promise<string>;
  /** 获取评测任务（跨模块契约 TaskConfigService.getTask） */
  getTask: (taskId: string) => Promise<EvaluationTask>;
  /** RunRecordService.archive（跨模块契约，任务7实现） */
  archiveProvider: (input: RunRecordArchiveInput) => Promise<string>;
  /** AppSettingsService.isNotificationEnabled（跨模块契约，任务8实现） */
  notificationEnabledProvider: () => Promise<boolean>;
  /** MetricCalculator.compute（跨模块契约，任务6实现） */
  metricsProvider: (cases: CaseResult[], usage?: UsageSummary) => Metrics;
}

// ============ SQL 常量 ============

const SQL_INSERT_CASE_RESULT: string =
  `INSERT INTO ${TABLE_CASE_RESULT}(case_id, task_id, seq, content, reference_answer, model_answer, verdict, elapsed_ms) VALUES(?,?,?,?,?,?,?,?)`;

const SQL_UPSERT_TASK_PROGRESS: string =
  `INSERT INTO ${TABLE_TASK_PROGRESS}(task_id, watermark_seq, completed_count, total_count) VALUES(?,?,?,?) ON CONFLICT(task_id) DO UPDATE SET watermark_seq=?, completed_count=?`;

const SQL_QUERY_TASK_PROGRESS: string =
  `SELECT task_id, watermark_seq, completed_count, total_count FROM ${TABLE_TASK_PROGRESS} WHERE task_id = ?`;

const SQL_UPDATE_TASK_STATUS: string =
  `UPDATE ${TABLE_EVAL_TASK} SET status=?, flag=? WHERE task_id=?`;

const SQL_QUERY_RUNNING_TASKS: string =
  `SELECT task_id, name, config_id, dataset_uri, params_json, status, flag, snapshot_json, dataset_json, created_at FROM ${TABLE_EVAL_TASK} WHERE status = ?`;

// ============ 进度行结构 ============

interface ProgressRow {
  task_id: string;
  watermark_seq: number;
  completed_count: number;
  total_count: number;
}

// ============ 观察者注册表结构 ============

interface ObserverEntry {
  taskId: string;
  observer: ExecutionObserver;
}

// ============ ExecutionService ============

export class ExecutionService {
  private static instance: ExecutionService | null = null;

  private deps: ExecutionDeps;
  private schemaReady: Promise<void> | null = null;

  /** 当前运行中任务标识（单例控制，spec 4.1.5） */
  private currentTaskId: string | null = null;
  /** 当前任务的取消令牌 */
  private currentToken: CancellationTokenImpl | null = null;
  /** 当前任务的后台任务句柄 */
  private currentBgHandle: BackgroundTaskHandle | null = null;
  /** 网络监听取消订阅句柄 */
  private networkUnsub: Unsubscribe | null = null;
  /** 超时定时器 ID */
  private timeoutTimerId: number = -1;

  /** 内存态进度 */
  private progress: ExecutionProgress | null = null;
  /** 观察者列表 */
  private observers: ObserverEntry[] = [];
  /** 流式组装器 */
  private streamAssembler: StreamAssembler = new StreamAssembler();
  /** 判定策略 */
  private judgeStrategy: JudgeStrategy = new DefaultJudgeStrategy();
  /** 累积用量 */
  private accumulatedUsage: UsageSummary = { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
  /** 已完成的用例结果（内存态） */
  private completedResults: CaseResult[] = [];
  /** 任务开始时间 */
  private startedAt: number = 0;
  /** 是否正在调度循环中（防止重入） */
  private scheduling: boolean = false;

  private constructor(deps: ExecutionDeps) {
    this.deps = deps;
  }

  static getInstance(): ExecutionService {
    if (ExecutionService.instance === null) {
      const container: AppContainer = AppContainer.getInstance();
      ExecutionService.instance = new ExecutionService({
        store: container.store(),
        modelClient: container.modelClient(),
        network: container.networkMonitor(),
        backgroundTask: container.backgroundTask(),
        notification: container.notification(),
        logger: container.logger(),
        getConfig: (configId: string): Promise<ModelServiceConfig> =>
          ServiceConfigService.getInstance().getConfig(configId),
        revealSecret: (configId: string): Promise<string> =>
          ServiceConfigService.getInstance().revealSecret(configId),
        getTask: (taskId: string): Promise<EvaluationTask> =>
          TaskConfigService.getInstance().getTask(taskId),
        archiveProvider: (input: RunRecordArchiveInput): Promise<string> => {
          // 跨模块契约：RunRecordService 尚未实现，暂返回占位 ID
          return Promise.resolve(newId('rec'));
        },
        notificationEnabledProvider: (): Promise<boolean> => {
          // 跨模块契约：AppSettingsService 尚未实现，暂默认开启
          return Promise.resolve(true);
        },
        metricsProvider: (cases: CaseResult[], usage?: UsageSummary): Metrics => {
          // 跨模块契约：MetricCalculator 尚未实现，暂返回占位指标
          const placeholderUsage: UsageSummary = usage ?? { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
          const metrics: Metrics = {
            accuracy: null,
            passRate: null,
            avgElapsedMs: null,
            usage: placeholderUsage,
            computed: false
          };
          return metrics;
        }
      });
    }
    return ExecutionService.instance;
  }

  static createForTest(deps: ExecutionDeps): ExecutionService {
    return new ExecutionService(deps);
  }

  private ensureInit(): Promise<void> {
    if (this.schemaReady === null) {
      this.schemaReady = ensureSchema(this.deps.store);
    }
    return this.schemaReady;
  }

  // ============ 对外接口 ============

  async start(taskId: string): Promise<void> {
    await this.ensureInit();

    if (this.hasRunningTask()) {
      throw new AppError(ErrorCode.TASK_ALREADY_RUNNING, '已有任务正在运行');
    }

    const task: EvaluationTask = await this.deps.getTask(taskId);
    const config: ModelServiceConfig = await this.deps.getConfig(task.configId);

    // 前置校验：连通性
    const secret: string = await this.deps.revealSecret(task.configId);
    const probeResult = await this.deps.modelClient.probe(config, secret);
    if (!probeResult.success) {
      throw new AppError(ErrorCode.CFG_CONNECT_FAILED, probeResult.reason);
    }

    // 前置校验：题目集可用数 > 0
    const dataset: DatasetSnapshot | undefined = task.dataset;
    if (dataset === undefined || dataset.cases.length === 0) {
      throw new AppError(ErrorCode.TASK_NO_VALID_CASE, '题目集无可用题目');
    }

    // 申请后台长时任务
    this.currentBgHandle = await this.deps.backgroundTask.acquire();

    // 初始化内存态
    this.currentTaskId = taskId;
    this.currentToken = new CancellationTokenImpl();
    this.completedResults = [];
    this.accumulatedUsage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
    this.startedAt = nowMs();
    this.scheduling = false;

    const totalCount: number = dataset.cases.length;
    this.progress = {
      taskId: taskId,
      status: TaskStatus.RUNNING,
      flag: ExecutionFlag.EXECUTING,
      completedCount: 0,
      totalCount: totalCount,
      watermarkSeq: -1,
      streamingText: ''
    };

    // 创建 task_progress 骨架并更新任务状态
    await this.persistProgressSkeleton(taskId, totalCount);
    await this.updateTaskStatus(taskId, TaskStatus.RUNNING, ExecutionFlag.EXECUTING);

    // 订阅网络状态
    this.subscribeNetwork(taskId);

    this.deps.logger.log(LogLevel.INFO, LogEvent.TASK_START,
      `启动评测任务 id=${taskId} name=${task.name} targetModel=${config.targetModel} cases=${totalCount}`);

    // 进入串行调度
    this.runScheduleLoop(taskId, task, config, secret).catch((e: Object): void => {
      this.handleScheduleError(taskId, e);
    });
  }

  async pause(taskId: string): Promise<void> {
    if (this.currentTaskId !== taskId) {
      return;
    }
    if (this.currentToken !== null) {
      this.currentToken.cancel();
    }
    this.clearTimeoutTimer();

    if (this.progress !== null) {
      this.progress.flag = ExecutionFlag.PAUSED;
    }
    await this.updateTaskStatus(taskId, TaskStatus.RUNNING, ExecutionFlag.PAUSED);
    await this.persistProgress(taskId);

    this.notifyInterrupted(taskId, InterruptReason.USER_PAUSED);
    this.deps.logger.log(LogLevel.INFO, LogEvent.PAUSE, `暂停任务 id=${taskId}`);
  }

  async resume(taskId: string): Promise<void> {
    if (this.currentTaskId !== taskId) {
      return;
    }

    // 网络不可用时拒绝恢复
    const netState: NetworkState = this.deps.network.current();
    if (!netState.available) {
      throw new AppError(ErrorCode.NET_UNAVAILABLE, '当前无可用网络');
    }

    if (this.progress !== null) {
      this.progress.flag = ExecutionFlag.EXECUTING;
    }
    await this.updateTaskStatus(taskId, TaskStatus.RUNNING, ExecutionFlag.EXECUTING);

    // 由 ResumePlanner 定位首个未完成 seq
    const task: EvaluationTask = await this.deps.getTask(taskId);
    const config: ModelServiceConfig = await this.deps.getConfig(task.configId);
    const secret: string = await this.deps.revealSecret(task.configId);

    this.deps.logger.log(LogLevel.INFO, LogEvent.RESUME, `恢复任务 id=${taskId}`);

    // 重新进入调度循环
    this.runScheduleLoop(taskId, task, config, secret).catch((e: Object): void => {
      this.handleScheduleError(taskId, e);
    });
  }

  async terminate(taskId: string): Promise<void> {
    if (this.currentTaskId !== taskId) {
      return;
    }
    if (this.currentToken !== null) {
      this.currentToken.cancel();
    }
    this.clearTimeoutTimer();
    this.unsubscribeNetwork();

    if (this.progress !== null) {
      this.progress.status = TaskStatus.TERMINATED;
    }
    await this.updateTaskStatus(taskId, TaskStatus.TERMINATED, ExecutionFlag.EXECUTING);

    // 归档已执行结果
    await this.archiveTask(taskId, RunRecordStatus.TERMINATED);

    // 释放后台任务
    await this.releaseBackgroundTask();

    this.deps.logger.log(LogLevel.INFO, LogEvent.TERMINATE, `终止任务 id=${taskId}`);

    this.notifyFinished(taskId);
    this.cleanupTask();
  }

  subscribe(taskId: string, observer: ExecutionObserver): Unsubscribe {
    this.observers.push({ taskId: taskId, observer: observer });
    return (): void => {
      for (let i = 0; i < this.observers.length; i++) {
        if (this.observers[i].taskId === taskId && this.observers[i].observer === observer) {
          this.observers.splice(i, 1);
          break;
        }
      }
    };
  }

  getProgress(taskId: string): ExecutionProgress {
    if (this.progress !== null && this.progress.taskId === taskId) {
      return this.progress;
    }
    const defaultProgress: ExecutionProgress = {
      taskId: taskId,
      status: TaskStatus.PENDING,
      flag: ExecutionFlag.EXECUTING,
      completedCount: 0,
      totalCount: 0,
      watermarkSeq: -1,
      streamingText: ''
    };
    return defaultProgress;
  }

  hasRunningTask(): boolean {
    return this.currentTaskId !== null;
  }

  runningTaskId(): string | undefined {
    return this.currentTaskId === null ? undefined : this.currentTaskId;
  }

  async recoverPending(): Promise<EvaluationTask | undefined> {
    await this.ensureInit();
    const spec: QuerySpec = {
      sql: SQL_QUERY_RUNNING_TASKS,
      args: [TaskStatus.RUNNING]
    };
    const rows: Object[] = await this.deps.store.query<Object>(spec);
    if (rows.length === 0) {
      return undefined;
    }
    // 返回第一个残留 RUNNING 任务供页面提示续跑
    const firstRow: Record<string, string> = rows[0] as Record<string, string>;
    const taskId: string = firstRow['task_id'];
    return this.deps.getTask(taskId);
  }

  // ============ 串行调度循环 ============

  private async runScheduleLoop(
    taskId: string,
    task: EvaluationTask,
    config: ModelServiceConfig,
    secret: string
  ): Promise<void> {
    if (this.scheduling) {
      return;
    }
    this.scheduling = true;

    try {
      const dataset: DatasetSnapshot | undefined = task.dataset;
      if (dataset === undefined) {
        throw new AppError(ErrorCode.TASK_NO_VALID_CASE, '题目集快照缺失');
      }

      const cases: CaseSnapshot[] = dataset.cases;
      const params: RunParameters = task.params;

      // 读取已持久化的水位线
      const watermark: number = await this.loadWatermark(taskId);
      const startSeq: number = ResumePlanner.firstUncompletedSeq(watermark);

      const caseScheduler: CaseScheduler = new CaseScheduler(this.streamAssembler, this.judgeStrategy);

      for (let i = 0; i < cases.length; i++) {
        const caseSnapshot: CaseSnapshot = cases[i];

        // 跳过已完成用例（seq <= watermark）
        if (caseSnapshot.seq < startSeq) {
          continue;
        }

        // 检查是否被暂停/终止
        if (this.currentToken === null || this.currentToken.cancelled) {
          break;
        }
        if (this.progress !== null && this.progress.flag === ExecutionFlag.PAUSED) {
          break;
        }

        // 构造 ChatRequest
        const messages: ChatMessage[] = [
          { role: 'user', content: caseSnapshot.content }
        ];
        const request: ChatRequest = {
          endpoint: config.endpoint,
          targetModel: config.targetModel,
          secret: secret,
          messages: messages,
          temperature: params.temperature,
          maxOutputTokens: params.maxOutputTokens,
          stream: true
        };

        // 设置超时定时器
        this.setupTimeout(params.timeoutMs);

        // 流式片段回调：仅追加内存缓冲并推送进度
        const onChunk: (chunk: ChatChunk) => void = (chunk: ChatChunk): void => {
          this.streamAssembler.append(chunk.delta);
          if (this.progress !== null) {
            this.progress.streamingText = this.streamAssembler.current();
            this.notifyProgress(taskId);
          }
        };

        try {
          const result = await caseScheduler.executeCase(
            caseSnapshot,
            request,
            this.deps.modelClient,
            this.currentToken!,
            onChunk,
            params.judgeMode,
            taskId
          );

          this.clearTimeoutTimer();

          // 累积用量
          this.accumulatedUsage.promptTokens += result.usage.promptTokens;
          this.accumulatedUsage.completionTokens += result.usage.completionTokens;
          this.accumulatedUsage.totalTokens += result.usage.totalTokens;

          // 持久化：case_result + task_progress 在同一事务内提交
          await this.persistCaseResultAndProgress(taskId, result.caseResult);

          // 更新内存态进度
          this.completedResults.push(result.caseResult);
          if (this.progress !== null) {
            this.progress.completedCount += 1;
            this.progress.watermarkSeq = caseSnapshot.seq;
            this.progress.streamingText = '';
          }

          this.notifyCaseFinished(taskId, result.caseResult);
          this.notifyProgress(taskId);

          this.deps.logger.log(LogLevel.INFO, LogEvent.CASE_FINISHED,
            `用例完成 task=${taskId} seq=${caseSnapshot.seq} verdict=${result.caseResult.verdict} elapsed=${result.caseResult.elapsedMs}ms`);
        } catch (e) {
          this.clearTimeoutTimer();

          // 限流达重试上限：暂停任务
          if (e instanceof AppError && e.detail.includes('RATE_LIMITED_MAX_RETRY')) {
            if (this.progress !== null) {
              this.progress.flag = ExecutionFlag.PAUSED;
            }
            await this.updateTaskStatus(taskId, TaskStatus.RUNNING, ExecutionFlag.PAUSED);
            await this.persistProgress(taskId);
            this.notifyInterrupted(taskId, InterruptReason.RATE_LIMITED);
            this.deps.logger.log(LogLevel.WARN, LogEvent.PAUSE,
              `限流达重试上限，暂停任务 id=${taskId} seq=${caseSnapshot.seq}`);
            break;
          }

          throw new AppError(ErrorCode.UNKNOWN_ERROR, `用例执行异常: ${e}`);
        }
      }

      // 调度循环结束：检查是否全部完成
      if (this.progress !== null && this.progress.flag === ExecutionFlag.EXECUTING) {
        await this.completeTask(taskId);
      }
    } finally {
      this.scheduling = false;
    }
  }

  // ============ 终态处理 ============

  private async completeTask(taskId: string): Promise<void> {
    if (this.progress !== null) {
      this.progress.status = TaskStatus.COMPLETED;
    }
    await this.updateTaskStatus(taskId, TaskStatus.COMPLETED, ExecutionFlag.EXECUTING);

    // 计算汇总指标
    const metrics: Metrics = this.deps.metricsProvider(this.completedResults, this.accumulatedUsage);

    // 归档运行记录
    await this.archiveTask(taskId, RunRecordStatus.COMPLETED);

    // 释放后台任务
    await this.releaseBackgroundTask();
    this.unsubscribeNetwork();

    // 推送通知（若开启）
    await this.publishCompletionNotification(taskId);

    this.deps.logger.log(LogLevel.INFO, LogEvent.ARCHIVE,
      `任务完成并归档 id=${taskId} completed=${this.completedResults.length}`);

    this.notifyFinished(taskId);
    this.cleanupTask();
  }

  private async archiveTask(taskId: string, status: RunRecordStatus): Promise<void> {
    const task: EvaluationTask = await this.deps.getTask(taskId);
    const targetModel: string = task.snapshot !== undefined ? task.snapshot.targetModel : '';
    const datasetUri: string = task.datasetUri;
    const endedAt: number = nowMs();

    const input: RunRecordArchiveInput = {
      taskId: taskId,
      taskName: task.name,
      targetModel: targetModel,
      status: status,
      startedAt: this.startedAt,
      endedAt: endedAt,
      datasetUri: datasetUri,
      modelVersion: MODEL_VERSION,
      caseResults: this.completedResults,
      usage: this.accumulatedUsage
    };

    await this.deps.archiveProvider(input);
  }

  private async publishCompletionNotification(taskId: string): Promise<void> {
    const enabled: boolean = await this.deps.notificationEnabledProvider();
    if (!enabled) {
      return;
    }
    const authorized: boolean = await this.deps.notification.isAuthorized();
    if (!authorized) {
      return;
    }
    const task: EvaluationTask = await this.deps.getTask(taskId);
    const title: string = '评测任务完成';
    const text: string = `任务「${this.deps.logger.redact(task.name)}」已完成 ${this.completedResults.length} 个用例`;
    await this.deps.notification.publish({
      id: Date.now(),
      title: this.deps.logger.redact(title),
      text: text
    });
  }

  // ============ 网络中断处理 ============

  private subscribeNetwork(taskId: string): void {
    this.networkUnsub = this.deps.network.onChanged((state: NetworkState): void => {
      if (!state.available && this.currentTaskId === taskId) {
        if (this.currentToken !== null) {
          this.currentToken.cancel();
        }
        this.clearTimeoutTimer();
        if (this.progress !== null) {
          this.progress.flag = ExecutionFlag.PAUSED;
        }
        this.updateTaskStatus(taskId, TaskStatus.RUNNING, ExecutionFlag.PAUSED)
          .then((): Promise<void> => this.persistProgress(taskId))
          .then((): void => {
            this.notifyInterrupted(taskId, InterruptReason.NETWORK_LOST);
            this.deps.logger.log(LogLevel.WARN, LogEvent.PAUSE,
              `网络中断，暂停任务 id=${taskId}`);
          });
      }
    });
  }

  private unsubscribeNetwork(): void {
    if (this.networkUnsub !== null) {
      this.networkUnsub();
      this.networkUnsub = null;
    }
  }

  // ============ 超时处理 ============

  private setupTimeout(timeoutMs: number): void {
    this.clearTimeoutTimer();
    this.timeoutTimerId = setTimeout((): void => {
      if (this.currentToken !== null && !this.currentToken.cancelled) {
        this.currentToken.cancel();
      }
    }, timeoutMs);
  }

  private clearTimeoutTimer(): void {
    if (this.timeoutTimerId !== -1) {
      clearTimeout(this.timeoutTimerId);
      this.timeoutTimerId = -1;
    }
  }

  // ============ 持久化 ============

  private async persistProgressSkeleton(taskId: string, totalCount: number): Promise<void> {
    const spec: ExecSpec = {
      sql: SQL_UPSERT_TASK_PROGRESS,
      args: [taskId, -1, 0, totalCount, -1, 0]
    };
    await this.deps.store.execute(spec);
  }

  private async persistProgress(taskId: string): Promise<void> {
    if (this.progress === null) {
      return;
    }
    const spec: ExecSpec = {
      sql: `UPDATE ${TABLE_TASK_PROGRESS} SET watermark_seq=?, completed_count=? WHERE task_id=?`,
      args: [this.progress.watermarkSeq, this.progress.completedCount, taskId]
    };
    await this.deps.store.execute(spec);
  }

  /** case_result + task_progress 在同一事务内提交（design.md 2.1.3(3)） */
  private async persistCaseResultAndProgress(taskId: string, caseResult: CaseResult): Promise<void> {
    await this.deps.store.transaction(async (tx: TxContext): Promise<void> => {
      await tx.execute({
        sql: SQL_INSERT_CASE_RESULT,
        args: [
          caseResult.caseId, caseResult.taskId, caseResult.seq,
          caseResult.content, caseResult.referenceAnswer,
          caseResult.modelAnswer, caseResult.verdict, caseResult.elapsedMs
        ]
      });
      await tx.execute({
        sql: `UPDATE ${TABLE_TASK_PROGRESS} SET watermark_seq=?, completed_count=? WHERE task_id=?`,
        args: [caseResult.seq, this.progress !== null ? this.progress.completedCount + 1 : 1, taskId]
      });
    });
  }

  private async loadWatermark(taskId: string): Promise<number> {
    const spec: QuerySpec = {
      sql: SQL_QUERY_TASK_PROGRESS,
      args: [taskId]
    };
    const rows: ProgressRow[] = await this.deps.store.query<ProgressRow>(spec);
    if (rows.length === 0) {
      return -1;
    }
    return rows[0].watermark_seq;
  }

  private async updateTaskStatus(taskId: string, status: TaskStatus, flag: ExecutionFlag): Promise<void> {
    const spec: ExecSpec = {
      sql: SQL_UPDATE_TASK_STATUS,
      args: [status, flag, taskId]
    };
    await this.deps.store.execute(spec);
  }

  // ============ 观察者通知 ============

  private notifyProgress(taskId: string): void {
    if (this.progress === null) {
      return;
    }
    for (let i = 0; i < this.observers.length; i++) {
      if (this.observers[i].taskId === taskId) {
        this.observers[i].observer.onProgress(this.progress);
      }
    }
  }

  private notifyCaseFinished(taskId: string, result: CaseResult): void {
    for (let i = 0; i < this.observers.length; i++) {
      if (this.observers[i].taskId === taskId) {
        this.observers[i].observer.onCaseFinished(result);
      }
    }
  }

  private notifyFinished(taskId: string): void {
    for (let i = 0; i < this.observers.length; i++) {
      if (this.observers[i].taskId === taskId) {
        this.observers[i].observer.onFinished('');
      }
    }
  }

  private notifyInterrupted(taskId: string, reason: InterruptReason): void {
    for (let i = 0; i < this.observers.length; i++) {
      if (this.observers[i].taskId === taskId) {
        this.observers[i].observer.onInterrupted(reason);
      }
    }
  }

  // ============ 错误处理与清理 ============

  private handleScheduleError(taskId: string, e: Object): void {
    const err: AppError = asAppError(e, ErrorCode.TASK_ALREADY_RUNNING);
    this.deps.logger.log(LogLevel.ERROR, LogEvent.ERROR,
      `调度异常 task=${taskId} code=${err.code} detail=${err.detail}`);

    if (this.progress !== null) {
      this.progress.status = TaskStatus.FAILED;
    }
    this.updateTaskStatus(taskId, TaskStatus.FAILED, ExecutionFlag.EXECUTING)
      .then((): Promise<void> => this.archiveTask(taskId, RunRecordStatus.FAILED))
      .then((): Promise<void> => this.releaseBackgroundTask())
      .then((): void => {
        this.unsubscribeNetwork();
        this.cleanupTask();
      });
  }

  private async releaseBackgroundTask(): Promise<void> {
    if (this.currentBgHandle !== null) {
      await this.deps.backgroundTask.release(this.currentBgHandle);
      this.currentBgHandle = null;
    }
  }

  private cleanupTask(): void {
    this.currentTaskId = null;
    this.currentToken = null;
    this.progress = null;
    this.completedResults = [];
    this.accumulatedUsage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
    this.streamAssembler.reset();
    this.clearTimeoutTimer();
  }
}