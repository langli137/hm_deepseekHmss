/**
 * 评测任务配置模块单元测试（tasks.md 4.8）。
 * 覆盖：题目集解析四条路径（成功/缺参考答案/超上限/损坏）、任务创建与名称重复、
 * 参数越界、配置不完整、运行中不可编辑、快照固化与 seq 起始、引用检测、题目集导入。
 * 通过 TaskConfigService.createForTest 注入端口桩，聚焦业务逻辑。
 */
import { describe, expect, it } from '@ohos/hypium';
import { TaskConfigDeps, TaskConfigService } from '../../../main/ets/biz/taskconfig/TaskConfigService';
import {
  buildDatasetSnapshot, buildSnapshot, DatasetRow, EvalTaskRow, rowToTask, taskCanEdit, taskCanStart
} from '../../../main/ets/biz/taskconfig/TaskModel';
import { DatasetValidator } from '../../../main/ets/domain/dataset/DatasetValidator';
import { RelationalStorePort } from '../../../main/ets/infra/ports/RelationalStorePort';
import { ExecSpec, QuerySpec, TxContext } from '../../../main/ets/common/types/InfraTypes';
import {
  DatasetValidationReport, EvaluationTask, ModelServiceConfig, RunParameters, TaskConfigDraft
} from '../../../main/ets/common/types/DomainTypes';
import { ConfigStatus, ExecutionFlag, JudgeMode, TaskStatus } from '../../../main/ets/common/types/Enums';
import { DATASET_CASE_LIMIT } from '../../../main/ets/common/types/Constants';
import { AppError } from '../../../main/ets/common/error/AppError';
import { ErrorCode } from '../../../main/ets/common/error/ErrorCode';
import { StubFile } from '../../../main/ets/infra/stubs/StubFile';
import { StubLogger } from '../../../main/ets/infra/stubs/StubLogger';

// ============ 内存存储桩（eval_task + dataset） ============

class FakeTxContext implements TxContext {
  private owner: FakeTaskStore;

  constructor(owner: FakeTaskStore) {
    this.owner = owner;
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    return this.owner.query<T>(spec);
  }

  async execute(spec: ExecSpec): Promise<number> {
    return this.owner.execute(spec);
  }
}

class FakeTaskStore implements RelationalStorePort {
  private taskRows: EvalTaskRow[] = [];
  private datasetRows: DatasetRow[] = [];

  async transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T> {
    return work(new FakeTxContext(this));
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    if (spec.sql.includes('FROM dataset')) {
      return this.dispatchDataset(spec) as T[];
    }
    return this.dispatchTask(spec) as T[];
  }

