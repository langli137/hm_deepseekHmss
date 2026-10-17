/**
 * 模型服务配置编辑页（tasks.md 3.7）。
 * - 表单项：服务地址、身份密钥（掩码输入）、目标模型、设为默认；
 * - 「测试连接」按钮展示成功/失败原因（spec 5.1.2）；
 * - 密钥查看与清除均二次确认（spec 4.3.2、4.3.3）；
 * - 保存前完成必填/格式校验并加密落盘（spec 5.1.1）。
 */
import router from '@ohos.router';
import { ServiceConfigService } from '../biz/serviceconfig/ServiceConfigService';
import { ServiceConfigDraft, ConnectionTestResult, ModelServiceConfig } from '../common/types/DomainTypes';
import { asAppError } from '../common/error/AppError';
import { ErrorCode } from '../common/error/ErrorCode';

interface ServiceConfigEditParams {
  configId?: string;
}

@Entry
@Component
struct ServiceConfigEditPage {
  @State configId: string = '';
  @State name: string = '';
  @State endpoint: string = '';
  @State targetModel: string = '';
  @State secret: string = '';
  @State isDefault: boolean = false;
  @State revealedSecret: string = '';
  @State tip: string = '';
  private service: ServiceConfigService = ServiceConfigService.getInstance();

  aboutToAppear(): void {
    const raw: Object = router.getParams();
    if (raw !== undefined && raw !== null) {
      const params: ServiceConfigEditParams = raw as ServiceConfigEditParams;
      if (params.configId !== undefined && params.configId.length > 0) {
        this.configId = params.configId;
        this.loadExisting(params.configId);
      }
    }
  }

  private loadExisting(configId: string): void {
    this.service.getConfig(configId).then((config: ModelServiceConfig): void => {
      this.name = config.name;
      this.endpoint = config.endpoint;
      this.targetModel = config.targetModel;
      this.isDefault = config.isDefault;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.CFG_MISSING_FIELD).userMessage();
    });
  }

  private buildDraft(): ServiceConfigDraft {
    const draft: ServiceConfigDraft = {
      name: this.name,
      endpoint: this.endpoint,
      targetModel: this.targetModel,
      secret: this.secret,
      isDefault: this.isDefault
    };
    if (this.configId.length > 0) {
      draft.configId = this.configId;
    }
    return draft;
  }

  private testConnection(): void {
    this.tip = '正在测试连接...';
    this.service.testConnection(this.buildDraft()).then((result: ConnectionTestResult): void => {
      this.tip = result.success ? '连接成功' : `连接失败：${result.reason}`;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.CFG_CONNECT_FAILED).userMessage();
    });
  }

  private save(): void {
    this.service.saveConfig(this.buildDraft()).then((): void => {
      this.tip = '保存成功';
      router.back();
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.CFG_MISSING_FIELD).userMessage();
    });
  }

  private confirmReveal(): void {
    if (this.configId.length === 0) {
      this.tip = '请先保存配置后再查看密钥';
      return;
    }
    AlertDialog.show({
      title: '查看密钥',
      message: '查看密钥明文属于敏感操作，确认继续？',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '确认查看',
        action: (): void => {
          this.revealSecret();
        }
      }
    });
  }

  private revealSecret(): void {
    this.service.revealSecret(this.configId).then((plain: string): void => {
      this.revealedSecret = plain;
      this.tip = '已显示密钥明文，请勿泄露';
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.CFG_SECRET_INVALID).userMessage();
    });
  }

  private confirmClearSecret(): void {
    AlertDialog.show({
      title: '清除密钥',
      message: '清除后需重新输入密钥方可保存配置，确认继续？',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '确认清除',
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.secret = '';
          this.revealedSecret = '';
          this.tip = '已清除密钥输入';
        }
      }
    });
  }

  @Builder
  fieldLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ top: 8 })
  }

  build() {
    Scroll() {
      Column({ space: 8 }) {
        Text(this.configId.length > 0 ? '编辑模型服务配置' : '新增模型服务配置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        this.fieldLabel('配置名称')
        TextInput({ text: this.name, placeholder: '长度 1~50，应用内唯一' })
          .onChange((value: string): void => {
            this.name = value;
          })

        this.fieldLabel('服务地址')
        TextInput({ text: this.endpoint, placeholder: '以 http:// 或 https:// 开头' })
          .onChange((value: string): void => {
            this.endpoint = value;
          })

        this.fieldLabel('身份密钥')
        TextInput({ text: this.secret, placeholder: '必填，保存前加密' })
          .type(InputType.Password)
          .onChange((value: string): void => {
            this.secret = value;
          })
        Row({ space: 8 }) {
          Button('查看密钥')
            .fontSize(13)
            .height(34)
            .onClick((): void => {
              this.confirmReveal();
            })
          Button('清除密钥')
            .fontSize(13)
            .height(34)
            .backgroundColor($r('app.color.status_error'))
            .onClick((): void => {
              this.confirmClearSecret();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)

        if (this.revealedSecret.length > 0) {
          Text(`当前密钥：${this.revealedSecret}`)
            .fontSize(13)
            .fontColor($r('app.color.status_warning'))
            .width('100%')
        }

        this.fieldLabel('目标模型名称')
        TextInput({ text: this.targetModel, placeholder: '长度 1~100' })
          .onChange((value: string): void => {
            this.targetModel = value;
          })

        Row({ space: 8 }) {
          Text('设为默认服务')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.isDefault })
            .onChange((value: boolean): void => {
              this.isDefault = value;
            })
        }
        .width('100%')
        .margin({ top: 8 })

        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(13)
            .fontColor($r('app.color.status_warning'))
            .width('100%')
            .margin({ top: 4 })
        }

        Row({ space: 10 }) {
          Button('测试连接')
            .layoutWeight(1)
            .height(44)
            .onClick((): void => {
              this.testConnection();
            })
          Button('保存')
            .layoutWeight(1)
            .height(44)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => {
              this.save();
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}