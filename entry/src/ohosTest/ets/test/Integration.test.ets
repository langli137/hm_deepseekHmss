/**
 * 跨模块集成测试（tasks.md 10.1）。
 * 覆盖两条主链路：
 * 1. 配置服务 → 创建任务 → 启动执行 → 指标计算 → 归档
 * 2. 导入题目集 → 快照固化 → 执行 → 续跑（验证 watermark 不重复）
 * 全部使用 createForTest 模式注入桩依赖，不依赖真实系统能力。
 */
import { describe, expect, it } from '@ohos/hypium';
import { ServiceConfigService, ServiceConfigDeps } from '../../../main/ets/biz/serviceconfig/ServiceConfigService';
import { TaskConfigService, TaskConfigDeps } from '../../../main/ets/biz/taskconfig/TaskConfigService';
import { ExecutionService, ExecutionDeps, RunRecordArchiveInput } from '../../../main/ets/biz/execution/ExecutionService';
import { RunRecordService, RunRecordDeps } from '../../../main/ets/biz/runrecord/RunRecordService';
import { MetricReportService, MetricReportDeps } from '../../../main/ets/biz/metricreport/MetricReportService';
import { MetricCalculator } from '../../../main/ets/domain/metric/MetricCalculator';
import { RelationalStorePort } from '../../../main/ets/infra/ports/RelationalStorePort';
import { PreferencesPort } from '../../../main/ets/infra/ports/PreferencesPort';
import { CryptoPort } from '../../../main/ets/infra/ports/CryptoPort';
import { ModelClientPort } from '../../../main/ets/infra/ports/ModelClientPort';
import { NetworkMonitorPort } from '../../../main/ets/infra/ports/NetworkMonitorPort';
import { BackgroundTaskPort } from '../../../main/ets/infra/ports/BackgroundTaskPort';
import { NotificationPort } from '../../../main/ets/infra/ports/NotificationPort';
import { FilePort } from '../../../main/ets/infra/ports/FilePort';
import { LoggerPort } from '../../../main/ets/infra/ports/LoggerPort';
import {
  BackgroundTaskHandle, ExecSpec, ExportResult, NetworkState, QuerySpec, SecretRef, TxContext, Unsubscribe
} from '../../../main/ets/common/types/InfraTypes';
import {
  CaseResult, CaseSnapshot, ChatChunk, ChatRequest, ChatResult, ConnectionTestResult,
  DatasetSnapshot, DatasetValidationReport, EvaluationTask, ExecutionObserver, ExecutionProgress,
  Metrics, ModelServiceConfig, RunParameters, UsageSummary, TaskConfigDraft, ServiceConfigDraft,
  DatasetCaseDraft, RunRecord, RunRecordQuery, AppSettings
} from '../../../main/ets/common/types/DomainTypes';
import {
  ConfigStatus, ExecutionFlag, InterruptReason, JudgeMode, LogEvent, LogLevel,
  RunRecordStatus, TaskStatus, Verdict
} from '../../../main/ets/common/types/Enums';
import { AppError } from '../../../main/ets/common/error/AppError';
import { ErrorCode } from '../../../main/ets/common/error/ErrorCode';
import { DEFAULT_RECORD_LIMIT, MODEL_VERSION } from '../../../main/ets/common/types/Constants';
import { StubModelClient, StubModelBehavior } from '../../../main/ets/infra/stubs/StubModelClient';
import { StubNetwork } from '../../../main/ets/infra/stubs/StubNetwork';
import { StubBackgroundTask } from '../../../main/ets/infra/stubs/StubBackgroundTask';
import { StubNotification } from '../../../main/ets/infra/stubs/StubNotification';
import { StubLogger, StubLogEntry } from '../../../main/ets/infra/stubs/StubLogger';
import { StubCrypto } from '../../../main/ets/infra/stubs/StubCrypto';
import { StubPreferences } from '../../../main/ets/infra/stubs/StubPreferences';
import { StubStore } from '../../../main/ets/infra/stubs/StubStore';
import { createDefaultParams } from '../../../main/ets/common/utils/ParamRules';

// ============ 统一内存存储桩（支撑全部表） ============

interface ServiceConfigRow {
  config_id: string; name: string; endpoint: string; target_model: string;
  is_default: number; status: string; secret_alias: string | null; secret_algo: string | null; created_at: number;
}
interface EvalTaskRow {
  task_id: string; name: string; config_id: string; dataset_uri: string;
  params_json: string; status: string; flag: string; snapshot_json: string | null;
  dataset_json: string | null; created_at: number;
}
interface DatasetRow {
  dataset_id: string; name: string; source_uri: string; total_count: number;
  valid_count: number; cases_json: string; imported_at: number;
}
interface CaseResultRow {
  case_id: string; task_id: string; seq: number; content: string;
  reference_answer: string | null; model_answer: string | null; verdict: string; elapsed_ms: number;
}
interface ProgressRow {
  task_id: string; watermark_seq: number; completed_count: number; total_count: number;
}
interface RunRecordRow {
  record_id: string; task_id: string; task_name: string; target_model: string;
  status: string; started_at: number; ended_at: number; model_version: number;
  dataset_uri: string | null; metrics_json: string;
}

class IntegrationTxContext implements TxContext {
  private owner: IntegrationStore;
  constructor(owner: IntegrationStore) { this.owner = owner; }
  async query<T>(spec: QuerySpec): Promise<T[]> { return this.owner.query<T>(spec); }
  async execute(spec: ExecSpec): Promise<number> { return this.owner.execute(spec); }
}

class IntegrationStore implements RelationalStorePort {
  configRows: ServiceConfigRow[] = [];
  taskRows: EvalTaskRow[] = [];
  datasetRows: DatasetRow[] = [];
  caseRows: CaseResultRow[] = [];
  progressRows: ProgressRow[] = [];
  recordRows: RunRecordRow[] = [];

  async transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T> {
    return work(new IntegrationTxContext(this));
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];

