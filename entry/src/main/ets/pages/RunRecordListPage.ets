/**
 * 运行记录列表页（tasks.md 7.5）。
 * - 含检索条件输入区（任务名称关键字、目标模型、状态）与记录列表；
 * - 展示任务名、模型、状态、时间、指标摘要；
 * - 实现单条删除与批量选择删除，均触发二次确认对话框（spec 4.3.3）；
 * - 记录异常项展示异常标识与删除入口（spec 5.5.3-1）。
 */
import { RunRecordService } from '../biz/runrecord/RunRecordService';
import { RunRecord, RunRecordQuery } from '../common/types/DomainTypes';
import { RunRecordStatus } from '../common/types/Enums';
import { AppError, asAppError } from '../common/error/AppError';
import { ErrorCode } from '../common/error/ErrorCode';

function statusLabel(status: RunRecordStatus): string {
  switch (status) {
    case RunRecordStatus.COMPLETED:
      return '已完成';
    case RunRecordStatus.FAILED:
      return '已失败';
    case RunRecordStatus.TERMINATED:
      return '已终止';
    default:
      return '未知';
  }
}

function formatTime(ms: number): string {
  if (ms <= 0) {
    return '-';
  }
  const date: Date = new Date(ms);
  const year: number = date.getFullYear();
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  const hour: number = date.getHours();
  const minute: number = date.getMinutes();
  return `${year}-${month < 10 ? '0' + month : month}-${day < 10 ? '0' + day : day} ${hour < 10 ? '0' + hour : hour}:${minute < 10 ? '0' + minute : minute}`;
}

function formatMetric(value: number | null, suffix: string): string {
  if (value === null) {
    return '无有效样本';
  }
  if (suffix === '%') {
    return (value * 100).toFixed(1) + '%';
  }
  return value.toFixed(0) + suffix;
}

@Entry
@Component
struct RunRecordListPage {
  @State records: RunRecord[] = [];
  @State loading: boolean = true;
  @State tip: string = '';
  @State keyword: string = '';
  @State modelFilter: string = '';
  @State statusFilter: RunRecordStatus | null = null;
  @State selectedIds: Set<string> = new Set();
  private service: RunRecordService = RunRecordService.getInstance();

  onPageShow(): void {
    this.reload();
  }

