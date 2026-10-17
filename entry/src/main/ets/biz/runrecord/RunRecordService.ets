/**
 * 运行记录管理应用服务（spec 5.5，tasks.md 7）。
 * - 单例入口：RunRecordService.getInstance()
 * - 依赖：RelationalStorePort（run_record + case_result 表）、LoggerPort，
 *   跨模块契约 ExecutionService.hasRunningTask/runningTaskId、AppSettingsService.getSettings、
 *   MetricCalculator.compute。
 * - 初始化调用 ensureSchema(AppContainer.getInstance().store())。
 *
 * 业务规则（spec 5.5 / 6.4）：
 * - archive(input)：计算指标 → 检查记录上限 → 校验 endedAt >= startedAt → 写入 run_record 表 → 返回 recordId。
 * - listRecords(query)：按 nameKeyword(LIKE)、targetModel、status 组合查询；
 *   metrics_json 解析失败时 corrupted=true（降级展示）；列表查询不查 case_result。
 * - getRecord(id)：单条查询。
 * - removeRecords(ids)：删除前校验非运行中任务占用；级联清理 case_result（按 task_id）。
 * - clearAll()：清空 run_record 与 case_result；受运行中任务约束（由调用方拦截）。
 */
import { AppContainer } from '../../entrystage/AppContainer';
import { ensureSchema, TABLE_CASE_RESULT, TABLE_RUN_RECORD } from '../../infra/adapters/DbSchema';
import { RelationalStorePort } from '../../infra/ports/RelationalStorePort';
import { LoggerPort } from '../../infra/ports/LoggerPort';
import { ExecSpec, QuerySpec, TxContext } from '../../common/types/InfraTypes';
import { LogEvent, LogLevel, RunRecordStatus, Verdict } from '../../common/types/Enums';
import {
  CaseResult, Metrics, RunRecord, RunRecordQuery, UsageSummary
} from '../../common/types/DomainTypes';

