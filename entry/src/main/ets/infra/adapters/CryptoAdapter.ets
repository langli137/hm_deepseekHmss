/**
 * 密钥加密适配器。基于 @ohos.security.huks 的系统密钥库 + AES-256-GCM（tasks.md 2.2）。
 * - 密钥实体由 HUKS 托管，别名即 SecretRef.alias；
 * - 密文与 nonce 存于独立首选项，明文不落盘、不进日志（spec 4.3.1）；
 * - 加解密在异步任务中执行，避免阻塞主线程。
 */
import huks from '@ohos.security.huks';
import cryptoFramework from '@ohos.security.cryptoFramework';
import preferences from '@ohos.data.preferences';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import { SecretRef } from '../../common/types/InfraTypes';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { newId, nowMs } from '../../common/utils/IdGen';
import { CryptoPort } from '../ports/CryptoPort';

const ALGORITHM: string = 'AES256-GCM';
const SECRET_STORE_NAME: string = 'deepseek_harness_secrets';
const NONCE_LENGTH: number = 12;

interface CipherPayload {
  nonce: Uint8Array;
  cipher: Uint8Array;
}

function emptyOptions(): huks.HuksOptions {
  return { properties: [] };
}

export class CryptoAdapter implements CryptoPort {
  private context: common.Context;
  private store: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async ensureStore(): Promise<preferences.Preferences> {
    if (this.store !== null) {
      return this.store;
    }
    this.store = await preferences.getPreferences(this.context, SECRET_STORE_NAME);
    return this.store;
  }

  private randomNonce(): Uint8Array {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = random.generateRandomSync(NONCE_LENGTH);
    return blob.data;
  }

  private encodeUtf8(text: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(text);
  }

  private decodeUtf8(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  }

  private toBase64(bytes: Uint8Array): string {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes);
  }

  private fromBase64(text: string): Uint8Array {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(text);
  }

  private async generateKey(alias: string): Promise<void> {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
      },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE }
    ];
    await huks.generateKeyItem(alias, { properties: properties });
  }

  private async transform(alias: string, purpose: number, nonce: Uint8Array, input: Uint8Array): Promise<Uint8Array> {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: new Uint8Array(0) }
    ];
    const options: huks.HuksOptions = { properties: properties, inData: input };
    const handle: huks.HuksSessionHandle = await huks.initSession(alias, options);
    const result: huks.HuksReturnResult = await huks.finishSession(handle.handle, options);
    return result.outData ?? new Uint8Array(0);
  }

  private async saveCipher(alias: string, payload: CipherPayload): Promise<void> {
    const store: preferences.Preferences = await this.ensureStore();
    const packed: string = `${this.toBase64(payload.nonce)}.${this.toBase64(payload.cipher)}`;
    await store.put(alias, packed);
    await store.flush();
  }

  private async loadCipher(alias: string): Promise<CipherPayload | null> {
    const store: preferences.Preferences = await this.ensureStore();
    if (!await store.has(alias)) {
      return null;
    }
    const raw: preferences.ValueType = await store.get(alias, '');
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    const parts: string[] = raw.split('.');
    if (parts.length !== 2) {
      return null;
    }
    return { nonce: this.fromBase64(parts[0]), cipher: this.fromBase64(parts[1]) };
  }

  async encryptSecret(plain: string): Promise<SecretRef> {
    const alias: string = newId('secret');
    const nonce: Uint8Array = this.randomNonce();
    await this.generateKey(alias);
    const cipher: Uint8Array = await this.transform(
      alias, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce, this.encodeUtf8(plain));
    await this.saveCipher(alias, { nonce: nonce, cipher: cipher });
    return { alias: alias, algorithm: ALGORITHM };
  }

  async decryptSecret(ref: SecretRef): Promise<string> {
    const payload: CipherPayload | null = await this.loadCipher(ref.alias);
    if (payload === null) {
      throw new AppError(ErrorCode.CFG_SECRET_INVALID, '密钥引用不存在');
    }
    try {
      const plainBytes: Uint8Array = await this.transform(
        ref.alias, huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, payload.nonce, payload.cipher);
      return this.decodeUtf8(plainBytes);
    } catch (e) {
      throw new AppError(ErrorCode.CFG_SECRET_INVALID, `解密失败：${nowMs()}`);
    }
  }

  async removeSecret(ref: SecretRef): Promise<void> {
    await huks.deleteKeyItem(ref.alias, emptyOptions());
    const store: preferences.Preferences = await this.ensureStore();
    await store.delete(ref.alias);
    await store.flush();
  }
}