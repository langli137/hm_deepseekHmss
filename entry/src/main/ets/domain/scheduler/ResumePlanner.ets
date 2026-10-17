/**
 * 断点续跑规划器（design.md 2.1.3(3)，tasks.md 5.7）。
 * 以 task_progress.watermark_seq 为水位线，定位首个未完成 seq。
 * seq 从 0 起，watermark_seq=-1 表示无已完成用例。
 */
export class ResumePlanner {
  /**
   * 返回首个未完成 seq。
   * watermark=-1 → 首个用例 seq=0；
   * watermark=N → 下一个 seq=N+1。
   */
  static firstUncompletedSeq(watermark: number): number {
    return watermark + 1;
  }
}