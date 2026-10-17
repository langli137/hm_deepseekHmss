/**
 * 系统通知端口。对齐 design.md 2.2.2(G) 与 tasks.md 2.5。
 * 通知内容必须经脱敏器过滤后方可发布（spec 4.3.4、5.1.6）。
 * requestAuthorization / cancel 为能力次要版本新增，不破坏既有签名。
 */
import { AppNotification } from '../../common/types/InfraTypes';

export interface NotificationPort {
  /** 是否已获得通知授权 */
  isAuthorized(): Promise<boolean>;
  /** 申请通知授权，返回最终授权结果 */
  requestAuthorization(): Promise<boolean>;
  /** 发布基础通知；用户关闭通知开关时调用方应跳过 */
  publish(n: AppNotification): Promise<void>;
  /** 取消指定标识的通知 */
  cancel(id: number): Promise<void>;
}