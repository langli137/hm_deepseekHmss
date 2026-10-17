/**
 * 应用设置页面（spec 5.6，tasks.md 8.2）。
 * - 默认执行参数编辑区（温度、最大输出长度、并发数、超时时间、判定方式）；
 * - 通知开关；
 * - 数据清理（二次确认，spec 4.3.3）。
 */
import { AppSettingsService } from '../biz/settings/AppSettingsService';
import { AppSettings, RunParameters } from '../common/types/DomainTypes';
import { JudgeMode } from '../common/types/Enums';
import { AppError, asAppError } from '../common/error/AppError';
import { ErrorCode } from '../common/error/ErrorCode';
import {
  CONCURRENCY_MAX, CONCURRENCY_MIN, MAX_OUTPUT_TOKENS_MAX, MAX_OUTPUT_TOKENS_MIN,
  TEMPERATURE_MAX, TEMPERATURE_MIN, TIMEOUT_MS_MAX, TIMEOUT_MS_MIN
} from '../common/types/Constants';

@Entry
@Component
struct AppSettingsPage {
  @State settings: AppSettings | null = null;
  @State loading: boolean = true;
  @State tip: string = '';

  // 默认参数编辑态
  @State temperature: string = '';
  @State maxOutputTokens: string = '';
  @State concurrency: string = '';
  @State timeoutMs: string = '';
  @State judgeMode: JudgeMode = JudgeMode.CONTAINS;

  // 通知开关
  @State notificationEnabled: boolean = true;

  private service: AppSettingsService = AppSettingsService.getInstance();

  onPageShow(): void {
    this.loadSettings();
  }

  private loadSettings(): void {
    this.loading = true;
    this.tip = '';
    this.service.getSettings().then((s: AppSettings): void => {
      this.settings = s;
      this.temperature = s.defaultParams.temperature.toString();
      this.maxOutputTokens = s.defaultParams.maxOutputTokens.toString();
      this.concurrency = s.defaultParams.concurrency.toString();
      this.timeoutMs = s.defaultParams.timeoutMs.toString();
      this.judgeMode = s.defaultParams.judgeMode;
      this.notificationEnabled = s.notificationEnabled;
      this.loading = false;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.SETTINGS_BUSY_TASK_RUNNING).userMessage();
      this.loading = false;
    });
  }

  private buildParams(): RunParameters {
    return {
      temperature: parseFloat(this.temperature),
      maxOutputTokens: parseInt(this.maxOutputTokens, 10),
      concurrency: parseInt(this.concurrency, 10),
      timeoutMs: parseInt(this.timeoutMs, 10),
      judgeMode: this.judgeMode
    };
  }

  private saveParams(): void {
    this.tip = '';
    const params: RunParameters = this.buildParams();
    this.service.updateDefaultParams(params).then((): void => {
      this.tip = '默认参数已保存';
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.TASK_PARAM_OUT_OF_RANGE).userMessage();
    });
  }

  private toggleNotification(enabled: boolean): void {
    this.notificationEnabled = enabled;
    this.service.setNotificationEnabled(enabled).then((): void => {
      this.tip = enabled ? '通知已开启' : '通知已关闭';
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.SETTINGS_BUSY_TASK_RUNNING).userMessage();
      this.notificationEnabled = !enabled;
    });
  }

  private confirmClearData(): void {
    AlertDialog.show({
      title: '数据清理确认',
      message: '将清除全部运行记录与本地题目集，此操作不可恢复。确定继续？',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清除',
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.clearData();
        }
      }
    });
  }

  private clearData(): void {
    this.tip = '';
    this.service.clearLocalData().then((): void => {
      this.tip = '本地数据已清除';
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.SETTINGS_BUSY_TASK_RUNNING).userMessage();
    });
  }

  build() {
    Column({ space: 12 }) {
      Text('应用设置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.loading) {
        Text('加载中...')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 24 })
      } else {
        // 默认执行参数区
        Column({ space: 10 }) {
          Text('默认执行参数')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Row({ space: 8 }) {
            Text('温度')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width(80)
            TextInput({ text: this.temperature, placeholder: `${TEMPERATURE_MIN}~${TEMPERATURE_MAX}` })
              .fontSize(14)
              .type(InputType.Number)
              .layoutWeight(1)
              .onChange((value: string): void => {
                this.temperature = value;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('最大输出长度')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width(80)
            TextInput({ text: this.maxOutputTokens, placeholder: `${MAX_OUTPUT_TOKENS_MIN}~${MAX_OUTPUT_TOKENS_MAX}` })
              .fontSize(14)
              .type(InputType.Number)
              .layoutWeight(1)
              .onChange((value: string): void => {
                this.maxOutputTokens = value;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('并发数')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width(80)
            TextInput({ text: this.concurrency, placeholder: `${CONCURRENCY_MIN}~${CONCURRENCY_MAX}` })
              .fontSize(14)
              .type(InputType.Number)
              .layoutWeight(1)
              .onChange((value: string): void => {
                this.concurrency = value;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('超时(ms)')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width(80)
            TextInput({ text: this.timeoutMs, placeholder: `${TIMEOUT_MS_MIN}~${TIMEOUT_MS_MAX}` })
              .fontSize(14)
              .type(InputType.Number)
              .layoutWeight(1)
              .onChange((value: string): void => {
                this.timeoutMs = value;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('判定方式')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width(80)
            Select([
              { value: '精确匹配' },
              { value: '包含匹配' },
              { value: '裁判模型' }
            ])
              .selected(this.judgeMode === JudgeMode.EXACT_MATCH ? 0 :
                this.judgeMode === JudgeMode.CONTAINS ? 1 : 2)

              .layoutWeight(1)
              .onSelect((index: number): void => {
                if (index === 0) {
                  this.judgeMode = JudgeMode.EXACT_MATCH;
                } else if (index === 1) {
                  this.judgeMode = JudgeMode.CONTAINS;
                } else {
                  this.judgeMode = JudgeMode.REFEREE_MODEL;
                }
              })
          }
          .width('100%')

          Button('保存默认参数')
            .width('100%')
            .height(44)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => {
              this.saveParams();
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(8)

        // 通知开关区
        Column({ space: 10 }) {
          Text('通知设置')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Row({ space: 8 }) {
            Text('任务完成通知')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.notificationEnabled })
              .onChange((isOn: boolean): void => {
                this.toggleNotification(isOn);
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(8)

        // 数据清理区
        Column({ space: 10 }) {
          Text('数据管理')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text('清除全部运行记录与本地题目集。运行中任务时不可执行。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Button('清除本地数据')
            .width('100%')
            .height(44)
            .backgroundColor($r('app.color.status_error'))
            .onClick((): void => {
              this.confirmClearData();
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(8)
      }

      if (this.tip.length > 0) {
        Text(this.tip)
          .fontSize(13)
          .fontColor($r('app.color.status_warning'))
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Start)
  }
}