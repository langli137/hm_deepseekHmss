/**
 * 模型服务与认证管理模块单元测试（tasks.md 3.8）。
 * 覆盖：字段校验、密钥加密与掩码、单默认约束、删除引用冲突、
 * 连通性验证成功/鉴权失败/网络不可用三条路径，以及 OpenAI 协议策略。
 * 通过 ServiceConfigService.createForTest 注入端口桩，聚焦业务逻辑。
 */
import { describe, expect, it } from '@ohos/hypium';
import { ServiceConfigDeps, ServiceConfigService } from '../../../main/ets/biz/serviceconfig/ServiceConfigService';
import {
  classifyProbeFailure, configToInsertArgs, isValidEndpoint, maskSecret, missingRequiredFields,
  rowToConfig, ServiceConfigRow, validateDraftForSave
} from '../../../main/ets/biz/serviceconfig/ServiceConfigModel';
import { RelationalStorePort } from '../../../main/ets/infra/ports/RelationalStorePort';
import { ExecSpec, QuerySpec, SecretRef, TxContext } from '../../../main/ets/common/types/InfraTypes';
import {
  ChatChunk, ChatMessage, ChatRequest, ChatResult, ConnectionTestResult, ModelServiceConfig, RunParameters,
  ServiceConfigDraft, UsageSummary
} from '../../../main/ets/common/types/DomainTypes';
import { ConfigStatus, JudgeMode } from '../../../main/ets/common/types/Enums';
import { StubCrypto } from '../../../main/ets/infra/stubs/StubCrypto';
import { StubLogger } from '../../../main/ets/infra/stubs/StubLogger';
import { StubModelBehavior, StubModelClient } from '../../../main/ets/infra/stubs/StubModelClient';
import { StubNetwork } from '../../../main/ets/infra/stubs/StubNetwork';
import { AppError } from '../../../main/ets/common/error/AppError';
import { ErrorCode } from '../../../main/ets/common/error/ErrorCode';
import { OpenAiProtocolStrategy } from '../../../main/ets/domain/strategy/ModelProtocolStrategy';

// ============ 内存存储桩（支撑 service_config 的增删改查断言） ============

class FakeTxContext implements TxContext {
  private owner: FakeConfigStore;

  constructor(owner: FakeConfigStore) {
    this.owner = owner;
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    return this.owner.query<T>(spec);
  }

  async execute(spec: ExecSpec): Promise<number> {
    return this.owner.execute(spec);
  }
}

class FakeConfigStore implements RelationalStorePort {
  private rows: ServiceConfigRow[] = [];

  async transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T> {
    return work(new FakeTxContext(this));
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    return this.dispatch(spec) as T[];
  }

  async execute(spec: ExecSpec): Promise<number> {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];
    if (sql.startsWith('INSERT')) {
      this.rows.push({
        config_id: args[0] as string,
        name: args[1] as string,
        endpoint: args[2] as string,
        target_model: args[3] as string,
        is_default: args[4] as number,
        status: args[5] as string,
        secret_alias: args[6] as string,
        secret_algo: args[7] as string,
        created_at: args[8] as number
      });
    } else if (sql.startsWith('DELETE')) {
      const id: string = args[0] as string;
      this.rows = this.rows.filter((row: ServiceConfigRow): boolean => row.config_id !== id);
    } else if (sql.startsWith('UPDATE')) {
      if (sql.includes('SET is_default = 0')) {
        for (let i = 0; i < this.rows.length; i++) {
          this.rows[i].is_default = 0;
        }
      } else if (sql.includes('SET is_default = 1')) {
        const id: string = args[0] as string;
        for (let i = 0; i < this.rows.length; i++) {
          this.rows[i].is_default = this.rows[i].config_id === id ? 1 : 0;
        }
      } else {
        const id: string = args[7] as string;
        for (let i = 0; i < this.rows.length; i++) {
          if (this.rows[i].config_id === id) {
            this.rows[i].name = args[0] as string;
            this.rows[i].endpoint = args[1] as string;
            this.rows[i].target_model = args[2] as string;
            this.rows[i].is_default = args[3] as number;
            this.rows[i].status = args[4] as string;
            this.rows[i].secret_alias = args[5] as string;
            this.rows[i].secret_algo = args[6] as string;
          }
        }
      }
    }
    return 1;
  }

  private dispatch(spec: QuerySpec): ServiceConfigRow[] {
    const sql: string = spec.sql;
    const args: Array<string | number | boolean | null> = spec.args ?? [];
    const matched: ServiceConfigRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const row: ServiceConfigRow = this.rows[i];
      if (sql.includes('WHERE config_id = ?') && row.config_id !== args[0]) {
        continue;
      }
      if (sql.includes('WHERE name = ?') && row.name !== args[0]) {
        continue;
      }
      if (sql.includes('WHERE is_default = 1') && row.is_default !== 1) {
        continue;
      }
      matched.push(row);
    }
    return matched;
  }

  seed(row: ServiceConfigRow): void {
    this.rows.push(row);
  }

  rowCount(): number {
    return this.rows.length;
  }

  findById(configId: string): ServiceConfigRow | undefined {
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].config_id === configId) {
        return this.rows[i];
      }
    }
    return undefined;
  }
}

