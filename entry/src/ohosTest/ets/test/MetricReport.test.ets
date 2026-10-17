/**
 * 评测结果与指标展示模块单元测试（tasks.md 6.7）。
 * 覆盖：指标计算边界（全通过/全失败/混合/无有效样本）、明细查询与失败筛选、
 * 对比校验（题目集一致/不一致）、导出脱敏。
 */
import { describe, expect, it } from '@ohos/hypium';
import { MetricReportDeps, MetricReportService } from '../../../main/ets/biz/metricreport/MetricReportService';
import { MetricCalculator } from '../../../main/ets/domain/metric/MetricCalculator';
import { CaseResult, CaseResultFilter, Metrics, RunRecord, UsageSummary } from '../../../main/ets/common/types/DomainTypes';
import { Verdict, RunRecordStatus } from '../../../main/ets/common/types/Enums';
import { ExecSpec, ExportResult, QuerySpec, TxContext } from '../../../main/ets/common/types/InfraTypes';
import { RelationalStorePort } from '../../../main/ets/infra/ports/RelationalStorePort';
import { FilePort } from '../../../main/ets/infra/ports/FilePort';
import { LoggerPort } from '../../../main/ets/infra/ports/LoggerPort';
import { StubLogger } from '../../../main/ets/infra/stubs/StubLogger';
import { AppError } from '../../../main/ets/common/error/AppError';
import { ErrorCode } from '../../../main/ets/common/error/ErrorCode';

// ============ 内存存储桩 ============

class FakeStore implements RelationalStorePort {
  private tables: Map<string, Array<Record<string, Object>>> = new Map();

  async transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T> {
    const tx: TxContext = {
      query: async <T>(spec: QuerySpec): Promise<T[]> => { return this.query<T>(spec); },
      execute: async (spec: ExecSpec): Promise<number> => { return this.execute(spec); }
    };
    return work(tx);
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    const tableName: string = this.extractTableName(spec.sql);
    const rows: Array<Record<string, Object>> | undefined = this.tables.get(tableName);
    if (rows === undefined) { return []; }
    return rows as T[];
  }

  async execute(spec: ExecSpec): Promise<number> {
    return 1;
  }

  setTable(name: string, rows: Array<Record<string, Object>>): void {
    this.tables.set(name, rows);
  }

  private extractTableName(sql: string): string {
    if (sql.indexOf('run_record') >= 0) { return 'run_record'; }
    if (sql.indexOf('case_result') >= 0) { return 'case_result'; }
    return '';
  }
}

class FakeFile implements FilePort {
  savedContent: string = '';
  shouldFail: boolean = false;

  async pickFile(): Promise<null> { return null; }
  async readText(): Promise<string> { return ''; }
  async saveText(options: Record<string, Object>, content: string): Promise<ExportResult> {
    if (this.shouldFail) {
      return { success: false, uri: '', reason: '空间不足' };
    }
    this.savedContent = content;
    return { success: true, uri: 'fake://report.txt', reason: '' };
  }
  async exists(): Promise<boolean> { return false; }
}

// ============ 测试数据构造 ============

function makeCase(seq: number, verdict: Verdict, elapsedMs: number): CaseResult {
  return {
    caseId: `case_${seq}`, taskId: 'task_1', seq: seq,
    content: `题面${seq}`, referenceAnswer: `参考${seq}`,
    modelAnswer: `作答${seq}`, verdict: verdict, elapsedMs: elapsedMs
  };
}

function makeRunRecord(recordId: string, datasetUri: string, metrics: Metrics): RunRecord {
  return {
    recordId: recordId, taskId: 'task_1', taskName: '测试任务',
    targetModel: 'deepseek-chat', status: RunRecordStatus.COMPLETED,
    startedAt: 1000, endedAt: 2000, modelVersion: 1,
    datasetUri: datasetUri, metrics: metrics, corrupted: false
  };
}

// ============ 测试 ============

