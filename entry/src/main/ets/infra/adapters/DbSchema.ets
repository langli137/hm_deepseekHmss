/**
 * 统一数据库 Schema 定义（建表与索引）。被各业务服务在首次初始化时幂等调用。
 * 各业务子域的持久化读写必须以此处表/列命名为准，避免跨模块读写错位。
 * 对应 spec 4.5.3（版本兼容）、5.5.1-2（检索索引）。
 */
import { ExecSpec } from '../../common/types/InfraTypes';
import { RelationalStorePort } from '../ports/RelationalStorePort';

export const TABLE_SERVICE_CONFIG: string = 'service_config';
export const TABLE_EVAL_TASK: string = 'eval_task';
export const TABLE_DATASET: string = 'dataset';
export const TABLE_CASE_RESULT: string = 'case_result';
export const TABLE_TASK_PROGRESS: string = 'task_progress';
export const TABLE_RUN_RECORD: string = 'run_record';

/** DDL 列表：全部使用 IF NOT EXISTS，可重复执行 */
const DDL_STATEMENTS: string[] = [
  // 模型服务配置（spec 6.1）：密钥仅存 SecretRef，明文不落盘
  `CREATE TABLE IF NOT EXISTS ${TABLE_SERVICE_CONFIG} (
    config_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    endpoint TEXT NOT NULL,
    target_model TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL,
    secret_alias TEXT,
    secret_algo TEXT,
    created_at INTEGER NOT NULL
  )`,

  // 评测任务（spec 6.2）：params_json / snapshot_json / dataset_json 为 JSON 文本
  `CREATE TABLE IF NOT EXISTS ${TABLE_EVAL_TASK} (
    task_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    config_id TEXT NOT NULL,
    dataset_uri TEXT,
    params_json TEXT NOT NULL,
    status TEXT NOT NULL,
    flag TEXT NOT NULL,
    snapshot_json TEXT,
    dataset_json TEXT,
    created_at INTEGER NOT NULL
  )`,

  // 题目集（spec 5.2）：cases_json 为解析后的题目数组 JSON
  `CREATE TABLE IF NOT EXISTS ${TABLE_DATASET} (
    dataset_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    source_uri TEXT NOT NULL UNIQUE,
    total_count INTEGER NOT NULL,
    valid_count INTEGER NOT NULL,
    cases_json TEXT NOT NULL,
    imported_at INTEGER NOT NULL
  )`,

  // 逐题用例结果（spec 6.3）：seq 在 task 内唯一且单调
  `CREATE TABLE IF NOT EXISTS ${TABLE_CASE_RESULT} (
    case_id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    content TEXT NOT NULL,
    reference_answer TEXT,
    model_answer TEXT,
    verdict TEXT NOT NULL,
    elapsed_ms INTEGER NOT NULL
  )`,

  // 进度水位线（spec 4.2.5 断点续跑）：与用例结果同事务提交
  `CREATE TABLE IF NOT EXISTS ${TABLE_TASK_PROGRESS} (
    task_id TEXT PRIMARY KEY,
    watermark_seq INTEGER NOT NULL DEFAULT -1,
    completed_count INTEGER NOT NULL DEFAULT 0,
    total_count INTEGER NOT NULL DEFAULT 0
  )`,

  // 运行记录（spec 6.4）：metrics_json 为汇总指标
  `CREATE TABLE IF NOT EXISTS ${TABLE_RUN_RECORD} (
    record_id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    task_name TEXT NOT NULL,
    target_model TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    ended_at INTEGER NOT NULL,
    model_version INTEGER NOT NULL,
    dataset_uri TEXT,
    metrics_json TEXT NOT NULL
  )`,

  `CREATE INDEX IF NOT EXISTS idx_case_result_task ON ${TABLE_CASE_RESULT}(task_id, seq)`,
  `CREATE INDEX IF NOT EXISTS idx_run_record_name ON ${TABLE_RUN_RECORD}(task_name)`,
  `CREATE INDEX IF NOT EXISTS idx_run_record_model ON ${TABLE_RUN_RECORD}(target_model)`,
  `CREATE INDEX IF NOT EXISTS idx_run_record_status ON ${TABLE_RUN_RECORD}(status)`
];

/** 幂等建表建索引。服务初始化时调用一次即可。 */
export async function ensureSchema(store: RelationalStorePort): Promise<void> {
  for (let i = 0; i < DDL_STATEMENTS.length; i++) {
    const spec: ExecSpec = { sql: DDL_STATEMENTS[i] };
    await store.execute(spec);
  }
}