  async execute(spec: ExecSpec): Promise<number> {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];
    if (sql.includes('CREATE TABLE') || sql.includes('CREATE INDEX')) {
      return 0;
    }
    if (sql.startsWith('INSERT INTO eval_task')) {
      this.taskRows.push({
        task_id: args[0] as string,
        name: args[1] as string,
        config_id: args[2] as string,
        dataset_uri: args[3] as string,
        params_json: args[4] as string,
        status: args[5] as string,
        flag: args[6] as string,
        snapshot_json: args[7] as string,
        dataset_json: args[8] as string,
        created_at: args[9] as number
      });
      return 1;
    }
    if (sql.startsWith('INSERT INTO dataset')) {
      this.datasetRows.push({
        dataset_id: args[0] as string,
        name: args[1] as string,
        source_uri: args[2] as string,
        total_count: args[3] as number,
        valid_count: args[4] as number,
        cases_json: args[5] as string,
        imported_at: args[6] as number
      });
      return 1;
    }
    if (sql.startsWith('UPDATE eval_task')) {
      const id: string = args[6] as string;
      for (let i = 0; i < this.taskRows.length; i++) {
        if (this.taskRows[i].task_id === id) {
          this.taskRows[i].name = args[0] as string;
          this.taskRows[i].config_id = args[1] as string;
          this.taskRows[i].dataset_uri = args[2] as string;
          this.taskRows[i].params_json = args[3] as string;
          this.taskRows[i].snapshot_json = args[4] as string;
          this.taskRows[i].dataset_json = args[5] as string;
        }
      }
      return 1;
    }
    if (sql.startsWith('UPDATE dataset')) {
      const uri: string = args[5] as string;
      for (let i = 0; i < this.datasetRows.length; i++) {
        if (this.datasetRows[i].source_uri === uri) {
          this.datasetRows[i].name = args[0] as string;
          this.datasetRows[i].total_count = args[1] as number;
          this.datasetRows[i].valid_count = args[2] as number;
          this.datasetRows[i].cases_json = args[3] as string;
          this.datasetRows[i].imported_at = args[4] as number;
        }
      }
      return 1;
    }
    if (sql.startsWith('DELETE FROM dataset')) {
      this.datasetRows = [];
      return 1;
    }
    if (sql.startsWith('DELETE FROM eval_task')) {
      const id: string = args[0] as string;
      this.taskRows = this.taskRows.filter((row: EvalTaskRow): boolean => row.task_id !== id);
      return 1;
    }
    return 0;
  }

  private dispatchTask(spec: QuerySpec): EvalTaskRow[] {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];
    const out: EvalTaskRow[] = [];
    for (let i = 0; i < this.taskRows.length; i++) {
      const row: EvalTaskRow = this.taskRows[i];
      if (sql.includes('WHERE name = ?') && row.name !== args[0]) {
        continue;
      }
      if (sql.includes('WHERE task_id = ?') && row.task_id !== args[0]) {
        continue;
      }
      if (sql.includes('WHERE config_id = ?') && row.config_id !== args[0]) {
        continue;
      }
      if (sql.includes('AND status = ?') && row.status !== args[1]) {
        continue;
      }
      out.push(row);
    }
    return out;
  }

  private dispatchDataset(spec: QuerySpec): DatasetRow[] {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];
    const out: DatasetRow[] = [];
    for (let i = 0; i < this.datasetRows.length; i++) {
      const row: DatasetRow = this.datasetRows[i];
      if (sql.includes('WHERE source_uri = ?') && row.source_uri !== args[0]) {
        continue;
      }
      out.push(row);
    }
    return out;
  }

  seedTask(row: EvalTaskRow): void {
    this.taskRows.push(row);
  }

  seedDataset(row: DatasetRow): void {
    this.datasetRows.push(row);
  }

  taskCount(): number {
    return this.taskRows.length;
  }

  datasetCount(): number {
    return this.datasetRows.length;
  }

  findTask(taskId: string): EvalTaskRow | undefined {
    for (let i = 0; i < this.taskRows.length; i++) {
      if (this.taskRows[i].task_id === taskId) {
        return this.taskRows[i];
      }
    }
    return undefined;
  }

  findDataset(uri: string): DatasetRow | undefined {
    for (let i = 0; i < this.datasetRows.length; i++) {
      if (this.datasetRows[i].source_uri === uri) {
        return this.datasetRows[i];
      }
    }
    return undefined;
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

function makeDraft(name: string, datasetUri: string): TaskConfigDraft {
  return { name: name, configId: 'cfg_1', datasetUri: datasetUri, params: makeParams() };
}

function makeDatasetRow(uri: string): DatasetRow {
  return {
    dataset_id: 'ds_1',
    name: '示例题目集',
    source_uri: uri,
    total_count: 2,
    valid_count: 2,
    cases_json: '[{"content":"q1","referenceAnswer":"a1"},{"content":"q2","referenceAnswer":"a2"}]',
    imported_at: 1000
  };
}

function makeTaskRow(taskId: string, name: string, status: string): EvalTaskRow {
  return {
    task_id: taskId,
    name: name,
    config_id: 'cfg_1',
    dataset_uri: 'file://ds/1.json',
    params_json: JSON.stringify(makeParams()),
    status: status,
    flag: ExecutionFlag.EXECUTING,
    snapshot_json: null,
    dataset_json: null,
    created_at: 1000
  };
}

function makeService(store: FakeTaskStore, file: StubFile, hasConfig: boolean): TaskConfigService {
  const deps: TaskConfigDeps = {
    store: store,
    file: file,
    logger: new StubLogger(),
    configProvider: (configId: string): Promise<ModelServiceConfig> => {
      if (!hasConfig) {
        return Promise.reject(new AppError(ErrorCode.CFG_MISSING_FIELD, '配置不存在'));
      }
      return Promise.resolve(makeConfig());
    }
  };
  return TaskConfigService.createForTest(deps);
}

function repeatCaseJson(count: number): string {
  let json: string = '[';
  for (let i = 0; i < count; i++) {
    json += `${i > 0 ? ',' : ''}{"content":"q","referenceAnswer":"a"}`;
  }
  return json + ']';
}

export default function taskConfigTest() {
  describe('DatasetValidator', () => {
    it('parses_valid_json_array', 0, () => {
      const report: DatasetValidationReport =
        DatasetValidator.parse('a.json', '[{"content":"1+1=?","referenceAnswer":"2"}]');
      expect(report.totalCount).assertEqual(1);
      expect(report.validCount).assertEqual(1);
      expect(report.missingReferenceIndexes.length).assertEqual(0);
      expect(report.cases[0].referenceAnswer).assertEqual('2');
    });

    it('parses_compatible_keys', 0, () => {
      const report: DatasetValidationReport =
        DatasetValidator.parse('a.json', '[{"question":"问题","answer":"答案"}]');
      expect(report.validCount).assertEqual(1);
      expect(report.cases[0].content).assertEqual('问题');
    });

    it('reports_missing_reference_indexes', 0, () => {
      const report: DatasetValidationReport =
        DatasetValidator.parse('a.json', '[{"content":"Q"},{"content":"Q2","referenceAnswer":"A2"}]');
      expect(report.missingReferenceIndexes.length).assertEqual(1);
      expect(report.missingReferenceIndexes[0]).assertEqual(0);
      expect(report.validCount).assertEqual(1);
    });

    it('rejects_case_limit_exceeded', 0, () => {
      let thrown: AppError | null = null;
      try {
        DatasetValidator.parse('big.json', repeatCaseJson(DATASET_CASE_LIMIT + 1));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.DS_CASE_LIMIT_EXCEEDED);
      }
    });

    it('rejects_broken_json', 0, () => {
      let thrown: AppError | null = null;
      try {
        DatasetValidator.parse('bad.json', '{not-json');
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.DS_PARSE_FAILED);
      }
    });

    it('rejects_non_array_top_level', 0, () => {
      let thrown: AppError | null = null;
      try {
        DatasetValidator.parse('obj.json', '{"content":"q"}');
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.DS_PARSE_FAILED);
      }
    });
  });

  describe('TaskModel', () => {
    it('can_edit_only_when_not_running', 0, () => {
      const pending: EvaluationTask = {
        taskId: 't1', name: 'n', configId: 'c', datasetUri: 'u', params: makeParams(),
        status: TaskStatus.PENDING, flag: ExecutionFlag.EXECUTING, createdAt: 1
      };
      const running: EvaluationTask = {
        taskId: 't2', name: 'n', configId: 'c', datasetUri: 'u', params: makeParams(),
        status: TaskStatus.RUNNING, flag: ExecutionFlag.EXECUTING, createdAt: 1
      };
      expect(taskCanEdit(pending)).assertTrue();
      expect(taskCanEdit(running)).assertFalse();
    });

    it('can_start_requires_valid_cases', 0, () => {
      const task: EvaluationTask = {
        taskId: 't1', name: 'n', configId: 'c', datasetUri: 'u', params: makeParams(),
        status: TaskStatus.PENDING, flag: ExecutionFlag.EXECUTING, createdAt: 1
      };
      expect(taskCanStart(task)).assertFalse();
      task.dataset = buildDatasetSnapshot('ds', [{ content: 'q', referenceAnswer: 'a' }]);
      expect(taskCanStart(task)).assertTrue();
    });

    it('dataset_snapshot_seq_starts_at_zero', 0, () => {
      const snapshot = buildDatasetSnapshot('ds', [
        { content: 'q1', referenceAnswer: 'a1' },
        { content: 'q2', referenceAnswer: 'a2' }
      ]);
      expect(snapshot.cases[0].seq).assertEqual(0);
      expect(snapshot.cases[1].seq).assertEqual(1);
    });

    it('config_snapshot_is_immutable_copy', 0, () => {
      const params: RunParameters = makeParams();
      const snapshot = buildSnapshot(makeConfig(), params);
      params.temperature = 1.9;
      expect(snapshot.params.temperature).assertEqual(0.7);
      expect(snapshot.targetModel).assertEqual('deepseek-chat');
      expect(snapshot.configName).assertEqual('本地服务');
    });

    it('maps_row_back_to_task', 0, () => {
      const task: EvaluationTask = rowToTask(makeTaskRow('t1', '任务A', TaskStatus.PENDING));
      expect(task.taskId).assertEqual('t1');
      expect(task.status).assertEqual(TaskStatus.PENDING);
    });
  });

  describe('TaskConfigService', () => {
    it('create_persists_snapshot_and_dataset', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      store.seedDataset(makeDatasetRow('file://ds/1.json'));
      const service: TaskConfigService = makeService(store, new StubFile(), true);

      const task: EvaluationTask = await service.createTask(makeDraft('任务A', 'file://ds/1.json'));
      expect(store.taskCount()).assertEqual(1);
      expect(task.snapshot !== undefined).assertTrue();
      expect(task.dataset !== undefined).assertTrue();
      if (task.dataset !== undefined) {
        expect(task.dataset.cases.length).assertEqual(2);
        expect(task.dataset.cases[0].seq).assertEqual(0);
      }
      const row: EvalTaskRow | undefined = store.findTask(task.taskId);
      expect(row !== undefined).assertTrue();
      if (row !== undefined) {
        expect(row.snapshot_json !== null).assertTrue();
        expect(row.dataset_json !== null).assertTrue();
      }
    });

    it('create_rejects_duplicate_name', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      store.seedDataset(makeDatasetRow('file://ds/1.json'));
      store.seedTask(makeTaskRow('t0', '任务A', TaskStatus.PENDING));
      const service: TaskConfigService = makeService(store, new StubFile(), true);

      let thrown: AppError | null = null;
      try {
        await service.createTask(makeDraft('任务A', 'file://ds/1.json'));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_DUPLICATE_NAME);
      }
    });

    it('create_rejects_param_out_of_range', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      store.seedDataset(makeDatasetRow('file://ds/1.json'));
      const service: TaskConfigService = makeService(store, new StubFile(), true);
      const draft: TaskConfigDraft = makeDraft('任务B', 'file://ds/1.json');
      draft.params.temperature = 3.0;

      let thrown: AppError | null = null;
      try {
        await service.createTask(draft);
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_PARAM_OUT_OF_RANGE);
      }
    });

    it('create_rejects_missing_dataset', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      const service: TaskConfigService = makeService(store, new StubFile(), true);
      let thrown: AppError | null = null;
      try {
        await service.createTask(makeDraft('任务C', 'file://ds/absent.json'));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_INCOMPLETE_CONFIG);
      }
    });

    it('create_rejects_missing_config', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      store.seedDataset(makeDatasetRow('file://ds/1.json'));
      const service: TaskConfigService = makeService(store, new StubFile(), false);
      let thrown: AppError | null = null;
      try {
        await service.createTask(makeDraft('任务D', 'file://ds/1.json'));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_INCOMPLETE_CONFIG);
      }
    });

    it('update_rejected_when_running', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      store.seedDataset(makeDatasetRow('file://ds/1.json'));
      store.seedTask(makeTaskRow('t1', '任务E', TaskStatus.RUNNING));
      const service: TaskConfigService = makeService(store, new StubFile(), true);

      let thrown: AppError | null = null;
      try {
        await service.updateTask('t1', makeDraft('任务E', 'file://ds/1.json'));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.TASK_ALREADY_RUNNING);
      }
    });

    it('detects_running_task_referencing_config', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      store.seedTask(makeTaskRow('t1', '运行中', TaskStatus.RUNNING));
      store.seedTask(makeTaskRow('t2', '待运行', TaskStatus.PENDING));
      const service: TaskConfigService = makeService(store, new StubFile(), true);
      expect(await service.hasTaskReferencingConfig('cfg_1')).assertTrue();
      expect(await service.hasTaskReferencingConfig('cfg_other')).assertFalse();
    });

    it('import_dataset_writes_and_overwrites', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      const file: StubFile = new StubFile();
      file.setPresetPick({ uri: 'file://ds/new.json', name: 'new.json' });
      file.putFile('file://ds/new.json', '[{"content":"q1","referenceAnswer":"a1"}]');
      const service: TaskConfigService = makeService(store, file, true);

      const report: DatasetValidationReport = await service.importDataset();
      expect(report.validCount).assertEqual(1);
      expect(store.datasetCount()).assertEqual(1);

      file.putFile('file://ds/new.json', '[{"content":"q1","referenceAnswer":"a1"},{"content":"q2","referenceAnswer":"a2"}]');
      await service.importDataset();
      expect(store.datasetCount()).assertEqual(1);
      const row: DatasetRow | undefined = store.findDataset('file://ds/new.json');
      expect(row !== undefined).assertTrue();
      if (row !== undefined) {
        expect(row.valid_count).assertEqual(2);
      }
    });

    it('import_dataset_rejects_missing_reference', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      const file: StubFile = new StubFile();
      file.setPresetPick({ uri: 'file://ds/bad.json', name: 'bad.json' });
      file.putFile('file://ds/bad.json', '[{"content":"q"}]');
      const service: TaskConfigService = makeService(store, file, true);

      let thrown: AppError | null = null;
      try {
        await service.importDataset();
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.DS_MISSING_REFERENCE);
      }
      expect(store.datasetCount()).assertEqual(0);
    });

    it('import_dataset_rejects_broken_file', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      const file: StubFile = new StubFile();
      file.setPresetPick({ uri: 'file://ds/corrupt.json', name: 'corrupt.json' });
      file.putFile('file://ds/corrupt.json', 'corrupted');
      const service: TaskConfigService = makeService(store, file, true);

      let thrown: AppError | null = null;
      try {
        await service.importDataset();
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.DS_PARSE_FAILED);
      }
      expect(store.datasetCount()).assertEqual(0);
    });

    it('clear_all_datasets', 0, async () => {
      const store: FakeTaskStore = new FakeTaskStore();
      store.seedDataset(makeDatasetRow('file://ds/1.json'));
      const service: TaskConfigService = makeService(store, new StubFile(), true);
      await service.clearAllDatasets();
      expect(store.datasetCount()).assertEqual(0);
    });
  });
}