/**
 * NotificationPort 内存测试桩：记录已发布通知，授权状态可配置。
 */
import { AppNotification } from '../../common/types/InfraTypes';
import { NotificationPort } from '../ports/NotificationPort';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';

export class StubNotification implements NotificationPort {
  private authorized: boolean;
  private published: AppNotification[] = [];

  constructor(authorized: boolean = true) {
    this.authorized = authorized;
  }

  async isAuthorized(): Promise<boolean> {
    return this.authorized;
  }

  async requestAuthorization(): Promise<boolean> {
    this.authorized = true;
    return true;
  }

  async publish(n: AppNotification): Promise<void> {
    if (!this.authorized) {
      throw new AppError(ErrorCode.UNKNOWN_ERROR, 'notification not authorized');
    }
    this.published.push(n);
  }

  async cancel(id: number): Promise<void> {
    this.published = this.published.filter((item: AppNotification) => item.id !== id);
  }

  publishedNotifications(): AppNotification[] {
    return this.published;
  }
}