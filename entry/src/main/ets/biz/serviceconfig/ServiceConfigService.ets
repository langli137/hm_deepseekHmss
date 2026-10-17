/**
 * 模型服务与认证管理应用服务（spec 5.1，tasks.md 3）。
 * - 单例入口：ServiceConfigService.getInstance()
 * - 依赖 9 个基础设施端口中与本模块相关的 4 个：RelationalStore / Crypto / ModelClient / NetworkMonitor，另用 Logger。
 * - 只读写表 service_config（列名以 infra/adapters/DbSchema.ets 为准）。
 * - 密钥明文仅在 saveConfig/testConnection 入参瞬间存在于内存，落盘仅保留 SecretRef（spec 4.3.1）。
 */
import { AppContainer } from '../../entrystage/AppContainer';
import { ensureSchema, TABLE_SERVICE_CONFIG } from '../../infra/adapters/DbSchema';
import { RelationalStorePort } from '../../infra/ports/RelationalStorePort';
import { CryptoPort } from '../../infra/ports/CryptoPort';
import { ModelClientPort } from '../../infra/ports/ModelClientPort';
import { NetworkMonitorPort } from '../../infra/ports/NetworkMonitorPort';
import { LoggerPort } from '../../infra/ports/LoggerPort';
import {
  ExecSpec, NetworkState, QuerySpec, SecretRef, TxContext, Unsubscribe
} from '../../common/types/InfraTypes';
import { ConfigStatus, LogEvent, LogLevel } from '../../common/types/Enums';
import {
  ConnectionTestResult, ModelServiceConfig, ServiceConfigDraft
} from '../../common/types/DomainTypes';
import { AppError } from '../../common/error/AppError';
import { ErrorCode, ErrorMessages } from '../../common/error/ErrorCode';
import { newId, nowMs } from '../../common/utils/IdGen';
import { TaskConfigService } from '../taskconfig/TaskConfigService';
import {
  classifyProbeFailure, configToInsertArgs, configToUpdateArgs, draftToConfig,
  rowToConfig, ServiceConfigRow, validateDraftForSave
} from './ServiceConfigModel';

const SELECT_COLUMNS: string =
  'config_id, name, endpoint, target_model, is_default, status, secret_alias, secret_algo, created_at';

const SQL_INSERT: string =
  `INSERT INTO ${TABLE_SERVICE_CONFIG}(config_id, name, endpoint, target_model, is_default, status, secret_alias, secret_algo, created_at) VALUES(?,?,?,?,?,?,?,?,?)`;

const SQL_UPDATE: string =
  `UPDATE ${TABLE_SERVICE_CONFIG} SET name=?, endpoint=?, target_model=?, is_default=?, status=?, secret_alias=?, secret_algo=? WHERE config_id=?`;

const SQL_CLEAR_DEFAULT: string = `UPDATE ${TABLE_SERVICE_CONFIG} SET is_default = 0 WHERE is_default = 1`;

const SQL_SET_DEFAULT: string = `UPDATE ${TABLE_SERVICE_CONFIG} SET is_default = 1 WHERE config_id = ?`;

const SQL_DELETE: string = `DELETE FROM ${TABLE_SERVICE_CONFIG} WHERE config_id = ?`;

/** 服务依赖集合；生产环境由 AppContainer 装配，测试可注入桩。 */
export interface ServiceConfigDeps {
  store: RelationalStorePort;
  crypto: CryptoPort;
  modelClient: ModelClientPort;
  network: NetworkMonitorPort;
  logger: LoggerPort;
  /** 引用冲突检测；默认对接跨模块契约 TaskConfigService.hasTaskReferencingConfig */
  taskReferenceChecker?: (configId: string) => Promise<boolean>;
}

export class ServiceConfigService {
  private static instance: ServiceConfigService | null = null;

  private deps: ServiceConfigDeps;
  private schemaReady: Promise<void> | null = null;
  private listeners: Array<() => void> = [];

  private constructor(deps: ServiceConfigDeps) {
    this.deps = deps;
  }

  /** 应用级单例：从 AppContainer 装配真实端口或测试桩（按运行环境切换） */
  static getInstance(): ServiceConfigService {
    if (ServiceConfigService.instance === null) {
      const container: AppContainer = AppContainer.getInstance();
      ServiceConfigService.instance = new ServiceConfigService({
        store: container.store(),
        crypto: container.crypto(),
        modelClient: container.modelClient(),
        network: container.networkMonitor(),
        logger: container.logger()
      });
    }
    return ServiceConfigService.instance;
  }

  /** 测试装配入口：注入端口桩与引用检测器，保持 getInstance 单例契约不变 */
  static createForTest(deps: ServiceConfigDeps): ServiceConfigService {
    return new ServiceConfigService(deps);
  }

  // ============ 初始化与订阅 ============

