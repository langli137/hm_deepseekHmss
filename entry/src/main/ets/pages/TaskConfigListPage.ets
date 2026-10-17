/**
 * 评测任务配置列表页（tasks.md 4.7）。
 * - 展示任务列表与状态标签、题目数与目标模型；
 * - 提供新建与编辑入口；运行中任务编辑项置灰（spec 5.3.1-8）；
 * - 对不可启动任务给出原因提示（tasks.md 4.6）；
 * - 删除操作二次确认。
 */
import router from '@ohos.router';
import { TaskConfigService } from '../biz/taskconfig/TaskConfigService';
import { taskCanEdit, taskCanStart } from '../biz/taskconfig/TaskModel';
import { EvaluationTask } from '../common/types/DomainTypes';
import { TaskStatus } from '../common/types/Enums';
import { asAppError } from '../common/error/AppError';
import { ErrorCode } from '../common/error/ErrorCode';

function statusLabel(status: TaskStatus): string {
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
      return '未知';
  }
}

@Entry
@Component
struct TaskConfigListPage {
  @State tasks: EvaluationTask[] = [];
  @State loading: boolean = true;
  @State tip: string = '';
  private service: TaskConfigService = TaskConfigService.getInstance();

  private statusColor(status: TaskStatus): Resource {
    if (status === TaskStatus.RUNNING) {
      return $r('app.color.status_warning');
    }
    if (status === TaskStatus.FAILED || status === TaskStatus.TERMINATED) {
      return $r('app.color.status_error');
    }
    if (status === TaskStatus.COMPLETED) {
      return $r('app.color.status_success');
    }
    return $r('app.color.text_secondary');
  }

  onPageShow(): void {
    this.reload();
  }

  private reload(): void {
    this.loading = true;
    this.service.listTasks().then((list: EvaluationTask[]): void => {
      this.tasks = list;
      this.loading = false;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.TASK_INCOMPLETE_CONFIG).userMessage();
      this.loading = false;
    });
  }

  private openCreate(): void {
    router.pushUrl({ url: 'pages/TaskConfigEditPage' }).catch((): void => {
      this.tip = '页面未注册，无法打开编辑页';
    });
  }

  private openEdit(task: EvaluationTask): void {
    router.pushUrl({
      url: 'pages/TaskConfigEditPage',
      params: { taskId: task.taskId }
    }).catch((): void => {
      this.tip = '页面未注册，无法打开编辑页';
    });
  }

  private confirmRemove(task: EvaluationTask): void {
    AlertDialog.show({
      title: '删除确认',
      message: `确定删除任务「${task.name}」？该操作不可恢复。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.remove(task.taskId);
        }
      }
    });
  }

  private remove(taskId: string): void {
    this.service.removeTask(taskId).then((): void => {
      this.tip = '删除成功';
      this.reload();
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.TASK_ALREADY_RUNNING).userMessage();
    });
  }

  private startHint(task: EvaluationTask): void {
    if (taskCanStart(task)) {
      this.tip = '任务可启动，请前往任务执行页运行';
    } else {
      this.tip = '任务不可启动：题目集无可用题目或任务非待运行状态';
    }
  }

  @Builder
  taskCard(task: EvaluationTask) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(task.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(statusLabel(task.status))
          .fontSize(11)
          .fontColor(this.statusColor(task.status))
      }
      .width('100%')

      Text(`目标模型：${task.snapshot === undefined ? '-' : task.snapshot.targetModel}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(`题目数：${task.dataset === undefined ? 0 : task.dataset.cases.length}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(`可启动：${taskCanStart(task) ? '是' : '否'}`)
        .fontSize(13)
        .fontColor(taskCanStart(task) ? $r('app.color.status_success') : $r('app.color.status_warning'))
        .width('100%')

      Row({ space: 8 }) {
        Button('编辑')
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.brand_primary'))
          .enabled(taskCanEdit(task))
          .onClick((): void => {
            this.openEdit(task);
          })
        Button('启动')
          .fontSize(13)
          .height(34)
          .enabled(taskCanStart(task))
          .onClick((): void => {
            this.startHint(task);
          })
        Button('删除')
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.status_error'))
          .enabled(taskCanEdit(task))
          .onClick((): void => {
            this.confirmRemove(task);
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
      Text('评测任务配置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.loading) {
        Text('加载中...')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 24 })
      } else if (this.tasks.length === 0) {
        Text('暂无评测任务，请点击下方「新建任务」')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 24 })
      } else {
        List({ space: 10 }) {
          ForEach(this.tasks, (task: EvaluationTask) => {
            ListItem() {
              this.taskCard(task)
            }
          }, (task: EvaluationTask) => task.taskId)
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

      Button('新建任务')
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