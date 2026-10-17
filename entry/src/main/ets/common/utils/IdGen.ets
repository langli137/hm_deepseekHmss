/**
 * 标识与时间工具。
 */
let seqCounter: number = 0;

/** 生成带前缀的唯一标识（本地单机单用户场景足够） */
export function newId(prefix: string): string {
  seqCounter += 1;
  const ts: number = Date.now();
  const rand: number = Math.floor(Math.random() * 100000);
  return `${prefix}_${ts}_${seqCounter}_${rand}`;
}

/** 当前毫秒时间戳 */
export function nowMs(): number {
  return Date.now();
}