/**
 * 应用首页 / Navigation 壳。提供进入 6 个业务页面的入口。
 * 目标页面由其他并行任务实现，此处仅引用约定路由名，不 import 页面实现。
 */
import router from '@ohos.router';

interface RouteItem {
  title: ResourceStr;
  url: string;
}

@Entry
@Component
struct Index {
  private routes: RouteItem[] = [
    { title: $r('app.string.entry_service_config'), url: 'pages/ServiceConfigListPage' },
    { title: $r('app.string.entry_task_config'), url: 'pages/TaskConfigListPage' },
    { title: $r('app.string.entry_task_execution'), url: 'pages/TaskExecutionPage' },
    { title: $r('app.string.entry_result_detail'), url: 'pages/ResultDetailPage' },
    { title: $r('app.string.entry_run_record'), url: 'pages/RunRecordListPage' },
    { title: $r('app.string.entry_app_settings'), url: 'pages/AppSettingsPage' }
  ];

  private open(url: string): void {
    router.pushUrl({ url: url }).catch(() => {
      // 目标页面由后续业务任务实现；未注册时静默忽略
    });
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.app_home_title'))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text($r('app.string.app_home_subtitle'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 12 })

      ForEach(this.routes, (item: RouteItem) => {
        Button(item.title)
          .width('100%')
          .height(44)
          .onClick(() => {
            this.open(item.url);
          })
      }, (item: RouteItem) => item.url)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Start)
  }
}