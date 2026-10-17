/**
 * 应用设置服务（spec 5.6，tasks.md 8）。
 * - 单例入口：AppSettingsService.getInstance()
 * - 持久化：使用 PreferencesPort（KV），不使用关系型数据库。
 * - 跨模块契约：
 *   ExecutionService.hasRunningTask()、RunRecordService.clearAll()、TaskConfigService.clearAllDatasets()。
 *
 * 业务规则（spec 5.6）：
 * - getSettings()：读取 default_params(JSON)、notification_enabled、record_limit；
 *   首次无值时返回默认值（createDefaultParams()、true、DEFAULT_RECORD_LIMIT）。
 * - updateDefaultParams(params)：isWithinRange() 校验，越界 → AppError(TASK_PARAM_OUT_OF_RANGE)；
 *   通过则 putString('default_params', JSON.stringify(params))；保存失败回滚为原设置（spec 5.6.3-2）。
 * - setNotificationEnabled(enabled)：putBoolean('notification_enabled', enabled)；运行时立即生效。
 * - isNotificationEnabled()：getBoolean('notification_enabled', true)。
 * - clearLocalData()：先检查 hasRunningTask()，为真 → AppError(SETTINGS_BUSY_TASK_RUNNING)；
 *   否则调用 RunRecordService.clearAll() + TaskConfigService.clearAllDatasets()。
 */