import { AppError, asAppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { MODEL_VERSION } from '../../common/types/Constants';
import { newId } from '../../common/utils/IdGen';
import { MetricCalculator } from '../../domain/metric/MetricCalculator';

// ============ 对外接口类型 ============

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

// ============ 依赖注入 ============

export interface RunRecordDeps {
  store: RelationalStorePort;
  logger: LoggerPort;
  /** 获取记录上限（跨模块契约 AppSettingsService.getSettings().recordLimit） */
  recordLimitProvider: () => Promise<number>;
  /** 判断是否有运行中任务（跨模块契约 ExecutionService.hasRunningTask） */
  hasRunningTaskProvider: () => boolean;
  /** 获取运行中任务 ID（跨模块契约 ExecutionService.runningTaskId） */
  runningTaskIdProvider: () => string | undefined;
}

// ============ SQL 常量 ============

const SQL_INSERT_RUN_RECORD: string =
  `INSERT INTO ${TABLE_RUN_RECORD}(record_id, task_id, task_name, target_model, status, started_at, ended_at, model_version, dataset_uri, metrics_json) VALUES(?,?,?,?,?,?,?,?,?,?)`;

const SQL_QUERY_LIST: string =
  `SELECT record_id, task_id, task_name, target_model, status, started_at, ended_at, model_version, dataset_uri, metrics_json FROM ${TABLE_RUN_RECORD}`;

const SQL_QUERY_BY_ID: string =
  `SELECT record_id, task_id, task_name, target_model, status, started_at, ended_at, model_version, dataset_uri, metrics_json FROM ${TABLE_RUN_RECORD} WHERE record_id = ?`;

const SQL_COUNT_RUN_RECORD: string =
  `SELECT COUNT(*) AS cnt FROM ${TABLE_RUN_RECORD}`;

const SQL_DELETE_RUN_RECORD: string =
  `DELETE FROM ${TABLE_RUN_RECORD} WHERE record_id = ?`;

const SQL_DELETE_CASE_RESULT_BY_TASK: string =
  `DELETE FROM ${TABLE_CASE_RESULT} WHERE task_id = ?`;

const SQL_QUERY_TASK_ID_BY_RECORD: string =
  `SELECT task_id FROM ${TABLE_RUN_RECORD} WHERE record_id = ?`;

const SQL_CLEAR_RUN_RECORD: string =
  `DELETE FROM ${TABLE_RUN_RECORD}`;

const SQL_CLEAR_CASE_RESULT: string =
  `DELETE FROM ${TABLE_CASE_RESULT}`;

// ============ 行结构 ============

interface RunRecordRow {
  record_id: string;
  task_id: string;
  task_name: string;
  target_model: string;
  status: string;
  started_at: number;
  ended_at: number;
  model_version: number;
  dataset_uri: string | null;
  metrics_json: string;
}

interface CountRow {
  cnt: number;
}

interface TaskIdRow {
  task_id: string;
}

interface CaseResultRow {
  case_id: string;
  task_id: string;
  seq: number;
  content: string;
  reference_answer: string | null;
  model_answer: string | null;
  verdict: string;
  elapsed_ms: number;
}

// ============ 序列化与反序列化 ============

function serializeMetrics(metrics: Metrics): string {
  return JSON.stringify({
    accuracy: metrics.accuracy,
    passRate: metrics.passRate,
    avgElapsedMs: metrics.avgElapsedMs,
    usage: metrics.usage,
    computed: metrics.computed
  });
}

function deserializeMetrics(json: string): Metrics {
  const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
  const accuracyRaw: Object | undefined = parsed['accuracy'];
  const passRateRaw: Object | undefined = parsed['passRate'];
  const avgElapsedMsRaw: Object | undefined = parsed['avgElapsedMs'];
  const usageRaw: Object | undefined = parsed['usage'];
  const computedRaw: Object | undefined = parsed['computed'];

  const usage: UsageSummary = usageRaw !== undefined
    ? {
        promptTokens: (usageRaw as Record<string, number>)['promptTokens'] ?? 0,
        completionTokens: (usageRaw as Record<string, number>)['completionTokens'] ?? 0,
        totalTokens: (usageRaw as Record<string, number>)['totalTokens'] ?? 0
      }
    : { promptTokens: 0, completionTokens: 0, totalTokens: 0 };

  return {
    accuracy: accuracyRaw === null || accuracyRaw === undefined ? null : accuracyRaw as number,
    passRate: passRateRaw === null || passRateRaw === undefined ? null : passRateRaw as number,
    avgElapsedMs: avgElapsedMsRaw === null || avgElapsedMsRaw === undefined ? null : avgElapsedMsRaw as number,
    usage: usage,
    computed: computedRaw !== undefined ? computedRaw as boolean : false
  };
}

// ============ 行 → 领域对象 ============

function rowToRunRecord(row: RunRecordRow): RunRecord {
  let metrics: Metrics;
  let corrupted: boolean = false;
  try {
    metrics = deserializeMetrics(row.metrics_json);
  } catch (e) {
    corrupted = true;
    metrics = {
      accuracy: null, passRate: null, avgElapsedMs: null,
      usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 },
      computed: false
    };
  }
  return {
    recordId: row.record_id,
    taskId: row.task_id,
    taskName: row.task_name,
    targetModel: row.target_model,
    status: row.status as RunRecordStatus,
    startedAt: row.started_at,
    endedAt: row.ended_at,
    modelVersion: row.model_version,
    datasetUri: row.dataset_uri === null ? '' : row.dataset_uri,
    metrics: metrics,
    corrupted: corrupted
  };
}

// ============ RunRecordService ============

export class RunRecordService {
  private static instance: RunRecordService | null = null;

  private deps: RunRecordDeps;
  private schemaReady: Promise<void> | null = null;

  private constructor(deps: RunRecordDeps) {
    this.deps = deps;
  }

  static getInstance(): RunRecordService {
    if (RunRecordService.instance === null) {
      const container: AppContainer = AppContainer.getInstance();
      RunRecordService.instance = new RunRecordService({
        store: container.store(),
        logger: container.logger(),
        recordLimitProvider: async (): Promise<number> => {
          // 跨模块契约：AppSettingsService 尚未实现，暂返回默认上限
          return 1000;
        },
        hasRunningTaskProvider: (): boolean => {
          // 跨模块契约：ExecutionService 尚未实现，暂返回 false
          return false;
        },
        runningTaskIdProvider: (): string | undefined => {
          return undefined;
        }
      });
    }
    return RunRecordService.instance;
  }

  static createForTest(deps: RunRecordDeps): RunRecordService {
    return new RunRecordService(deps);
  }

  private ensureInit(): Promise<void> {
    if (this.schemaReady === null) {
      this.schemaReady = ensureSchema(this.deps.store);
    }
    return this.schemaReady;
  }

  // ============ 对外接口 ============

