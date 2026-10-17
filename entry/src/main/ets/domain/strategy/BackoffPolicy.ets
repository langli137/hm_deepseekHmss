/**
 * 限流退避策略（design.md 2.1.3(4)，tasks.md 5.4）。
 * 指数退避：base=1000ms，delay = base * 2^attempt，上限 30000ms。
 * spec 5.3.3-3：限流时按退避策略重试，达到重试上限后暂停任务。
 */
const BASE_DELAY_MS: number = 1000;
const MAX_DELAY_MS: number = 30000;

export class BackoffPolicy {
  /**
   * 计算第 attempt 次重试的延迟毫秒数。
   * attempt=0 → 1000ms，attempt=1 → 2000ms，attempt=2 → 4000ms，...
   * 上限 30000ms。
   */
  static nextDelayMs(attempt: number): number {
    const delay: number = BASE_DELAY_MS * Math.pow(2, attempt);
    return delay > MAX_DELAY_MS ? MAX_DELAY_MS : delay;
  }
}