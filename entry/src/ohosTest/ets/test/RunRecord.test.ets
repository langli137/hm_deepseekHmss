/**
 * 运行记录管理模块单元测试（tasks.md 7.6）。
 * 覆盖：归档一致性、检索条件组合、删除冲突、上限拦截、损坏记录隔离。
 */
import { describe, expect, it } from '@ohos/hypium';
import { RunRecordDeps, RunRecordService, RunRecordArchiveInput } from '../../../main/ets/biz/runrecord/RunRecordService';
import { CaseResult, Metrics, RunRecord, RunRecordQuery, UsageSummary } from '../../../main/ets/common/types/DomainTypes';
import { RunRecordStatus, Verdict } from '../../../main/ets/common/types/Enums';
import { ExecSpec, QuerySpec, TxContext } from '../../../main/ets/common/types/InfraTypes';
import { RelationalStorePort } from '../../../main/ets/infra/ports/RelationalStorePort';
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

    // 简易过滤：支持 WHERE record_id = ? / WHERE task_id = ? / WHERE status = ? / LIKE
    let filtered: Array<Record<string, Object>> = rows;
    if (spec.args !== undefined && spec.args.length > 0) {
      if (spec.sql.indexOf('WHERE record_id = ?') >= 0) {
        const id: string = spec.args[0] as string;
        filtered = rows.filter((r: Record<string, Object>): boolean => r['record_id'] === id);
      } else if (spec.sql.indexOf('WHERE task_id = ?') >= 0) {
        const tid: string = spec.args[0] as string;
        filtered = rows.filter((r: Record<string, Object>): boolean => r['task_id'] === tid);
      } else if (spec.sql.indexOf('LIKE') >= 0) {
        const kw: string = spec.args[0] as string;
        const pattern: string = kw.replace(/%/g, '');
        filtered = rows.filter((r: Record<string, Object>): boolean =>
          (r['task_name'] as string).indexOf(pattern) >= 0);
      } else if (spec.sql.indexOf('WHERE status = ?') >= 0) {
        const st: string = spec.args[0] as string;
        filtered = rows.filter((r: Record<string, Object>): boolean => r['status'] === st);
      }
    }

    // COUNT(*) 特殊处理
    if (spec.sql.indexOf('COUNT(*)') >= 0) {
      return [{ cnt: filtered.length }] as T[];
    }

    return filtered as T[];
  }

  async execute(spec: ExecSpec): Promise<number> {
    const tableName: string = this.extractTableName(spec.sql);
    if (spec.sql.indexOf('INSERT') >= 0) {
      let rows: Array<Record<string, Object>> = this.tables.get(tableName) ?? [];
      if (rows === undefined) { rows = []; }
      const newRow: Record<string, Object> = {};
      // 简易解析：从 args 填充列（按 SQL 列顺序）
      if (tableName === 'run_record' && spec.args !== undefined) {
        newRow['record_id'] = spec.args[0];
        newRow['task_id'] = spec.args[1];
        newRow['task_name'] = spec.args[2];
        newRow['target_model'] = spec.args[3];
        newRow['status'] = spec.args[4];
        newRow['started_at'] = spec.args[5];
        newRow['ended_at'] = spec.args[6];
        newRow['model_version'] = spec.args[7];
        newRow['dataset_uri'] = spec.args[8];
        newRow['metrics_json'] = spec.args[9];
      }
      rows.push(newRow);
      this.tables.set(tableName, rows);
      return 1;
    }
    if (spec.sql.indexOf('DELETE') >= 0) {
      if (spec.sql.indexOf('WHERE record_id = ?') >= 0 && spec.args !== undefined) {
        const id: string = spec.args[0] as string;
        let rows: Array<Record<string, Object>> = this.tables.get(tableName) ?? [];
        rows = rows.filter((r: Record<string, Object>): boolean => r['record_id'] !== id);
        this.tables.set(tableName, rows);
      } else if (spec.sql.indexOf('WHERE task_id = ?') >= 0 && spec.args !== undefined) {
        const tid: string = spec.args[0] as string;
        let rows: Array<Record<string, Object>> = this.tables.get(tableName) ?? [];
        rows = rows.filter((r: Record<string, Object>): boolean => r['task_id'] !== tid);
        this.tables.set(tableName, rows);
      } else {
        this.tables.set(tableName, []);
      }
      return 1;
    }
    return 1;
  }

  setTable(name: string, rows: Array<Record<string, Object>>): void {
    this.tables.set(name, rows);
  }

  getTable(name: string): Array<Record<string, Object>> {
    return this.tables.get(name) ?? [];
  }

  private extractTableName(sql: string): string {
    if (sql.indexOf('run_record') >= 0) { return 'run_record'; }
    if (sql.indexOf('case_result') >= 0) { return 'case_result'; }
    return '';
  }
}

// ============ 测试数据构造 ============