    if (sql.includes('FROM service_config') && sql.includes('WHERE name')) {
      const name: string = args[0] as string;
      return this.configRows.filter(r => r.name === name) as T[];
    }
    if (sql.includes('FROM service_config') && sql.includes('WHERE config_id')) {
      const id: string = args[0] as string;
      return this.configRows.filter(r => r.config_id === id) as T[];
    }
    if (sql.includes('FROM service_config') && sql.includes('is_default = 1')) {
      return this.configRows.filter(r => r.is_default === 1) as T[];
    }
    if (sql.includes('FROM service_config')) {
      return [...this.configRows].sort((a, b) => b.is_default - a.is_default || b.created_at - a.created_at) as T[];
    }
    if (sql.includes('FROM eval_task') && sql.includes('WHERE name')) {
      const name: string = args[0] as string;
      return this.taskRows.filter(r => r.name === name) as T[];
    }
    if (sql.includes('FROM eval_task') && sql.includes('WHERE config_id')) {
      const cid: string = args[0] as string;
      const st: string = args[1] as string;
      return this.taskRows.filter(r => r.config_id === cid && r.status === st) as T[];
    }
    if (sql.includes('FROM eval_task') && sql.includes('WHERE status')) {
      const st: string = args[0] as string;
      return this.taskRows.filter(r => r.status === st) as T[];
    }
    if (sql.includes('FROM eval_task') && sql.includes('WHERE task_id')) {
      const id: string = args[0] as string;
      return this.taskRows.filter(r => r.task_id === id) as T[];
    }
    if (sql.includes('FROM eval_task')) {
      return [...this.taskRows].sort((a, b) => b.created_at - a.created_at) as T[];
    }
    if (sql.includes('FROM dataset') && sql.includes('WHERE source_uri')) {
      const uri: string = args[0] as string;
      return this.datasetRows.filter(r => r.source_uri === uri) as T[];
    }
    if (sql.includes('FROM dataset')) {
      return [...this.datasetRows] as T[];
    }
    if (sql.includes('FROM case_result') && sql.includes('WHERE task_id')) {
      const tid: string = args[0] as string;
      return this.caseRows.filter(r => r.task_id === tid).sort((a, b) => a.seq - b.seq) as T[];
    }
    if (sql.includes('FROM task_progress') && sql.includes('WHERE task_id')) {
      const tid: string = args[0] as string;
      return this.progressRows.filter(r => r.task_id === tid) as T[];
    }
    if (sql.includes('FROM run_record') && sql.includes('WHERE record_id')) {
      const id: string = args[0] as string;
      return this.recordRows.filter(r => r.record_id === id) as T[];
    }
    if (sql.includes('FROM run_record') && sql.includes('WHERE task_id')) {
      const tid: string = args[0] as string;
      return this.recordRows.filter(r => r.task_id === tid) as T[];
    }
    if (sql.includes('COUNT(*)') && sql.includes('FROM run_record')) {
      return [{ cnt: this.recordRows.length }] as T[];
    }
    if (sql.includes('FROM run_record')) {
      let filtered: RunRecordRow[] = [...this.recordRows];
      const conditions: string[] = [];
      if (sql.includes('task_name LIKE')) {
        const kw: string = args[0] as string;
        filtered = filtered.filter(r => r.task_name.includes(kw.replace(/%/g, '')));
      }
      if (sql.includes('target_model =')) {
        const idx: number = sql.indexOf('target_model =');
        const modelArg: string = args[sql.substring(0, idx).split('?').length - 1] as string;
        filtered = filtered.filter(r => r.target_model === modelArg);
      }
      if (sql.includes('status =')) {
        const idx: number = sql.indexOf('status =');
        const statusArg: string = args[sql.substring(0, idx).split('?').length - 1] as string;
        filtered = filtered.filter(r => r.status === statusArg);
      }
      return filtered.sort((a, b) => b.started_at - a.started_at) as T[];
    }
    return [];
  }

  async execute(spec: ExecSpec): Promise<number> {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];

    if (sql.includes('CREATE TABLE') || sql.includes('CREATE INDEX')) {
      return 0;
    }
    if (sql.startsWith('INSERT INTO service_config')) {
      this.configRows.push({
        config_id: args[0] as string, name: args[1] as string, endpoint: args[2] as string,
        target_model: args[3] as string, is_default: args[4] as number, status: args[5] as string,
        secret_alias: args[6] as string | null, secret_algo: args[7] as string | null, created_at: args[8] as number
      });
      return 1;
    }
    if (sql.startsWith('UPDATE service_config SET name')) {
      const id: string = args[7] as string;
      for (let i = 0; i < this.configRows.length; i++) {
        if (this.configRows[i].config_id === id) {
          this.configRows[i].name = args[0] as string;
          this.configRows[i].endpoint = args[1] as string;
          this.configRows[i].target_model = args[2] as string;
          this.configRows[i].is_default = args[3] as number;
          this.configRows[i].status = args[4] as string;
          this.configRows[i].secret_alias = args[5] as string | null;
          this.configRows[i].secret_algo = args[6] as string | null;
        }
      }
      return 1;
    }
    if (sql.includes('UPDATE service_config SET is_default = 0')) {
      for (let i = 0; i < this.configRows.length; i++) {
        this.configRows[i].is_default = 0;
      }
      return this.configRows.length;
    }
    if (sql.includes('UPDATE service_config SET is_default = 1')) {
      const id: string = args[0] as string;
      for (let i = 0; i < this.configRows.length; i++) {
        if (this.configRows[i].config_id === id) {
          this.configRows[i].is_default = 1;
        }
      }
      return 1;
    }
    if (sql.startsWith('DELETE FROM service_config')) {
      const id: string = args[0] as string;
      const before: number = this.configRows.length;
      this.configRows = this.configRows.filter(r => r.config_id !== id);
      return before - this.configRows.length;
    }
    if (sql.startsWith('INSERT INTO eval_task')) {
      this.taskRows.push({
        task_id: args[0] as string, name: args[1] as string, config_id: args[2] as string,
        dataset_uri: args[3] as string, params_json: args[4] as string, status: args[5] as string,
        flag: args[6] as string, snapshot_json: args[7] as string | null,
        dataset_json: args[8] as string | null, created_at: args[9] as number
      });
      return 1;
    }
    if (sql.startsWith('UPDATE eval_task SET name')) {
      const id: string = args[6] as string;
      for (let i = 0; i < this.taskRows.length; i++) {
        if (this.taskRows[i].task_id === id) {
          this.taskRows[i].name = args[0] as string;
          this.taskRows[i].config_id = args[1] as string;
          this.taskRows[i].dataset_uri = args[2] as string;
          this.taskRows[i].params_json = args[3] as string;
          this.taskRows[i].snapshot_json = args[4] as string | null;
          this.taskRows[i].dataset_json = args[5] as string | null;
        }
      }
      return 1;
    }
    if (sql.startsWith('UPDATE eval_task SET status')) {
      const id: string = args[2] as string;
      for (let i = 0; i < this.taskRows.length; i++) {
        if (this.taskRows[i].task_id === id) {
          this.taskRows[i].status = args[0] as string;
          this.taskRows[i].flag = args[1] as string;
        }
      }
      return 1;
    }
    if (sql.startsWith('DELETE FROM eval_task')) {
      const id: string = args[0] as string;
      const before: number = this.taskRows.length;
      this.taskRows = this.taskRows.filter(r => r.task_id !== id);
      return before - this.taskRows.length;
    }
    if (sql.startsWith('INSERT INTO dataset')) {
      this.datasetRows.push({
        dataset_id: args[0] as string, name: args[1] as string, source_uri: args[2] as string,
        total_count: args[3] as number, valid_count: args[4] as number,
        cases_json: args[5] as string, imported_at: args[6] as number
      });
      return 1;
    }
    if (sql.startsWith('UPDATE dataset SET')) {
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
    if (sql.startsWith('INSERT INTO case_result')) {
      this.caseRows.push({
        case_id: args[0] as string, task_id: args[1] as string, seq: args[2] as number,
        content: args[3] as string, reference_answer: args[4] as string | null,
        model_answer: args[5] as string | null, verdict: args[6] as string, elapsed_ms: args[7] as number
      });
      return 1;
    }
    if (sql.startsWith('INSERT INTO task_progress')) {
      const tid: string = args[0] as string;
      const existing: number = this.progressRows.findIndex(r => r.task_id === tid);
      if (existing >= 0) {
        this.progressRows[existing].watermark_seq = args[1] as number;
        this.progressRows[existing].completed_count = args[2] as number;
        this.progressRows[existing].total_count = args[3] as number;
      } else {
        this.progressRows.push({
          task_id: tid, watermark_seq: args[1] as number,
          completed_count: args[2] as number, total_count: args[3] as number
        });
      }
      return 1;
    }
    if (sql.startsWith('UPDATE task_progress SET watermark_seq')) {
      const tid: string = args[2] as string;
      for (let i = 0; i < this.progressRows.length; i++) {
        if (this.progressRows[i].task_id === tid) {
          this.progressRows[i].watermark_seq = args[0] as number;
          this.progressRows[i].completed_count = args[1] as number;
        }
      }
      return 1;
    }
    if (sql.startsWith('INSERT INTO run_record')) {
      this.recordRows.push({
        record_id: args[0] as string, task_id: args[1] as string, task_name: args[2] as string,
        target_model: args[3] as string, status: args[4] as string, started_at: args[5] as number,
        ended_at: args[6] as number, model_version: args[7] as number,
        dataset_uri: args[8] as string | null, metrics_json: args[9] as string
      });
      return 1;
    }
    if (sql.startsWith('DELETE FROM run_record WHERE record_id')) {
      const id: string = args[0] as string;
      const before: number = this.recordRows.length;
      this.recordRows = this.recordRows.filter(r => r.record_id !== id);
      return before - this.recordRows.length;
    }
    if (sql.startsWith('DELETE FROM case_result WHERE task_id')) {
      const tid: string = args[0] as string;
      const before: number = this.caseRows.length;
      this.caseRows = this.caseRows.filter(r => r.task_id !== tid);
      return before - this.caseRows.length;
    }
    if (sql.startsWith('DELETE FROM run_record')) {
      this.recordRows = [];
      return 1;
    }
    if (sql.startsWith('DELETE FROM case_result')) {
      this.caseRows = [];
      return 1;
    }
    return 0;
  }

  // ============ 测试辅助方法 ============

  findConfig(id: string): ServiceConfigRow | undefined {
    return this.configRows.find(r => r.config_id === id);
  }
  findTask(id: string): EvalTaskRow | undefined {
    return this.taskRows.find(r => r.task_id === id);
  }
  findProgress(tid: string): ProgressRow | undefined {
    return this.progressRows.find(r => r.task_id === tid);
  }
  caseCountForTask(tid: string): number {
    return this.caseRows.filter(r => r.task_id === tid).length;
  }
  recordCount(): number {
    return this.recordRows.length;
  }
}