import { AppContainer } from '../../entrystage/AppContainer';
import { PreferencesPort } from '../../infra/ports/PreferencesPort';
import { LoggerPort } from '../../infra/ports/LoggerPort';
import { AppSettings, RunParameters } from '../../common/types/DomainTypes';
import { DEFAULT_RECORD_LIMIT } from '../../common/types/Constants';
import { AppError, asAppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { LogEvent, LogLevel, JudgeMode } from '../../common/types/Enums';
import { createDefaultParams, describeViolation, isWithinRange } from '../../common/utils/ParamRules';
import { ExecutionService } from '../execution/ExecutionService';
import { RunRecordService } from '../runrecord/RunRecordService';
import { TaskConfigService } from '../taskconfig/TaskConfigService';

// ============ Preferences 键名 ============

const KEY_DEFAULT_PARAMS: string = 'default_params';
const KEY_NOTIFICATION_ENABLED: string = 'notification_enabled';
const KEY_RECORD_LIMIT: string = 'record_limit';

// ============ 依赖注入 ============

export interface AppSettingsDeps {
  preferences: PreferencesPort;
  logger: LoggerPort;
  /** 是否有运行中任务（跨模块契约 ExecutionService.hasRunningTask） */
  hasRunningTaskProvider: () => boolean;
  /** 清空全部运行记录（跨模块契约 RunRecordService.clearAll） */
  clearRunRecordsProvider: () => Promise<void>;
  /** 清空全部本地题目集（跨模块契约 TaskConfigService.clearAllDatasets） */
  clearDatasetsProvider: () => Promise<void>;
}

// ============ AppSettingsService ============

export class AppSettingsService {
  private static instance: AppSettingsService | null = null;

  private deps: AppSettingsDeps;

  private constructor(deps: AppSettingsDeps) {
    this.deps = deps;
  }

  static getInstance(): AppSettingsService {
    if (AppSettingsService.instance === null) {
      const container: AppContainer = AppContainer.getInstance();
      AppSettingsService.instance = new AppSettingsService({
        preferences: container.preferences(),
        logger: container.logger(),
        hasRunningTaskProvider: (): boolean => {
          return ExecutionService.getInstance().hasRunningTask();
        },
        clearRunRecordsProvider: (): Promise<void> => {
          return RunRecordService.getInstance().clearAll();
        },
        clearDatasetsProvider: (): Promise<void> => {
          return TaskConfigService.getInstance().clearAllDatasets();
        }
      });
    }
    return AppSettingsService.instance;
  }

  static createForTest(deps: AppSettingsDeps): AppSettingsService {
    return new AppSettingsService(deps);
  }

  // ============ 对外接口 ============

  /**
   * 读取应用设置（spec 5.6.1-1）。
   * 首次无值时返回默认值：createDefaultParams()、notificationEnabled=true、recordLimit=DEFAULT_RECORD_LIMIT。
   */
  async getSettings(): Promise<AppSettings> {
    const paramsJson: string = await this.deps.preferences.getString(KEY_DEFAULT_PARAMS, '');
    let defaultParams: RunParameters;
    if (paramsJson.length === 0) {
      defaultParams = createDefaultParams();
    } else {
      defaultParams = this.parseParams(paramsJson);
    }

    const notificationEnabled: boolean = await this.deps.preferences.getBoolean(KEY_NOTIFICATION_ENABLED, true);
    const recordLimit: number = await this.deps.preferences.getNumber(KEY_RECORD_LIMIT, DEFAULT_RECORD_LIMIT);

    return {
      defaultParams: defaultParams,
      notificationEnabled: notificationEnabled,
      recordLimit: recordLimit
    };
  }

  /**
   * 更新默认执行参数（spec 5.6.1-1）。
   * 越界 → AppError(TASK_PARAM_OUT_OF_RANGE, describeViolation(params))；
   * 保存失败回滚为原设置（spec 5.6.3-2）。
   */
  async updateDefaultParams(params: RunParameters): Promise<void> {
    if (!isWithinRange(params)) {
      throw new AppError(ErrorCode.TASK_PARAM_OUT_OF_RANGE, describeViolation(params));
    }

    const oldJson: string = await this.deps.preferences.getString(KEY_DEFAULT_PARAMS, '');
    const newJson: string = JSON.stringify(params);

    try {
      await this.deps.preferences.putString(KEY_DEFAULT_PARAMS, newJson);
      await this.deps.preferences.flush();
    } catch (e) {
      // 保存失败回滚为原设置（spec 5.6.3-2）
      if (oldJson.length > 0) {
        await this.deps.preferences.putString(KEY_DEFAULT_PARAMS, oldJson);
        await this.deps.preferences.flush();
      }
      const cause: AppError = asAppError(e, ErrorCode.SETTINGS_BUSY_TASK_RUNNING);
      throw new AppError(ErrorCode.SETTINGS_BUSY_TASK_RUNNING, `设置保存失败：${cause.detail}`);
    }

    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE, '更新默认执行参数');
  }

  /**
   * 设置通知开关（spec 5.6.1-2）。
   * 运行时立即生效（其他模块通过 isNotificationEnabled() 读取）。
   */
  async setNotificationEnabled(enabled: boolean): Promise<void> {
    await this.deps.preferences.putBoolean(KEY_NOTIFICATION_ENABLED, enabled);
    await this.deps.preferences.flush();
    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE, `通知开关设为 ${enabled}`);
  }

  /**
   * 查询通知是否开启（spec 5.6.1-2）。
   * 默认值为 true。
   */
  async isNotificationEnabled(): Promise<boolean> {
    return this.deps.preferences.getBoolean(KEY_NOTIFICATION_ENABLED, true);
  }

  /**
   * 清除本地数据（spec 5.6.1-3、5.6.1-4）。
   * 存在运行中任务时 → AppError(SETTINGS_BUSY_TASK_RUNNING)；
   * 否则调用 RunRecordService.clearAll() + TaskConfigService.clearAllDatasets()。
   */
  async clearLocalData(): Promise<void> {
    if (this.deps.hasRunningTaskProvider()) {
      throw new AppError(ErrorCode.SETTINGS_BUSY_TASK_RUNNING, '请先终止运行中的任务');
    }

    await this.deps.clearRunRecordsProvider();
    await this.deps.clearDatasetsProvider();

    this.deps.logger.log(LogLevel.INFO, LogEvent.CONFIG_SAVE, '清除全部本地数据');
  }

  // ============ 内部辅助 ============

  private parseParams(json: string): RunParameters {
    const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    return {
      temperature: parsed['temperature'] as number,
      maxOutputTokens: parsed['maxOutputTokens'] as number,
      concurrency: parsed['concurrency'] as number,
      timeoutMs: parsed['timeoutMs'] as number,
      judgeMode: parsed['judgeMode'] as JudgeMode
    };
  }
}
