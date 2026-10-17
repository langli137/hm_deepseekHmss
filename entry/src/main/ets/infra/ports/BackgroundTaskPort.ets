/**
 * 后台长时任务端口。对齐 design.md 2.2.2(G) 与 tasks.md 2.6。
 * acquire 与 release 必须成对出现，避免句柄泄漏。
 */
import { BackgroundTaskHandle } from '../../common/types/InfraTypes';

export interface BackgroundTaskPort {
  /** 按长时任务类型申请后台运行，返回句柄 */
  acquire(): Promise<BackgroundTaskHandle>;
  /** 释放后台运行；重复释放需幂等 */
  release(handle: BackgroundTaskHandle): Promise<void>;
}