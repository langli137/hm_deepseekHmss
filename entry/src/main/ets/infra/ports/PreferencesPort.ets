/**
 * 用户首选项（KV）端口。承载轻量配置：默认执行参数、通知开关、运行记录上限等。
 * 对齐 tasks.md 2.1「定义 KV 读写接口」。为遵守强类型约束，按值类型提供显式方法，
 * 不使用 Object 泛型容器。
 */
export interface PreferencesPort {
  getString(key: string, defValue: string): Promise<string>;
  putString(key: string, value: string): Promise<void>;
  getNumber(key: string, defValue: number): Promise<number>;
  putNumber(key: string, value: number): Promise<void>;
  getBoolean(key: string, defValue: boolean): Promise<boolean>;
  putBoolean(key: string, value: boolean): Promise<void>;
  has(key: string): Promise<boolean>;
  delete(key: string): Promise<void>;
  clear(): Promise<void>;
  /** 显式落盘，保证进程退出后可见 */
  flush(): Promise<void>;
}