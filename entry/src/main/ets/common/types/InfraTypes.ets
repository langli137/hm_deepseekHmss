/**
 * 基础设施层通用类型（端口与适配器共用）。对齐 design.md 2.2.2(G)、tasks.md 1.5。
 */

/** 取消订阅句柄 */
export type Unsubscribe = () => void;

/** 可取消令牌，用于中断流式请求与超时控制 */
export interface CancellationToken {
  readonly cancelled: boolean;
  onCancel(callback: () => void): void;
  cancel(): void;
}

/** 密钥引用句柄：仅保存别名与算法，明文不出系统密钥库（spec 4.3.1） */
export interface SecretRef {
  alias: string;
  algorithm: string;
}

/** 网络状态（NetworkMonitorPort） */
export interface NetworkState {
  available: boolean;
  type: string;
}

/** 后台长时任务句柄（BackgroundTaskPort） */
export interface BackgroundTaskHandle {
  id: number;
}

/** 系统通知内容（NotificationPort） */
export interface AppNotification {
  id: number;
  title: string;
  text: string;
}

/** 报告导出结果（MetricReportService.exportReport） */
export interface ExportResult {
  success: boolean;
  uri: string;
  reason: string;
}

/** 存储查询规格 */
export interface QuerySpec {
  sql: string;
  args?: Array<string | number | boolean | null>;
}

/** 存储写入规格 */
export interface ExecSpec {
  sql: string;
  args?: Array<string | number | boolean | null>;
}

/** 事务上下文：事务内查询与写入共用同一连接 */
export interface TxContext {
  query<T>(spec: QuerySpec): Promise<T[]>;
  execute(spec: ExecSpec): Promise<number>;
}