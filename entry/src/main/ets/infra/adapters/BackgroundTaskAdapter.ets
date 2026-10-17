/**
 * 后台长时任务适配器。基于 @ohos.resourceschedule.backgroundTaskManager（tasks.md 2.6）。
 * 申请与释放成对，避免句柄泄漏；长时任务类型与 dataTransfer 匹配。
 */
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { BackgroundMode } from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { Want, WantAgent, WantAgentFlags, WantAgentInfo, OperationType } from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
import { BackgroundTaskHandle } from '../../common/types/InfraTypes';
import { nowMs } from '../../common/utils/IdGen';
import { BackgroundTaskPort } from '../ports/BackgroundTaskPort';

const DEFAULT_BUNDLE: string = 'com.deepseek.harness';
const ABILITY_NAME: string = 'EntryAbility';

export class BackgroundTaskAdapter implements BackgroundTaskPort {
  private context: common.UIAbilityContext;
  private bundleName: string;
  private active: boolean = false;

  constructor(context: common.UIAbilityContext, bundleName: string = DEFAULT_BUNDLE) {
    this.context = context;
    this.bundleName = bundleName;
  }

  async acquire(): Promise<BackgroundTaskHandle> {
    if (!this.active) {
      const want: Want = {
        bundleName: this.bundleName,
        abilityName: ABILITY_NAME
      };
      const info: WantAgentInfo = {
        wants: [want],
        actionType: OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        this.context, BackgroundMode.DATA_TRANSFER, agent);
      this.active = true;
    }
    return { id: nowMs() };
  }

  async release(handle: BackgroundTaskHandle): Promise<void> {
    if (this.active) {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.active = false;
    }
  }
}