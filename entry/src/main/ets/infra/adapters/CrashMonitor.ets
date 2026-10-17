/**
 * 应用崩溃监听与崩溃日志导出（tasks.md 2.8）。
 * 崩溃条目经 LoggerPort 结构化记录（含时间、级别、事件类型与简述），
 * 导出时经统一脱敏器过滤，禁止密钥明文外泄（spec 4.4.2、4.4.3）。
 *
 * API 说明：errorManager.on('error', ErrorObserver) 注册 JS_CRASH 观测器并返回
 * observerId（number）；注销必须使用 off('error', observerId)，而非传入 observer 对象。
 * （'freeze' 类型的 FreezeObserver 为 () => void 回调，不承载异常信息，不在此使用。）
 */
import errorManager from '@ohos.app.ability.errorManager';
import { LogEvent, LogLevel } from '../../common/types/Enums';
import { ExportResult } from '../../common/types/InfraTypes';
import { LoggerPort } from '../ports/LoggerPort';
import { FilePort, SaveFileOptions } from '../ports/FilePort';
import { Redactor } from './Redactor';

export class CrashMonitor {
  private static observer: errorManager.ErrorObserver | null = null;
  private static observerId: number = -1;

  /** 注册崩溃监听，将未处理异常写入结构化日志 */
  static install(logger: LoggerPort): void {
    if (CrashMonitor.observer !== null) {
      return;
    }
    const observer: errorManager.ErrorObserver = {
      onUnhandledException: (errMsg: string, errStack?: string) => {
        const detail: string = errStack !== undefined && errStack.length > 0 ? `${errMsg} | ${errStack}` : errMsg;
        logger.log(LogLevel.ERROR, LogEvent.CRASH, detail);
      }
    };
    try {
      CrashMonitor.observerId = errorManager.on('error', observer);
      CrashMonitor.observer = observer;
    } catch (e) {
      // 仅在主线程生效，注册失败时静默降级
      CrashMonitor.observer = null;
    }
  }

  static uninstall(): void {
    if (CrashMonitor.observer !== null && CrashMonitor.observerId >= 0) {
      try {
        errorManager.off('error', CrashMonitor.observerId).catch(() => {
          // 注销失败不影响进程退出
        });
      } catch (e) {
        // ignore
      }
      CrashMonitor.observer = null;
      CrashMonitor.observerId = -1;
    }
  }

  /** 导出崩溃日志文本（已脱敏） */
  static async exportCrashLog(content: string, filePort: FilePort, redactor: Redactor): Promise<ExportResult> {
    const options: SaveFileOptions = { suggestedFileName: 'crash_log', fileSuffix: 'txt' };
    return filePort.saveText(options, redactor.redactExport(content));
  }
}