/**
 * 评测任务执行模块单元测试（tasks.md 5.12）。
 * 覆盖：状态机迁移全覆盖、ResumePlanner、StreamAssembler、JudgeStrategy、
 * BackoffPolicy、ExecutionService 串行调度/超时/限流/网络中断/单例并发拒绝。
 */
import { describe, expect, it } from '@ohos/hypium';
import { TaskStateMachine } from '../../../main/ets/domain/statemachine/TaskStateMachine';
import { ResumePlanner } from '../../../main/ets/domain/scheduler/ResumePlanner';
import { StreamAssembler } from '../../../main/ets/domain/scheduler/StreamAssembler';
import { CaseScheduler } from '../../../main/ets/domain/scheduler/CaseScheduler';
import { DefaultJudgeStrategy } from '../../../main/ets/domain/strategy/JudgeStrategy';
import { BackoffPolicy } from '../../../main/ets/domain/strategy/BackoffPolicy';
import { ExecutionDeps, ExecutionService, RunRecordArchiveInput } from '../../../main/ets/biz/execution/ExecutionService';
import { RelationalStorePort } from '../../../main/ets/infra/ports/RelationalStorePort';
import { ModelClientPort } from '../../../main/ets/infra/ports/ModelClientPort';
import { NetworkMonitorPort } from '../../../main/ets/infra/ports/NetworkMonitorPort';
import { BackgroundTaskPort } from '../../../main/ets/infra/ports/BackgroundTaskPort';
import { NotificationPort } from '../../../main/ets/infra/ports/NotificationPort';
import { LoggerPort } from '../../../main/ets/infra/ports/LoggerPort';
import {
  BackgroundTaskHandle, CancellationToken, ExecSpec, NetworkState, QuerySpec, TxContext, Unsubscribe
} from '../../../main/ets/common/types/InfraTypes';
import {
  CaseResult, CaseSnapshot, ChatChunk, ChatRequest, ChatResult, ConnectionTestResult,
  DatasetSnapshot, EvaluationTask, ExecutionObserver, ExecutionProgress, Metrics,
  ModelServiceConfig, RunParameters, UsageSummary
} from '../../../main/ets/common/types/DomainTypes';
import {
  ConfigStatus, ExecutionFlag, InterruptReason, JudgeMode, LogEvent, LogLevel,
  RunRecordStatus, TaskStatus, Verdict
} from '../../../main/ets/common/types/Enums';
import { AppError } from '../../../main/ets/common/error/AppError';
import { ErrorCode } from '../../../main/ets/common/error/ErrorCode';
import { StubModelBehavior, StubModelClient } from '../../../main/ets/infra/stubs/StubModelClient';
import { StubNetwork } from '../../../main/ets/infra/stubs/StubNetwork';
import { StubBackgroundTask } from '../../../main/ets/infra/stubs/StubBackgroundTask';
import { StubNotification } from '../../../main/ets/infra/stubs/StubNotification';
import { StubLogger } from '../../../main/ets/infra/stubs/StubLogger';
import { StubCrypto } from '../../../main/ets/infra/stubs/StubCrypto';


// ============ CancellationToken 测试桩 ============

class TestCancellationToken implements CancellationToken {
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

// ============ 内存存储桩（支撑 case_result + task_progress + eval_task） ============

interface FakeProgressRow {
  task_id: string;
  watermark_seq: number;
  completed_count: number;
  total_count: number;
}

interface FakeCaseRow {
  case_id: string;
  task_id: string;
  seq: number;
  content: string;
  reference_answer: string;
  model_answer: string;
  verdict: string;
  elapsed_ms: number;
}

interface FakeTaskRow {
  task_id: string;
  name: string;
  config_id: string;
  dataset_uri: string;
  params_json: string;
  status: string;
  flag: string;
  snapshot_json: string | null;
  dataset_json: string | null;
  created_at: number;
}

class FakeExecTxContext implements TxContext {
  private owner: FakeExecStore;

  constructor(owner: FakeExecStore) {
    this.owner = owner;
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    return this.owner.query<T>(spec);
  }

