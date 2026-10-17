/**
 * 评测结果与指标展示应用服务（spec 5.4，tasks.md 6）。
 * - 单例入口：MetricReportService.getInstance()
 * - 依赖：RelationalStorePort（run_record + case_result 表）、FilePort（报告导出）、LoggerPort，
 *   以及跨模块契约 RunRecordService.getRecord（任务7实现，通过 provider 注入）。
 * - 只读 run_record + case_result 表，不写入。
 * - 初始化调用 ensureSchema(AppContainer.getInstance().store())。
 *
 * 指标计算规则（确定性，spec 5.4.1-1、4.2.4）：
 * - total = cases.length
 * - validJudged = count(verdict == PASSED || verdict == FAILED)
 * - passed = count(verdict == PASSED)
 * - accuracy = validJudged > 0 ? passed / validJudged : null
 * - passRate = total > 0 ? passed / total : null
 * - avgElapsedMs = total > 0 ? sum(elapsedMs) / total : null
 * - 全部用例失败/超时（validJudged == 0）→ accuracy/passRate 为 null（spec 5.4.3-1）
 *
 * 业务规则（spec 5.4）：
 * - getMetrics(recordId)：读 run_record 表的 metrics_json，反序列化为 Metrics；
 *   记录不存在或损坏时返回 computed=false 的占位 Metrics。
 * - listCaseResults(recordId, filter)：通过 run_record.task_id 查 case_result 表，按 seq 排序；
 *   filter.onlyFailed 为真时仅返回 verdict == FAILED || verdict == TIMEOUT。
 * - compareRecords(recordIds)：先校验所选记录的 dataset_uri 一致，
 *   不一致 → AppError(TASK_INCOMPLETE_CONFIG, '题目集不一致')；
 *   一致则返回并列矩阵（metricNames: ['accuracy','passRate','avgElapsedMs','totalTokens']）。
 * - exportReport(recordId)：序列化报告文本 → logger().redact() 脱敏 → file().saveText()；
 *   失败/取消 → AppError(REPORT_EXPORT_FAILED)；导出内容禁止密钥明文（spec 4.4.3）。
 */
import { AppContainer } from '../../entrystage/AppContainer';
import { ensureSchema, TABLE_CASE_RESULT, TABLE_RUN_RECORD } from '../../infra/adapters/DbSchema';
import { RelationalStorePort } from '../../infra/ports/RelationalStorePort';
import { FilePort } from '../../infra/ports/FilePort';
import { LoggerPort } from '../../infra/ports/LoggerPort';
import { ExecSpec, ExportResult, QuerySpec } from '../../common/types/InfraTypes';
import { LogEvent, LogLevel, RunRecordStatus, Verdict } from '../../common/types/Enums';
import {
  CaseResult, CaseResultFilter, Metrics, MetricsComparison, RunRecord, UsageSummary
} from '../../common/types/DomainTypes';
import { AppError, asAppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { MetricCalculator } from '../../domain/metric/MetricCalculator';
import { MetricStrategy, DefaultMetricStrategy } from '../../domain/strategy/MetricStrategy';

// ============ SQL 常量 ============

const SQL_QUERY_RUN_RECORD: string =
  `SELECT record_id, task_id, task_name, target_model, status, started_at, ended_at, model_version, dataset_uri, metrics_json FROM ${TABLE_RUN_RECORD} WHERE record_id = ?`;

const SQL_QUERY_CASE_RESULTS_BY_TASK: string =
  `SELECT case_id, task_id, seq, content, reference_answer, model_answer, verdict, elapsed_ms FROM ${TABLE_CASE_RESULT} WHERE task_id = ? ORDER BY seq ASC`;

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

// ============ 依赖注入 ============

export interface MetricReportDeps {
  store: RelationalStorePort;
  file: FilePort;
  logger: LoggerPort;
  /** 跨模块契约 RunRecordService.getRecord（任务7实现） */
  getRecordProvider: (recordId: string) => Promise<RunRecord>;
  /** 指标口径策略；默认使用 DefaultMetricStrategy（R1 替换点） */
  metricStrategy?: MetricStrategy;
}

// ============ 占位 Metrics（记录不存在或损坏时返回） ============

function placeholderMetrics(): Metrics {
  return {
    accuracy: null,
    passRate: null,
    avgElapsedMs: null,
    usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 },
    computed: false
  };
}

