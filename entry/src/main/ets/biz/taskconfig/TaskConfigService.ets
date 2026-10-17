/**
 * 评测任务配置应用服务（spec 5.2，tasks.md 4）。
 * - 单例入口：TaskConfigService.getInstance()
 * - 依赖：RelationalStorePort（eval_task + dataset 表）、FilePort（题目集导入）、LoggerPort，
 *   以及跨模块契约 ServiceConfigService.getConfig（关联配置存在性校验）。
 * - 题目集导入：pickFile → readText → DatasetValidator.parse，成功后写入 dataset 表
 *   （source_uri UNIQUE，重复导入同 URI 覆盖）。
 * - 快照固化：createTask/updateTask 时以 cloneParams 深拷贝参数，并深拷贝题目集快照，
 *   写入 eval_task.params_json / snapshot_json / dataset_json（spec 5.2.1-6、6.2.7）。
 * - 关联配置查询与默认参数通过可注入 provider 提供，测试可注入桩；
 *   AppSettingsService 落地后可将 defaultParamsProvider 指向其 getSettings()。
 */
import { AppContainer } from '../../entrystage/AppContainer';
import { ensureSchema, TABLE_DATASET, TABLE_EVAL_TASK } from '../../infra/adapters/DbSchema';
import { RelationalStorePort } from '../../infra/ports/RelationalStorePort';
import { FilePort } from '../../infra/ports/FilePort';
import { LoggerPort } from '../../infra/ports/LoggerPort';
import { ExecSpec, QuerySpec } from '../../common/types/InfraTypes';
import { ExecutionFlag, LogEvent, LogLevel, TaskStatus } from '../../common/types/Enums';
import {
  DatasetCaseDraft, DatasetSnapshot, DatasetValidationReport, EvaluationTask, ModelServiceConfig,
  RunParameters, TaskConfigDraft
} from '../../common/types/DomainTypes';
import { TASK_NAME_MAX_LENGTH } from '../../common/types/Constants';
import { AppError, asAppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { newId, nowMs } from '../../common/utils/IdGen';
import { cloneParams, createDefaultParams, describeViolation, isWithinRange } from '../../common/utils/ParamRules';
import { DatasetValidator } from '../../domain/dataset/DatasetValidator';
import { ServiceConfigService } from '../serviceconfig/ServiceConfigService';
import {
  buildDatasetSnapshot, buildSnapshot, DatasetRow, EvalTaskRow, parseCases, rowToTask,
  stringifyCases, taskCanEdit, taskToInsertArgs, taskToUpdateArgs
} from './TaskModel';

const SELECT_TASK_COLUMNS: string =
  'task_id, name, config_id, dataset_uri, params_json, status, flag, snapshot_json, dataset_json, created_at';
const SELECT_DATASET_COLUMNS: string =
  'dataset_id, name, source_uri, total_count, valid_count, cases_json, imported_at';

const SQL_INSERT_TASK: string =
  `INSERT INTO ${TABLE_EVAL_TASK}(task_id, name, config_id, dataset_uri, params_json, status, flag, snapshot_json, dataset_json, created_at) VALUES(?,?,?,?,?,?,?,?,?,?)`;
const SQL_UPDATE_TASK: string =
  `UPDATE ${TABLE_EVAL_TASK} SET name=?, config_id=?, dataset_uri=?, params_json=?, snapshot_json=?, dataset_json=? WHERE task_id=?`;
const SQL_DELETE_TASK: string = `DELETE FROM ${TABLE_EVAL_TASK} WHERE task_id = ?`;
const SQL_INSERT_DATASET: string =
  `INSERT INTO ${TABLE_DATASET}(dataset_id, name, source_uri, total_count, valid_count, cases_json, imported_at) VALUES(?,?,?,?,?,?,?)`;
const SQL_UPDATE_DATASET: string =
  `UPDATE ${TABLE_DATASET} SET name=?, total_count=?, valid_count=?, cases_json=?, imported_at=? WHERE source_uri=?`;
const SQL_DELETE_ALL_DATASETS: string = `DELETE FROM ${TABLE_DATASET}`;

/** 服务依赖集合；生产由 AppContainer 装配，测试可注入桩。 */
export interface TaskConfigDeps {
  store: RelationalStorePort;
  file: FilePort;
  logger: LoggerPort;
  /** 关联配置查询；默认对接跨模块契约 ServiceConfigService.getConfig */
  configProvider: (configId: string) => Promise<ModelServiceConfig>;
  /** 默认参数预填；默认 createDefaultParams（AppSettingsService 落地后替换为 getSettings） */
  defaultParamsProvider?: () => Promise<RunParameters>;
}

/** 草稿基础校验：任务名称非空且 1~50，configId/datasetUri 必填（spec 5.2.1-2、6.2.2/6.2.3/6.2.4） */
function validateDraftBasic(draft: TaskConfigDraft): void {
  const name: string = draft.name.trim();
  if (name.length === 0 || name.length > TASK_NAME_MAX_LENGTH) {
    throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, `任务名称必填且长度需为 1~${TASK_NAME_MAX_LENGTH} 个字符`);
  }
  if (draft.configId.trim().length === 0) {
    throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, '缺少关联模型服务配置');
  }
  if (draft.datasetUri.trim().length === 0) {
    throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, '缺少题目集');
  }
}