  /**
   * 归档运行记录（spec 5.5.1-1、6.4）。
   * 流程：计算指标 → 检查记录上限 → 校验 endedAt >= startedAt → 写入 run_record 表 → 返回 recordId。
   */
  async archive(input: RunRecordArchiveInput): Promise<string> {
    await this.ensureInit();

    // 计算指标（spec 5.4.1-1，以用例明细为唯一数据源）
    const metrics: Metrics = MetricCalculator.compute(input.caseResults, input.usage);

    // 检查记录上限（spec 5.5.1-4、6.4.7）
    const limit: number = await this.deps.recordLimitProvider();
    const countSpec: QuerySpec = { sql: SQL_COUNT_RUN_RECORD };
    const countRows: CountRow[] = await this.deps.store.query<CountRow>(countSpec);
    const currentCount: number = countRows.length > 0 ? countRows[0].cnt : 0;
    if (currentCount >= limit) {
      throw new AppError(ErrorCode.RECORD_LIMIT_REACHED, `当前 ${currentCount} 条，上限 ${limit} 条`);
    }

    // 校验 endedAt >= startedAt（spec 6.4.5）
    if (input.endedAt < input.startedAt) {
      throw new AppError(ErrorCode.RECORD_LIMIT_REACHED, '结束时间不得早于开始时间');
    }

    // 写入 run_record 表
    const recordId: string = newId('rec');
    const metricsJson: string = serializeMetrics(metrics);
    const insertSpec: ExecSpec = {
      sql: SQL_INSERT_RUN_RECORD,
      args: [
        recordId, input.taskId, input.taskName, input.targetModel,
        input.status, input.startedAt, input.endedAt, input.modelVersion,
        input.datasetUri, metricsJson
      ]
    };
    await this.deps.store.execute(insertSpec);

    this.deps.logger.log(LogLevel.INFO, LogEvent.ARCHIVE,
      `归档运行记录 id=${recordId} task=${input.taskName} status=${input.status}`);

    return recordId;
  }

  /**
   * 列表检索（spec 5.5.1-2）。
   * 按 nameKeyword(LIKE)、targetModel、status 组合查询；
   * metrics_json 解析失败时 corrupted=true（降级展示，spec 5.5.3-1）；
   * 列表查询避免整条加载超长模型输出（不查 case_result）。
   */
  async listRecords(query: RunRecordQuery): Promise<RunRecord[]> {
    await this.ensureInit();

    let sql: string = SQL_QUERY_LIST;
    const args: Array<string | number> = [];
    const conditions: string[] = [];

    if (query.nameKeyword !== undefined && query.nameKeyword.length > 0) {
      conditions.push('task_name LIKE ?');
      args.push(`%${query.nameKeyword}%`);
    }
    if (query.targetModel !== undefined && query.targetModel.length > 0) {
      conditions.push('target_model = ?');
      args.push(query.targetModel);
    }
    if (query.status !== undefined) {
      conditions.push('status = ?');
      args.push(query.status);
    }

    if (conditions.length > 0) {
      sql += ' WHERE ' + conditions.join(' AND ');
    }
    sql += ' ORDER BY started_at DESC';

    const spec: QuerySpec = { sql: sql, args: args };
    const rows: RunRecordRow[] = await this.deps.store.query<RunRecordRow>(spec);

    const records: RunRecord[] = [];
    for (let i = 0; i < rows.length; i++) {
      records.push(rowToRunRecord(rows[i]));
    }
    return records;
  }

  /**
   * 单条查询（spec 5.5）。
   */
  async getRecord(recordId: string): Promise<RunRecord> {
    await this.ensureInit();

    const spec: QuerySpec = { sql: SQL_QUERY_BY_ID, args: [recordId] };
    const rows: RunRecordRow[] = await this.deps.store.query<RunRecordRow>(spec);
    if (rows.length === 0) {
      throw new AppError(ErrorCode.RECORD_LIMIT_REACHED, '运行记录不存在');
    }
    return rowToRunRecord(rows[0]);
  }

