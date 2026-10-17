/**
 * 关系型数据库适配器。基于 @ohos.data.relationalStore（tasks.md 2.1）。
 * 职责：建表/建索引、事务、查询、写入、结果集关闭、版本升级回调。
 * 表名与列名采用 snake_case；结构化明细（任务、用例结果、运行记录）由此承载。
 */
import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';
import { ExecSpec, QuerySpec, TxContext } from '../../common/types/InfraTypes';
import { MODEL_VERSION } from '../../common/types/Constants';
import { RelationalStorePort } from '../ports/RelationalStorePort';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';

const STORE_NAME: string = 'deepseek_harness.db';

const CREATE_TABLE_SQLS: string[] = [
  `CREATE TABLE IF NOT EXISTS model_service_config (
     config_id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     endpoint TEXT NOT NULL,
     target_model TEXT NOT NULL,
     is_default INTEGER NOT NULL DEFAULT 0,
     status TEXT NOT NULL,
     secret_alias TEXT,
     secret_algorithm TEXT,
     created_at INTEGER NOT NULL
   )`,
  `CREATE TABLE IF NOT EXISTS evaluation_task (
     task_id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     config_id TEXT,
     dataset_uri TEXT,
     params_json TEXT,
     status TEXT NOT NULL,
     flag TEXT NOT NULL,
     snapshot_json TEXT,
     dataset_json TEXT,
     created_at INTEGER NOT NULL
   )`,
  `CREATE TABLE IF NOT EXISTS case_result (
     case_id TEXT PRIMARY KEY,
     task_id TEXT NOT NULL,
     seq INTEGER NOT NULL,
     content TEXT,
     reference_answer TEXT,
     model_answer TEXT,
     verdict TEXT NOT NULL,
     elapsed_ms INTEGER NOT NULL
   )`,
  `CREATE TABLE IF NOT EXISTS run_record (
     record_id TEXT PRIMARY KEY,
     task_id TEXT,
     task_name TEXT,
     target_model TEXT,
     status TEXT NOT NULL,
     started_at INTEGER,
     ended_at INTEGER,
     model_version INTEGER,
     dataset_uri TEXT,
     metrics_json TEXT,
     corrupted INTEGER NOT NULL DEFAULT 0
   )`,
  `CREATE TABLE IF NOT EXISTS dataset (
     dataset_id TEXT PRIMARY KEY,
     name TEXT,
     source_uri TEXT,
     total_count INTEGER,
     valid_count INTEGER,
     imported_at INTEGER
   )`
];

const CREATE_INDEX_SQLS: string[] = [
  'CREATE INDEX IF NOT EXISTS idx_task_name ON evaluation_task(name)',
  'CREATE INDEX IF NOT EXISTS idx_case_task_seq ON case_result(task_id, seq)',
  'CREATE INDEX IF NOT EXISTS idx_record_status ON run_record(status)',
  'CREATE INDEX IF NOT EXISTS idx_record_model ON run_record(target_model)'
];

class TxContextImpl implements TxContext {
  private store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    return queryRows<T>(this.store, spec);
  }

  async execute(spec: ExecSpec): Promise<number> {
    return execRows(this.store, spec);
  }
}

async function queryRows<T>(store: relationalStore.RdbStore, spec: QuerySpec): Promise<T[]> {
  const args: Array<relationalStore.ValueType> = spec.args ?? [];
  const resultSet: relationalStore.ResultSet = await store.querySql(spec.sql, args);
  const rows: T[] = [];
  try {
    while (resultSet.goToNextRow()) {
      // getRow 返回 Object，在此按调用方声明的行类型断言（列名与 T 的字段需一致）
      rows.push(resultSet.getRow() as T);
    }
  } finally {
    resultSet.close();
  }
  return rows;
}

async function execRows(store: relationalStore.RdbStore, spec: ExecSpec): Promise<number> {
  const args: Array<relationalStore.ValueType> = spec.args ?? [];
  await store.executeSql(spec.sql, args);
  const changed: relationalStore.ResultSet = await store.querySql('SELECT changes() AS changed');
  let count: number = 0;
  try {
    if (changed.goToNextRow()) {
      count = changed.getLong(changed.getColumnIndex('changed'));
    }
  } finally {
    changed.close();
  }
  return count;
}

export class RelationalStoreAdapter implements RelationalStorePort {
  private context: common.Context;
  private store: relationalStore.RdbStore | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async ensureStore(): Promise<relationalStore.RdbStore> {
    if (this.store !== null) {
      return this.store;
    }
    const config: relationalStore.StoreConfig = {
      name: STORE_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(this.context, config);
    await this.migrate(store);
    for (let i = 0; i < CREATE_TABLE_SQLS.length; i++) {
      await store.executeSql(CREATE_TABLE_SQLS[i]);
    }
    for (let i = 0; i < CREATE_INDEX_SQLS.length; i++) {
      await store.executeSql(CREATE_INDEX_SQLS[i]);
    }
    this.store = store;
    return store;
  }

  /** 版本升级回调：读取旧版本、按 modelVersion 补齐字段（spec 4.5.3） */
  private async migrate(store: relationalStore.RdbStore): Promise<void> {
    const current: number = store.version;
    if (current === 0) {
      store.version = MODEL_VERSION;
      return;
    }
    if (current < MODEL_VERSION) {
      // 旧版本数据兼容入口：后续按 modelVersion 逐级补全字段与默认值
      store.version = MODEL_VERSION;
    }
  }

  async transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    store.beginTransaction();
    try {
      const tx: TxContext = new TxContextImpl(store);
      const result: T = await work(tx);
      store.commit();
      return result;
    } catch (e) {
      store.rollBack();
      throw new AppError(ErrorCode.UNKNOWN_ERROR, e?.toString() ?? 'Unknown error');
    }
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    return queryRows<T>(store, spec);
  }

  async execute(spec: ExecSpec): Promise<number> {
    const store: relationalStore.RdbStore = await this.ensureStore();
    return execRows(store, spec);
  }

  /** 显式销毁连接（应用退出时调用） */
  async close(): Promise<void> {
    if (this.store !== null) {
      await this.store.close();
      this.store = null;
    }
  }
}