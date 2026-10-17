/**
 * 模型服务配置领域模型：字段范围校验、密钥掩码生成、数据库行 ↔ 领域对象映射。
 * 表名/列名以 infra/adapters/DbSchema.ets 为准（service_config）。
 * 校验规则对齐 spec 5.1.1-1、6.1，以及 tasks.md 3.1 / 3.2 / 3.3。
 */
import { ConfigStatus } from '../../common/types/Enums';
import { ModelServiceConfig, ServiceConfigDraft } from '../../common/types/DomainTypes';
import { SecretRef } from '../../common/types/InfraTypes';
import { CONFIG_NAME_MAX_LENGTH, TARGET_MODEL_MAX_LENGTH } from '../../common/types/Constants';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';

/** 列表/详情默认掩码串（spec 4.3.2）；固定长度，不暴露明文长度 */
export const SECRET_MASK: string = '********';

/** 合法服务地址：须以 http:// 或 https:// 开头且存在主机名（spec 6.1.3） */
const ENDPOINT_REGEX: RegExp = /^https?:\/\/[^\s/]+/;

/** service_config 表行结构（snake_case，与 DbSchema 列名一一对应） */
export interface ServiceConfigRow {
  config_id: string;
  name: string;
  endpoint: string;
  target_model: string;
  is_default: number;
  status: string;
  secret_alias: string | null;
  secret_algo: string | null;
  created_at: number;
}

/** 必填项校验，返回缺失字段的中文描述集合（空数组表示齐全，spec 5.1.1-1） */
export function missingRequiredFields(draft: ServiceConfigDraft): string[] {
  const missing: string[] = [];
  if (draft.name.trim().length === 0) {
    missing.push('配置名称');
  }
  if (draft.endpoint.trim().length === 0) {
    missing.push('服务地址');
  }
  if (draft.secret.length === 0) {
    missing.push('身份密钥');
  }
  if (draft.targetModel.trim().length === 0) {
    missing.push('目标模型名称');
  }
  return missing;
}

/** 服务地址合法性（spec 6.1.3） */
export function isValidEndpoint(endpoint: string): boolean {
  return ENDPOINT_REGEX.test(endpoint.trim());
}

/** 配置名称长度 1~50（spec 6.1.2） */
export function isNameLengthValid(name: string): boolean {
  const len: number = name.trim().length;
  return len >= 1 && len <= CONFIG_NAME_MAX_LENGTH;
}

/** 目标模型名称长度 1~100（spec 6.1.5） */
export function isTargetModelLengthValid(targetModel: string): boolean {
  const len: number = targetModel.trim().length;
  return len >= 1 && len <= TARGET_MODEL_MAX_LENGTH;
}

/** 保存前完整校验；失败抛出携带缺失字段说明的 AppError（tasks.md 3.2） */
export function validateDraftForSave(draft: ServiceConfigDraft): void {
  const missing: string[] = missingRequiredFields(draft);
  if (missing.length > 0) {
    throw new AppError(ErrorCode.CFG_MISSING_FIELD, `缺少必填项：${missing.join('、')}`);
  }
  if (!isValidEndpoint(draft.endpoint)) {
    throw new AppError(ErrorCode.CFG_INVALID_ENDPOINT, `服务地址须以 http:// 或 https:// 开头：${draft.endpoint}`);
  }
  if (!isNameLengthValid(draft.name)) {
    throw new AppError(ErrorCode.CFG_MISSING_FIELD, `配置名称长度需为 1~${CONFIG_NAME_MAX_LENGTH} 个字符`);
  }
  if (!isTargetModelLengthValid(draft.targetModel)) {
    throw new AppError(ErrorCode.CFG_MISSING_FIELD, `目标模型名称长度需为 1~${TARGET_MODEL_MAX_LENGTH} 个字符`);
  }
}

/** 生成密钥掩码串（列表/详情默认展示，spec 4.3.2） */
export function maskSecret(plain: string): string {
  return plain.length === 0 ? '' : SECRET_MASK;
}

/** 数据库行 → 领域对象 */
export function rowToConfig(row: ServiceConfigRow): ModelServiceConfig {
  const alias: string = row.secret_alias === null ? '' : row.secret_alias;
  const algo: string = row.secret_algo === null ? '' : row.secret_algo;
  const status: ConfigStatus = row.status === ConfigStatus.INVALID ? ConfigStatus.INVALID : ConfigStatus.VALID;
  const secretRef: SecretRef = { alias: alias, algorithm: algo };
  return {
    configId: row.config_id,
    name: row.name,
    endpoint: row.endpoint,
    targetModel: row.target_model,
    isDefault: row.is_default === 1,
    status: status,
    secretRef: secretRef,
    createdAt: row.created_at
  };
}

/** 领域对象 → 数据库行 */
export function configToRow(config: ModelServiceConfig): ServiceConfigRow {
  return {
    config_id: config.configId,
    name: config.name,
    endpoint: config.endpoint,
    target_model: config.targetModel,
    is_default: config.isDefault ? 1 : 0,
    status: config.status,
    secret_alias: config.secretRef.alias,
    secret_algo: config.secretRef.algorithm,
    created_at: config.createdAt
  };
}

/** 插入语句绑定参数：仅含 secret_alias/secret_algo，明文绝不落盘（spec 4.3.1） */
export function configToInsertArgs(config: ModelServiceConfig): Array<string | number | boolean | null> {
  const row: ServiceConfigRow = configToRow(config);
  return [row.config_id, row.name, row.endpoint, row.target_model, row.is_default,
    row.status, row.secret_alias, row.secret_algo, row.created_at];
}

/** 更新语句绑定参数：保留 created_at（spec 6.1.7） */
export function configToUpdateArgs(config: ModelServiceConfig): Array<string | number | boolean | null> {
  const row: ServiceConfigRow = configToRow(config);
  return [row.name, row.endpoint, row.target_model, row.is_default, row.status,
    row.secret_alias, row.secret_algo, row.config_id];
}

/** 由草稿 + 已加密密钥引用构造领域对象 */
export function draftToConfig(draft: ServiceConfigDraft, secretRef: SecretRef,
  configId: string, createdAt: number): ModelServiceConfig {
  return {
    configId: configId,
    name: draft.name.trim(),
    endpoint: draft.endpoint.trim(),
    targetModel: draft.targetModel.trim(),
    isDefault: draft.isDefault,
    status: ConfigStatus.VALID,
    secretRef: secretRef,
    createdAt: createdAt
  };
}

/**
 * 探测失败原因分类：鉴权失败（401/403）→ CFG_SECRET_INVALID，
 * 其余不可达/异常 → CFG_CONNECT_FAILED（spec 5.1.3-1、5.1.3-2）。
 */
export function classifyProbeFailure(reason: string): ErrorCode {
  if (reason.includes('密钥') || reason.includes('鉴权') || reason.includes('身份')
    || reason.includes('401') || reason.includes('403')) {
    return ErrorCode.CFG_SECRET_INVALID;
  }
  return ErrorCode.CFG_CONNECT_FAILED;
}