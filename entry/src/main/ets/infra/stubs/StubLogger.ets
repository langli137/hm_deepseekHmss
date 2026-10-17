/**
 * LoggerPort 内存测试桩：记录结构化日志条目，供断言（脱敏结论仍走 Redactor）。
 */
import { LogEvent, LogLevel } from '../../common/types/Enums';
import { LoggerPort } from '../ports/LoggerPort';
import { Redactor } from '../adapters/Redactor';

export interface StubLogEntry {
  level: LogLevel;
  event: LogEvent;
  message: string;
}

export class StubLogger implements LoggerPort {
  private entries: StubLogEntry[] = [];
  private redactor: Redactor = new Redactor();

  log(level: LogLevel, event: LogEvent, message: string): void {
    this.entries.push({ level: level, event: event, message: this.redactor.redactText(message) });
  }

  redact(text: string): string {
    return this.redactor.redactText(text);
  }

  entriesOf(): StubLogEntry[] {
    return this.entries;
  }

  clear(): void {
    this.entries = [];
  }
}