/**
 * 评测任务配置编辑页（tasks.md 4.7）。
 * - 表单项：任务名称、目标模型（选择关联模型服务配置，默认选中默认服务）、
 *   题目集导入（展示题目数量与校验结果，spec 5.2.2）、执行参数（含控件级范围提示）；
 * - 任务处于 RUNNING 时全部配置项不可编辑（spec 5.3.1-8）。
 */
import router from '@ohos.router';
import { TaskConfigService } from '../biz/taskconfig/TaskConfigService';
import { taskCanEdit } from '../biz/taskconfig/TaskModel';
import { ServiceConfigService } from '../biz/serviceconfig/ServiceConfigService';
import {
  DatasetValidationReport, EvaluationTask, ModelServiceConfig, RunParameters, TaskConfigDraft
} from '../common/types/DomainTypes';
import { JudgeMode } from '../common/types/Enums';
import { asAppError } from '../common/error/AppError';
import { ErrorCode } from '../common/error/ErrorCode';

interface TaskEditParams {
  taskId?: string;
}

function toNum(text: string, fallback: number): number {
  const value: number = Number.parseFloat(text);
  return Number.isNaN(value) ? fallback : value;
}

function judgeModeLabel(mode: JudgeMode): string {
  switch (mode) {
    case JudgeMode.EXACT_MATCH:
      return '精确匹配';
    case JudgeMode.CONTAINS:
      return '包含匹配';
    case JudgeMode.REFEREE_MODEL:
      return '裁判模型';
    default:
      return '包含匹配';
  }
}

@Entry
@Component
struct TaskConfigEditPage {
  @State taskId: string = '';
  @State editable: boolean = true;
  @State name: string = '';
  @State configs: ModelServiceConfig[] = [];
  @State configId: string = '';
  @State datasetUri: string = '';
  @State datasetName: string = '';
  @State datasetTotal: number = 0;
  @State datasetValid: number = 0;
  @State temperature: string = '0.7';
  @State maxOutputTokens: string = '2048';
  @State concurrency: string = '1';
  @State timeoutMs: string = '60000';
  @State judgeMode: JudgeMode = JudgeMode.CONTAINS;
  @State loading: boolean = true;
  @State tip: string = '';

  private service: TaskConfigService = TaskConfigService.getInstance();
  private configService: ServiceConfigService = ServiceConfigService.getInstance();
  private judgeModes: JudgeMode[] = [JudgeMode.EXACT_MATCH, JudgeMode.CONTAINS, JudgeMode.REFEREE_MODEL];

  aboutToAppear(): void {
    const raw: Object = router.getParams();
    if (raw !== undefined && raw !== null) {
      const params: TaskEditParams = raw as TaskEditParams;
      if (params.taskId !== undefined && params.taskId.length > 0) {
        this.taskId = params.taskId;
      }
    }
    this.loadConfigs();
    if (this.taskId.length > 0) {
      this.loadTask(this.taskId);
    } else {
      this.prefillDefaultParams();
    }
  }

