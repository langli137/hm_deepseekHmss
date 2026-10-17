/**
 * CryptoPort 内存测试桩：以可逆编码模拟加密，密钥材料仅驻内存。
 * 缺失引用时抛出 CFG_SECRET_INVALID，供密钥缺失场景测试。
 */
import { SecretRef } from '../../common/types/InfraTypes';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { newId } from '../../common/utils/IdGen';
import { CryptoPort } from '../ports/CryptoPort';

export class StubCrypto implements CryptoPort {
  private vault: Map<string, string> = new Map<string, string>();

  async encryptSecret(plain: string): Promise<SecretRef> {
    const alias: string = newId('stub_secret');
    this.vault.set(alias, plain);
    return { alias: alias, algorithm: 'AES256-GCM' };
  }

  async decryptSecret(ref: SecretRef): Promise<string> {
    const value: string | undefined = this.vault.get(ref.alias);
    if (value === undefined) {
      throw new AppError(ErrorCode.CFG_SECRET_INVALID, '密钥引用不存在');
    }
    return value;
  }

  async removeSecret(ref: SecretRef): Promise<void> {
    this.vault.delete(ref.alias);
  }

  /** 测试辅助：判断密钥是否仍在内存库中 */
  contains(ref: SecretRef): boolean {
    return this.vault.has(ref.alias);
  }
}