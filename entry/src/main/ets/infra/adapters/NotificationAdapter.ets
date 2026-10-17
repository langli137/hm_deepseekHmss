/**
 * 通知适配器。基于 @ohos.notificationManager（tasks.md 2.5）。
 * 发布前须经脱敏器过滤，禁止密钥明文进入通知（spec 4.3.4、5.1.6）。
 */
import notificationManager from '@ohos.notificationManager';
import { NotificationBasicContent, NotificationContent, NotificationRequest, ContentType } from '@ohos.notificationManager';
import common from '@ohos.app.ability.common';
import { AppNotification } from '../../common/types/InfraTypes';
import { NotificationPort } from '../ports/NotificationPort';
import { Redactor } from './Redactor';

export class NotificationAdapter implements NotificationPort {
  private context: common.UIAbilityContext;
  private redactor: Redactor;

  constructor(context: common.UIAbilityContext, redactor: Redactor = new Redactor()) {
    this.context = context;
    this.redactor = redactor;
  }

  async isAuthorized(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      return false;
    }
  }

  async requestAuthorization(): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(this.context);
      return true;
    } catch (e) {
      return false;
    }
  }

  async publish(n: AppNotification): Promise<void> {
    const safe: AppNotification = this.redactor.redactNotification(n);
    const request: NotificationRequest = new NotificationRequest();
    request.id = safe.id;
    const content: NotificationContent = new NotificationContent();
    content.notificationContentType = ContentType.NOTIFICATION_CONTENT_BASIC_TEXT;
    const normal: NotificationBasicContent = new NotificationBasicContent();
    normal.title = safe.title;
    normal.text = safe.text;
    content.normal = normal;
    request.content = content;
    await notificationManager.publish(request);
  }

  async cancel(id: number): Promise<void> {
    await notificationManager.cancel(id);
  }
}