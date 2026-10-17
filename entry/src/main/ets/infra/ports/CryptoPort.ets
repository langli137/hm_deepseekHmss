/**
 * 密钥加密端口。对齐 design.md 2.2.2(G) 与 tasks.md 2.2。
 * 明文仅在内存与提交瞬间存在，落盘只保留 SecretRef{alias, algorithm}。
 */
import { SecretRef } from '../../common/types/InfraTypes';

export interface CryptoPort {
  /** 加密明文密钥并返回密钥库别名引用（spec 4.3.1） */
  encryptSecret(plain: string): Promise<SecretRef>;
  /** 按引用解密；密钥缺失时抛出 CFG_SECRET_INVALID */
  decryptSecret(ref: SecretRef): Promise<string>;
  /** 清除密钥库中的密钥实体（不可逆，spec 4.3.3） */
  removeSecret(ref: SecretRef): Promise<void>;
}