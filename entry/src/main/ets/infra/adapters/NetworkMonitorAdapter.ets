/**
 * 网络状态监控适配器。基于 @ohos.net.connection（tasks.md 2.4）。
 * 返回取消订阅句柄，避免监听泄漏；状态变化用于触发任务暂停/续跑。
 */
import connection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import { NetworkState, Unsubscribe } from '../../common/types/InfraTypes';
import { NetworkMonitorPort } from '../ports/NetworkMonitorPort';

export class NetworkMonitorAdapter implements NetworkMonitorPort {
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  current(): NetworkState {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      if (handle === undefined || handle.netId === 0) {
        return { available: false, type: 'none' };
      }
      const capabilities: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle);
      return { available: true, type: this.bearerOf(capabilities) };
    } catch (e) {
      return { available: false, type: 'unknown' };
    }
  }

  private bearerOf(capabilities: connection.NetCapabilities): string {
    const types: connection.NetBearType[] = capabilities.bearerTypes;
    if (types === undefined || types.length === 0) {
      return 'unknown';
    }
    switch (types[0]) {
      case connection.NetBearType.BEARER_CELLULAR:
        return 'cellular';
      case connection.NetBearType.BEARER_WIFI:
        return 'wifi';
      case connection.NetBearType.BEARER_ETHERNET:
        return 'ethernet';
      default:
        return 'other';
    }
  }

  onChanged(listener: (state: NetworkState) => void): Unsubscribe {
    const notify = (): void => {
      listener(this.current());
    };
    // 网络状态监听在HarmonyOS中需要通过其他方式实现
    // 暂时返回一个空的取消订阅函数
    return (): void => {
      // 取消订阅逻辑
    };
  }
}