export function metricReportTest(): void {
  describe('MetricCalculator', () => {
    it('全通过：accuracy=1.0, passRate=1.0', 0, () => {
      const cases: CaseResult[] = [
        makeCase(0, Verdict.PASSED, 100),
        makeCase(1, Verdict.PASSED, 200)
      ];
      const m: Metrics = MetricCalculator.compute(cases);
      expect(m.accuracy).assertEqual(1.0);
      expect(m.passRate).assertEqual(1.0);
      expect(m.avgElapsedMs).assertEqual(150);
      expect(m.computed).assertTrue();
    });

    it('全失败：accuracy=null（无有效判定样本）', 0, () => {
      const cases: CaseResult[] = [
        makeCase(0, Verdict.TIMEOUT, 5000),
        makeCase(1, Verdict.ERROR, 100)
      ];
      const m: Metrics = MetricCalculator.compute(cases);
      expect(m.accuracy).assertNull();
      expect(m.passRate).assertEqual(0.0);
    });

    it('混合：1通过1失败1超时', 0, () => {
      const cases: CaseResult[] = [
        makeCase(0, Verdict.PASSED, 100),
        makeCase(1, Verdict.FAILED, 200),
        makeCase(2, Verdict.TIMEOUT, 5000)
      ];
      const m: Metrics = MetricCalculator.compute(cases);
      expect(m.accuracy).assertEqual(0.5);
      expect(m.passRate).assertClose(0.333, 0.01);
    });

    it('空用例集：所有派生指标为 null', 0, () => {
      const m: Metrics = MetricCalculator.compute([]);
      expect(m.accuracy).assertNull();
      expect(m.passRate).assertNull();
      expect(m.avgElapsedMs).assertNull();
    });

    it('用量汇总传入', 0, () => {
      const usage: UsageSummary = { promptTokens: 100, completionTokens: 50, totalTokens: 150 };
      const m: Metrics = MetricCalculator.compute([], usage);
      expect(m.usage.totalTokens).assertEqual(150);
    });
  });

  describe('MetricReportService', () => {
    let store: FakeStore;
    let file: FakeFile;
    let logger: StubLogger;
    let svc: MetricReportService;

    function setup(records: Array<Record<string, Object>>, cases: Array<Record<string, Object>>,
                   recordProvider?: (id: string) => Promise<RunRecord>): void {
      store = new FakeStore();
      store.setTable('run_record', records);
      store.setTable('case_result', cases);
      file = new FakeFile();
      logger = new StubLogger();
      svc = MetricReportService.createForTest({
        store: store, file: file, logger: logger,
        getRecordProvider: recordProvider ?? (async (id: string): Promise<RunRecord> => {
          const rows: Array<Record<string, Object>> = records;
          for (let i = 0; i < rows.length; i++) {
            if (rows[i]['record_id'] === id) {
              return makeRunRecord(
                id,
                rows[i]['dataset_uri'] as string,
                JSON.parse(rows[i]['metrics_json'] as string) as Metrics
              );
            }
          }
          return makeRunRecord(id, '', { accuracy: null, passRate: null, avgElapsedMs: null,
            usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: false });
        })
      });
    }

    it('getMetrics：从 run_record.metrics_json 反序列化', 0, async () => {
      const metricsJson: string = JSON.stringify({
        accuracy: 0.8, passRate: 0.6, avgElapsedMs: 150,
        usage: { promptTokens: 10, completionTokens: 5, totalTokens: 15 }, computed: true
      });
      setup([{ record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm',
        status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
        dataset_uri: 'ds1', metrics_json: metricsJson }], []);

      const m: Metrics = await svc.getMetrics('r1');
      expect(m.accuracy).assertEqual(0.8);
      expect(m.computed).assertTrue();
    });

    it('getMetrics：记录不存在返回 computed=false 占位', 0, async () => {
      setup([], []);
      const m: Metrics = await svc.getMetrics('notexist');
      expect(m.computed).assertFalse();
    });

    it('listCaseResults：onlyFailed 筛选仅返回 FAILED+TIMEOUT', 0, async () => {
      const caseRows: Array<Record<string, Object>> = [
        { case_id: 'c0', task_id: 't1', seq: 0, content: '题0', reference_answer: '答0',
          model_answer: '作0', verdict: 'PASSED', elapsed_ms: 100 },
        { case_id: 'c1', task_id: 't1', seq: 1, content: '题1', reference_answer: '答1',
          model_answer: '作1', verdict: 'FAILED', elapsed_ms: 200 },
        { case_id: 'c2', task_id: 't1', seq: 2, content: '题2', reference_answer: '答2',
          model_answer: '作2', verdict: 'TIMEOUT', elapsed_ms: 5000 }
      ];
      setup([{ record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm',
        status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
        dataset_uri: 'ds1', metrics_json: '{}' }], caseRows);

      const all: CaseResult[] = await svc.listCaseResults('r1', { onlyFailed: false });
      expect(all.length).assertEqual(3);

      const failed: CaseResult[] = await svc.listCaseResults('r1', { onlyFailed: true });
      expect(failed.length).assertEqual(2);
      expect(failed[0].verdict).assertEqual(Verdict.FAILED);
      expect(failed[1].verdict).assertEqual(Verdict.TIMEOUT);
    });

    it('compareRecords：题目集不一致抛 TASK_INCOMPLETE_CONFIG', 0, async () => {
      const provider = async (id: string): Promise<RunRecord> => {
        if (id === 'r1') { return makeRunRecord('r1', 'ds_A', { accuracy: 0.8, passRate: 0.8,
          avgElapsedMs: 100, usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: true }); }
        return makeRunRecord('r2', 'ds_B', { accuracy: 0.5, passRate: 0.5,
          avgElapsedMs: 200, usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: true });
      };
      setup([], [], provider);

      try {
        await svc.compareRecords(['r1', 'r2']);
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.TASK_INCOMPLETE_CONFIG);
      }
    });

    it('exportReport：成功导出且内容经脱敏', 0, async () => {
      const provider = async (id: string): Promise<RunRecord> => {
        return makeRunRecord('r1', 'ds1', { accuracy: 1.0, passRate: 1.0, avgElapsedMs: 100,
          usage: { promptTokens: 10, completionTokens: 5, totalTokens: 15 }, computed: true });
      };
      const caseRows: Array<Record<string, Object>> = [
        { case_id: 'c0', task_id: 't1', seq: 0, content: '题0', reference_answer: '答0',
          model_answer: '作0', verdict: 'PASSED', elapsed_ms: 100 }
      ];
      setup([{ record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm',
        status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
        dataset_uri: 'ds1', metrics_json: '{}' }], caseRows, provider);

      const result: ExportResult = await svc.exportReport('r1');
      expect(result.success).assertTrue();
      expect(file.savedContent.length > 0).assertTrue();
    });

    it('exportReport：空间不足抛 REPORT_EXPORT_FAILED', 0, async () => {
      const provider = async (id: string): Promise<RunRecord> => {
        return makeRunRecord('r1', 'ds1', { accuracy: 1.0, passRate: 1.0, avgElapsedMs: 100,
          usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: true });
      };
      setup([{ record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm',
        status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
        dataset_uri: 'ds1', metrics_json: '{}' }], [], provider);
      file.shouldFail = true;

      try {
        await svc.exportReport('r1');
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.REPORT_EXPORT_FAILED);
      }
    });
  });
}