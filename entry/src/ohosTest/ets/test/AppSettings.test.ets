/**
 * 应用设置模块单元测试（tasks.md 8.3）。
 * 覆盖：getSettings 默认值、updateDefaultParams 校验与回滚、
 * setNotificationEnabled / isNotificationEnabled、clearLocalData 拦截与成功。
 */
import { describe, expect, it } from '@ohos/hypium';
import { AppSettingsDeps, AppSettingsService } from '../../../main/ets/biz/settings/AppSettingsService';
import { AppSettings, RunParameters } from '../../../main/ets/common/types/DomainTypes';
import { JudgeMode } from '../../../main/ets/common/types/Enums';
import { PreferencesPort } from '../../../main/infra/ports/PreferencesPort';
import { LoggerPort } from '../../../main/ets/infra/ports/LoggerPort';
import { StubPreferences } from '../../../main/ets/infra/stubs/StubPreferences';
import { StubLogger } from '../../../main/ets/infra/stubs/StubLogger';
import { AppError } from '../../../main/ets/common/error/AppError';
import { ErrorCode } from '../../../main/ets/common/error/ErrorCode';
import { DEFAULT_RECORD_LIMIT } from '../../../main/ets/common/types/Constants';

// ============ 可控 PreferencesPort 桩 ============

class FailingPreferences implements PreferencesPort {
  private inner: StubPreferences = new StubPreferences();
  private failPutString: boolean = false;

  setFailPutString(fail: boolean): void {
    this.failPutString = fail;
  }

  async getString(key: string, defValue: string): Promise<string> {
    return this.inner.getString(key, defValue);
  }

  async putString(key: string, value: string): Promise<void> {
    if (this.failPutString) {
      throw new Error('模拟写入失败');
    }
    return this.inner.putString(key, value);
  }

  async getNumber(key: string, defValue: number): Promise<number> {
    return this.inner.getNumber(key, defValue);
  }

  async putNumber(key: string, value: number): Promise<void> {
    return this.inner.putNumber(key, value);
  }

  async getBoolean(key: string, defValue: boolean): Promise<boolean> {
    return this.inner.getBoolean(key, defValue);
  }

  async putBoolean(key: string, value: boolean): Promise<void> {
    return this.inner.putBoolean(key, value);
  }

  async has(key: string): Promise<boolean> {
    return this.inner.has(key);
  }

  async delete(key: string): Promise<void> {
    return this.inner.delete(key);
  }

  async clear(): Promise<void> {
    return this.inner.clear();
  }

  async flush(): Promise<void> {
    return this.inner.flush();
  }
}

// ============ 测试数据 ============

function makeParams(temperature: number, maxOutputTokens: number,
  concurrency: number, timeoutMs: number, judgeMode: JudgeMode): RunParameters {
  return {
    temperature: temperature,
    maxOutputTokens: maxOutputTokens,
    concurrency: concurrency,
    timeoutMs: timeoutMs,
    judgeMode: judgeMode
  };
}

// ============ 测试 ============