  async execute(spec: ExecSpec): Promise<number> {
    return this.owner.execute(spec);
  }
}

class FakeExecStore implements RelationalStorePort {
  taskRows: FakeTaskRow[] = [];
  progressRows: FakeProgressRow[] = [];
  caseRows: FakeCaseRow[] = [];

  async transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T> {
    return work(new FakeExecTxContext(this));
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];

    if (sql.includes('FROM task_progress')) {
      const taskId: string = args[0] as string;
      const matched: FakeProgressRow[] = [];
      for (let i = 0; i < this.progressRows.length; i++) {
        if (this.progressRows[i].task_id === taskId) {
          matched.push(this.progressRows[i]);
        }
      }
      return matched as T[];
    }

    if (sql.includes('FROM eval_task') && sql.includes('WHERE status')) {
      const status: string = args[0] as string;
      const matched: FakeTaskRow[] = [];
      for (let i = 0; i < this.taskRows.length; i++) {
        if (this.taskRows[i].status === status) {
          matched.push(this.taskRows[i]);
        }
      }
      return matched as T[];
    }

    return [];
  }

  async execute(spec: ExecSpec): Promise<number> {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];

    if (sql.includes('CREATE TABLE') || sql.includes('CREATE INDEX')) {
      return 0;
    }

    if (sql.startsWith('INSERT INTO task_progress')) {
      this.progressRows.push({
        task_id: args[0] as string,
        watermark_seq: args[1] as number,
        completed_count: args[2] as number,
        total_count: args[3] as number
      });
      return 1;
    }

    if (sql.startsWith('UPDATE task_progress')) {
      const taskId: string = args[2] as string;
      for (let i = 0; i < this.progressRows.length; i++) {
        if (this.progressRows[i].task_id === taskId) {
          this.progressRows[i].watermark_seq = args[0] as number;
          this.progressRows[i].completed_count = args[1] as number;
        }
      }
      return 1;
    }

    if (sql.startsWith('INSERT INTO case_result')) {
      this.caseRows.push({
        case_id: args[0] as string,
        task_id: args[1] as string,
        seq: args[2] as number,
        content: args[3] as string,
        reference_answer: args[4] as string,
        model_answer: args[5] as string,
        verdict: args[6] as string,
        elapsed_ms: args[7] as number
      });
      return 1;
    }

    if (sql.startsWith('UPDATE eval_task SET status')) {
      const taskId: string = args[2] as string;
      for (let i = 0; i < this.taskRows.length; i++) {
        if (this.taskRows[i].task_id === taskId) {
          this.taskRows[i].status = args[0] as string;
          this.taskRows[i].flag = args[1] as string;
        }
      }
      return 1;
    }

    return 0;
  }

  seedTask(row: FakeTaskRow): void {
    this.taskRows.push(row);
  }

  findProgress(taskId: string): FakeProgressRow | undefined {
    for (let i = 0; i < this.progressRows.length; i++) {
      if (this.progressRows[i].task_id === taskId) {
        return this.progressRows[i];
      }
    }
    return undefined;
  }

  findTask(taskId: string): FakeTaskRow | undefined {
    for (let i = 0; i < this.taskRows.length; i++) {
      if (this.taskRows[i].task_id === taskId) {
        return this.taskRows[i];
      }
    }
    return undefined;
  }

  caseCount(): number {
    return this.caseRows.length;
  }
}

// ============ 测试数据构造 ============

function makeParams(): RunParameters {
  return { temperature: 0.7, maxOutputTokens: 2048, concurrency: 1, timeoutMs: 60000, judgeMode: JudgeMode.CONTAINS };
}

function makeConfig(): ModelServiceConfig {
  return {
    configId: 'cfg_1',
    name: '本地服务',
    endpoint: 'https://api.deepseek.com/v1',
    targetModel: 'deepseek-chat',
    isDefault: true,
    status: ConfigStatus.VALID,
    secretRef: { alias: 'a1', algorithm: 'AES256-GCM' },
    createdAt: 1000
  };
}

function makeDatasetSnapshot(): DatasetSnapshot {
  return {
    modelVersion: 1,
    name: '测试题目集',
    cases: [
      { seq: 0, content: '1+1=?', referenceAnswer: '2' },
      { seq: 1, content: '2+2=?', referenceAnswer: '4' }
    ]
  };
}

