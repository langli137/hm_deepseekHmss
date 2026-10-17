/**
 * 网络状态监控端口。对齐 design.md 2.2.2(G) 与 tasks.md 2.4。
 * 状态变化是触发任务暂停/续跑的信号源（spec 5.3.3）。
 */
import { NetworkState, Unsubscribe } from '../../common/types/InfraTypes';

export interface NetworkMonitorPort {
  /** 同步返回当前网络状态 */
  current(): NetworkState;
  /** 订阅网络状态变化，返回取消订阅句柄 */
  onChanged(listener: (state: NetworkState) => void): Unsubscribe;
}