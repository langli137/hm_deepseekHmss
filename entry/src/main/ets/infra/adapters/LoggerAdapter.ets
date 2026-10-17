/**
 * 结构化日志适配器。基于 @ohos.hilog，条目包含时间、级别、事件类型与简述（spec 4.4.1）。
 * 所有文案经脱敏器过滤后再落日志（spec 4.3.4）。
 */
import hilog from '@ohos.hilog';
import { LogEvent, LogLevel } from '../../common/types/Enums';
import { LoggerPort } from '../ports/LoggerPort';
import { Redactor } from './Redactor';

const DOMAIN: number = 0xD0001;
const TAG: string = 'DeepSeekHarness';

export class LoggerAdapter implements LoggerPort {
  private redactor: Redactor;

  constructor(redactor: Redactor = new Redactor()) {
    this.redactor = redactor;
  }

  log(level: LogLevel, event: LogEvent, message: string): void {
    const safe: string = this.redactor.redactText(message);
    const line: string = `[${event}] ${safe}`;
    switch (level) {
      case LogLevel.DEBUG:
        hilog.debug(DOMAIN, TAG, '%{public}s', line);
        break;
      case LogLevel.INFO:
        hilog.info(DOMAIN, TAG, '%{public}s', line);
        break;
      case LogLevel.WARN:
        hilog.warn(DOMAIN, TAG, '%{public}s', line);
        break;
      case LogLevel.ERROR:
        hilog.error(DOMAIN, TAG, '%{public}s', line);
        break;
      default:
        hilog.info(DOMAIN, TAG, '%{public}s', line);
        break;
    }
  }

  redact(text: string): string {
    return this.redactor.redactText(text);
  }
}