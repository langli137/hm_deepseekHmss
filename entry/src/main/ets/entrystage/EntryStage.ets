/**
 * AbilityStage 宿主。作为应用服务层单例的载体（tasks.md 1.3）。
 * 本任务仅保证容器可用；ExecutionService 等长生命周期业务服务由后续任务在此注册。
 */
import AbilityStage from '@ohos.app.ability.AbilityStage';

export default class EntryStage extends AbilityStage {
  onCreate(): void {
    // 容器实例由 EntryAbility.onCreate 通过 AppContainer.init 完成上下文注入
  }
}