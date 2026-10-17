/**
 * 用户首选项适配器。基于 @ohos.data.preferences（tasks.md 2.1）。
 * 承载轻量配置：默认执行参数、通知开关、运行记录上限。
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { PreferencesPort } from '../ports/PreferencesPort';

const STORE_NAME: string = 'deepseek_harness_pref';

export class PreferencesAdapter implements PreferencesPort {
  private context: common.Context;
  private store: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async ensureStore(): Promise<preferences.Preferences> {
    if (this.store !== null) {
      return this.store;
    }
    const store: preferences.Preferences = await preferences.getPreferences(this.context, STORE_NAME);
    this.store = store;
    return store;
  }

  async getString(key: string, defValue: string): Promise<string> {
    const store: preferences.Preferences = await this.ensureStore();
    const value: preferences.ValueType = await store.get(key, defValue);
    return typeof value === 'string' ? value : defValue;
  }

  async putString(key: string, value: string): Promise<void> {
    const store: preferences.Preferences = await this.ensureStore();
    await store.put(key, value);
  }

  async getNumber(key: string, defValue: number): Promise<number> {
    const store: preferences.Preferences = await this.ensureStore();
    const value: preferences.ValueType = await store.get(key, defValue);
    return typeof value === 'number' ? value : defValue;
  }

  async putNumber(key: string, value: number): Promise<void> {
    const store: preferences.Preferences = await this.ensureStore();
    await store.put(key, value);
  }

  async getBoolean(key: string, defValue: boolean): Promise<boolean> {
    const store: preferences.Preferences = await this.ensureStore();
    const value: preferences.ValueType = await store.get(key, defValue);
    return typeof value === 'boolean' ? value : defValue;
  }

  async putBoolean(key: string, value: boolean): Promise<void> {
    const store: preferences.Preferences = await this.ensureStore();
    await store.put(key, value);
  }

  async has(key: string): Promise<boolean> {
    const store: preferences.Preferences = await this.ensureStore();
    return await store.has(key);
  }

  async delete(key: string): Promise<void> {
    const store: preferences.Preferences = await this.ensureStore();
    await store.delete(key);
  }

  async clear(): Promise<void> {
    const store: preferences.Preferences = await this.ensureStore();
    await store.clear();
  }

  async flush(): Promise<void> {
    const store: preferences.Preferences = await this.ensureStore();
    await store.flush();
  }
}