// ============ 行 → 领域对象 ============

function rowToCaseResult(row: CaseResultRow): CaseResult {
  return {
    caseId: row.case_id,
    taskId: row.task_id,
    seq: row.seq,
    content: row.content,
    referenceAnswer: row.reference_answer === null ? '' : row.reference_answer,
    modelAnswer: row.model_answer === null ? '' : row.model_answer,
    verdict: row.verdict as Verdict,
    elapsedMs: row.elapsed_ms
  };
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
      } as UsageSummary
    : { promptTokens: 0, completionTokens: 0, totalTokens: 0 } as UsageSummary;

  const metrics: Metrics = {
    accuracy: accuracyRaw === null || accuracyRaw === undefined ? null : accuracyRaw as number,
    passRate: passRateRaw === null || passRateRaw === undefined ? null : passRateRaw as number,
    avgElapsedMs: avgElapsedMsRaw === null || avgElapsedMsRaw === undefined ? null : avgElapsedMsRaw as number,
    usage: usage,
    computed: computedRaw !== undefined ? computedRaw as boolean : false
  };
  return metrics;
}

// ============ MetricReportService ============

export class MetricReportService {
  private static instance: MetricReportService | null = null;

  private deps: MetricReportDeps;
  private schemaReady: Promise<void> | null = null;
  private metricStrategy: MetricStrategy;

  private constructor(deps: MetricReportDeps) {
    this.deps = deps;
    this.metricStrategy = deps.metricStrategy !== undefined ? deps.metricStrategy : new DefaultMetricStrategy();
  }

  static getInstance(): MetricReportService {
    if (MetricReportService.instance === null) {
      const container: AppContainer = AppContainer.getInstance();
      MetricReportService.instance = new MetricReportService({
        store: container.store(),
        file: container.file(),
        logger: container.logger(),
        getRecordProvider: (recordId: string): Promise<RunRecord> => {
          // 跨模块契约：RunRecordService 尚未实现，暂返回占位记录
          const placeholder: RunRecord = {
            recordId: recordId,
            taskId: '',
            taskName: '',
            targetModel: '',
            status: RunRecordStatus.COMPLETED,
            startedAt: 0,
            endedAt: 0,
            modelVersion: 1,
            datasetUri: '',
            metrics: placeholderMetrics(),
            corrupted: false
          };
          return Promise.resolve(placeholder);
        }
      });
    }
    return MetricReportService.instance;
  }

  static createForTest(deps: MetricReportDeps): MetricReportService {
    return new MetricReportService(deps);
  }

  private ensureInit(): Promise<void> {
    if (this.schemaReady === null) {
      this.schemaReady = ensureSchema(this.deps.store);
    }
    return this.schemaReady;
  }

  // ============ 对外接口 ============

  /**
   * 读 run_record 表的 metrics_json，反序列化为 Metrics。
   * 记录不存在或损坏时返回 computed=false 的占位 Metrics（spec 5.4）。
   */
  async getMetrics(recordId: string): Promise<Metrics> {
    await this.ensureInit();
    try {
      const spec: QuerySpec = { sql: SQL_QUERY_RUN_RECORD, args: [recordId] };
      const rows: RunRecordRow[] = await this.deps.store.query<RunRecordRow>(spec);
      if (rows.length === 0) {
        return placeholderMetrics();
      }
      const row: RunRecordRow = rows[0];
      if (row.metrics_json === null || row.metrics_json.length === 0) {
        return placeholderMetrics();
      }
      return deserializeMetrics(row.metrics_json);
    } catch (e) {
      this.deps.logger.log(LogLevel.WARN, LogEvent.ERROR, `读取指标失败 recordId=${recordId} err=${(e as Error).message}`);
      return placeholderMetrics();
    }
  }

