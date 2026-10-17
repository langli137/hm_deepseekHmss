/**
 * 日志与脱敏端口。对齐 design.md 2.2.2(G) 与 tasks.md 2.8。
 * 结构化日志条目包含时间、级别、事件类型与简述（spec 4.4.1）。
 */
import { LogEvent, LogLevel } from '../../common/types/Enums';

export interface LoggerPort {
  /** 写入结构化日志；message 内部应经脱敏处理 */
  log(level: LogLevel, event: LogEvent, message: string): void;
  /** 对任意文本脱敏，覆盖日志/通知/导出三类出口（spec 4.3.4、4.4.3、5.1.6） */
  redact(text: string): string;
}