function makeCase(seq: number, verdict: Verdict, elapsedMs: number): CaseResult {
  return {
    caseId: `case_${seq}`, taskId: 'task_1', seq: seq,
    content: `题面${seq}`, referenceAnswer: `参考${seq}`,
    modelAnswer: `作答${seq}`, verdict: verdict, elapsedMs: elapsedMs
  };
}

function makeArchiveInput(status: RunRecordStatus, caseResults: CaseResult[]): RunRecordArchiveInput {
  return {
    taskId: 'task_1', taskName: '测试任务', targetModel: 'deepseek-chat',
    status: status, startedAt: 1000, endedAt: 2000,
    datasetUri: 'ds1', modelVersion: 1,
    caseResults: caseResults,
    usage: { promptTokens: 100, completionTokens: 50, totalTokens: 150 }
  };
}

// ============ 测试 ============

export function runRecordTest(): void {
  describe('RunRecordService', () => {
    let store: FakeStore;
    let logger: StubLogger;
    let svc: RunRecordService;
    let recordLimit: number = 1000;
    let hasRunning: boolean = false;
    let runningTaskId: string | undefined = undefined;

    function setup(): void {
      store = new FakeStore();
      logger = new StubLogger();
      recordLimit = 1000;
      hasRunning = false;
      runningTaskId = undefined;
      svc = RunRecordService.createForTest({
        store: store,
        logger: logger,
        recordLimitProvider: async (): Promise<number> => { return recordLimit; },
        hasRunningTaskProvider: (): boolean => { return hasRunning; },
        runningTaskIdProvider: (): string | undefined => { return runningTaskId; }
      });
    }

    it('archive：成功归档并返回 recordId', 0, async () => {
      setup();
      const input: RunRecordArchiveInput = makeArchiveInput(RunRecordStatus.COMPLETED, [
        makeCase(0, Verdict.PASSED, 100),
        makeCase(1, Verdict.FAILED, 200)
      ]);
      const recordId: string = await svc.archive(input);
      expect(recordId.length > 0).assertTrue();
      expect(recordId.startsWith('rec_')).assertTrue();
    });

    it('archive：指标计算正确（1通过1失败 → accuracy=0.5）', 0, async () => {
      setup();
      const input: RunRecordArchiveInput = makeArchiveInput(RunRecordStatus.COMPLETED, [
        makeCase(0, Verdict.PASSED, 100),
        makeCase(1, Verdict.FAILED, 200)
      ]);
      const recordId: string = await svc.archive(input);
      const record: RunRecord = await svc.getRecord(recordId);
      expect(record.metrics.accuracy).assertEqual(0.5);
      expect(record.metrics.computed).assertTrue();
    });

    it('archive：达上限抛 RECORD_LIMIT_REACHED', 0, async () => {
      setup();
      recordLimit = 1;
      // 先插入一条
      const input1: RunRecordArchiveInput = makeArchiveInput(RunRecordStatus.COMPLETED, [
        makeCase(0, Verdict.PASSED, 100)
      ]);
      await svc.archive(input1);
      // 再归档应抛错
      const input2: RunRecordArchiveInput = makeArchiveInput(RunRecordStatus.FAILED, [
        makeCase(0, Verdict.ERROR, 100)
      ]);
      try {
        await svc.archive(input2);
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.RECORD_LIMIT_REACHED);
      }
    });

    it('archive：endedAt < startedAt 抛错', 0, async () => {
      setup();
      const input: RunRecordArchiveInput = {
        taskId: 'task_1', taskName: '测试', targetModel: 'm',
        status: RunRecordStatus.COMPLETED, startedAt: 2000, endedAt: 1000,
        datasetUri: 'ds1', modelVersion: 1,
        caseResults: [makeCase(0, Verdict.PASSED, 100)],
        usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }
      };
      try {
        await svc.archive(input);
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.RECORD_LIMIT_REACHED);
      }
    });

    it('listRecords：按名称关键字检索', 0, async () => {
      setup();
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: 'Alpha测试', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{"accuracy":0.8,"passRate":0.8,"avgElapsedMs":100,"usage":{"promptTokens":0,"completionTokens":0,"totalTokens":0},"computed":true}' },
        { record_id: 'r2', task_id: 't2', task_name: 'Beta测试', target_model: 'm2',
          status: 'FAILED', started_at: 3000, ended_at: 4000, model_version: 1,
          dataset_uri: 'ds2', metrics_json: '{"accuracy":0.5,"passRate":0.5,"avgElapsedMs":200,"usage":{"promptTokens":0,"completionTokens":0,"totalTokens":0},"computed":true}' }
      ]);
      const query: RunRecordQuery = { nameKeyword: 'Alpha' };
      const records: RunRecord[] = await svc.listRecords(query);
      expect(records.length).assertEqual(1);
      expect(records[0].taskName).assertEqual('Alpha测试');
    });

    it('listRecords：按状态检索', 0, async () => {
      setup();
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{}' },
        { record_id: 'r2', task_id: 't2', task_name: '任务2', target_model: 'm2',
          status: 'FAILED', started_at: 3000, ended_at: 4000, model_version: 1,
          dataset_uri: 'ds2', metrics_json: '{}' }
      ]);
      const query: RunRecordQuery = { status: RunRecordStatus.FAILED };
      const records: RunRecord[] = await svc.listRecords(query);
      expect(records.length).assertEqual(1);
      expect(records[0].status).assertEqual(RunRecordStatus.FAILED);
    });

    it('listRecords：组合条件检索', 0, async () => {
      setup();
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: 'Alpha', target_model: 'deepseek-chat',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{}' },
        { record_id: 'r2', task_id: 't2', task_name: 'Alpha', target_model: 'other-model',
          status: 'COMPLETED', started_at: 3000, ended_at: 4000, model_version: 1,
          dataset_uri: 'ds2', metrics_json: '{}' }
      ]);
      const query: RunRecordQuery = { nameKeyword: 'Alpha', targetModel: 'deepseek-chat' };
      const records: RunRecord[] = await svc.listRecords(query);
      expect(records.length).assertEqual(1);
      expect(records[0].targetModel).assertEqual('deepseek-chat');
    });

    it('listRecords：metrics_json 解析失败时 corrupted=true', 0, async () => {
      setup();
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: '损坏记录', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '<<<invalid json>>>' }
      ]);
      const records: RunRecord[] = await svc.listRecords({});
      expect(records.length).assertEqual(1);
      expect(records[0].corrupted).assertTrue();
      expect(records[0].metrics.computed).assertFalse();
    });

    it('getRecord：单条查询成功', 0, async () => {
      setup();
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{"accuracy":1.0,"passRate":1.0,"avgElapsedMs":100,"usage":{"promptTokens":10,"completionTokens":5,"totalTokens":15},"computed":true}' }
      ]);
      const record: RunRecord = await svc.getRecord('r1');
      expect(record.taskName).assertEqual('任务1');
      expect(record.metrics.accuracy).assertEqual(1.0);
    });

    it('getRecord：记录不存在抛错', 0, async () => {
      setup();
      try {
        await svc.getRecord('notexist');
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.RECORD_LIMIT_REACHED);
      }
    });

    it('removeRecords：成功删除并级联清理 case_result', 0, async () => {
      setup();
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{}' }
      ]);
      store.setTable('case_result', [
        { case_id: 'c1', task_id: 't1', seq: 0, content: '题0', reference_answer: '答0',
          model_answer: '作0', verdict: 'PASSED', elapsed_ms: 100 }
      ]);
      await svc.removeRecords(['r1']);
      expect(store.getTable('run_record').length).assertEqual(0);
      expect(store.getTable('case_result').length).assertEqual(0);
    });

    it('removeRecords：运行中任务占用时抛 RECORD_BUSY_CANNOT_DELETE', 0, async () => {
      setup();
      hasRunning = true;
      runningTaskId = 't1';
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{}' }
      ]);
      try {
        await svc.removeRecords(['r1']);
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.RECORD_BUSY_CANNOT_DELETE);
      }
    });

    it('removeRecords：运行中任务但不冲突时可删除', 0, async () => {
      setup();
      hasRunning = true;
      runningTaskId = 't_other';
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{}' }
      ]);
      await svc.removeRecords(['r1']);
      expect(store.getTable('run_record').length).assertEqual(0);
    });

    it('removeRecords：空数组不报错', 0, async () => {
      setup();
      await svc.removeRecords([]);
      expect(store.getTable('run_record').length).assertEqual(0);
    });

    it('clearAll：清空 run_record 与 case_result', 0, async () => {
      setup();
      store.setTable('run_record', [
        { record_id: 'r1', task_id: 't1', task_name: '任务1', target_model: 'm1',
          status: 'COMPLETED', started_at: 1000, ended_at: 2000, model_version: 1,
          dataset_uri: 'ds1', metrics_json: '{}' },
        { record_id: 'r2', task_id: 't2', task_name: '任务2', target_model: 'm2',
          status: 'FAILED', started_at: 3000, ended_at: 4000, model_version: 1,
          dataset_uri: 'ds2', metrics_json: '{}' }
      ]);
      store.setTable('case_result', [
        { case_id: 'c1', task_id: 't1', seq: 0, content: '题0', reference_answer: '答0',
          model_answer: '作0', verdict: 'PASSED', elapsed_ms: 100 }
      ]);
      await svc.clearAll();
      expect(store.getTable('run_record').length).assertEqual(0);
      expect(store.getTable('case_result').length).assertEqual(0);
    });

    it('archive：全失败用例 accuracy=null', 0, async () => {
      setup();
      const input: RunRecordArchiveInput = makeArchiveInput(RunRecordStatus.FAILED, [
        makeCase(0, Verdict.TIMEOUT, 5000),
        makeCase(1, Verdict.ERROR, 100)
      ]);
      const recordId: string = await svc.archive(input);
      const record: RunRecord = await svc.getRecord(recordId);
      expect(record.metrics.accuracy).assertNull();
    });
  });
}