  private reload(): void {
    this.loading = true;
    this.tip = '';
    const query: RunRecordQuery = {};
    if (this.keyword.length > 0) {
      query.nameKeyword = this.keyword;
    }
    if (this.modelFilter.length > 0) {
      query.targetModel = this.modelFilter;
    }
    if (this.statusFilter !== null) {
      query.status = this.statusFilter;
    }
    this.service.listRecords(query).then((list: RunRecord[]): void => {
      this.records = list;
      this.loading = false;
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.RECORD_LIMIT_REACHED).userMessage();
      this.loading = false;
    });
  }

  private toggleSelect(recordId: string): void {
    if (this.selectedIds.has(recordId)) {
      this.selectedIds.delete(recordId);
    } else {
      this.selectedIds.add(recordId);
    }
    // 触发状态刷新
    this.selectedIds = new Set(this.selectedIds);
  }

  private confirmRemoveSingle(record: RunRecord): void {
    AlertDialog.show({
      title: '删除确认',
      message: `确定删除记录「${record.taskName}」？该操作不可恢复。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.removeSingle(record.recordId);
        }
      }
    });
  }

  private confirmRemoveBatch(): void {
    if (this.selectedIds.size === 0) {
      this.tip = '请先选择要删除的记录';
      return;
    }
    AlertDialog.show({
      title: '批量删除确认',
      message: `确定删除选中的 ${this.selectedIds.size} 条记录？该操作不可恢复。`,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.removeBatch();
        }
      }
    });
  }

  private removeSingle(recordId: string): void {
    this.service.removeRecords([recordId]).then((): void => {
      this.tip = '删除成功';
      this.selectedIds.delete(recordId);
      this.reload();
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.RECORD_BUSY_CANNOT_DELETE).userMessage();
    });
  }

  private removeBatch(): void {
    const ids: string[] = Array.from(this.selectedIds);
    this.service.removeRecords(ids).then((): void => {
      this.tip = `成功删除 ${ids.length} 条记录`;
      this.selectedIds = new Set();
      this.reload();
    }).catch((e: Object): void => {
      this.tip = asAppError(e, ErrorCode.RECORD_BUSY_CANNOT_DELETE).userMessage();
    });
  }

  private statusColor(status: RunRecordStatus): Resource {
    if (status === RunRecordStatus.FAILED || status === RunRecordStatus.TERMINATED) {
      return $r('app.color.status_error');
    }
    if (status === RunRecordStatus.COMPLETED) {
      return $r('app.color.status_success');
    }
    return $r('app.color.text_secondary');
  }

  @Builder
  recordCard(record: RunRecord) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Checkbox()
          .select(this.selectedIds.has(record.recordId))
          .onChange((checked: boolean): void => {
            this.toggleSelect(record.recordId);
          })
          .width(20)
          .height(20)
        Text(record.taskName)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(statusLabel(record.status))
          .fontSize(11)
          .fontColor(this.statusColor(record.status))
        if (record.corrupted) {
          Text('记录异常')
            .fontSize(11)
            .fontColor($r('app.color.status_error'))
            .backgroundColor($r('app.color.status_error_bg'))
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
        }
      }
      .width('100%')

      Text(`目标模型：${record.targetModel}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(`开始：${formatTime(record.startedAt)}  结束：${formatTime(record.endedAt)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      if (!record.corrupted && record.metrics.computed) {
        Row({ space: 12 }) {
          Text(`准确率：${formatMetric(record.metrics.accuracy, '%')}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Text(`通过率：${formatMetric(record.metrics.passRate, '%')}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Text(`平均耗时：${formatMetric(record.metrics.avgElapsedMs, 'ms')}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Text(`用量：${record.metrics.usage.totalTokens}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
      }

      Row({ space: 8 }) {
        Button('删除')
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.status_error'))
          .onClick((): void => {
            this.confirmRemoveSingle(record);
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
      Text('运行记录')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      // 检索条件区
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '任务名称关键字' })
            .fontSize(14)
            .layoutWeight(1)
            .onChange((value: string): void => {
              this.keyword = value;
            })
          TextInput({ placeholder: '目标模型' })
            .fontSize(14)
            .layoutWeight(1)
            .onChange((value: string): void => {
              this.modelFilter = value;
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Button('全部')
            .fontSize(13)
            .height(34)
            .backgroundColor(this.statusFilter === null ? $r('app.color.brand_primary') : $r('app.color.card_background'))
            .onClick((): void => {
              this.statusFilter = null;
              this.reload();
            })
          Button('已完成')
            .fontSize(13)
            .height(34)
            .backgroundColor(this.statusFilter === RunRecordStatus.COMPLETED ? $r('app.color.brand_primary') : $r('app.color.card_background'))
            .onClick((): void => {
              this.statusFilter = RunRecordStatus.COMPLETED;
              this.reload();
            })
          Button('已失败')
            .fontSize(13)
            .height(34)
            .backgroundColor(this.statusFilter === RunRecordStatus.FAILED ? $r('app.color.brand_primary') : $r('app.color.card_background'))
            .onClick((): void => {
              this.statusFilter = RunRecordStatus.FAILED;
              this.reload();
            })
          Button('已终止')
            .fontSize(13)
            .height(34)
            .backgroundColor(this.statusFilter === RunRecordStatus.TERMINATED ? $r('app.color.brand_primary') : $r('app.color.card_background'))
            .onClick((): void => {
              this.statusFilter = RunRecordStatus.TERMINATED;
              this.reload();
            })
          Button('搜索')
            .fontSize(13)
            .height(34)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => {
              this.reload();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(10)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(8)

      if (this.loading) {
        Text('加载中...')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 24 })
      } else if (this.records.length === 0) {
        Text('暂无运行记录')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 24 })
      } else {
        List({ space: 10 }) {
          ForEach(this.records, (record: RunRecord) => {
            ListItem() {
              this.recordCard(record)
            }
          }, (record: RunRecord) => record.recordId)
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

      if (this.selectedIds.size > 0) {
        Button(`批量删除(${this.selectedIds.size})`)
          .width('100%')
          .height(44)
          .backgroundColor($r('app.color.status_error'))
          .onClick((): void => {
            this.confirmRemoveBatch();
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Start)
  }
}