// ============ 文件桩 ============

class IntegrationFile implements FilePort {
  pickedUri: string = '';
  pickedName: string = '';
  content: string = '';
  savedContent: string = '';
  savedFileName: string = '';

  async pickFile(opts: { fileSuffixFilters: string[]; maxCount: number }): Promise<{ uri: string; name: string } | null> {
    if (this.pickedUri.length === 0) {
      return null;
    }
    return { uri: this.pickedUri, name: this.pickedName };
  }

  async readText(uri: string): Promise<string> {
    return this.content;
  }

  async saveText(opts: { suggestedFileName: string; fileSuffix: string }, content: string): Promise<ExportResult> {
    this.savedContent = content;
    this.savedFileName = opts.suggestedFileName;
    return { success: true, uri: 'file://saved/' + opts.suggestedFileName, reason: '' };
  }

  setPickResult(uri: string, name: string): void {
    this.pickedUri = uri;
    this.pickedName = name;
  }

  setFileContent(content: string): void {
    this.content = content;
  }
}

// ============ 测试数据构造 ============

function makeParams(): RunParameters {
  return { temperature: 0.7, maxOutputTokens: 2048, concurrency: 1, timeoutMs: 60000, judgeMode: JudgeMode.CONTAINS };
}

function makeConfig(configId: string): ModelServiceConfig {
  return {
    configId: configId, name: '测试服务', endpoint: 'https://api.test.com/v1',
    targetModel: 'test-model', isDefault: true, status: ConfigStatus.VALID,
    secretRef: { alias: 'a1', algorithm: 'AES256-GCM' }, createdAt: 1000
  };
}

function makeDatasetSnapshot(cases: CaseSnapshot[]): DatasetSnapshot {
  return { modelVersion: MODEL_VERSION, name: '测试题目集', cases: cases };
}

