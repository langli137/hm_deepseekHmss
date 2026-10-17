/**
 * 应用入口 UIAbility。onCreate 初始化 AbilityStage 级服务容器并加载首页。
 */
import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { BusinessError } from '@ohos.base';
import { LogEvent, LogLevel } from '../common/types/Enums';
import { AppContainer, RuntimeEnv } from '../entrystage/AppContainer';
import { CrashMonitor } from '../infra/adapters/CrashMonitor';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 生产环境使用真实适配器；联调时可切换为 RuntimeEnv.DEV / RuntimeEnv.TEST 注入测试桩
    AppContainer.init(this.context, RuntimeEnv.PROD);
    CrashMonitor.install(AppContainer.getInstance().logger());
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        AppContainer.getInstance().logger().log(LogLevel.ERROR, LogEvent.ERROR, '首页加载失败');
      }
    });
  }

  onDestroy(): void {
  }
}