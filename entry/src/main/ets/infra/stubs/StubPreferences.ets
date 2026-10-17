/**
 * PreferencesPort 内存测试桩。
 */
import { PreferencesPort } from '../ports/PreferencesPort';

export class StubPreferences implements PreferencesPort {
  private strings: Map<string, string> = new Map<string, string>();
  private numbers: Map<string, number> = new Map<string, number>();
  private booleans: Map<string, boolean> = new Map<string, boolean>();
  private flushes: number = 0;

  async getString(key: string, defValue: string): Promise<string> {
    const value: string | undefined = this.strings.get(key);
    return value === undefined ? defValue : value;
  }

  async putString(key: string, value: string): Promise<void> {
    this.strings.set(key, value);
  }

  async getNumber(key: string, defValue: number): Promise<number> {
    const value: number | undefined = this.numbers.get(key);
    return value === undefined ? defValue : value;
  }

  async putNumber(key: string, value: number): Promise<void> {
    this.numbers.set(key, value);
  }

  async getBoolean(key: string, defValue: boolean): Promise<boolean> {
    const value: boolean | undefined = this.booleans.get(key);
    return value === undefined ? defValue : value;
  }

  async putBoolean(key: string, value: boolean): Promise<void> {
    this.booleans.set(key, value);
  }

  async has(key: string): Promise<boolean> {
    return this.strings.has(key) || this.numbers.has(key) || this.booleans.has(key);
  }

  async delete(key: string): Promise<void> {
    this.strings.delete(key);
    this.numbers.delete(key);
    this.booleans.delete(key);
  }

  async clear(): Promise<void> {
    this.strings.clear();
    this.numbers.clear();
    this.booleans.clear();
  }

  async flush(): Promise<void> {
    this.flushes += 1;
  }

  flushCount(): number {
    return this.flushes;
  }
}