// ============ 测试数据构造 ============

function makeRow(configId: string, name: string, isDefault: number, alias: string): ServiceConfigRow {
  return {
    config_id: configId,
    name: name,
    endpoint: 'https://api.deepseek.com/v1',
    target_model: 'deepseek-chat',
    is_default: isDefault,
    status: ConfigStatus.VALID,
    secret_alias: alias,
    secret_algo: 'AES256-GCM',
    created_at: 1000
  };
}

function makeDraft(name: string, secret: string, isDefault: boolean): ServiceConfigDraft {
  return {
    name: name,
    endpoint: 'https://api.deepseek.com/v1',
    targetModel: 'deepseek-chat',
    secret: secret,
    isDefault: isDefault
  };
}

function makeService(store: FakeConfigStore, client: StubModelClient, network: StubNetwork,
  crypto: StubCrypto, referenced: boolean): ServiceConfigService {
  const deps: ServiceConfigDeps = {
    store: store,
    crypto: crypto,
    modelClient: client,
    network: network,
    logger: new StubLogger(),
    taskReferenceChecker: (configId: string): Promise<boolean> => Promise.resolve(referenced)
  };
  return ServiceConfigService.createForTest(deps);
}

function makeConfig(): ModelServiceConfig {
  return {
    configId: 'cfg_x',
    name: '本地服务',
    endpoint: 'https://api.deepseek.com/v1',
    targetModel: 'deepseek-chat',
    isDefault: false,
    status: ConfigStatus.VALID,
    secretRef: { alias: 'a1', algorithm: 'AES256-GCM' },
    createdAt: 1000
  };
}

function makeParams(): RunParameters {
  return { temperature: 0.7, maxOutputTokens: 16, concurrency: 1, timeoutMs: 1000, judgeMode: JudgeMode.CONTAINS };
}

