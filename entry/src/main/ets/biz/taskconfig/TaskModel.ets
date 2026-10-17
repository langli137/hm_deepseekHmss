/**
 * 评测任务领域模型辅助（spec 5.2 / 6.2，tasks.md 4.1 / 4.5）。
 * ArkTS interface 无方法体，故 `canEdit()` / `canStart()`、行↔对象映射、快照构造以纯函数提供。
 * 表名/列名以 infra/adapters/DbSchema.ets 为准（eval_task、dataset）。
 */
import { ExecutionFlag, TaskStatus } from '../../common/types/Enums';
import {
  CaseSnapshot, DatasetCaseDraft, DatasetSnapshot, EvaluationTask, ModelServiceConfig,
  RunParameters, TaskConfigSnapshot
} from '../../common/types/DomainTypes';
import { MODEL_VERSION } from '../../common/types/Constants';
import { cloneParams } from '../../common/utils/ParamRules';

/** eval_task 表行结构（snake_case，与 DbSchema 列名一一对应） */
export interface EvalTaskRow {
  task_id: string;
  name: string;
  config_id: string;
  dataset_uri: string | null;
  params_json: string;
  status: string;
  flag: string;
  snapshot_json: string | null;
  dataset_json: string | null;
  created_at: number;
}

/** dataset 表行结构（snake_case，与 DbSchema 列名一一对应） */
export interface DatasetRow {
  dataset_id: string;
  name: string;
  source_uri: string;
  total_count: number;
  valid_count: number;
  cases_json: string;
  imported_at: number;
}

// ============ 领域判定 ============

/** 运行中任务不可编辑（spec 5.3.1-8）：仅非 RUNNING 状态可编辑 */
export function taskCanEdit(task: EvaluationTask): boolean {
  return task.status !== TaskStatus.RUNNING;
}

/** 可启动：待运行且题目集快照存在可用题目（spec 5.2.1-7、6.2.4） */
export function taskCanStart(task: EvaluationTask): boolean {
  if (task.status !== TaskStatus.PENDING) {
    return false;
  }
  const snapshot: DatasetSnapshot | undefined = task.dataset;
  return snapshot !== undefined && snapshot.cases.length > 0;
}

// ============ 快照构造（spec 5.2.1-6、6.2.7） ============

/** 固化任务配置快照；params 经 cloneParams 深拷贝，保证不可变 */
export function buildSnapshot(config: ModelServiceConfig, params: RunParameters): TaskConfigSnapshot {
  return {
    modelVersion: MODEL_VERSION,
    params: cloneParams(params),
    targetModel: config.targetModel,
    configName: config.name
  };
}

/**
 * 固化题目集快照。
 * seq 起始约定：从 0 起（与 case_result.execution 序号、progress.watermark_seq 默认 -1 对齐），
 * 即首个用例 seq=0，第 N 个用例 seq=N-1。
 */
export function buildDatasetSnapshot(name: string, cases: DatasetCaseDraft[]): DatasetSnapshot {
  const snapshots: CaseSnapshot[] = [];
  for (let i = 0; i < cases.length; i++) {
    snapshots.push({ seq: i, content: cases[i].content, referenceAnswer: cases[i].referenceAnswer });
  }
  return { modelVersion: MODEL_VERSION, name: name, cases: snapshots };
}

// ============ JSON 编解码 ============

export function stringifyParams(params: RunParameters): string {
  return JSON.stringify(params);
}

export function parseParams(json: string): RunParameters {
  return JSON.parse(json) as RunParameters;
}

export function stringifyCases(cases: DatasetCaseDraft[]): string {
  return JSON.stringify(cases);
}

export function parseCases(json: string): DatasetCaseDraft[] {
  try {
    return JSON.parse(json) as DatasetCaseDraft[];
  } catch (e) {
    return [];
  }
}

// ============ 行 ↔ 领域对象映射 ============

function toTaskStatus(raw: string): TaskStatus {
  switch (raw) {
    case TaskStatus.RUNNING:
      return TaskStatus.RUNNING;
    case TaskStatus.COMPLETED:
      return TaskStatus.COMPLETED;
    case TaskStatus.FAILED:
      return TaskStatus.FAILED;
    case TaskStatus.TERMINATED:
      return TaskStatus.TERMINATED;
    default:
      return TaskStatus.PENDING;
  }
}

function toExecutionFlag(raw: string): ExecutionFlag {
  return raw === ExecutionFlag.PAUSED ? ExecutionFlag.PAUSED : ExecutionFlag.EXECUTING;
}

function snapshotJson(task: EvaluationTask): string | null {
  return task.snapshot === undefined ? null : JSON.stringify(task.snapshot);
}

function datasetJson(task: EvaluationTask): string | null {
  return task.dataset === undefined ? null : JSON.stringify(task.dataset);
}

/** 数据库行 → 领域对象（含快照反序列化） */
export function rowToTask(row: EvalTaskRow): EvaluationTask {
  const task: EvaluationTask = {
    taskId: row.task_id,
    name: row.name,
    configId: row.config_id,
    datasetUri: row.dataset_uri === null ? '' : row.dataset_uri,
    params: parseParams(row.params_json),
    status: toTaskStatus(row.status),
    flag: toExecutionFlag(row.flag),
    createdAt: row.created_at
  };
  if (row.snapshot_json !== null && row.snapshot_json.length > 0) {
    task.snapshot = JSON.parse(row.snapshot_json) as TaskConfigSnapshot;
  }
  if (row.dataset_json !== null && row.dataset_json.length > 0) {
    task.dataset = JSON.parse(row.dataset_json) as DatasetSnapshot;
  }
  return task;
}

/** 插入语句绑定参数（列序与 SQL_INSERT_TASK 一致） */
export function taskToInsertArgs(task: EvaluationTask): Array<string | number | boolean | null> {
  return [task.taskId, task.name, task.configId, task.datasetUri, stringifyParams(task.params),
    task.status, task.flag, snapshotJson(task), datasetJson(task), task.createdAt];
}

/** 更新语句绑定参数（不含 status/flag/created_at，列序与 SQL_UPDATE_TASK 一致） */
export function taskToUpdateArgs(task: EvaluationTask): Array<string | number | boolean | null> {
  return [task.name, task.configId, task.datasetUri, stringifyParams(task.params),
    snapshotJson(task), datasetJson(task), task.taskId];
}