  private loadConfigs(): void {
    this.configService.listConfigs().then((list: ModelServiceConfig[]): void => {
      this.configs = list;
      if (this.taskId.length === 0 && this.configId.length === 0) {
        for (let i = 0; i < list.length; i++) {
          if (list[i].isDefault) {
            this.configId = list[i].configId;
            break;
          }
        }
      }
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.CFG_MISSING_FIELD).userMessage();
    });
  }

  private prefillDefaultParams(): void {
    this.service.getDefaultParams().then((params: RunParameters): void => {
      this.temperature = `${params.temperature}`;
      this.maxOutputTokens = `${params.maxOutputTokens}`;
      this.concurrency = `${params.concurrency}`;
      this.timeoutMs = `${params.timeoutMs}`;
      this.judgeMode = params.judgeMode;
      this.loading = false;
    }).catch((e: Object): void => {
      this.loading = false;
    });
  }

  private loadTask(taskId: string): void {
    this.service.getTask(taskId).then((task: EvaluationTask): void => {
      this.editable = taskCanEdit(task);
      this.name = task.name;
      this.configId = task.configId;
      this.datasetUri = task.datasetUri;
      if (task.dataset !== undefined) {
        this.datasetName = task.dataset.name;
        this.datasetValid = task.dataset.cases.length;
        this.datasetTotal = task.dataset.cases.length;
      }
      this.temperature = `${task.params.temperature}`;
      this.maxOutputTokens = `${task.params.maxOutputTokens}`;
      this.concurrency = `${task.params.concurrency}`;
      this.timeoutMs = `${task.params.timeoutMs}`;
      this.judgeMode = task.params.judgeMode;
      this.loading = false;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.TASK_INCOMPLETE_CONFIG).userMessage();
      this.loading = false;
    });
  }

  private importDataset(): void {
    this.tip = '正在读取题目集...';
    this.service.importDataset().then((report: DatasetValidationReport): void => {
      this.datasetUri = report.fileUri;
      this.datasetName = report.fileName;
      this.datasetTotal = report.totalCount;
      this.datasetValid = report.validCount;
      this.tip = `导入成功：共 ${report.totalCount} 题，可用 ${report.validCount} 题`;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.DS_PARSE_FAILED).userMessage();
    });
  }

  private buildDraft(): TaskConfigDraft {
    const params: RunParameters = {
      temperature: toNum(this.temperature, 0.7),
      maxOutputTokens: toNum(this.maxOutputTokens, 2048),
      concurrency: toNum(this.concurrency, 1),
      timeoutMs: toNum(this.timeoutMs, 60000),
      judgeMode: this.judgeMode
    };
    return {
      name: this.name,
      configId: this.configId,
      datasetUri: this.datasetUri,
      params: params
    };
  }

  private save(): void {
    if (this.name.trim().length === 0) {
      this.tip = '请填写任务名称';
      return;
    }
    if (this.configId.length === 0) {
      this.tip = '请选择关联模型服务配置';
      return;
    }
    if (this.datasetUri.length === 0) {
      this.tip = '请先导入题目集';
      return;
    }
    this.tip = '正在保存...';
    if (this.taskId.length > 0) {
      this.service.updateTask(this.taskId, this.buildDraft()).then((): void => {
        this.tip = '保存成功';
        router.back();
      }).catch((e: Object): void => {
        this.tip = asAppError(e, ErrorCode.TASK_INCOMPLETE_CONFIG).userMessage();
      });
    } else {
      this.service.createTask(this.buildDraft()).then((): void => {
        this.tip = '保存成功';
        router.back();
      }).catch((e: Object): void => {
        this.tip = asAppError(e, ErrorCode.TASK_INCOMPLETE_CONFIG).userMessage();
      });
    }
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
        Text(this.taskId.length > 0 ? '编辑评测任务' : '新建评测任务')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        if (!this.editable) {
          Text('任务运行中，配置不可编辑')
            .fontSize(13)
            .fontColor($r('app.color.status_warning'))
            .width('100%')
            .margin({ top: 4 })
        }

        this.fieldLabel('任务名称')
        TextInput({ text: this.name, placeholder: '长度 1~50，应用内唯一' })
          .enabled(this.editable)
          .onChange((value: string): void => {
            this.name = value;
          })

        this.fieldLabel('关联模型服务配置（目标模型由配置决定）')
        if (this.configs.length === 0) {
          Text('暂无模型服务配置，请先在「模型服务配置」中创建')
            .fontSize(13)
            .fontColor($r('app.color.status_warning'))
            .width('100%')
        } else {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.configs, (config: ModelServiceConfig) => {
              Button(`${config.name}${config.isDefault ? '（默认）' : ''}`)
                .fontSize(12)
                .height(32)
                .margin({ right: 8, bottom: 8 })
                .backgroundColor(this.configId === config.configId
                  ? $r('app.color.brand_primary') : $r('app.color.card_background'))
                .fontColor(this.configId === config.configId
                  ? $r('app.color.brand_on_primary') : $r('app.color.text_primary'))
                .enabled(this.editable)
                .onClick((): void => {
                  this.configId = config.configId;
                })
            }, (config: ModelServiceConfig) => config.configId)
          }
          .width('100%')
        }

        this.fieldLabel('题目集')
        Row({ space: 8 }) {
          Button('导入题目集')
            .fontSize(13)
            .height(34)
            .enabled(this.editable)
            .onClick((): void => {
              this.importDataset();
            })
          Text(this.datasetUri.length > 0
            ? `已导入：${this.datasetName}（可用 ${this.datasetValid}/${this.datasetTotal} 题）`
            : '未导入')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')

        this.fieldLabel('温度 temperature（0.0~2.0）')
        TextInput({ text: this.temperature, placeholder: '0.0~2.0' })
          .type(InputType.Number)
          .enabled(this.editable)
          .onChange((value: string): void => {
            this.temperature = value;
          })

        this.fieldLabel('最大输出长度 maxOutputTokens（1~8192）')
        TextInput({ text: this.maxOutputTokens, placeholder: '1~8192' })
          .type(InputType.Number)
          .enabled(this.editable)
          .onChange((value: string): void => {
            this.maxOutputTokens = value;
          })

        this.fieldLabel('并发数 concurrency（1~4）')
        TextInput({ text: this.concurrency, placeholder: '1~4' })
          .type(InputType.Number)
          .enabled(this.editable)
          .onChange((value: string): void => {
            this.concurrency = value;
          })

        this.fieldLabel('超时时间 timeoutMs（1000~300000 毫秒）')
        TextInput({ text: this.timeoutMs, placeholder: '1000~300000' })
          .type(InputType.Number)
          .enabled(this.editable)
          .onChange((value: string): void => {
            this.timeoutMs = value;
          })

        this.fieldLabel('判定方式')
        Row({ space: 8 }) {
          ForEach(this.judgeModes, (mode: JudgeMode) => {
            Button(judgeModeLabel(mode))
              .fontSize(12)
              .height(32)
              .backgroundColor(this.judgeMode === mode
                ? $r('app.color.brand_primary') : $r('app.color.card_background'))
              .fontColor(this.judgeMode === mode
                ? $r('app.color.brand_on_primary') : $r('app.color.text_primary'))
              .enabled(this.editable)
              .onClick((): void => {
                this.judgeMode = mode;
              })
          }, (mode: JudgeMode): string => `${mode}`)
        }
        .width('100%')

        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(13)
            .fontColor($r('app.color.status_warning'))
            .width('100%')
            .margin({ top: 4 })
        }

        Button('保存')
          .width('100%')
          .height(44)
          .margin({ top: 12 })
          .backgroundColor($r('app.color.brand_primary'))
          .enabled(this.editable)
          .onClick((): void => {
            this.save();
          })
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