export default function serviceConfigTest() {
  describe('ServiceConfigModel', () => {
    it('reports_missing_required_fields', 0, () => {
      const draft: ServiceConfigDraft = { name: '', endpoint: '', targetModel: '', secret: '', isDefault: false };
      const missing: string[] = missingRequiredFields(draft);
      expect(missing.length).assertEqual(4);
    });

    it('rejects_invalid_endpoint', 0, () => {
      expect(isValidEndpoint('api.deepseek.com/v1')).assertFalse();
      expect(isValidEndpoint('https://api.deepseek.com/v1')).assertTrue();
    });

    it('validate_draft_throws_on_missing_secret', 0, () => {
      let thrown: AppError | null = null;
      try {
        validateDraftForSave(makeDraft('n1', '', false));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.CFG_MISSING_FIELD);
      }
    });

    it('masks_secret', 0, () => {
      expect(maskSecret('sk-abcdef')).assertEqual('********');
      expect(maskSecret('')).assertEqual('');
    });

    it('maps_row_without_plaintext', 0, () => {
      const config: ModelServiceConfig = rowToConfig(makeRow('c1', 'n1', 1, 'alias_1'));
      expect(config.isDefault).assertTrue();
      expect(config.secretRef.alias).assertEqual('alias_1');
      const args: Array<string | number | boolean | null> = configToInsertArgs(config);
      expect(args.includes('alias_1')).assertTrue();
      expect(args.length).assertEqual(9);
    });

    it('classifies_probe_failure', 0, () => {
      expect(classifyProbeFailure('身份密钥无效')).assertEqual(ErrorCode.CFG_SECRET_INVALID);
      expect(classifyProbeFailure('网络不可达')).assertEqual(ErrorCode.CFG_CONNECT_FAILED);
    });
  });

  describe('ServiceConfigService', () => {
    it('save_encrypts_secret_and_persists_ref_only', 0, async () => {
      const store: FakeConfigStore = new FakeConfigStore();
      const crypto: StubCrypto = new StubCrypto();
      const service: ServiceConfigService =
        makeService(store, new StubModelClient(), new StubNetwork(), crypto, false);

      const config: ModelServiceConfig = await service.saveConfig(makeDraft('配置A', 'sk-plain-1', false));
      expect(store.rowCount()).assertEqual(1);
      const row: ServiceConfigRow | undefined = store.findById(config.configId);
      expect(row !== undefined).assertTrue();
      if (row !== undefined) {
        expect(row.secret_alias === 'sk-plain-1').assertFalse();
        expect(crypto.contains(config.secretRef)).assertTrue();
      }
    });

    it('rejects_duplicate_name', 0, async () => {
      const store: FakeConfigStore = new FakeConfigStore();
      store.seed(makeRow('c1', '重复名', 0, 'a1'));
      const service: ServiceConfigService =
        makeService(store, new StubModelClient(), new StubNetwork(), new StubCrypto(), false);

      let thrown: AppError | null = null;
      try {
        await service.saveConfig(makeDraft('重复名', 'sk-2', false));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.CFG_DUPLICATE_NAME);
      }
    });

    it('set_default_clears_previous_default', 0, async () => {
      const store: FakeConfigStore = new FakeConfigStore();
      store.seed(makeRow('c1', 'n1', 1, 'a1'));
      store.seed(makeRow('c2', 'n2', 0, 'a2'));
      const service: ServiceConfigService =
        makeService(store, new StubModelClient(), new StubNetwork(), new StubCrypto(), false);

      await service.setDefault('c2');
      const first: ServiceConfigRow | undefined = store.findById('c1');
      const second: ServiceConfigRow | undefined = store.findById('c2');
      expect(first !== undefined).assertTrue();
      expect(second !== undefined).assertTrue();
      if (first !== undefined) {
        expect(first.is_default).assertEqual(0);
      }
      if (second !== undefined) {
        expect(second.is_default).assertEqual(1);
      }
    });

    it('remove_blocked_when_referenced', 0, async () => {
      const store: FakeConfigStore = new FakeConfigStore();
      store.seed(makeRow('c1', 'n1', 0, 'a1'));
      const service: ServiceConfigService =
        makeService(store, new StubModelClient(), new StubNetwork(), new StubCrypto(), true);

      let thrown: AppError | null = null;
      try {
        await service.removeConfig('c1');
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.RECORD_BUSY_CANNOT_DELETE);
      }
      expect(store.rowCount()).assertEqual(1);
    });

    it('remove_deletes_row_and_secret', 0, async () => {
      const store: FakeConfigStore = new FakeConfigStore();
      const crypto: StubCrypto = new StubCrypto();
      const ref: SecretRef = await crypto.encryptSecret('sk-remove');
      store.seed(makeRow('c1', 'n1', 0, ref.alias));
      const service: ServiceConfigService =
        makeService(store, new StubModelClient(), new StubNetwork(), crypto, false);

      await service.removeConfig('c1');
      expect(store.rowCount()).assertEqual(0);
      expect(crypto.contains(ref)).assertFalse();
    });

    it('test_connection_success', 0, async () => {
      const service: ServiceConfigService = makeService(new FakeConfigStore(),
        new StubModelClient(StubModelBehavior.SUCCESS), new StubNetwork(), new StubCrypto(), false);
      const result: ConnectionTestResult = await service.testConnection(makeDraft('n1', 'sk-1', false));
      expect(result.success).assertTrue();
      expect(result.reason).assertEqual('');
    });

    it('test_connection_auth_failure_returns_secret_invalid_reason', 0, async () => {
      const service: ServiceConfigService = makeService(new FakeConfigStore(),
        new StubModelClient(StubModelBehavior.AUTH_FAILURE), new StubNetwork(), new StubCrypto(), false);
      const result: ConnectionTestResult = await service.testConnection(makeDraft('n1', 'sk-bad', false));
      expect(result.success).assertFalse();
      expect(result.reason.includes('密钥无效')).assertTrue();
    });

    it('test_connection_network_unavailable_throws', 0, async () => {
      const offline: StubNetwork = new StubNetwork({ available: false, type: 'none' });
      const service: ServiceConfigService = makeService(new FakeConfigStore(),
        new StubModelClient(StubModelBehavior.SUCCESS), offline, new StubCrypto(), false);
      let thrown: AppError | null = null;
      try {
        await service.testConnection(makeDraft('n1', 'sk-1', false));
      } catch (e) {
        thrown = e as AppError;
      }
      expect(thrown !== null).assertTrue();
      if (thrown !== null) {
        expect(thrown.code).assertEqual(ErrorCode.NET_UNAVAILABLE);
      }
    });
  });

  describe('OpenAiProtocolStrategy', () => {
    it('builds_openai_chat_request', 0, () => {
      const strategy: OpenAiProtocolStrategy = new OpenAiProtocolStrategy();
      const messages: ChatMessage[] = [{ role: 'user', content: '你好' }];
      const request: ChatRequest = strategy.buildRequest(makeConfig(), 'sk-1', messages, makeParams(), true);
      expect(request.targetModel).assertEqual('deepseek-chat');
      expect(request.stream).assertTrue();
      expect(request.messages.length).assertEqual(1);
    });

    it('parses_stream_chunk_delta', 0, () => {
      const strategy: OpenAiProtocolStrategy = new OpenAiProtocolStrategy();
      const chunk: ChatChunk = strategy.parseChunk('{"choices":[{"delta":{"content":"你好"}}]}');
      expect(chunk.delta).assertEqual('你好');
    });

    it('extracts_usage', 0, () => {
      const strategy: OpenAiProtocolStrategy = new OpenAiProtocolStrategy();
      const usage: UsageSummary | undefined =
        strategy.extractUsage('{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}');
      expect(usage !== undefined).assertTrue();
      if (usage !== undefined) {
        expect(usage.totalTokens).assertEqual(3);
      }
    });

    it('parses_final_response', 0, () => {
      const strategy: OpenAiProtocolStrategy = new OpenAiProtocolStrategy();
      const result: ChatResult = strategy.parseFinal(
        '{"choices":[{"message":{"role":"assistant","content":"答案"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}');
      expect(result.content).assertEqual('答案');
      expect(result.finishReason).assertEqual('stop');
      expect(result.usage.totalTokens).assertEqual(2);
    });
  });
}