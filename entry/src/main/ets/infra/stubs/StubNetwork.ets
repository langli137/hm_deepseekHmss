/**
 * NetworkMonitorPort 内存测试桩：可手动切换网络状态并驱动监听器。
 */
import { NetworkState, Unsubscribe } from '../../common/types/InfraTypes';
import { NetworkMonitorPort } from '../ports/NetworkMonitorPort';

export class StubNetwork implements NetworkMonitorPort {
  private state: NetworkState;
  private listeners: Array<(state: NetworkState) => void> = [];

  constructor(initial: NetworkState = { available: true, type: 'wifi' }) {
    this.state = initial;
  }

  current(): NetworkState {
    return this.state;
  }

  onChanged(listener: (state: NetworkState) => void): Unsubscribe {
    this.listeners.push(listener);
    return (): void => {
      const idx: number = this.listeners.indexOf(listener);
      if (idx >= 0) {
        this.listeners.splice(idx, 1);
      }
    };
  }

  /** 测试辅助：变更网络状态并通知订阅者 */
  emit(next: NetworkState): void {
    this.state = next;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](next);
    }
  }
}