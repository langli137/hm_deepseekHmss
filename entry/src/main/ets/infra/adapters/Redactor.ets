/**
 * 统一脱敏器。对齐 design.md 2.1.3（5）与 tasks.md 2.8：
 * 覆盖日志、通知、导出报告三类出口，禁止密钥明文外泄（spec 4.3.4、4.4.3、5.1.6）。
 */
import { AppNotification } from '../../common/types/InfraTypes';

interface SecretPattern {
  regex: RegExp;
  replacement: string;
}

const MASK: string = '***REDACTED***';

const PATTERNS: SecretPattern[] = [
  // OpenAI 风格密钥 sk-xxxx
  { regex: /sk-[A-Za-z0-9_\-]{6,}/g, replacement: MASK },
  // Authorization: Bearer xxxx
  { regex: /(Bearer\s+)[A-Za-z0-9._\-]{6,}/gi, replacement: `$1${MASK}` },
  // JSON / query 形态的 key、token、secret、password
  { regex: /("?(?:api[_-]?key|access[_-]?token|secret|password|authorization)"?\s*[:=]\s*"?)[^",\s}]{4,}/gi, replacement: `$1${MASK}` }
];

export class Redactor {
  /** 文本脱敏，适用于日志与导出内容 */
  redactText(text: string): string {
    let result: string = text;
    for (let i = 0; i < PATTERNS.length; i++) {
      const p: SecretPattern = PATTERNS[i];
      result = result.replace(p.regex, p.replacement);
    }
    return result;
  }

  /** 通知脱敏，标题与正文均过滤 */
  redactNotification(n: AppNotification): AppNotification {
    return {
      id: n.id,
      title: this.redactText(n.title),
      text: this.redactText(n.text)
    };
  }

  /** 导出报告脱敏，与日志共用规则 */
  redactExport(content: string): string {
    return this.redactText(content);
  }
}

/** 无状态便捷函数：日志适配器的默认脱敏入口 */
export function redactText(text: string): string {
  return new Redactor().redactText(text);
}