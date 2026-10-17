/**
 * 流式片段增量组装器（design.md 2.1.3(2)，tasks.md 5.3）。
 * 流式片段仅追加到内存缓冲，推送进度事件；禁止在回调中执行耗时主线程操作。
 */
export class StreamAssembler {
  private buffer: string = '';

  /** 追加流式片段到内存缓冲 */
  append(chunk: string): void {
    this.buffer += chunk;
  }

  /** 获取当前组装的完整文本 */
  current(): string {
    return this.buffer;
  }

  /** 重置缓冲，用于切换到下一个用例 */
  reset(): void {
    this.buffer = '';
  }
}