  /**
   * 通过 run_record.task_id 查 case_result 表，按 seq 排序。
   * filter.onlyFailed 为真时仅返回 verdict == FAILED || verdict == TIMEOUT（spec 5.4.1-3）。
   */
  async listCaseResults(recordId: string, filter: CaseResultFilter): Promise<CaseResult[]> {
    await this.ensureInit();
    try {
      // 先通过 getRecordProvider 获取 RunRecord 以拿到 task_id
      const record: RunRecord = await this.deps.getRecordProvider(recordId);
      const taskId: string = record.taskId;
      if (taskId.length === 0) {
        // getRecordProvider 占位返回空 taskId 时，尝试从 run_record 表直接查
        const recordSpec: QuerySpec = { sql: SQL_QUERY_RUN_RECORD, args: [recordId] };
        const recordRows: RunRecordRow[] = await this.deps.store.query<RunRecordRow>(recordSpec);
        if (recordRows.length === 0) {
          return [];
        }
        const row: RunRecordRow = recordRows[0];
        const caseSpec: QuerySpec = { sql: SQL_QUERY_CASE_RESULTS_BY_TASK, args: [row.task_id] };
        const caseRows: CaseResultRow[] = await this.deps.store.query<CaseResultRow>(caseSpec);
        return this.filterAndConvert(caseRows, filter);
      }
      const caseSpec: QuerySpec = { sql: SQL_QUERY_CASE_RESULTS_BY_TASK, args: [taskId] };
      const caseRows: CaseResultRow[] = await this.deps.store.query<CaseResultRow>(caseSpec);
      return this.filterAndConvert(caseRows, filter);
    } catch (e) {
      this.deps.logger.log(LogLevel.WARN, LogEvent.ERROR, `查询用例明细失败 recordId=${recordId} err=${(e as Error).message}`);
      return [];
    }
  }

  /**
   * 多记录指标对比（spec 5.4.1-4、5.4.3-3）。
   * 先校验所选记录的 dataset_uri 一致，不一致 → AppError(TASK_INCOMPLETE_CONFIG, '题目集不一致')。
   * 一致则返回并列矩阵（metricNames: ['accuracy','passRate','avgElapsedMs','totalTokens']）。
   */
  async compareRecords(recordIds: string[]): Promise<MetricsComparison> {
    await this.ensureInit();
    if (recordIds.length < 2) {
      throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, '请选择至少两条运行记录进行对比');
    }

    // 查询所有记录，校验 dataset_uri 一致性
    const datasetUris: string[] = [];
    const metricsList: Metrics[] = [];
    for (let i = 0; i < recordIds.length; i++) {
      const record: RunRecord = await this.deps.getRecordProvider(recordIds[i]);
      datasetUris.push(record.datasetUri);
      metricsList.push(record.metrics);
    }