export function appSettingsTest(): void {
  describe('AppSettingsService', () => {
    let preferences: StubPreferences;
    let logger: StubLogger;
    let svc: AppSettingsService;
    let hasRunning: boolean = false;
    let clearRunRecordsCalled: boolean = false;
    let clearDatasetsCalled: boolean = false;

    function setup(): void {
      preferences = new StubPreferences();
      logger = new StubLogger();
      hasRunning = false;
      clearRunRecordsCalled = false;
      clearDatasetsCalled = false;
      svc = AppSettingsService.createForTest({
        preferences: preferences,
        logger: logger,
        hasRunningTaskProvider: (): boolean => { return hasRunning; },
        clearRunRecordsProvider: async (): Promise<void> => { clearRunRecordsCalled = true; },
        clearDatasetsProvider: async (): Promise<void> => { clearDatasetsCalled = true; }
      });
    }

    it('getSettings：首次无值返回默认值', 0, async () => {
      setup();
      const s: AppSettings = await svc.getSettings();
      expect(s.defaultParams.temperature).assertEqual(0.7);
      expect(s.defaultParams.maxOutputTokens).assertEqual(2048);
      expect(s.defaultParams.concurrency).assertEqual(1);
      expect(s.defaultParams.timeoutMs).assertEqual(60000);
      expect(s.defaultParams.judgeMode).assertEqual(JudgeMode.CONTAINS);
      expect(s.notificationEnabled).assertTrue();
      expect(s.recordLimit).assertEqual(DEFAULT_RECORD_LIMIT);
    });

    it('getSettings：已保存值正确读取', 0, async () => {
      setup();
      const params: RunParameters = makeParams(1.0, 4096, 2, 120000, JudgeMode.EXACT_MATCH);
      await preferences.putString('default_params', JSON.stringify(params));
      await preferences.putBoolean('notification_enabled', false);
      await preferences.putNumber('record_limit', 500);

      const s: AppSettings = await svc.getSettings();
      expect(s.defaultParams.temperature).assertEqual(1.0);
      expect(s.defaultParams.maxOutputTokens).assertEqual(4096);
      expect(s.defaultParams.concurrency).assertEqual(2);
      expect(s.defaultParams.timeoutMs).assertEqual(120000);
      expect(s.defaultParams.judgeMode).assertEqual(JudgeMode.EXACT_MATCH);
      expect(s.notificationEnabled).assertFalse();
      expect(s.recordLimit).assertEqual(500);
    });

    it('updateDefaultParams：合法参数保存成功', 0, async () => {
      setup();
      const params: RunParameters = makeParams(0.5, 1024, 1, 30000, JudgeMode.CONTAINS);
      await svc.updateDefaultParams(params);

      const s: AppSettings = await svc.getSettings();
      expect(s.defaultParams.temperature).assertEqual(0.5);
      expect(s.defaultParams.maxOutputTokens).assertEqual(1024);
    });

    it('updateDefaultParams：温度越界抛 TASK_PARAM_OUT_OF_RANGE', 0, async () => {
      setup();
      const params: RunParameters = makeParams(3.0, 1024, 1, 30000, JudgeMode.CONTAINS);
      try {
        await svc.updateDefaultParams(params);
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.TASK_PARAM_OUT_OF_RANGE);
      }
    });

    it('updateDefaultParams：并发数越界抛 TASK_PARAM_OUT_OF_RANGE', 0, async () => {
      setup();
      const params: RunParameters = makeParams(0.7, 2048, 5, 60000, JudgeMode.CONTAINS);
      try {
        await svc.updateDefaultParams(params);
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.TASK_PARAM_OUT_OF_RANGE);
      }
    });

    it('updateDefaultParams：保存失败回滚为原设置', 0, async () => {
      setup();
      const failingPrefs: FailingPreferences = new FailingPreferences();
      const originalParams: RunParameters = makeParams(0.7, 2048, 1, 60000, JudgeMode.CONTAINS);
      await failingPrefs.putString('default_params', JSON.stringify(originalParams));

      const svc2: AppSettingsService = AppSettingsService.createForTest({
        preferences: failingPrefs,
        logger: logger,
        hasRunningTaskProvider: (): boolean => { return false; },
        clearRunRecordsProvider: async (): Promise<void> => {},
        clearDatasetsProvider: async (): Promise<void> => {}
      });

      failingPrefs.setFailPutString(true);
      const newParams: RunParameters = makeParams(1.0, 4096, 2, 120000, JudgeMode.EXACT_MATCH);
      try {
        await svc2.updateDefaultParams(newParams);
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.SETTINGS_BUSY_TASK_RUNNING);
      }

      // 验证回滚：原值应保持不变
      failingPrefs.setFailPutString(false);
      const s: AppSettings = await svc2.getSettings();
      expect(s.defaultParams.temperature).assertEqual(0.7);
      expect(s.defaultParams.maxOutputTokens).assertEqual(2048);
    });

    it('setNotificationEnabled：关闭后读取为 false', 0, async () => {
      setup();
      await svc.setNotificationEnabled(false);
      const enabled: boolean = await svc.isNotificationEnabled();
      expect(enabled).assertFalse();
    });

    it('setNotificationEnabled：开启后读取为 true', 0, async () => {
      setup();
      await svc.setNotificationEnabled(false);
      await svc.setNotificationEnabled(true);
      const enabled: boolean = await svc.isNotificationEnabled();
      expect(enabled).assertTrue();
    });

    it('isNotificationEnabled：首次默认为 true', 0, async () => {
      setup();
      const enabled: boolean = await svc.isNotificationEnabled();
      expect(enabled).assertTrue();
    });

    it('clearLocalData：无运行中任务时成功清除', 0, async () => {
      setup();
      hasRunning = false;
      await svc.clearLocalData();
      expect(clearRunRecordsCalled).assertTrue();
      expect(clearDatasetsCalled).assertTrue();
    });

    it('clearLocalData：有运行中任务时抛 SETTINGS_BUSY_TASK_RUNNING', 0, async () => {
      setup();
      hasRunning = true;
      try {
        await svc.clearLocalData();
        expect(true).assertFalse();
      } catch (e) {
        const err: AppError = e as AppError;
        expect(err.code).assertEqual(ErrorCode.SETTINGS_BUSY_TASK_RUNNING);
      }
      expect(clearRunRecordsCalled).assertFalse();
      expect(clearDatasetsCalled).assertFalse();
    });
  });
}