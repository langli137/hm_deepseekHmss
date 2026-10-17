/**
 * 应用级服务容器（AbilityStage 级单例）。tasks.md 1.3 的关键依赖：
 * 统一提供「运行环境切换 + 9 个基础设施端口」的获取入口。
 * - PROD：返回真实系统能力适配器；
 * - DEV / TEST：返回 infra/stubs 下的内存测试桩（缓解 R2：无真机）。
 * 注意：业务服务（ServiceConfigService 等）由后续任务注册，本容器不承载业务实现。
 */
import common from '@ohos.app.ability.common';
import { RelationalStorePort } from '../infra/ports/RelationalStorePort';
import { PreferencesPort } from '../infra/ports/PreferencesPort';
import { CryptoPort } from '../infra/ports/CryptoPort';
import { ModelClientPort } from '../infra/ports/ModelClientPort';
import { NotificationPort } from '../infra/ports/NotificationPort';
import { BackgroundTaskPort } from '../infra/ports/BackgroundTaskPort';
import { FilePort } from '../infra/ports/FilePort';
import { NetworkMonitorPort } from '../infra/ports/NetworkMonitorPort';
import { LoggerPort } from '../infra/ports/LoggerPort';
import { RelationalStoreAdapter } from '../infra/adapters/RelationalStoreAdapter';
import { PreferencesAdapter } from '../infra/adapters/PreferencesAdapter';
import { CryptoAdapter } from '../infra/adapters/CryptoAdapter';
import { HttpModelClientAdapter } from '../infra/adapters/HttpModelClientAdapter';
import { NotificationAdapter } from '../infra/adapters/NotificationAdapter';
import { BackgroundTaskAdapter } from '../infra/adapters/BackgroundTaskAdapter';
import { FileAdapter } from '../infra/adapters/FileAdapter';
import { NetworkMonitorAdapter } from '../infra/adapters/NetworkMonitorAdapter';
import { LoggerAdapter } from '../infra/adapters/LoggerAdapter';
import { Redactor } from '../infra/adapters/Redactor';
import { StubStore } from '../infra/stubs/StubStore';
import { StubPreferences } from '../infra/stubs/StubPreferences';
import { StubCrypto } from '../infra/stubs/StubCrypto';
import { StubModelClient } from '../infra/stubs/StubModelClient';
import { StubNotification } from '../infra/stubs/StubNotification';
import { StubBackgroundTask } from '../infra/stubs/StubBackgroundTask';
import { StubFile } from '../infra/stubs/StubFile';
import { StubNetwork } from '../infra/stubs/StubNetwork';
import { StubLogger } from '../infra/stubs/StubLogger';
import { AppError } from '../common/error/AppError';
import { ErrorCode } from '../common/error/ErrorCode';

export enum RuntimeEnv {
  DEV = 'DEV',
  TEST = 'TEST',
  PROD = 'PROD'
}

export class AppContainer {
  private static instance: AppContainer | null = null;
  private static appContext: common.UIAbilityContext | null = null;

  private env: RuntimeEnv;
  private redactor: Redactor = new Redactor();
  private storePort: RelationalStorePort | null = null;
  private preferencesPort: PreferencesPort | null = null;
  private cryptoPort: CryptoPort | null = null;
  private modelClientPort: ModelClientPort | null = null;
  private notificationPort: NotificationPort | null = null;
  private backgroundTaskPort: BackgroundTaskPort | null = null;
  private filePort: FilePort | null = null;
  private networkMonitorPort: NetworkMonitorPort | null = null;
  private loggerPort: LoggerPort | null = null;

  private constructor(env: RuntimeEnv) {
    this.env = env;
  }

  /** 由 EntryAbility.onCreate 调用；重复调用仅更新上下文与环境 */
  static init(context: common.UIAbilityContext, env: RuntimeEnv): void {
    AppContainer.appContext = context;
    if (AppContainer.instance === null) {
      AppContainer.instance = new AppContainer(env);
    } else {
      AppContainer.instance.setEnv(env);
    }
  }

  static getInstance(): AppContainer {
    if (AppContainer.instance === null) {
      AppContainer.instance = new AppContainer(RuntimeEnv.PROD);
    }
    return AppContainer.instance;
  }

  /** 切换运行环境；已创建的端口被清空，下次获取按新环境重建 */
  setEnv(env: RuntimeEnv): void {
    if (this.env === env) {
      return;
    }
    this.env = env;
    this.storePort = null;
    this.preferencesPort = null;
    this.cryptoPort = null;
    this.modelClientPort = null;
    this.notificationPort = null;
    this.backgroundTaskPort = null;
    this.filePort = null;
    this.networkMonitorPort = null;
    this.loggerPort = null;
  }

  currentEnv(): RuntimeEnv {
    return this.env;
  }

  private isReal(): boolean {
    return this.env === RuntimeEnv.PROD;
  }

  private requireContext(): common.UIAbilityContext {
    if (AppContainer.appContext === null) {
      throw new AppError(ErrorCode.UNKNOWN_ERROR, 'AppContainer 未初始化，请先调用 AppContainer.init');
    }
    return AppContainer.appContext;
  }

  store(): RelationalStorePort {
    if (this.storePort === null) {
      this.storePort = this.isReal() ? new RelationalStoreAdapter(this.requireContext()) : new StubStore();
    }
    return this.storePort;
  }

  preferences(): PreferencesPort {
    if (this.preferencesPort === null) {
      this.preferencesPort = this.isReal() ? new PreferencesAdapter(this.requireContext()) : new StubPreferences();
    }
    return this.preferencesPort;
  }

  crypto(): CryptoPort {
    if (this.cryptoPort === null) {
      this.cryptoPort = this.isReal() ? new CryptoAdapter(this.requireContext()) : new StubCrypto();
    }
    return this.cryptoPort;
  }

  modelClient(): ModelClientPort {
    if (this.modelClientPort === null) {
      this.modelClientPort = this.isReal() ? new HttpModelClientAdapter() : new StubModelClient();
    }
    return this.modelClientPort;
  }

  notification(): NotificationPort {
    if (this.notificationPort === null) {
      this.notificationPort = this.isReal()
        ? new NotificationAdapter(this.requireContext(), this.redactor)
        : new StubNotification();
    }
    return this.notificationPort;
  }

  backgroundTask(): BackgroundTaskPort {
    if (this.backgroundTaskPort === null) {
      this.backgroundTaskPort = this.isReal()
        ? new BackgroundTaskAdapter(this.requireContext())
        : new StubBackgroundTask();
    }
    return this.backgroundTaskPort;
  }

  file(): FilePort {
    if (this.filePort === null) {
      this.filePort = this.isReal() ? new FileAdapter(this.requireContext()) : new StubFile();
    }
    return this.filePort;
  }

  networkMonitor(): NetworkMonitorPort {
    if (this.networkMonitorPort === null) {
      this.networkMonitorPort = this.isReal()
        ? new NetworkMonitorAdapter(this.requireContext())
        : new StubNetwork();
    }
    return this.networkMonitorPort;
  }

  logger(): LoggerPort {
    if (this.loggerPort === null) {
      this.loggerPort = this.isReal() ? new LoggerAdapter(this.redactor) : new StubLogger();
    }
    return this.loggerPort;
  }
}