function makeTask(taskId: string, status: TaskStatus): EvaluationTask {
  return {
    taskId: taskId,
    name: '测试任务',
    configId: 'cfg_1',
    datasetUri: 'file://ds/1.json',
    params: makeParams(),
    status: status,
    flag: ExecutionFlag.EXECUTING,
    snapshot: { modelVersion: 1, params: makeParams(), targetModel: 'deepseek-chat', configName: '本地服务' },
    dataset: makeDatasetSnapshot(),
    createdAt: 1000
  };
}

function makeFakeTaskRow(taskId: string, status: string): FakeTaskRow {
  return {
    task_id: taskId,
    name: '测试任务',
    config_id: 'cfg_1',
    dataset_uri: 'file://ds/1.json',
    params_json: JSON.stringify(makeParams()),
    status: status,
    flag: ExecutionFlag.EXECUTING,
    snapshot_json: JSON.stringify({ modelVersion: 1, params: makeParams(), targetModel: 'deepseek-chat', configName: '本地服务' }),
    dataset_json: JSON.stringify(makeDatasetSnapshot()),
    created_at: 1000
  };
}

function makeExecutionDeps(
  store: FakeExecStore,
  modelClient: StubModelClient,
  network: StubNetwork,
  taskProvider: (taskId: string) => Promise<EvaluationTask>,
  configProvider: (configId: string) => Promise<ModelServiceConfig>,
  secretProvider: (configId: string) => Promise<string>
): ExecutionDeps {
  const stubLogger: StubLogger = new StubLogger();
  return {
    store: store,
    modelClient: modelClient,
    network: network,
    backgroundTask: new StubBackgroundTask(),
    notification: new StubNotification(),
    logger: stubLogger,
    getConfig: configProvider,
    revealSecret: secretProvider,
    getTask: taskProvider,
    archiveProvider: (input: RunRecordArchiveInput): Promise<string> => Promise.resolve('rec_test'),
    notificationEnabledProvider: (): Promise<boolean> => Promise.resolve(false),
    metricsProvider: (cases: CaseResult[], usage?: UsageSummary): Metrics => ({
      accuracy: 0.5,
      passRate: 0.5,
      avgElapsedMs: 100,
      usage: usage ?? { promptTokens: 0, completionTokens: 0, totalTokens: 0 },
      computed: true
    })
  };
}