  /** 首次使用时幂等建表（tasks.md 3.1/3.7） */
  private ensureInit(): Promise<void> {
    if (this.schemaReady === null) {
      this.schemaReady = ensureSchema(this.deps.store);
    }
    return this.schemaReady;
  }

  /** 订阅配置变更；返回取消订阅句柄（tasks.md 3.7） */
  subscribe(listener: () => void): Unsubscribe {
    this.listeners.push(listener);
    return (): void => {
      const idx: number = this.listeners.indexOf(listener);
      if (idx >= 0) {
        this.listeners.splice(idx, 1);
      }
    };
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  // ============ 查询 ============

  async listConfigs(): Promise<ModelServiceConfig[]> {
    await this.ensureInit();
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_COLUMNS} FROM ${TABLE_SERVICE_CONFIG} ORDER BY is_default DESC, created_at DESC`
    };
    const rows: ServiceConfigRow[] = await this.deps.store.query<ServiceConfigRow>(spec);
    const configs: ModelServiceConfig[] = [];
    for (let i = 0; i < rows.length; i++) {
      configs.push(rowToConfig(rows[i]));
    }
    return configs;
  }

  async getConfig(configId: string): Promise<ModelServiceConfig> {
    await this.ensureInit();
    const row: ServiceConfigRow | undefined = await this.findRow(configId);
    if (row === undefined) {
      throw new AppError(ErrorCode.CFG_MISSING_FIELD, `配置不存在：${configId}`);
    }
    return rowToConfig(row);
  }

  async getDefaultConfig(): Promise<ModelServiceConfig | undefined> {
    await this.ensureInit();
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_COLUMNS} FROM ${TABLE_SERVICE_CONFIG} WHERE is_default = 1 LIMIT 1`
    };
    const rows: ServiceConfigRow[] = await this.deps.store.query<ServiceConfigRow>(spec);
    return rows.length === 0 ? undefined : rowToConfig(rows[0]);
  }

  // ============ 保存（校验 + 加密 + 单默认原子更新） ============

  async saveConfig(draft: ServiceConfigDraft): Promise<ModelServiceConfig> {
    await this.ensureInit();
    validateDraftForSave(draft);

    const duplicated: ServiceConfigRow | undefined = await this.findRowByName(draft.name, draft.configId);
    if (duplicated !== undefined) {
      throw new AppError(ErrorCode.CFG_DUPLICATE_NAME, `配置名称已存在：${draft.name.trim()}`);
    }

    const current: ServiceConfigRow | undefined =
      draft.configId !== undefined && draft.configId.length > 0 ? await this.findRow(draft.configId) : undefined;

    // 落盘前加密；明文绝不进入存储参数（spec 4.3.1）
    const secretRef: SecretRef = await this.deps.crypto.encryptSecret(draft.secret);
    const configId: string = current !== undefined
      ? current.config_id
      : (draft.configId !== undefined && draft.configId.length > 0 ? draft.configId : newId('cfg'));
    const createdAt: number = current !== undefined ? current.created_at : nowMs();
    const config: ModelServiceConfig = draftToConfig(draft, secretRef, configId, createdAt);

    try {
      await this.deps.store.transaction(async (tx: TxContext): Promise<void> => {
        if (draft.isDefault) {
          await tx.execute({ sql: SQL_CLEAR_DEFAULT });
        }
        if (current !== undefined) {
          await tx.execute({ sql: SQL_UPDATE, args: configToUpdateArgs(config) });
        } else {
          await tx.execute({ sql: SQL_INSERT, args: configToInsertArgs(config) });
        }
      });
    } catch (e) {
      // 事务失败：清理刚生成的密钥实体，避免悬挂引用
      await this.deps.crypto.removeSecret(secretRef);
      throw new AppError(ErrorCode.UNKNOWN_ERROR, `事务执行失败: ${e}`);
    }

    // 更新场景：密钥别名变化时清理旧密钥引用
    if (current !== undefined) {
      const oldAlias: string = current.secret_alias === null ? '' : current.secret_alias;
      if (oldAlias.length > 0 && oldAlias !== secretRef.alias) {
        await this.deps.crypto.removeSecret({
          alias: oldAlias,
          algorithm: current.secret_algo === null ? '' : current.secret_algo
        });
      }
    }

    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE,
      `保存服务配置 id=${configId} name=${config.name} endpoint=${config.endpoint} targetModel=${config.targetModel}`);
    this.notify();
    return config;
  }

  // ============ 默认设置（单默认约束，spec 6.1.6） ============

  async setDefault(configId: string): Promise<void> {
    await this.ensureInit();
    const current: ServiceConfigRow | undefined = await this.findRow(configId);
    if (current === undefined) {
      throw new AppError(ErrorCode.CFG_MISSING_FIELD, `配置不存在：${configId}`);
    }
    await this.deps.store.transaction(async (tx: TxContext): Promise<void> => {
      await tx.execute({ sql: SQL_CLEAR_DEFAULT });
      await tx.execute({ sql: SQL_SET_DEFAULT, args: [configId] });
    });
    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE, `设为默认配置 id=${configId}`);
    this.notify();
  }

  // ============ 删除（引用冲突拦截 + 密钥清理） ============

  async removeConfig(configId: string): Promise<void> {
    await this.ensureInit();
    const current: ServiceConfigRow | undefined = await this.findRow(configId);
    if (current === undefined) {
      throw new AppError(ErrorCode.CFG_MISSING_FIELD, `配置不存在：${configId}`);
    }

    const checker: ((id: string) => Promise<boolean>) | undefined = this.deps.taskReferenceChecker;
    const referenced: boolean = checker !== undefined
      ? await checker(configId)
      : await TaskConfigService.getInstance().hasTaskReferencingConfig(configId);
    if (referenced) {
      throw new AppError(ErrorCode.RECORD_BUSY_CANNOT_DELETE, '该配置正被评测任务引用，无法删除');
    }

    const spec: ExecSpec = { sql: SQL_DELETE, args: [configId] };
    await this.deps.store.execute(spec);

    const alias: string = current.secret_alias === null ? '' : current.secret_alias;
    if (alias.length > 0) {
      await this.deps.crypto.removeSecret({
        alias: alias,
        algorithm: current.secret_algo === null ? '' : current.secret_algo
      });
    }

    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE, `删除服务配置 id=${configId} name=${current.name}`);
    this.notify();
  }

  // ============ 明文查看（二次确认后调用；明文不落盘、不进日志） ============

  async revealSecret(configId: string): Promise<string> {
    await this.ensureInit();
    const current: ServiceConfigRow | undefined = await this.findRow(configId);
    if (current === undefined) {
      throw new AppError(ErrorCode.CFG_MISSING_FIELD, `配置不存在：${configId}`);
    }
    const alias: string = current.secret_alias === null ? '' : current.secret_alias;
    if (alias.length === 0) {
      throw new AppError(ErrorCode.CFG_SECRET_INVALID, '该配置未存储密钥');
    }
    const ref: SecretRef = {
      alias: alias,
      algorithm: current.secret_algo === null ? '' : current.secret_algo
    };
    // 明文仅返回调用方，不写日志
    return this.deps.crypto.decryptSecret(ref);
  }

  // ============ 连通性验证（无持久化副作用） ============

  async testConnection(draft: ServiceConfigDraft): Promise<ConnectionTestResult> {
    const state: NetworkState = this.deps.network.current();
    if (!state.available) {
      // 网络不可用：直接拒绝，不进入等待态（spec 5.1.3-3）
      throw new AppError(ErrorCode.NET_UNAVAILABLE, '当前无可用网络');
    }

    const probeConfig: ModelServiceConfig = {
      configId: draft.configId === undefined ? 'probe' : draft.configId,
      name: draft.name,
      endpoint: draft.endpoint,
      targetModel: draft.targetModel,
      isDefault: draft.isDefault,
      status: ConfigStatus.VALID,
      secretRef: { alias: '', algorithm: '' },
      createdAt: nowMs()
    };
    const raw: ConnectionTestResult = await this.deps.modelClient.probe(probeConfig, draft.secret);

    if (raw.success) {
      this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_TEST, `连通性验证成功 endpoint=${draft.endpoint}`);
      return { success: true, reason: '' };
    }

    const code: ErrorCode = classifyProbeFailure(raw.reason);
    const reason: string = ErrorMessages.of(code, this.deps.logger.redact(raw.reason));
    this.deps.logger.log(LogLevel.WARN, LogEvent.CONFIG_TEST,
      `连通性验证失败 endpoint=${draft.endpoint} reason=${reason}`);
    return { success: false, reason: reason };
  }

  // ============ 内部查询辅助 ============

  private async findRow(configId: string): Promise<ServiceConfigRow | undefined> {
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_COLUMNS} FROM ${TABLE_SERVICE_CONFIG} WHERE config_id = ?`,
      args: [configId]
    };
    const rows: ServiceConfigRow[] = await this.deps.store.query<ServiceConfigRow>(spec);
    return rows.length === 0 ? undefined : rows[0];
  }

  /** 名称唯一性查询；excludeId 用于更新场景排除自身 */
  private async findRowByName(name: string, excludeId?: string): Promise<ServiceConfigRow | undefined> {
    const spec: QuerySpec = {
      sql: `SELECT ${SELECT_COLUMNS} FROM ${TABLE_SERVICE_CONFIG} WHERE name = ?`,
      args: [name.trim()]
    };
    const rows: ServiceConfigRow[] = await this.deps.store.query<ServiceConfigRow>(spec);
    for (let i = 0; i < rows.length; i++) {
      if (excludeId === undefined || rows[i].config_id !== excludeId) {
        return rows[i];
      }
    }
    return undefined;
  }
}