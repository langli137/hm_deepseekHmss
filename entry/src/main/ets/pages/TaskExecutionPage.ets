/**
 * 任务执行页面（spec 5.3，tasks.md 5.11）。
 * 展示整体进度（已完成/总数）、当前用例流式输出与状态标签；
 * 提供启动、暂停、继续、终止四个操作按钮，按状态机合法迁移动态启用。
 */
import router from '@ohos.router';
import { ExecutionService } from '../biz/execution/ExecutionService';
import { TaskConfigService } from '../biz/taskconfig/TaskConfigService';
import {
  CaseResult, EvaluationTask, ExecutionObserver, ExecutionProgress
} from '../common/types/DomainTypes';
import { ExecutionFlag, InterruptReason, TaskStatus } from '../common/types/Enums';
import { Unsubscribe } from '../common/types/InfraTypes';

@Entry
@Component
struct TaskExecutionPage {
  @State currentTask: EvaluationTask | null = null;
  @State progress: ExecutionProgress = {
    taskId: '',
    status: TaskStatus.PENDING,
    flag: ExecutionFlag.EXECUTING,
    completedCount: 0,
    totalCount: 0,
    watermarkSeq: -1,
    streamingText: ''
  };
  @State interruptMessage: string = '';
  @State isStarting: boolean = false;
  @State taskList: EvaluationTask[] = [];

  private executionService: ExecutionService = ExecutionService.getInstance();
  private taskConfigService: TaskConfigService = TaskConfigService.getInstance();
  private unsub: Unsubscribe | null = null;

  aboutToAppear(): void {
    this.loadTasks();
  }

  aboutToDisappear(): void {
    if (this.unsub !== null) {
      this.unsub();
      this.unsub = null;
    }
  }

  private async loadTasks(): Promise<void> {
    this.taskList = await this.taskConfigService.listTasks();
  }

  private subscribeTask(taskId: string): void {
    if (this.unsub !== null) {
      this.unsub();
    }
    const observer: ExecutionObserver = {
      onProgress: (p: ExecutionProgress): void => {
        this.progress = p;
      },
      onCaseFinished: (result: CaseResult): void => {
        // 用例完成时刷新进度（已在 onProgress 中更新）
      },
      onFinished: (recordId: string): void => {
        this.loadTasks();
      },
      onInterrupted: (reason: InterruptReason): void => {
        switch (reason) {
          case InterruptReason.NETWORK_LOST:
            this.interruptMessage = '网络中断，任务已暂停，可稍后继续';
            break;
          case InterruptReason.USER_PAUSED:
            this.interruptMessage = '任务已暂停';
            break;
          case InterruptReason.RATE_LIMITED:
            this.interruptMessage = '服务繁忙，任务已暂停，可稍后继续';
            break;
          default:
            this.interruptMessage = '任务已中断';
            break;
        }
      }
    } as ExecutionObserver;
    this.unsub = this.executionService.subscribe(taskId, observer);
    this.progress = this.executionService.getProgress(taskId);
  }

  private canStart(): boolean {
    return this.currentTask !== null
      && this.currentTask.status === TaskStatus.PENDING
      && !this.executionService.hasRunningTask();
  }

  private canPause(): boolean {
    return this.progress.status === TaskStatus.RUNNING
      && this.progress.flag === ExecutionFlag.EXECUTING;
  }

  private canResume(): boolean {
    return this.progress.status === TaskStatus.RUNNING
      && this.progress.flag === ExecutionFlag.PAUSED;
  }

  private canTerminate(): boolean {
    return this.progress.status === TaskStatus.RUNNING;
  }

  private async onStart(): Promise<void> {
    if (this.currentTask === null) {
      return;
    }
    this.isStarting = true;
    this.interruptMessage = '';
    try {
      this.subscribeTask(this.currentTask.taskId);
      await this.executionService.start(this.currentTask.taskId);
    } catch (e) {
      this.interruptMessage = (e as Error).message;
    }
    this.isStarting = false;
  }

  private async onPause(): Promise<void> {
    if (this.currentTask !== null) {
      await this.executionService.pause(this.currentTask.taskId);
    }
  }