/** 参数范围校验；越界抛 TASK_PARAM_OUT_OF_RANGE 并携带合法区间（spec 5.2.1-3） */
function validateParams(params: RunParameters): void {
  if (!isWithinRange(params)) {
    throw new AppError(ErrorCode.TASK_PARAM_OUT_OF_RANGE, describeViolation(params));
  }
}

export class TaskConfigService {
  private static instance: TaskConfigService | null = null;

  private deps: TaskConfigDeps;
  private schemaReady: Promise<void> | null = null;

  private constructor(deps: TaskConfigDeps) {
    this.deps = deps;
  }

  /** 应用级单例：从 AppContainer 装配端口，关联配置委托 ServiceConfigService */
  static getInstance(): TaskConfigService {
    if (TaskConfigService.instance === null) {
      const container: AppContainer = AppContainer.getInstance();
      TaskConfigService.instance = new TaskConfigService({
        store: container.store(),
        file: container.file(),
        logger: container.logger(),
        configProvider: (configId: string): Promise<ModelServiceConfig> =>
          ServiceConfigService.getInstance().getConfig(configId)
      });
    }
    return TaskConfigService.instance;
  }

  /** 测试装配入口：注入端口桩与 provider，保持 getInstance 单例契约不变 */
  static createForTest(deps: TaskConfigDeps): TaskConfigService {
    return new TaskConfigService(deps);
  }

  private ensureInit(): Promise<void> {
    if (this.schemaReady === null) {
      this.schemaReady = ensureSchema(this.deps.store);
    }
    return this.schemaReady;
  }

  // ============ 查询 ============

