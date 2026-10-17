/**
 * 模型服务配置列表页（tasks.md 3.7）。
 * - 展示配置列表，标识「默认」与「失效」项；
 * - 密钥默认以掩码呈现（spec 4.3.2）；
 * - 订阅 ServiceConfigService 配置变更事件，变更后自动刷新（tasks.md 3.7）；
 * - 删除操作二次确认（spec 4.3.3）。
 */
import router from '@ohos.router';
import { ServiceConfigService } from '../biz/serviceconfig/ServiceConfigService';
import { SECRET_MASK } from '../biz/serviceconfig/ServiceConfigModel';
import { ConfigStatus } from '../common/types/Enums';
import { ModelServiceConfig } from '../common/types/DomainTypes';
import { Unsubscribe } from '../common/types/InfraTypes';
import { AppError, asAppError } from '../common/error/AppError';
import { ErrorCode } from '../common/error/ErrorCode';

@Entry
@Component
struct ServiceConfigListPage {
  @State configs: ModelServiceConfig[] = [];
  @State loading: boolean = true;
  @State tip: string = '';
  private service: ServiceConfigService = ServiceConfigService.getInstance();
  private unsubscribe: Unsubscribe | null = null;

  aboutToAppear(): void {
    this.unsubscribe = this.service.subscribe((): void => {
      this.reload();
    });
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  private reload(): void {
    this.loading = true;
    this.service.listConfigs().then((list: ModelServiceConfig[]): void => {
      this.configs = list;
      this.loading = false;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.CFG_CONNECT_FAILED).userMessage();
      this.loading = false;
    });
  }

  private openCreate(): void {
    router.pushUrl({ url: 'pages/ServiceConfigEditPage' }).catch((): void => {
      this.tip = '页面未注册，无法打开编辑页';
    });
  }

  private openEdit(config: ModelServiceConfig): void {
    router.pushUrl({
      url: 'pages/ServiceConfigEditPage',
      params: { configId: config.configId }
    }).catch((): void => {
      this.tip = '页面未注册，无法打开编辑页';
    });
  }

  private applyDefault(config: ModelServiceConfig): void {
    this.service.setDefault(config.configId).then((): void => {
      this.tip = '已设为默认配置';
      this.reload();
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.CFG_CONNECT_FAILED).userMessage();
    });
  }

  private confirmRemove(config: ModelServiceConfig): void {
    AlertDialog.show({
      title: '删除确认',
      message: `确定删除配置「${config.name}」？该操作不可恢复。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.remove(config.configId);
        }
      }
    });
  }

  private remove(configId: string): void {
    this.service.removeConfig(configId).then((): void => {
      this.tip = '删除成功';
      this.reload();
    }).catch((e: Object): void => {
      const error: AppError = asAppError(e, ErrorCode.RECORD_BUSY_CANNOT_DELETE);
      this.tip = error.userMessage();
    });
  }

  @Builder
  configCard(config: ModelServiceConfig) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(config.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        if (config.isDefault) {
          Text('默认')
            .fontSize(11)
            .fontColor($r('app.color.brand_on_primary'))
            .backgroundColor($r('app.color.brand_primary'))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        }
        if (config.status === ConfigStatus.INVALID) {
          Text('密钥失效')
            .fontSize(11)
            .fontColor($r('app.color.status_error'))
        }
      }
      .width('100%')

      Text(`服务地址：${config.endpoint}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(`目标模型：${config.targetModel}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(`身份密钥：${SECRET_MASK}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: 8 }) {
        Button('编辑')
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.brand_primary'))
          .onClick((): void => {
            this.openEdit(config);
          })
        Button('设为默认')
          .fontSize(13)
          .height(34)
          .enabled(!config.isDefault)
          .onClick((): void => {
            this.applyDefault(config);
          })
        Button('删除')
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.status_error'))
          .onClick((): void => {
            this.confirmRemove(config);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(8)
  }

  build() {
    Column({ space: 10 }) {
      Text('模型服务配置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.loading) {
        Text('加载中...')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 24 })
      } else if (this.configs.length === 0) {
        Text('暂无模型服务配置，请点击下方「新增配置」')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 24 })
      } else {
        List({ space: 10 }) {
          ForEach(this.configs, (config: ModelServiceConfig) => {
            ListItem() {
              this.configCard(config)
            }
          }, (config: ModelServiceConfig) => config.configId)
        }
        .layoutWeight(1)
        .width('100%')
      }

      if (this.tip.length > 0) {
        Text(this.tip)
          .fontSize(13)
          .fontColor($r('app.color.status_warning'))
          .width('100%')
      }

      Button('新增配置')
        .width('100%')
        .height(44)
        .onClick((): void => {
          this.openCreate();
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Start)
  }
}