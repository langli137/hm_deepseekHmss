/**
 * SSE 增量解析器。对齐 tasks.md 2.3：按 data: 行切分，处理 [DONE] 终止标记。
 * 该组件为纯函数式状态机，便于独立单测；网络回调线程仅调用 feed 追加缓冲。
 */
const DELIMITER: string = '\n\n';
const DATA_PREFIX: string = 'data:';
const DONE_MARK: string = '[DONE]';

export class SseParser {
  private buffer: string = '';
  private done: boolean = false;

  /** 追加原始片段，返回本次可产出的 data 负载数组（已去除 data: 前缀） */
  feed(raw: string): string[] {
    const payloads: string[] = [];
    if (this.done) {
      return payloads;
    }
    // 统一换行，兼容 \r\n\r\n 分帧
    this.buffer += raw.replace(/\r\n/g, '\n');
    let idx: number = this.buffer.indexOf(DELIMITER);
    while (idx >= 0) {
      const frame: string = this.buffer.substring(0, idx);
      this.buffer = this.buffer.substring(idx + DELIMITER.length);
      this.consumeFrame(frame, payloads);
      if (this.done) {
        return payloads;
      }
      idx = this.buffer.indexOf(DELIMITER);
    }
    return payloads;
  }

  /** 流结束时冲刷残余缓冲（可能缺少结尾空行） */
  flush(): string[] {
    const payloads: string[] = [];
    if (!this.done && this.buffer.length > 0) {
      this.consumeFrame(this.buffer, payloads);
      this.buffer = '';
    }
    return payloads;
  }

  isDone(): boolean {
    return this.done;
  }

  reset(): void {
    this.buffer = '';
    this.done = false;
  }

  private consumeFrame(frame: string, out: string[]): void {
    const lines: string[] = frame.split('\n');
    for (let i = 0; i < lines.length; i++) {
      let line: string = lines[i];
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.length === 0 || line.startsWith(':')) {
        continue;
      }
      if (!line.startsWith(DATA_PREFIX)) {
        continue;
      }
      const data: string = line.substring(DATA_PREFIX.length).trim();
      if (data === DONE_MARK) {
        this.done = true;
        return;
      }
      if (data.length > 0) {
        out.push(data);
      }
    }
  }
}