function makeTask(taskId: string, configId: string, datasetUri: string, cases: CaseSnapshot[]): EvaluationTask {
  return {
    taskId: taskId, name: '集成测试任务', configId: configId, datasetUri: datasetUri,
    params: makeParams(), status: TaskStatus.PENDING, flag: ExecutionFlag.EXECUTING,
    snapshot: { modelVersion: MODEL_VERSION, params: makeParams(), targetModel: 'test-model', configName: '测试服务' },
    dataset: makeDatasetSnapshot(cases), createdAt: 1000
  };
}

function makeDatasetJson(cases: CaseSnapshot[]): string {
  return JSON.stringify({ modelVersion: MODEL_VERSION, name: '测试题目集', cases: cases });
}

function makeParamsJson(): string {
  return JSON.stringify(makeParams());
}

function makeSnapshotJson(): string {
  return JSON.stringify({ modelVersion: MODEL_VERSION, params: makeParams(), targetModel: 'test-model', configName: '测试服务' });
}

// ============ 集成测试 ============

export default function integrationTest() {
  describe('IntegrationTest', () => {

    // ============ 链路1：配置服务 → 创建任务 → 启动执行 → 指标计算 → 归档 ============

    describe('MainChain_ConfigToArchive', () => {
      it('full_pipeline_config_to_archive', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const crypto: StubCrypto = new StubCrypto();
        const logger: StubLogger = new StubLogger();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();
        const bgTask: StubBackgroundTask = new StubBackgroundTask();
        const notification: StubNotification = new StubNotification();

        // 1. 配置服务：保存模型服务配置
        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);
        const draft: ServiceConfigDraft = {
          name: '测试服务', endpoint: 'https://api.test.com/v1',
          targetModel: 'test-model', secret: 'sk-test-key', isDefault: true
        };
        const savedConfig: ModelServiceConfig = await configService.saveConfig(draft);
        expect(savedConfig.configId.length > 0).assertTrue();
        expect(savedConfig.isDefault).assertTrue();

        // 验证：数据库中仅存 SecretRef，无明文密钥
        const configRow: ServiceConfigRow | undefined = store.findConfig(savedConfig.configId);
        expect(configRow !== undefined).assertTrue();
        if (configRow !== undefined) {
          expect(configRow.secret_alias !== null).assertTrue();
          expect(configRow.secret_alias !== 'sk-test-key').assertTrue();
        }

        // 2. 任务配置服务：创建评测任务
        const fileStub: IntegrationFile = new IntegrationFile();
        const taskDeps: TaskConfigDeps = {
          store: store, file: fileStub, logger: logger,
          configProvider: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid)
        };
        const taskService: TaskConfigService = TaskConfigService.createForTest(taskDeps);

        // 先导入题目集
        const cases: CaseSnapshot[] = [
          { seq: 0, content: '1+1=?', referenceAnswer: '2' },
          { seq: 1, content: '2+2=?', referenceAnswer: '4' }
        ];
        fileStub.setPickResult('file://ds/test.json', 'test.json');
        fileStub.setFileContent(JSON.stringify([
          { content: '1+1=?', referenceAnswer: '2' },
          { content: '2+2=?', referenceAnswer: '4' }
        ]));
        const importReport: DatasetValidationReport = await taskService.importDataset();
        expect(importReport.validCount).assertEqual(2);

        // 创建任务
        const taskDraft: TaskConfigDraft = {
          name: '集成测试任务', configId: savedConfig.configId,
          datasetUri: 'file://ds/test.json', params: makeParams()
        };
        const task: EvaluationTask = await taskService.createTask(taskDraft);
        expect(task.taskId.length > 0).assertTrue();
        expect(task.status).assertEqual(TaskStatus.PENDING);

        // 验证：快照已固化（包含 modelVersion）
        expect(task.snapshot !== undefined).assertTrue();
        if (task.snapshot !== undefined) {
          expect(task.snapshot.modelVersion).assertEqual(MODEL_VERSION);
          expect(task.snapshot.targetModel).assertEqual('test-model');
        }
        expect(task.dataset !== undefined).assertTrue();
        if (task.dataset !== undefined) {
          expect(task.dataset.modelVersion).assertEqual(MODEL_VERSION);
          expect(task.dataset.cases.length).assertEqual(2);
        }

        // 3. 执行服务：启动执行
        let archivedInput: RunRecordArchiveInput | null = null;
        const execDeps: ExecutionDeps = {
          store: store, modelClient: modelClient, network: network,
          backgroundTask: bgTask, notification: notification, logger: logger,
          getConfig: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid),
          revealSecret: (cid: string): Promise<string> => configService.revealSecret(cid),
          getTask: (tid: string): Promise<EvaluationTask> => taskService.getTask(tid),
          archiveProvider: (input: RunRecordArchiveInput): Promise<string> => {
            archivedInput = input;
            return Promise.resolve('rec_integration_1');
          },
          notificationEnabledProvider: (): Promise<boolean> => Promise.resolve(false),
          metricsProvider: (cs: CaseResult[], usage?: UsageSummary): Metrics =>
            MetricCalculator.compute(cs, usage)
        };
        const execService: ExecutionService = ExecutionService.createForTest(execDeps);

        // 需要把任务状态设为 PENDING 才能启动
        const taskRow: EvalTaskRow | undefined = store.findTask(task.taskId);
        expect(taskRow !== undefined).assertTrue();

        await execService.start(task.taskId);

        // 等待执行完成（异步调度循环）
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 200);
        });

        // 4. 验证指标计算与归档
        expect(archivedInput !== null).assertTrue();
        if (archivedInput !== null) {
          expect(archivedInput.caseResults.length).assertEqual(2);
          expect(archivedInput.modelVersion).assertEqual(MODEL_VERSION);
          expect(archivedInput.status).assertEqual(RunRecordStatus.COMPLETED);

          // 指标应以 CaseResult[] 为唯一数据源
          const metrics: Metrics = MetricCalculator.compute(archivedInput.caseResults, archivedInput.usage);
          expect(metrics.computed).assertTrue();
          expect(metrics.usage.totalTokens > 0).assertTrue();
        }

        // 5. 验证 case_result + task_progress 同事务提交
        const progress: ProgressRow | undefined = store.findProgress(task.taskId);
        expect(progress !== undefined).assertTrue();
        if (progress !== undefined) {
          expect(progress.watermark_seq).assertEqual(1);
          expect(progress.completed_count).assertEqual(2);
        }
        expect(store.caseCountForTask(task.taskId)).assertEqual(2);
      });

      it('metric_consistency_check', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();

        // 直接写入一条 run_record 和对应的 case_result
        const taskId: string = 'task_consistency';
        const cases: CaseResult[] = [
          { caseId: 'c1', taskId: taskId, seq: 0, content: '1+1', referenceAnswer: '2', modelAnswer: '2', verdict: Verdict.PASSED, elapsedMs: 100 },
          { caseId: 'c2', taskId: taskId, seq: 1, content: '2+2', referenceAnswer: '4', modelAnswer: '5', verdict: Verdict.FAILED, elapsedMs: 200 }
        ];

        for (let i = 0; i < cases.length; i++) {
          store.caseRows.push({
            case_id: cases[i].caseId, task_id: cases[i].taskId, seq: cases[i].seq,
            content: cases[i].content, reference_answer: cases[i].referenceAnswer,
            model_answer: cases[i].modelAnswer, verdict: cases[i].verdict, elapsed_ms: cases[i].elapsedMs
          });
        }

        const metrics: Metrics = MetricCalculator.compute(cases);
        const metricsJson: string = JSON.stringify({
          accuracy: metrics.accuracy, passRate: metrics.passRate,
          avgElapsedMs: metrics.avgElapsedMs, usage: metrics.usage, computed: metrics.computed
        });

        store.recordRows.push({
          record_id: 'rec_consist', task_id: taskId, task_name: '一致性测试',
          target_model: 'test-model', status: RunRecordStatus.COMPLETED,
          started_at: 1000, ended_at: 2000, model_version: MODEL_VERSION,
          dataset_uri: 'file://ds/test.json', metrics_json: metricsJson
        });

        // 使用 RunRecordService.isConsistent 验证
        const runRecordDeps: RunRecordDeps = {
          store: store, logger: logger,
          recordLimitProvider: (): Promise<number> => Promise.resolve(DEFAULT_RECORD_LIMIT),
          hasRunningTaskProvider: (): boolean => false,
          runningTaskIdProvider: (): string | undefined => undefined
        };
        const runRecordService: RunRecordService = RunRecordService.createForTest(runRecordDeps);

        const consistent: boolean = await runRecordService.isConsistent('rec_consist');
        expect(consistent).assertTrue();
      });

      it('metric_inconsistency_detected', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();

        const taskId: string = 'task_inconsist';
        // 写入 case_result：1 passed, 1 failed
        store.caseRows.push({
          case_id: 'c1', task_id: taskId, seq: 0, content: '1+1',
          reference_answer: '2', model_answer: '2', verdict: Verdict.PASSED, elapsed_ms: 100
        });
        store.caseRows.push({
          case_id: 'c2', task_id: taskId, seq: 1, content: '2+2',
          reference_answer: '4', model_answer: '5', verdict: Verdict.FAILED, elapsed_ms: 200
        });

        // 写入篡改后的 metrics_json（accuracy=1.0，但实际应为 0.5）
        store.recordRows.push({
          record_id: 'rec_inconsist', task_id: taskId, task_name: '篡改测试',
          target_model: 'test-model', status: RunRecordStatus.COMPLETED,
          started_at: 1000, ended_at: 2000, model_version: MODEL_VERSION,
          dataset_uri: 'file://ds/test.json',
          metrics_json: JSON.stringify({
            accuracy: 1.0, passRate: 1.0, avgElapsedMs: 150,
            usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: true
          })
        });

        const runRecordDeps: RunRecordDeps = {
          store: store, logger: logger,
          recordLimitProvider: (): Promise<number> => Promise.resolve(DEFAULT_RECORD_LIMIT),
          hasRunningTaskProvider: (): boolean => false,
          runningTaskIdProvider: (): string | undefined => undefined
        };
        const runRecordService: RunRecordService = RunRecordService.createForTest(runRecordDeps);

        const consistent: boolean = await runRecordService.isConsistent('rec_inconsist');
        expect(consistent).assertFalse();
      });
    });

    // ============ 链路2：导入题目集 → 快照固化 → 执行 → 续跑（验证 watermark 不重复） ============

    describe('DatasetSnapshotToResume', () => {
      it('snapshot_fixed_at_creation', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();
        const fileStub: IntegrationFile = new IntegrationFile();
        const crypto: StubCrypto = new StubCrypto();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();

        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);
        await configService.saveConfig({
          name: '测试服务', endpoint: 'https://api.test.com/v1',
          targetModel: 'test-model', secret: 'sk-test', isDefault: true
        });
        const configId: string = store.configRows[0].config_id;

        const taskDeps: TaskConfigDeps = {
          store: store, file: fileStub, logger: logger,
          configProvider: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid)
        };
        const taskService: TaskConfigService = TaskConfigService.createForTest(taskDeps);

        // 导入题目集
        fileStub.setPickResult('file://ds/snap.json', 'snap.json');
        fileStub.setFileContent(JSON.stringify([
          { content: '题1', referenceAnswer: '答1' },
          { content: '题2', referenceAnswer: '答2' },
          { content: '题3', referenceAnswer: '答3' }
        ]));
        await taskService.importDataset();

        // 创建任务（快照固化）
        const task: EvaluationTask = await taskService.createTask({
          name: '快照测试任务', configId: configId,
          datasetUri: 'file://ds/snap.json', params: makeParams()
        });

        // 验证快照不可变：修改配置后任务快照不变
        await configService.saveConfig({
          configId: configId, name: '改名服务', endpoint: 'https://api.test.com/v2',
          targetModel: 'new-model', secret: 'sk-new', isDefault: true
        });

        const reloadedTask: EvaluationTask = await taskService.getTask(task.taskId);
        expect(reloadedTask.snapshot !== undefined).assertTrue();
        if (reloadedTask.snapshot !== undefined) {
          expect(reloadedTask.snapshot.targetModel).assertEqual('test-model');
          expect(reloadedTask.snapshot.configName).assertEqual('测试服务');
        }
      });

      it('resume_does_not_repeat_completed_cases', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();
        const crypto: StubCrypto = new StubCrypto();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();
        const bgTask: StubBackgroundTask = new StubBackgroundTask();
        const notification: StubNotification = new StubNotification();

        // 配置服务
        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);
        await configService.saveConfig({
          name: '续跑服务', endpoint: 'https://api.test.com/v1',
          targetModel: 'test-model', secret: 'sk-test', isDefault: true
        });
        const configId: string = store.configRows[0].config_id;

        // 题目集导入 + 任务创建
        const fileStub: IntegrationFile = new IntegrationFile();
        const taskDeps: TaskConfigDeps = {
          store: store, file: fileStub, logger: logger,
          configProvider: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid)
        };
        const taskService: TaskConfigService = TaskConfigService.createForTest(taskDeps);

        fileStub.setPickResult('file://ds/resume.json', 'resume.json');
        fileStub.setFileContent(JSON.stringify([
          { content: '题A', referenceAnswer: '答A' },
          { content: '题B', referenceAnswer: '答B' },
          { content: '题C', referenceAnswer: '答C' }
        ]));
        await taskService.importDataset();

        const task: EvaluationTask = await taskService.createTask({
          name: '续跑测试任务', configId: configId,
          datasetUri: 'file://ds/resume.json', params: makeParams()
        });

        // 模拟部分完成：手动写入 case_result 和 task_progress
        store.caseRows.push({
          case_id: 'case_0', task_id: task.taskId, seq: 0,
          content: '题A', reference_answer: '答A', model_answer: '答A',
          verdict: Verdict.PASSED, elapsed_ms: 100
        });
        store.progressRows.push({
          task_id: task.taskId, watermark_seq: 0, completed_count: 1, total_count: 3
        });

        // 将任务状态设为 RUNNING + PAUSED
        const taskRow: EvalTaskRow | undefined = store.findTask(task.taskId);
        expect(taskRow !== undefined).assertTrue();
        if (taskRow !== undefined) {
          taskRow.status = TaskStatus.RUNNING;
          taskRow.flag = ExecutionFlag.PAUSED;
        }

        // 执行服务：resume 续跑
        let archivedInput: RunRecordArchiveInput | null = null;
        const execDeps: ExecutionDeps = {
          store: store, modelClient: modelClient, network: network,
          backgroundTask: bgTask, notification: notification, logger: logger,
          getConfig: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid),
          revealSecret: (cid: string): Promise<string> => configService.revealSecret(cid),
          getTask: (tid: string): Promise<EvaluationTask> => taskService.getTask(tid),
          archiveProvider: (input: RunRecordArchiveInput): Promise<string> => {
            archivedInput = input;
            return Promise.resolve('rec_resume_1');
          },
          notificationEnabledProvider: (): Promise<boolean> => Promise.resolve(false),
          metricsProvider: (cs: CaseResult[], usage?: UsageSummary): Metrics =>
            MetricCalculator.compute(cs, usage)
        };
        const execService: ExecutionService = ExecutionService.createForTest(execDeps);

        await execService.resume(task.taskId);

        // 等待执行完成
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 200);
        });

        // 验证：seq=0 的用例不被重复执行
        const caseResultsForTask: CaseResultRow[] = store.caseRows.filter(r => r.task_id === task.taskId);
        const seqZeroResults: CaseResultRow[] = caseResultsForTask.filter(r => r.seq === 0);
        expect(seqZeroResults.length).assertEqual(1);

        // 验证：全部 3 个用例都有结果
        expect(caseResultsForTask.length).assertEqual(3);

        // 验证：watermark 推进到最后一个 seq
        const progress: ProgressRow | undefined = store.findProgress(task.taskId);
        expect(progress !== undefined).assertTrue();
        if (progress !== undefined) {
          expect(progress.watermark_seq).assertEqual(2);
          expect(progress.completed_count).assertEqual(3);
        }

        // 验证：归档时的 caseResults 包含全部 3 条
        expect(archivedInput !== null).assertTrue();
        if (archivedInput !== null) {
          expect(archivedInput.caseResults.length).assertEqual(3);
        }
      });

      it('watermark_minus_one_means_no_completed', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();
        const crypto: StubCrypto = new StubCrypto();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();
        const bgTask: StubBackgroundTask = new StubBackgroundTask();
        const notification: StubNotification = new StubNotification();

        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);
        await configService.saveConfig({
          name: '全新服务', endpoint: 'https://api.test.com/v1',
          targetModel: 'test-model', secret: 'sk-test', isDefault: true
        });
        const configId: string = store.configRows[0].config_id;

        const fileStub: IntegrationFile = new IntegrationFile();
        const taskDeps: TaskConfigDeps = {
          store: store, file: fileStub, logger: logger,
          configProvider: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid)
        };
        const taskService: TaskConfigService = TaskConfigService.createForTest(taskDeps);

        fileStub.setPickResult('file://ds/fresh.json', 'fresh.json');
        fileStub.setFileContent(JSON.stringify([
          { content: '题X', referenceAnswer: '答X' }
        ]));
        await taskService.importDataset();

        const task: EvaluationTask = await taskService.createTask({
          name: '全新任务', configId: configId,
          datasetUri: 'file://ds/fresh.json', params: makeParams()
        });

        // 启动执行（watermark=-1，从头开始）
        let archivedInput: RunRecordArchiveInput | null = null;
        const execDeps: ExecutionDeps = {
          store: store, modelClient: modelClient, network: network,
          backgroundTask: bgTask, notification: notification, logger: logger,
          getConfig: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid),
          revealSecret: (cid: string): Promise<string> => configService.revealSecret(cid),
          getTask: (tid: string): Promise<EvaluationTask> => taskService.getTask(tid),
          archiveProvider: (input: RunRecordArchiveInput): Promise<string> => {
            archivedInput = input;
            return Promise.resolve('rec_fresh_1');
          },
          notificationEnabledProvider: (): Promise<boolean> => Promise.resolve(false),
          metricsProvider: (cs: CaseResult[], usage?: UsageSummary): Metrics =>
            MetricCalculator.compute(cs, usage)
        };
        const execService: ExecutionService = ExecutionService.createForTest(execDeps);

        await execService.start(task.taskId);

        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 200);
        });

        // 验证：1 个用例被执行
        expect(store.caseCountForTask(task.taskId)).assertEqual(1);
        const progress: ProgressRow | undefined = store.findProgress(task.taskId);
        expect(progress !== undefined).assertTrue();
        if (progress !== undefined) {
          expect(progress.watermark_seq).assertEqual(0);
          expect(progress.completed_count).assertEqual(1);
        }
      });
    });

    // ============ 不变式校验集成验证 ============

    describe('DataConstraints', () => {
      it('single_default_config_enforced', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const crypto: StubCrypto = new StubCrypto();
        const logger: StubLogger = new StubLogger();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();

        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);

        // 保存第一个默认配置
        await configService.saveConfig({
          name: '服务A', endpoint: 'https://a.com', targetModel: 'model-a', secret: 'sk-a', isDefault: true
        });
        // 保存第二个默认配置
        await configService.saveConfig({
          name: '服务B', endpoint: 'https://b.com', targetModel: 'model-b', secret: 'sk-b', isDefault: true
        });

        // 验证：只有一个默认配置
        const defaults: ServiceConfigRow[] = store.configRows.filter(r => r.is_default === 1);
        expect(defaults.length).assertEqual(1);
        expect(defaults[0].name).assertEqual('服务B');
      });

      it('config_name_unique_enforced', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const crypto: StubCrypto = new StubCrypto();
        const logger: StubLogger = new StubLogger();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();

        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);

        await configService.saveConfig({
          name: '同名服务', endpoint: 'https://a.com', targetModel: 'model-a', secret: 'sk-a', isDefault: false
        });

        let thrown: AppError | null = null;
        try {
          await configService.saveConfig({
            name: '同名服务', endpoint: 'https://b.com', targetModel: 'model-b', secret: 'sk-b', isDefault: false
          });
        } catch (e) {
          thrown = e as AppError;
        }
        expect(thrown !== null).assertTrue();
        if (thrown !== null) {
          expect(thrown.code).assertEqual(ErrorCode.CFG_DUPLICATE_NAME);
        }
      });

      it('task_name_unique_enforced', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();
        const crypto: StubCrypto = new StubCrypto();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();
        const fileStub: IntegrationFile = new IntegrationFile();

        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);
        await configService.saveConfig({
          name: '服务', endpoint: 'https://a.com', targetModel: 'model-a', secret: 'sk-a', isDefault: true
        });
        const configId: string = store.configRows[0].config_id;

        const taskDeps: TaskConfigDeps = {
          store: store, file: fileStub, logger: logger,
          configProvider: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid)
        };
        const taskService: TaskConfigService = TaskConfigService.createForTest(taskDeps);

        fileStub.setPickResult('file://ds/dup.json', 'dup.json');
        fileStub.setFileContent(JSON.stringify([{ content: '题', referenceAnswer: '答' }]));
        await taskService.importDataset();

        await taskService.createTask({
          name: '同名任务', configId: configId, datasetUri: 'file://ds/dup.json', params: makeParams()
        });

        let thrown: AppError | null = null;
        try {
          await taskService.createTask({
            name: '同名任务', configId: configId, datasetUri: 'file://ds/dup.json', params: makeParams()
          });
        } catch (e) {
          thrown = e as AppError;
        }
        expect(thrown !== null).assertTrue();
        if (thrown !== null) {
          expect(thrown.code).assertEqual(ErrorCode.TASK_DUPLICATE_NAME);
        }
      });

      it('param_out_of_range_rejected', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();
        const crypto: StubCrypto = new StubCrypto();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();
        const fileStub: IntegrationFile = new IntegrationFile();

        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);
        await configService.saveConfig({
          name: '服务', endpoint: 'https://a.com', targetModel: 'model-a', secret: 'sk-a', isDefault: true
        });
        const configId: string = store.configRows[0].config_id;

        const taskDeps: TaskConfigDeps = {
          store: store, file: fileStub, logger: logger,
          configProvider: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid)
        };
        const taskService: TaskConfigService = TaskConfigService.createForTest(taskDeps);

        fileStub.setPickResult('file://ds/range.json', 'range.json');
        fileStub.setFileContent(JSON.stringify([{ content: '题', referenceAnswer: '答' }]));
        await taskService.importDataset();

        const badParams: RunParameters = {
          temperature: 5.0, maxOutputTokens: 2048, concurrency: 1, timeoutMs: 60000, judgeMode: JudgeMode.CONTAINS
        };

        let thrown: AppError | null = null;
        try {
          await taskService.createTask({
            name: '越界任务', configId: configId, datasetUri: 'file://ds/range.json', params: badParams
          });
        } catch (e) {
          thrown = e as AppError;
        }
        expect(thrown !== null).assertTrue();
        if (thrown !== null) {
          expect(thrown.code).assertEqual(ErrorCode.TASK_PARAM_OUT_OF_RANGE);
        }
      });

      it('record_limit_enforced', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();

        // 预填充 2 条记录，上限设为 2
        store.recordRows.push({
          record_id: 'rec_1', task_id: 't1', task_name: '任务1', target_model: 'm1',
          status: RunRecordStatus.COMPLETED, started_at: 1000, ended_at: 2000,
          model_version: MODEL_VERSION, dataset_uri: 'uri1',
          metrics_json: JSON.stringify({ accuracy: 0.5, passRate: 0.5, avgElapsedMs: 100, usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: true })
        });
        store.recordRows.push({
          record_id: 'rec_2', task_id: 't2', task_name: '任务2', target_model: 'm2',
          status: RunRecordStatus.COMPLETED, started_at: 1000, ended_at: 2000,
          model_version: MODEL_VERSION, dataset_uri: 'uri2',
          metrics_json: JSON.stringify({ accuracy: 0.5, passRate: 0.5, avgElapsedMs: 100, usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: true })
        });

        const runRecordDeps: RunRecordDeps = {
          store: store, logger: logger,
          recordLimitProvider: (): Promise<number> => Promise.resolve(2),
          hasRunningTaskProvider: (): boolean => false,
          runningTaskIdProvider: (): string | undefined => undefined
        };
        const runRecordService: RunRecordService = RunRecordService.createForTest(runRecordDeps);

        let thrown: AppError | null = null;
        try {
          await runRecordService.archive({
            taskId: 't3', taskName: '任务3', targetModel: 'm3',
            status: RunRecordStatus.COMPLETED, startedAt: 1000, endedAt: 2000,
            datasetUri: 'uri3', modelVersion: MODEL_VERSION,
            caseResults: [], usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }
          });
        } catch (e) {
          thrown = e as AppError;
        }
        expect(thrown !== null).assertTrue();
        if (thrown !== null) {
          expect(thrown.code).assertEqual(ErrorCode.RECORD_LIMIT_REACHED);
        }
      });

      it('ended_at_before_started_at_rejected', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();

        const runRecordDeps: RunRecordDeps = {
          store: store, logger: logger,
          recordLimitProvider: (): Promise<number> => Promise.resolve(DEFAULT_RECORD_LIMIT),
          hasRunningTaskProvider: (): boolean => false,
          runningTaskIdProvider: (): string | undefined => undefined
        };
        const runRecordService: RunRecordService = RunRecordService.createForTest(runRecordDeps);

        let thrown: AppError | null = null;
        try {
          await runRecordService.archive({
            taskId: 't1', taskName: '时间倒置', targetModel: 'm1',
            status: RunRecordStatus.COMPLETED, startedAt: 2000, endedAt: 1000,
            datasetUri: 'uri1', modelVersion: MODEL_VERSION,
            caseResults: [], usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }
          });
        } catch (e) {
          thrown = e as AppError;
        }
        expect(thrown !== null).assertTrue();
        if (thrown !== null) {
          expect(thrown.code).assertEqual(ErrorCode.RECORD_LIMIT_REACHED);
        }
      });

      it('model_version_in_snapshot_and_record', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();
        const crypto: StubCrypto = new StubCrypto();
        const modelClient: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS);
        const network: StubNetwork = new StubNetwork();
        const fileStub: IntegrationFile = new IntegrationFile();

        const configDeps: ServiceConfigDeps = {
          store: store, crypto: crypto, modelClient: modelClient, network: network, logger: logger
        };
        const configService: ServiceConfigService = ServiceConfigService.createForTest(configDeps);
        await configService.saveConfig({
          name: '版本服务', endpoint: 'https://a.com', targetModel: 'model-a', secret: 'sk-a', isDefault: true
        });
        const configId: string = store.configRows[0].config_id;

        const taskDeps: TaskConfigDeps = {
          store: store, file: fileStub, logger: logger,
          configProvider: (cid: string): Promise<ModelServiceConfig> => configService.getConfig(cid)
        };
        const taskService: TaskConfigService = TaskConfigService.createForTest(taskDeps);

        fileStub.setPickResult('file://ds/ver.json', 'ver.json');
        fileStub.setFileContent(JSON.stringify([{ content: '题', referenceAnswer: '答' }]));
        await taskService.importDataset();

        const task: EvaluationTask = await taskService.createTask({
          name: '版本任务', configId: configId, datasetUri: 'file://ds/ver.json', params: makeParams()
        });

        // 验证快照携带 modelVersion
        expect(task.snapshot !== undefined).assertTrue();
        if (task.snapshot !== undefined) {
          expect(task.snapshot.modelVersion).assertEqual(MODEL_VERSION);
        }
        expect(task.dataset !== undefined).assertTrue();
        if (task.dataset !== undefined) {
          expect(task.dataset.modelVersion).assertEqual(MODEL_VERSION);
        }

        // 验证数据库行中也携带 model_version
        const taskRow: EvalTaskRow | undefined = store.findTask(task.taskId);
        expect(taskRow !== undefined).assertTrue();
        if (taskRow !== undefined) {
          const snap: Record<string, Object> = JSON.parse(taskRow.snapshot_json!) as Record<string, Object>;
          expect(snap['modelVersion']).assertEqual(MODEL_VERSION);
          const ds: Record<string, Object> = JSON.parse(taskRow.dataset_json!) as Record<string, Object>;
          expect(ds['modelVersion']).assertEqual(MODEL_VERSION);
        }
      });
    });

    // ============ 脱敏链路集成验证 ============

    describe('RedactionIntegration', () => {
      it('log_redaction_strips_secret', 0, () => {
        const logger: StubLogger = new StubLogger();
        logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE, '保存配置 secret=sk-abcdef123456 endpoint=https://a.com');
        const entries: StubLogEntry[] = logger.entriesOf();
        expect(entries.length > 0).assertTrue();
        const msg: string = entries[0].message;
        expect(msg.includes('sk-abcdef123456')).assertFalse();
        expect(msg.includes('REDACTED')).assertTrue();
      });

      it('export_report_redacted', 0, async () => {
        const store: IntegrationStore = new IntegrationStore();
        const logger: StubLogger = new StubLogger();
        const fileStub: IntegrationFile = new IntegrationFile();

        // 写入一条含密钥信息的 case_result
        store.caseRows.push({
          case_id: 'c1', task_id: 't1', seq: 0,
          content: 'sk-secret-key-in-content', reference_answer: '答',
          model_answer: 'Bearer sk-export-test-key', verdict: Verdict.PASSED, elapsed_ms: 100
        });
        store.recordRows.push({
          record_id: 'rec_export', task_id: 't1', task_name: '导出测试',
          target_model: 'model-a', status: RunRecordStatus.COMPLETED,
          started_at: 1000, ended_at: 2000, model_version: MODEL_VERSION,
          dataset_uri: 'file://ds/export.json',
          metrics_json: JSON.stringify({
            accuracy: 1.0, passRate: 1.0, avgElapsedMs: 100,
            usage: { promptTokens: 10, completionTokens: 5, totalTokens: 15 }, computed: true
          })
        });

        // 使用 MetricReportService 导出

        const reportDeps: MetricReportDeps = {
          store: store, file: fileStub, logger: logger,
          getRecordProvider: (rid: string): Promise<RunRecord> => {
            const row: RunRecordRow | undefined = store.recordRows.find(r => r.record_id === rid);
            if (row === undefined) {
              return Promise.reject(new AppError(ErrorCode.RECORD_LIMIT_REACHED, '记录不存在'));
            }
            const metrics: Metrics = JSON.parse(row.metrics_json);
            return Promise.resolve({
              recordId: row.record_id, taskId: row.task_id, taskName: row.task_name,
              targetModel: row.target_model, status: row.status as RunRecordStatus,
              startedAt: row.started_at, endedAt: row.ended_at, modelVersion: row.model_version,
              datasetUri: row.dataset_uri ?? '', metrics: metrics, corrupted: false
            });
          }
        };
        const reportService = MetricReportService.createForTest(reportDeps);

        const result: ExportResult = await reportService.exportReport('rec_export');
        expect(result.success).assertTrue();
        expect(fileStub.savedContent.includes('sk-secret-key-in-content')).assertFalse();
        expect(fileStub.savedContent.includes('sk-export-test-key')).assertFalse();
        expect(fileStub.savedContent.includes('REDACTED')).assertTrue();
      });
    });
  });
}