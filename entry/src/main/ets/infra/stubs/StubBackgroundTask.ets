/**
 * BackgroundTaskPort 内存测试桩：记录申请/释放次数，验证成对出现。
 */
import { BackgroundTaskHandle } from '../../common/types/InfraTypes';
import { nowMs } from '../../common/utils/IdGen';
import { BackgroundTaskPort } from '../ports/BackgroundTaskPort';

export class StubBackgroundTask implements BackgroundTaskPort {
  private activeCount: number = 0;

  async acquire(): Promise<BackgroundTaskHandle> {
    this.activeCount += 1;
    return { id: nowMs() };
  }

  async release(handle: BackgroundTaskHandle): Promise<void> {
    if (this.activeCount > 0) {
      this.activeCount -= 1;
    }
  }

  active(): number {
    return this.activeCount;
  }
}