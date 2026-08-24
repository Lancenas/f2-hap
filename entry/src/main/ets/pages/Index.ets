/**
 * Index —— 应用主入口页
 *
 * 四个 Tab：下载 / 任务 / 日志 / 设置
 * 职责：
 *   1. 组合四个 Tab 页面
 *   2. 把 TaskManager 的 Toast 事件转发到 promptAction
 *   3. 订阅任务列表以在「任务」Tab 上显示进行中数量
 *   4. 收到系统分享链接时自动切到「下载」Tab
 */
import { promptAction } from '@kit.ArkUI';
import { DownloadTab } from '../views/DownloadTab';
import { TasksTab } from '../views/TasksTab';
import { LogsTab } from '../views/LogsTab';
import { SettingsTab } from '../views/SettingsTab';
import { BRAND, MUTED } from '../views/Theme';
import { TaskManager } from '../core/download/TaskManager';
import { DownloadTask, TaskStatus } from '../core/model/Models';

@Entry
@Component
struct Index {
  @State currentIndex: number = 0;
  @State activeCount: number = 0;
  @StorageLink('sharedUrl') @Watch('onShared') sharedUrl: string = '';

  private unsubTasks: (() => void) | null = null;
  private unsubToast: (() => void) | null = null;

  onShared(): void {
    // 系统分享唤起时，DownloadTab 会读取 sharedUrl；这里负责把界面切过去
    if (this.sharedUrl.length > 0) {
      this.currentIndex = 0;
    }
  }

  aboutToAppear(): void {
    this.unsubToast = TaskManager.onToast((msg: string) => {
      promptAction.showToast({ message: msg, duration: 2200, bottom: 120 });
    });
    this.unsubTasks = TaskManager.subscribe((tasks: DownloadTask[]) => {
      let n = 0;
      for (let i = 0; i < tasks.length; i++) {
        const s = tasks[i].status;
        if (s === TaskStatus.PENDING || s === TaskStatus.PARSING || s === TaskStatus.RUNNING) {
          n++;
        }
      }
      this.activeCount = n;
    });
    this.activeCount = TaskManager.activeCount();
  }

  aboutToDisappear(): void {
    if (this.unsubToast !== null) {
      this.unsubToast();
      this.unsubToast = null;
    }
    if (this.unsubTasks !== null) {
      this.unsubTasks();
      this.unsubTasks = null;
    }
  }

  @Builder
  tabItem(index: number, icon: string, label: string, badge: number) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(icon)
          .fontSize(21)
          .opacity(this.currentIndex === index ? 1 : 0.55)
        if (badge > 0) {
          Text(badge > 99 ? '99+' : badge.toString())
            .fontSize(9)
            .fontColor(Color.White)
            .backgroundColor(BRAND)
            .borderRadius(8)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .offset({ x: 10, y: -4 })
        }
      }
      .height(24)

      Text(label)
        .fontSize(10)
        .fontWeight(this.currentIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentIndex === index ? BRAND : MUTED)
    }
    .width('100%')
    .height(52)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
      TabContent() {
        DownloadTab()
      }
      .tabBar(this.tabItem(0, '⬇', '下载', 0))

      TabContent() {
        TasksTab()
      }
      .tabBar(this.tabItem(1, '☰', '任务', this.activeCount))

      TabContent() {
        LogsTab()
      }
      .tabBar(this.tabItem(2, '✎', '日志', 0))

      TabContent() {
        SettingsTab()
      }
      .tabBar(this.tabItem(3, '⚙', '设置', 0))
    }
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .scrollable(false)
    .animationDuration(180)
    .onChange((i: number) => {
      this.currentIndex = i;
    })
    .backgroundColor($r('sys.color.background_secondary'))
    .width('100%')
    .height('100%')
  }
}