  async listTasks(): Promise<EvaluationTask[]> {
    await this.ensureInit();
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_TASK_COLUMNS} FROM ${TABLE_EVAL_TASK} ORDER BY created_at DESC`
    };
    const rows: EvalTaskRow[] = await this.deps.store.query<EvalTaskRow>(spec);
    const tasks: EvaluationTask[] = [];
    for (let i = 0; i < rows.length; i++) {
      tasks.push(rowToTask(rows[i]));
    }
    return tasks;
  }

  async getTask(taskId: string): Promise<EvaluationTask> {
    await this.ensureInit();
    const row: EvalTaskRow | undefined = await this.findTaskRow(taskId);
    if (row === undefined) {
      throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, `任务不存在：${taskId}`);
    }
    return rowToTask(row);
  }

  /** 新建任务默认参数预填入口（对齐 spec 5.6.1-1，由页面调用） */
  async getDefaultParams(): Promise<RunParameters> {
    const provider: (() => Promise<RunParameters>) | undefined = this.deps.defaultParamsProvider;
    if (provider !== undefined) {
      return provider();
    }
    return createDefaultParams();
  }

  // ============ 创建 / 更新 / 删除 ============

  async createTask(draft: TaskConfigDraft): Promise<EvaluationTask> {
    await this.ensureInit();
    validateDraftBasic(draft);
    await this.ensureNameUnique(draft.name, undefined);

    const config: ModelServiceConfig = await this.loadConfig(draft.configId);
    validateParams(draft.params);
    const params: RunParameters = cloneParams(draft.params);
    const dataset: DatasetSnapshot = await this.loadDatasetSnapshot(draft.datasetUri);

    const task: EvaluationTask = {
      taskId: newId('task'),
      name: draft.name.trim(),
      configId: draft.configId.trim(),
      datasetUri: draft.datasetUri.trim(),
      params: params,
      status: TaskStatus.PENDING,
      flag: ExecutionFlag.EXECUTING,
      snapshot: buildSnapshot(config, params),
      dataset: dataset,
      createdAt: nowMs()
    };

    const spec: ExecSpec = { sql: SQL_INSERT_TASK, args: taskToInsertArgs(task) };
    await this.deps.store.execute(spec);
    this.deps.logger.log(LogLevel.INFO, LogEvent.TASK_START,
      `创建评测任务 id=${task.taskId} name=${task.name} targetModel=${config.targetModel}`);
    return task;
  }

  async updateTask(taskId: string, draft: TaskConfigDraft): Promise<EvaluationTask> {
    await this.ensureInit();
    const existing: EvaluationTask = await this.getTask(taskId);
    if (!taskCanEdit(existing)) {
      throw new AppError(ErrorCode.TASK_ALREADY_RUNNING, '任务运行中，配置不可编辑');
    }
    validateDraftBasic(draft);
    await this.ensureNameUnique(draft.name, taskId);

    const config: ModelServiceConfig = await this.loadConfig(draft.configId);
    validateParams(draft.params);
    const params: RunParameters = cloneParams(draft.params);
    const dataset: DatasetSnapshot = await this.loadDatasetSnapshot(draft.datasetUri);

    const task: EvaluationTask = {
      taskId: taskId,
      name: draft.name.trim(),
      configId: draft.configId.trim(),
      datasetUri: draft.datasetUri.trim(),
      params: params,
      status: existing.status,
      flag: existing.flag,
      snapshot: buildSnapshot(config, params),
      dataset: dataset,
      createdAt: existing.createdAt
    };

    const spec: ExecSpec = { sql: SQL_UPDATE_TASK, args: taskToUpdateArgs(task) };
    await this.deps.store.execute(spec);
    this.deps.logger.log(LogLevel.INFO, LogEvent.TASK_START,
      `更新评测任务 id=${taskId} name=${task.name}`);
    return task;
  }

  async removeTask(taskId: string): Promise<void> {
    await this.ensureInit();
    const existing: EvaluationTask = await this.getTask(taskId);
    if (existing.status === TaskStatus.RUNNING) {
      throw new AppError(ErrorCode.TASK_ALREADY_RUNNING, '任务运行中，无法删除');
    }
    const spec: ExecSpec = { sql: SQL_DELETE_TASK, args: [taskId] };
    await this.deps.store.execute(spec);
    this.deps.logger.log(LogLevel.INFO, LogEvent.TASK_START, `删除评测任务 id=${taskId}`);
  }

  // ============ 题目集导入 ============

  /**
   * 拉起文件选择器导入题目集。
   * 解析失败/超限抛错且不触碰原文件；缺题面或参考答案抛 DS_MISSING_REFERENCE；
   * 成功后写入 dataset 表（同 source_uri 覆盖）。
   */
  async importDataset(): Promise<DatasetValidationReport> {
    await this.ensureInit();
    const picked = await this.deps.file.pickFile({ fileSuffixFilters: ['json'], maxCount: 1 });
    if (picked === null) {
      throw new AppError(ErrorCode.DS_PARSE_FAILED, '未选择题目集文件');
    }
    const content: string = await this.deps.file.readText(picked.uri);
    const report: DatasetValidationReport = DatasetValidator.parse(picked.name, content);
    report.fileUri = picked.uri;

    if (report.missingReferenceIndexes.length > 0) {
      throw new AppError(ErrorCode.DS_MISSING_REFERENCE,
        `以下题目缺少题面或参考答案（序号从 0 起）：${report.missingReferenceIndexes.join('、')}`);
    }

    await this.saveDataset(picked.uri, picked.name, report);
    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE,
      `导入题目集 name=${picked.name} uri=${picked.uri} total=${report.totalCount} valid=${report.validCount}`);
    return report;
  }

  // ============ 跨模块契约支撑 ============

  /** 是否存在引用该配置的运行中任务（供 ServiceConfigService.removeConfig 引用冲突拦截） */
  async hasTaskReferencingConfig(configId: string): Promise<boolean> {
    await this.ensureInit();
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_TASK_COLUMNS} FROM ${TABLE_EVAL_TASK} WHERE config_id = ? AND status = ?`,
      args: [configId, TaskStatus.RUNNING]
    };
    const rows: EvalTaskRow[] = await this.deps.store.query<EvalTaskRow>(spec);
    return rows.length > 0;
  }

  /** 清除全部本地题目集（供应用设置的数据清理调用，spec 5.6.1-3） */
  async clearAllDatasets(): Promise<void> {
    await this.ensureInit();
    const spec: ExecSpec = { sql: SQL_DELETE_ALL_DATASETS };
    await this.deps.store.execute(spec);
    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE, '清除全部本地题目集');
  }

  // ============ 内部辅助 ============

  private async loadConfig(configId: string): Promise<ModelServiceConfig> {
    try {
      return await this.deps.configProvider(configId.trim());
    } catch (e) {
      const cause: AppError = asAppError(e, ErrorCode.TASK_INCOMPLETE_CONFIG);
      throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, `关联模型服务配置不可用：${cause.detail}`);
    }
  }

  /** 名称唯一性校验；excludeTaskId 用于更新场景排除自身（spec 6.2.2） */
  private async ensureNameUnique(name: string, excludeTaskId?: string): Promise<void> {
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_TASK_COLUMNS} FROM ${TABLE_EVAL_TASK} WHERE name = ?`,
      args: [name.trim()]
    };
    const rows: EvalTaskRow[] = await this.deps.store.query<EvalTaskRow>(spec);
    for (let i = 0; i < rows.length; i++) {
      if (excludeTaskId === undefined || rows[i].task_id !== excludeTaskId) {
        throw new AppError(ErrorCode.TASK_DUPLICATE_NAME, `任务名称已存在：${name.trim()}`);
      }
    }
  }

  /** 由 datasetUri 读取题目集并生成不可变快照；不存在或无可用题目则视为配置不完整 */
  private async loadDatasetSnapshot(datasetUri: string): Promise<DatasetSnapshot> {
    const row: DatasetRow | undefined = await this.findDatasetByUri(datasetUri.trim());
    if (row === undefined) {
      throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, `题目集不存在或未导入：${datasetUri}`);
    }
    const cases: DatasetCaseDraft[] = parseCases(row.cases_json);
    if (cases.length === 0) {
      throw new AppError(ErrorCode.TASK_INCOMPLETE_CONFIG, `题目集无可用题目：${row.name}`);
    }
    return buildDatasetSnapshot(row.name, cases);
  }

  private async findTaskRow(taskId: string): Promise<EvalTaskRow | undefined> {
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_TASK_COLUMNS} FROM ${TABLE_EVAL_TASK} WHERE task_id = ?`,
      args: [taskId]
    };
    const rows: EvalTaskRow[] = await this.deps.store.query<EvalTaskRow>(spec);
    return rows.length === 0 ? undefined : rows[0];
  }

  private async findDatasetByUri(uri: string): Promise<DatasetRow | undefined> {
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_DATASET_COLUMNS} FROM ${TABLE_DATASET} WHERE source_uri = ?`,
      args: [uri]
    };
    const rows: DatasetRow[] = await this.deps.store.query<DatasetRow>(spec);
    return rows.length === 0 ? undefined : rows[0];
  }

  /** 写入题目集；同 source_uri 已存在则覆盖（spec 5.2） */
  private async saveDataset(uri: string, name: string, report: DatasetValidationReport): Promise<void> {
    const casesJson: string = stringifyCases(report.cases);
    const existing: DatasetRow | undefined = await this.findDatasetByUri(uri);
    if (existing === undefined) {
      const spec: ExecSpec = {
        sql: SQL_INSERT_DATASET,
        args: [newId('ds'), name, uri, report.totalCount, report.validCount, casesJson, nowMs()]
      };
      await this.deps.store.execute(spec);
    } else {
      const spec: ExecSpec = {
        sql: SQL_UPDATE_DATASET,
        args: [name, report.totalCount, report.validCount, casesJson, nowMs(), uri]
      };
      await this.deps.store.execute(spec);
    }
  }
}