    // 校验题目集一致性
    const firstUri: string = datasetUris[0];
    for (let i = 1; i < datasetUris.length; i++) {
      if (datasetUris[i] !== firstUri) {
        throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, '题目集不一致');
      }
    }

    // 构建并列矩阵
    const metricNames: string[] = ['accuracy', 'passRate', 'avgElapsedMs', 'totalTokens'];
    const values: Array<Array<number | null>> = [];

    for (let i = 0; i < recordIds.length; i++) {
      const m: Metrics = metricsList[i];
      const row: Array<number | null> = [
        m.accuracy,
        m.passRate,
        m.avgElapsedMs,
        m.usage.totalTokens
      ];
      values.push(row);
    }

    return {
      recordIds: recordIds,
      metricNames: metricNames,
      values: values
    };
  }

  /**
   * 导出报告（spec 5.4.1-5、4.4.3、5.4.3-2）。
   * 序列化报告文本 → logger().redact() 脱敏 → file().saveText()。
   * 失败/取消 → AppError(REPORT_EXPORT_FAILED)；导出内容禁止密钥明文。
   */
  async exportReport(recordId: string): Promise<ExportResult> {
    await this.ensureInit();
    try {
      const record: RunRecord = await this.deps.getRecordProvider(recordId);
      const metrics: Metrics = record.metrics;
      const caseResults: CaseResult[] = await this.listCaseResults(recordId, { onlyFailed: false });

      // 序列化报告文本
      const reportContent: string = this.buildReportText(record, metrics, caseResults);

      // 脱敏处理（spec 4.4.3：导出内容禁止密钥明文）
      const redactedContent: string = this.deps.logger.redact(reportContent);

      // 经保存选择器落盘
      const result: ExportResult = await this.deps.file.saveText(
        { suggestedFileName: `report_${recordId}`, fileSuffix: 'txt' },
        redactedContent
      );

      if (!result.success) {
        throw new AppError(ErrorCode.REPORT_EXPORT_FAILED, result.reason);
      }

      this.deps.logger.log(LogLevel.INFO, LogEvent.ARCHIVE, `导出报告 recordId=${recordId} uri=${result.uri}`);
      return result;
    } catch (e) {
      const cause: AppError = asAppError(e, ErrorCode.REPORT_EXPORT_FAILED);
      if (cause.code === ErrorCode.REPORT_EXPORT_FAILED) {
        throw cause;
      }
      throw new AppError(ErrorCode.REPORT_EXPORT_FAILED, cause.detail);
    }
  }

  // ============ 内部辅助 ============

  private filterAndConvert(rows: CaseResultRow[], filter: CaseResultFilter): CaseResult[] {
    const results: CaseResult[] = [];
    for (let i = 0; i < rows.length; i++) {
      const cr: CaseResult = rowToCaseResult(rows[i]);
      if (filter.onlyFailed) {
        if (cr.verdict === Verdict.FAILED || cr.verdict === Verdict.TIMEOUT) {
          results.push(cr);
        }
      } else {
        results.push(cr);
      }
    }
    return results;
  }

  private buildReportText(record: RunRecord, metrics: Metrics, cases: CaseResult[]): string {
    const lines: string[] = [];
    lines.push('=== 评测报告 ===');
    lines.push(`任务名称：${record.taskName}`);
    lines.push(`目标模型：${record.targetModel}`);
    lines.push(`记录状态：${record.status}`);
    lines.push(`开始时间：${record.startedAt}`);
    lines.push(`结束时间：${record.endedAt}`);
    lines.push('');
    lines.push('--- 汇总指标 ---');
    lines.push(`准确率：${metrics.accuracy !== null ? (metrics.accuracy * 100).toFixed(2) + '%' : '无有效样本'}`);
    lines.push(`通过率：${metrics.passRate !== null ? (metrics.passRate * 100).toFixed(2) + '%' : '无有效样本'}`);
    lines.push(`平均耗时：${metrics.avgElapsedMs !== null ? metrics.avgElapsedMs.toFixed(0) + 'ms' : '无有效样本'}`);
    lines.push(`用量汇总：promptTokens=${metrics.usage.promptTokens} completionTokens=${metrics.usage.completionTokens} totalTokens=${metrics.usage.totalTokens}`);
    lines.push('');
    lines.push('--- 逐题明细 ---');
    for (let i = 0; i < cases.length; i++) {
      const c: CaseResult = cases[i];
      lines.push(`[序号 ${c.seq}] 判定：${c.verdict} 耗时：${c.elapsedMs}ms`);
      lines.push(`  题面：${c.content}`);
      lines.push(`  参考答案：${c.referenceAnswer}`);
      lines.push(`  模型作答：${c.modelAnswer}`);
      lines.push('');
    }
    lines.push('=== 报告结束 ===');
    return lines.join('\n');
  }
}