  private async onResume(): Promise<void> {
    if (this.currentTask !== null) {
      this.interruptMessage = '';
      try {
        await this.executionService.resume(this.currentTask.taskId);
      } catch (e) {
        this.interruptMessage = (e as Error).message;
      }
    }
  }

  private async onTerminate(): Promise<void> {
    if (this.currentTask !== null) {
      await this.executionService.terminate(this.currentTask.taskId);
    }
  }

  private statusLabel(): string {
    switch (this.progress.status) {
      case TaskStatus.PENDING:
        return '待运行';
      case TaskStatus.RUNNING:
        return this.progress.flag === ExecutionFlag.PAUSED ? '已暂停' : '运行中';
      case TaskStatus.COMPLETED:
        return '已完成';
      case TaskStatus.FAILED:
        return '已失败';
      case TaskStatus.TERMINATED:
        return '已终止';
      default:
        return '';
    }
  }

  build() {
    Column({ space: 12 }) {
      // 标题与返回
      Row() {
        Button('返回')
          .fontSize(14)
          .onClick((): void => {
            router.back();
          })
        Text('任务执行')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })
      }
      .width('100%')

      // 任务选择
      if (this.currentTask === null) {
        Text('请选择评测任务')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 20 })

        List({ space: 8 }) {
          ForEach(this.taskList, (task: EvaluationTask) => {
            ListItem() {
              Row() {
                Column() {
                  Text(task.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                  Text(`状态：${this.taskStatusLabel(task.status)}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)

                Blank()

                Button('选择')
                  .fontSize(14)
                  .onClick((): void => {
                    this.currentTask = task;
                    this.progress = this.executionService.getProgress(task.taskId);
                    this.subscribeTask(task.taskId);
                  })
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.card_background'))
              .borderRadius($r('app.float.radius_card'))
            }
          }, (task: EvaluationTask) => task.taskId)
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        // 任务信息
        Column({ space: 8 }) {
          Text(this.currentTask.name)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)

          Row() {
            Text(`状态：${this.statusLabel()}`)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text(`${this.progress.completedCount} / ${this.progress.totalCount}`)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')

          // 进度条
          Progress({ value: this.progress.completedCount, total: this.progress.totalCount, type: ProgressType.Linear })
            .width('100%')
            .color($r('app.color.brand_primary'))
        }
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius($r('app.float.radius_card'))

        // 流式输出区域
        if (this.progress.streamingText.length > 0) {
          Column() {
            Text('当前用例输出')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 4 })
            Scroll() {
              Text(this.progress.streamingText)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            .height(200)
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.radius_card'))
        }

        // 中断提示
        if (this.interruptMessage.length > 0) {
          Text(this.interruptMessage)
            .fontSize(14)
            .fontColor($r('app.color.status_warning'))
            .padding(8)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(8)
        }

        // 操作按钮
        Row({ space: 8 }) {
          Button('启动')
            .enabled(this.canStart() && !this.isStarting)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => { this.onStart(); })
            .layoutWeight(1)

          Button('暂停')
            .enabled(this.canPause())
            .backgroundColor($r('app.color.status_warning'))
            .onClick((): void => { this.onPause(); })
            .layoutWeight(1)

          Button('继续')
            .enabled(this.canResume())
            .backgroundColor($r('app.color.status_success'))
            .onClick((): void => { this.onResume(); })
            .layoutWeight(1)

          Button('终止')
            .enabled(this.canTerminate())
            .backgroundColor($r('app.color.status_error'))
            .onClick((): void => { this.onTerminate(); })
            .layoutWeight(1)
        }
        .width('100%')

        // 切换任务按钮
        Button('切换任务')
          .fontSize(14)
          .onClick((): void => {
            if (this.unsub !== null) {
              this.unsub();
              this.unsub = null;
            }
            this.currentTask = null;
            this.loadTasks();
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('app.color.page_background'))
  }

  private taskStatusLabel(status: TaskStatus): string {
    switch (status) {
      case TaskStatus.PENDING:
        return '待运行';
      case TaskStatus.RUNNING:
        return '运行中';
      case TaskStatus.COMPLETED:
        return '已完成';
      case TaskStatus.FAILED:
        return '已失败';
      case TaskStatus.TERMINATED:
        return '已终止';
      default:
        return '';
    }
  }
}