  /**
   * 删除记录（spec 5.5.1-3、5.5.1-5）。
   * 删除前校验目标记录对应的任务非运行中——通过 hasRunningTask/runningTaskId 判断，
   * 若被占用 → AppError(RECORD_BUSY_CANNOT_DELETE)；
   * 删除时级联清理 case_result（按 task_id）。
   */
  async removeRecords(recordIds: string[]): Promise<void> {
    await this.ensureInit();

    if (recordIds.length === 0) {
      return;
    }

    // 校验是否有运行中任务占用（spec 5.5.1-5）
    if (this.deps.hasRunningTaskProvider()) {
      const runningTaskId: string | undefined = this.deps.runningTaskIdProvider();
      if (runningTaskId !== undefined) {
        // 查询待删除记录对应的 task_id，判断是否与运行中任务冲突
        for (let i = 0; i < recordIds.length; i++) {
          const taskIdSpec: QuerySpec = { sql: SQL_QUERY_TASK_ID_BY_RECORD, args: [recordIds[i]] };
          const taskIdRows: TaskIdRow[] = await this.deps.store.query<TaskIdRow>(taskIdSpec);
          if (taskIdRows.length > 0 && taskIdRows[0].task_id === runningTaskId) {
            throw new AppError(ErrorCode.RECORD_BUSY_CANNOT_DELETE, '记录正在使用中，无法删除');
          }
        }
      }
    }

    // 执行删除：先级联清理 case_result，再删除 run_record
    await this.deps.store.transaction(async (tx: TxContext): Promise<void> => {
      for (let i = 0; i < recordIds.length; i++) {
        // 查询 task_id 用于级联清理 case_result
        const taskIdSpec: QuerySpec = { sql: SQL_QUERY_TASK_ID_BY_RECORD, args: [recordIds[i]] };
        const taskIdRows: TaskIdRow[] = await tx.query<TaskIdRow>(taskIdSpec);
        if (taskIdRows.length > 0) {
          const taskId: string = taskIdRows[0].task_id;
          await tx.execute({ sql: SQL_DELETE_CASE_RESULT_BY_TASK, args: [taskId] });
        }
        await tx.execute({ sql: SQL_DELETE_RUN_RECORD, args: [recordIds[i]] });
      }
    });

    this.deps.logger.log(LogLevel.INFO, LogEvent.ARCHIVE,
      `删除运行记录 ids=${recordIds.join(',')}`);
  }

  /**
   * 一致性自检（spec 4.2.4、tasks.md 9.1）。
   * 从 case_result 表重新计算指标，与 run_record 中持久化的 metrics_json 比对。
   * 不一致（明细被篡改或指标计算偏差）时返回 false。
   */
  async isConsistent(recordId: string): Promise<boolean> {
    await this.ensureInit();
    const record: RunRecord = await this.getRecord(recordId);
    const caseSpec: QuerySpec = {
      sql: `SELECT case_id, task_id, seq, content, reference_answer, model_answer, verdict, elapsed_ms FROM ${TABLE_CASE_RESULT} WHERE task_id = ? ORDER BY seq ASC`,
      args: [record.taskId]
    };
    const caseRows: CaseResultRow[] = await this.deps.store.query<CaseResultRow>(caseSpec);
    const cases: CaseResult[] = [];
    for (let i = 0; i < caseRows.length; i++) {
      const r: CaseResultRow = caseRows[i];
      cases.push({
        caseId: r.case_id,
        taskId: r.task_id,
        seq: r.seq,
        content: r.content,
        referenceAnswer: r.reference_answer === null ? '' : r.reference_answer,
        modelAnswer: r.model_answer === null ? '' : r.model_answer,
        verdict: r.verdict as Verdict,
        elapsedMs: r.elapsed_ms
      });
    }
    const recomputed: Metrics = MetricCalculator.compute(cases, record.metrics.usage);
    const stored: Metrics = record.metrics;
    const tolerance: number = 1e-9;
    const accuracyMatch: boolean = stored.accuracy === null && recomputed.accuracy === null
      || (stored.accuracy !== null && recomputed.accuracy !== null && Math.abs(stored.accuracy - recomputed.accuracy) < tolerance);
    const passRateMatch: boolean = stored.passRate === null && recomputed.passRate === null
      || (stored.passRate !== null && recomputed.passRate !== null && Math.abs(stored.passRate - recomputed.passRate) < tolerance);
    const avgMatch: boolean = stored.avgElapsedMs === null && recomputed.avgElapsedMs === null
      || (stored.avgElapsedMs !== null && recomputed.avgElapsedMs !== null && Math.abs(stored.avgElapsedMs - recomputed.avgElapsedMs) < tolerance);
    return accuracyMatch && passRateMatch && avgMatch;
  }

  /**
   * 清空全部运行记录与用例结果（spec 5.6.1-3）。
   * 受运行中任务约束（由调用方 AppSettingsService 拦截）。
   */
  async clearAll(): Promise<void> {
    await this.ensureInit();

    await this.deps.store.transaction(async (tx: TxContext): Promise<void> => {
      await tx.execute({ sql: SQL_CLEAR_CASE_RESULT });
      await tx.execute({ sql: SQL_CLEAR_RUN_RECORD });
    });

    this.deps.logger.log(LogLevel.INFO, LogEvent.ARCHIVE, '清空全部运行记录与用例结果');
  }
}