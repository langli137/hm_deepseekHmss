import router from '@ohos.router';
import { MetricReportService } from '../biz/metricreport/MetricReportService';
import { CaseResult, CaseResultFilter, Metrics } from '../common/types/DomainTypes';
import { Verdict } from '../common/types/Enums';
import { AppError } from '../common/error/AppError';

@Entry
@Component
struct ResultDetailPage {
  @State recordId: string = '';
  @State metrics: Metrics = {
    accuracy: null, passRate: null, avgElapsedMs: null,
    usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0 }, computed: false
  };
  @State caseResults: CaseResult[] = [];
  @State onlyFailed: boolean = false;
  @State selectedCase: CaseResult | null = null;
  @State showDetail: boolean = false;
  @State exportMsg: string = '';

  aboutToAppear(): void {
    const params: Record<string, string> = router.getParams() as Record<string, string>;
    if (params !== null && params !== undefined) {
      this.recordId = params['recordId'] ?? '';
    }
    this.loadData();
  }

  async loadData(): Promise<void> {
    if (this.recordId.length === 0) {
      return;
    }
    const svc: MetricReportService = MetricReportService.getInstance();
    this.metrics = await svc.getMetrics(this.recordId);
    this.caseResults = await svc.listCaseResults(this.recordId, { onlyFailed: false });
  }

  getFilteredCases(): CaseResult[] {
    if (!this.onlyFailed) {
      return this.caseResults;
    }
    const filtered: CaseResult[] = [];
    for (let i = 0; i < this.caseResults.length; i++) {
      const c: CaseResult = this.caseResults[i];
      if (c.verdict === Verdict.FAILED || c.verdict === Verdict.TIMEOUT) {
        filtered.push(c);
      }
    }
    return filtered;
  }

  verdictColor(v: Verdict): string {
    if (v === Verdict.PASSED) {
      return '#4CAF50';
    } else if (v === Verdict.FAILED) {
      return '#F44336';
    } else if (v === Verdict.TIMEOUT) {
      return '#FF9800';
    }
    return '#9E9E9E';
  }

  formatPercent(val: number | null): string {
    if (val === null) {
      return '无有效样本';
    }
    return (val * 100).toFixed(2) + '%';
  }

  async onExport(): Promise<void> {
    try {
      const result = await MetricReportService.getInstance().exportReport(this.recordId);
      if (result.success) {
        this.exportMsg = '导出成功';
      } else {
        this.exportMsg = '导出失败：' + result.reason;
      }
    } catch (e) {
      const err: AppError = e as AppError;
      this.exportMsg = err.userMessage();
    }
  }

  build(): void {
    Column() {
      // 标题栏
      Row() {
        Text('评测结果详情')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('返回')
          .fontSize(14)
          .onClick(() => { router.back(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      // 汇总指标卡片
      Column() {
        Text('汇总指标')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 8 })

        if (!this.metrics.computed) {
          Text('计算中...')
            .fontSize(14)
            .fontColor('#9E9E9E')
        } else {
          Row() {
            Column() {
              Text('准确率')
                .fontSize(12)
                .fontColor('#666666')
              Text(this.formatPercent(this.metrics.accuracy))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
            }
            .layoutWeight(1)

            Column() {
              Text('通过率')
                .fontSize(12)
                .fontColor('#666666')
              Text(this.formatPercent(this.metrics.passRate))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
            }
            .layoutWeight(1)

            Column() {
              Text('平均耗时')
                .fontSize(12)
                .fontColor('#666666')
              Text(this.metrics.avgElapsedMs !== null ?
                this.metrics.avgElapsedMs.toFixed(0) + 'ms' : '无有效样本')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
            }
            .layoutWeight(1)
          }
          .width('100%')

          Row() {
            Text(`用量：prompt=${this.metrics.usage.promptTokens} completion=${this.metrics.usage.completionTokens} total=${this.metrics.usage.totalTokens}`)
              .fontSize(12)
              .fontColor('#666666')
          }
          .width('100%')
          .margin({ top: 4 })
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
      .borderRadius(8)
      .margin({ left: 16, right: 16, top: 8 })

      // 筛选与导出
      Row() {
        Toggle({ type: ToggleType.Switch, isOn: this.onlyFailed })
          .onChange((isOn: boolean) => { this.onlyFailed = isOn; })
          .margin({ right: 8 })
        Text('仅看失败项')
          .fontSize(14)
          .layoutWeight(1)

        Button('导出报告')
          .fontSize(14)
          .onClick(() => { this.onExport(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      if (this.exportMsg.length > 0) {
        Text(this.exportMsg)
          .fontSize(12)
          .fontColor('#FF6600')
          .margin({ left: 16 })
      }

      // 逐题明细列表
      List() {
        ForEach(this.getFilteredCases(), (c: CaseResult) => {
          ListItem() {
            Row() {
              Text(`[${c.seq}]`)
                .fontSize(12)
                .fontColor('#666666')
                .width(40)
              Text(c.verdict)
                .fontSize(12)
                .fontColor(this.verdictColor(c.verdict))
                .width(60)
              Text(c.content.length > 30 ? c.content.substring(0, 30) + '...' : c.content)
                .fontSize(14)
                .layoutWeight(1)
                .maxLines(1)
              Text(c.elapsedMs + 'ms')
                .fontSize(12)
                .fontColor('#666666')
                .width(60)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .onClick(() => {
              this.selectedCase = c;
              this.showDetail = true;
            })
          }
        }, (c: CaseResult) => c.caseId)
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 4 })

      // 用例详情弹层
      if (this.showDetail && this.selectedCase !== null) {
        Column() {
          Text('用例详情')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 8 })

          Text('题面：')
            .fontSize(12)
            .fontColor('#666666')
          Text(this.selectedCase!.content)
            .fontSize(14)
            .margin({ bottom: 8 })

          Text('参考答案：')
            .fontSize(12)
            .fontColor('#666666')
          Text(this.selectedCase!.referenceAnswer)
            .fontSize(14)
            .margin({ bottom: 8 })

          Text('模型作答：')
            .fontSize(12)
            .fontColor('#666666')
          Text(this.selectedCase!.modelAnswer)
            .fontSize(14)
            .margin({ bottom: 8 })

          Text(`判定：${this.selectedCase!.verdict}  耗时：${this.selectedCase!.elapsedMs}ms`)
            .fontSize(14)
            .fontColor(this.verdictColor(this.selectedCase!.verdict))

          Button('关闭')
            .fontSize(14)
            .margin({ top: 12 })
            .onClick(() => { this.showDetail = false; })
        }
        .width('90%')
        .padding(16)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .shadow({ radius: 8, color: '#33000000', offsetX: 0, offsetY: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}