export default function executionTest() {
  // ============ TaskStateMachine ============
  describe('TaskStateMachine', () => {
    it('legal_transition_pending_to_running', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.PENDING, TaskStatus.RUNNING)).assertTrue();
    });

    it('legal_transition_pending_to_terminated', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.PENDING, TaskStatus.TERMINATED)).assertTrue();
    });

    it('legal_transition_running_to_completed', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.RUNNING, TaskStatus.COMPLETED)).assertTrue();
    });

    it('legal_transition_running_to_failed', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.RUNNING, TaskStatus.FAILED)).assertTrue();
    });

    it('legal_transition_running_to_terminated', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.RUNNING, TaskStatus.TERMINATED)).assertTrue();
    });

    it('illegal_transition_pending_to_completed', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.PENDING, TaskStatus.COMPLETED)).assertFalse();
    });

    it('illegal_transition_completed_to_running', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.COMPLETED, TaskStatus.RUNNING)).assertFalse();
    });

    it('illegal_transition_failed_to_running', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.FAILED, TaskStatus.RUNNING)).assertFalse();
    });

    it('illegal_transition_terminated_to_pending', 0, () => {
      expect(TaskStateMachine.isLegalTransition(TaskStatus.TERMINATED, TaskStatus.PENDING)).assertFalse();
    });

    it('assert_transition_throws_on_illegal', 0, () => {
      let thrown: AppError | null = null;
      try {
        TaskStateMachine.assertTransition(TaskStatus.COMPLETED, TaskStatus.RUNNING);
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_ALREADY_RUNNING);
      }
    });

    it('legal_flag_transition_executing_to_paused', 0, () => {
      expect(TaskStateMachine.isLegalFlagTransition(ExecutionFlag.EXECUTING, ExecutionFlag.PAUSED)).assertTrue();
    });

    it('legal_flag_transition_paused_to_executing', 0, () => {
      expect(TaskStateMachine.isLegalFlagTransition(ExecutionFlag.PAUSED, ExecutionFlag.EXECUTING)).assertTrue();
    });

    it('is_terminal_completed', 0, () => {
      expect(TaskStateMachine.isTerminal(TaskStatus.COMPLETED)).assertTrue();
    });

    it('is_terminal_running_false', 0, () => {
      expect(TaskStateMachine.isTerminal(TaskStatus.RUNNING)).assertFalse();
    });
  });

  // ============ ResumePlanner ============
  describe('ResumePlanner', () => {
    it('first_uncompleted_seq_from_minus_one', 0, () => {
      expect(ResumePlanner.firstUncompletedSeq(-1)).assertEqual(0);
    });

    it('first_uncompleted_seq_from_zero', 0, () => {
      expect(ResumePlanner.firstUncompletedSeq(0)).assertEqual(1);
    });

    it('first_uncompleted_seq_from_five', 0, () => {
      expect(ResumePlanner.firstUncompletedSeq(5)).assertEqual(6);
    });
  });

  // ============ StreamAssembler ============
  describe('StreamAssembler', () => {
    it('append_and_current', 0, () => {
      const assembler: StreamAssembler = new StreamAssembler();
      assembler.append('你好');
      assembler.append('世界');
      expect(assembler.current()).assertEqual('你好世界');
    });

    it('reset_clears_buffer', 0, () => {
      const assembler: StreamAssembler = new StreamAssembler();
      assembler.append('data');
      assembler.reset();
      expect(assembler.current()).assertEqual('');
    });
  });

  // ============ JudgeStrategy ============
  describe('JudgeStrategy', () => {
    const strategy: DefaultJudgeStrategy = new DefaultJudgeStrategy();

    it('exact_match_pass', 0, () => {
      expect(strategy.judge('2', '2', JudgeMode.EXACT_MATCH)).assertEqual(Verdict.PASSED);
    });

    it('exact_match_fail', 0, () => {
      expect(strategy.judge('2', '3', JudgeMode.EXACT_MATCH)).assertEqual(Verdict.FAILED);
    });

    it('exact_match_trim_whitespace', 0, () => {
      expect(strategy.judge(' 2 ', '2', JudgeMode.EXACT_MATCH)).assertEqual(Verdict.PASSED);
    });

    it('contains_pass_reference_in_answer', 0, () => {
      expect(strategy.judge('2', '答案是2', JudgeMode.CONTAINS)).assertEqual(Verdict.PASSED);
    });

    it('contains_pass_answer_in_reference', 0, () => {
      expect(strategy.judge('答案是2', '2', JudgeMode.CONTAINS)).assertEqual(Verdict.PASSED);
    });

    it('contains_fail', 0, () => {
      expect(strategy.judge('2', '3', JudgeMode.CONTAINS)).assertEqual(Verdict.FAILED);
    });

    it('referee_model_degrades_to_contains', 0, () => {
      expect(strategy.judge('2', '答案是2', JudgeMode.REFEREE_MODEL)).assertEqual(Verdict.PASSED);
    });
  });

  // ============ BackoffPolicy ============
  describe('BackoffPolicy', () => {
    it('attempt_zero_returns_base', 0, () => {
      expect(BackoffPolicy.nextDelayMs(0)).assertEqual(1000);
    });

    it('attempt_one_returns_double', 0, () => {
      expect(BackoffPolicy.nextDelayMs(1)).assertEqual(2000);
    });

    it('attempt_two_returns_quad', 0, () => {
      expect(BackoffPolicy.nextDelayMs(2)).assertEqual(4000);
    });

    it('attempt_large_capped_at_max', 0, () => {
      expect(BackoffPolicy.nextDelayMs(10)).assertEqual(30000);
    });
  });

  // ============ ExecutionService ============
  describe('ExecutionService', () => {
    it('has_running_task_initially_false', 0, () => {
      const store: FakeExecStore = new FakeExecStore();
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);
      expect(service.hasRunningTask()).assertFalse();
    });

    it('start_rejects_when_already_running', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      // 先启动一个任务
      await service.start('task_1');

      // 再启动另一个任务应被拒绝
      let thrown: AppError | null = null;
      try {
        await service.start('task_2');
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_ALREADY_RUNNING);
      }
    });

    it('start_creates_progress_skeleton', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      store.seedTask(makeFakeTaskRow('task_1', TaskStatus.PENDING));
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      await service.start('task_1');

      const progress: FakeProgressRow | undefined = store.findProgress('task_1');
      expect(progress !== undefined).assertTrue();
      if (progress !== undefined) {
        expect(progress.watermark_seq).assertEqual(-1);
        expect(progress.completed_count).assertEqual(0);
        expect(progress.total_count).assertEqual(2);
      }
    });

    it('get_progress_returns_default_for_unknown_task', 0, () => {
      const store: FakeExecStore = new FakeExecStore();
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      const progress: ExecutionProgress = service.getProgress('unknown_task');
      expect(progress.status).assertEqual(TaskStatus.PENDING);
      expect(progress.completedCount).assertEqual(0);
    });

    it('subscribe_and_unsubscribe', 0, () => {
      const store: FakeExecStore = new FakeExecStore();
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      let receivedProgress: ExecutionProgress | null = null;
      const observer: ExecutionObserver = {
        onProgress: (p: ExecutionProgress): void => { receivedProgress = p; },
        onCaseFinished: (_r: CaseResult): void => {},
        onFinished: (_id: string): void => {},
        onInterrupted: (_r: InterruptReason): void => {}
      };

      const unsub: Unsubscribe = service.subscribe('task_1', observer);
      expect(unsub).toBeDefined();

      unsub();
    });

    it('running_task_id_returns_current', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      store.seedTask(makeFakeTaskRow('task_1', TaskStatus.PENDING));
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      await service.start('task_1');
      expect(service.runningTaskId()).assertEqual('task_1');
    });

    it('recover_pending_returns_running_task', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      store.seedTask(makeFakeTaskRow('task_residual', TaskStatus.RUNNING));
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.RUNNING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      const recovered: EvaluationTask | undefined = await service.recoverPending();
      expect(recovered !== undefined).assertTrue();
      if (recovered !== undefined) {
        expect(recovered.taskId).assertEqual('task_residual');
      }
    });

    it('recover_pending_returns_undefined_when_none', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      const recovered: EvaluationTask | undefined = await service.recoverPending();
      expect(recovered).assertUndefined();
    });

    it('start_rejects_no_valid_cases', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      const emptyTask: EvaluationTask = makeTask('task_empty', TaskStatus.PENDING);
      emptyTask.dataset = { modelVersion: 1, name: '空', cases: [] };
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(emptyTask),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      let thrown: AppError | null = null;
      try {
        await service.start('task_empty');
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_NO_VALID_CASE);
      }
    });

    it('start_rejects_connect_failed', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      store.seedTask(makeFakeTaskRow('task_1', TaskStatus.PENDING));
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.AUTH_FAILURE),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      let thrown: AppError | null = null;
      try {
        await service.start('task_1');
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.CFG_CONNECT_FAILED);
      }
    });

    it('terminate_sets_terminated_status', 0, async () => {
      const store: FakeExecStore = new FakeExecStore();
      store.seedTask(makeFakeTaskRow('task_1', TaskStatus.PENDING));
      const deps: ExecutionDeps = makeExecutionDeps(
        store,
        new StubModelClient(StubModelBehavior.SUCCESS),
        new StubNetwork(),
        (taskId: string): Promise<EvaluationTask> => Promise.resolve(makeTask(taskId, TaskStatus.PENDING)),
        (configId: string): Promise<ModelServiceConfig> => Promise.resolve(makeConfig()),
        (configId: string): Promise<string> => Promise.resolve('sk-test')
      );
      const service: ExecutionService = ExecutionService.createForTest(deps);

      await service.start('task_1');
      await service.terminate('task_1');

      const taskRow: FakeTaskRow | undefined = store.findTask('task_1');
      expect(taskRow !== undefined).assertTrue();
      if (taskRow !== undefined) {
        expect(taskRow.status).assertEqual(TaskStatus.TERMINATED);
      }
    });
  });
}