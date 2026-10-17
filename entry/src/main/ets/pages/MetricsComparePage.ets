import router from '@ohos.router';
import { MetricReportService } from '../biz/metricreport/MetricReportService';
import { RunRecordService } from '../biz/runrecord/RunRecordService';
import { MetricsComparison, RunRecord } from '../common/types/DomainTypes';
import { AppError } from '../common/error/AppError';

@Entry
@Component
struct MetricsComparePage {
  @State records: RunRecordBrief[] = [];
  @State selectedIds: string[] = [];
  @State comparison: MetricsComparison | null = null;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.loadRecords();
  }

  async loadRecords(): Promise<void> {
    try {
      const all: RunRecord[] = await RunRecordService.getInstance().listRecords({});
      const briefs: RunRecordBrief[] = [];
      for (let i = 0; i < all.length; i++) {
        const r: RunRecord = all[i];
        briefs.push({
          recordId: r.recordId,
          taskName: r.taskName,
          targetModel: r.targetModel,
          status: r.status
        });
      }
      this.records = briefs;
    } catch (e) {
      this.errorMsg = '加载记录失败';
    }
  }

  toggleSelect(id: string): void {
    const idx: number = this.selectedIds.indexOf(id);
    if (idx >= 0) {
      const newList: string[] = [];
      for (let i = 0; i < this.selectedIds.length; i++) {
        if (this.selectedIds[i] !== id) {
          newList.push(this.selectedIds[i]);
        }
      }
      this.selectedIds = newList;
    } else {
      const newList: string[] = [];
      for (let i = 0; i < this.selectedIds.length; i++) {
        newList.push(this.selectedIds[i]);
      }
      newList.push(id);
      this.selectedIds = newList;
    }
  }

  async onCompare(): Promise<void> {
    if (this.selectedIds.length < 2) {
      this.errorMsg = '请选择至少两条记录';
      return;
    }
    this.errorMsg = '';
    try {
      this.comparison = await MetricReportService.getInstance().compareRecords(this.selectedIds);
    } catch (e) {
      const err: AppError = e as AppError;
      this.errorMsg = err.userMessage();
      this.comparison = null;
    }
  }

  formatVal(val: number | null): string {
    if (val === null) {
      return '—';
    }
    if (val < 1) {
      return (val * 100).toFixed(2) + '%';
    }
    return val.toFixed(0);
  }

  build(): void {
    Column() {
      // 标题栏
      Row() {
        Text('指标对比')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('返回')
          .fontSize(14)
          .onClick(() => { router.back(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      // 记录选择列表
      Text('选择运行记录（至少两条）')
        .fontSize(14)
        .fontColor('#666666')
        .margin({ left: 16, top: 8 })

      List() {
        ForEach(this.records, (r: RunRecordBrief) => {
          ListItem() {
            Row() {
              Checkbox()
                .select(this.selectedIds.indexOf(r.recordId) >= 0)
                .onChange((isChecked: boolean) => {
                  if (isChecked) {
                    this.toggleSelect(r.recordId);
                  } else {
                    this.toggleSelect(r.recordId);
                  }
                })
                .margin({ right: 8 })
              Text(r.taskName)
                .fontSize(14)
                .layoutWeight(1)
              Text(r.targetModel)
                .fontSize(12)
                .fontColor('#666666')
                .width(100)
              Text(r.status)
                .fontSize(12)
                .fontColor('#666666')
                .width(60)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          }
        }, (r: RunRecordBrief) => r.recordId)
      }
      .layoutWeight(1)
      .width('100%')

      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(14)
          .fontColor('#F44336')
          .margin({ left: 16, bottom: 8 })
      }

      Button('开始对比')
        .fontSize(14)
        .width('80%')
        .margin({ bottom: 8 })
        .onClick(() => { this.onCompare(); })

      // 对比结果矩阵
      if (this.comparison !== null) {
        Column() {
          // 表头
          Row() {
            Text('指标')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .width(80)
            ForEach(this.comparison!.recordIds, (id: string, index: number) => {
              Text(`记录${index + 1}`)
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            }, (id: string) => id)
          }
          .width('100%')
          .padding({ left: 8, right: 8 })

          // 数据行
          ForEach(this.comparison!.metricNames, (metricName: string, mIndex: number) => {
            Row() {
              Text(metricName)
                .fontSize(12)
                .width(80)
              ForEach(this.comparison!.values, (row: Array<number | null>) => {
                Text(this.formatVal(row[mIndex]))
                  .fontSize(12)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
              }, (row: Array<number | null>, rIndex: number) => `${rIndex}`)
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          }, (metricName: string) => metricName)
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}

interface RunRecordBrief {
  recordId: string;
  taskName: string;
  targetModel: string;
  status: string;
}