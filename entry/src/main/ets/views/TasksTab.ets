/**
 * 「任务」页 —— 对应 macOS 版 TasksView。
 *
 * 桌面版是宽表格（列：平台/标题/状态/进度/操作），手机端改成卡片列表，
 * 每张卡左侧一条平台色条，进度条压在标题下方，操作按钮按状态动态显示。
 */

import { promptAction } from '@kit.ArkUI';
import { DownloadTask, TaskStatus, platformLabel, statusLabel } from '../core/model/Models';
import { TaskManager } from '../core/download/TaskManager';
import {
  CARD_RADIUS, GAP, MUTED, PAGE_PADDING, platformBadge, platformColor, statusColor,
} from './Theme';

@Component
export struct TasksTab {
  @State tasks: DownloadTask[] = [];
  @State filter: number = 0;  // 0 全部 1 进行中 2 已完成 3 失败
  private unsub: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsub = TaskManager.subscribe((list: DownloadTask[]) => {
      this.tasks = list;
    });
  }

  aboutToDisappear(): void {
    if (this.unsub !== null) {
      this.unsub();
      this.unsub = null;
    }
  }

  private visible(): DownloadTask[] {
    if (this.filter === 0) {
      return this.tasks;
    }
    return this.tasks.filter((t: DownloadTask) => {
      if (this.filter === 1) {
        return t.status === TaskStatus.PENDING || t.status === TaskStatus.PARSING
          || t.status === TaskStatus.RUNNING;
      }
      if (this.filter === 2) {
        return t.status === TaskStatus.DONE;
      }
      return t.status === TaskStatus.ERROR || t.status === TaskStatus.CANCELLED;
    });
  }

  build() {
    Column() {
      Row() {
        Text('任务')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text('清理已结束')
          .fontSize(13)
          .fontColor(MUTED)
          .onClick(() => {
            TaskManager.clearFinished();
            promptAction.showToast({ message: '已清理', duration: 1500 });
          })
      }
      .width('100%')
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 8, bottom: 10 })

      this.filterBar()

      if (this.visible().length === 0) {
        this.emptyView()
      } else {
        List({ space: GAP }) {
          ForEach(this.visible(), (t: DownloadTask) => {
            ListItem() {
              this.taskCard(t)
            }
          }, (t: DownloadTask) => `${t.taskId}_${t.status}_${Math.floor(t.progress * 100)}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  filterBar() {
    Row({ space: 8 }) {
      this.chip('全部', 0, this.tasks.length)
      this.chip('进行中', 1, TaskManager.activeCount())
      this.chip('已完成', 2, TaskManager.countByStatus(TaskStatus.DONE))
      this.chip('失败', 3,
        TaskManager.countByStatus(TaskStatus.ERROR) + TaskManager.countByStatus(TaskStatus.CANCELLED))
    }
    .width('100%')
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 10 })
  }

  @Builder
  chip(label: string, idx: number, count: number) {
    Text(count > 0 ? `${label} ${count}` : label)
      .fontSize(13)
      .fontColor(this.filter === idx ? Color.White : $r('sys.color.font_secondary'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.filter === idx
        ? $r('sys.color.font_primary')
        : $r('sys.color.comp_background_tertiary'))
      .borderRadius(14)
      .onClick(() => {
        this.filter = idx;
      })
  }

  @Builder
  emptyView() {
    Column({ space: 10 }) {
      Text('还没有任务')
        .fontSize(16)
        .fontColor($r('sys.color.font_secondary'))
      Text('到「下载」页粘贴链接试试')
        .fontSize(13)
        .fontColor(MUTED)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  taskCard(t: DownloadTask) {
    Row() {
      // 平台色条
      Column()
        .width(4)
        .height('100%')
        .backgroundColor(platformColor(t.platform))

      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(platformBadge(t.platform))
            .fontSize(11)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(platformColor(t.platform))
            .borderRadius(5)
          Text(statusLabel(t.status))
            .fontSize(11)
            .fontColor(statusColor(t.status))
          if (t.isBatch) {
            Text(`${t.batchDone}/${t.batchTotal}`)
              .fontSize(11)
              .fontColor(MUTED)
          }
          Blank()
          Text(t.createdAt)
            .fontSize(11)
            .fontColor(MUTED)
        }
        .width('100%')

        Text(t.title === '' ? t.url : t.title)
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (t.author !== '') {
          Text(`${t.author} · ${platformLabel(t.platform)}`)
            .fontSize(12)
            .fontColor(MUTED)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        if (t.status === TaskStatus.RUNNING || t.status === TaskStatus.PARSING) {
          Progress({ value: Math.floor(t.progress * 100), total: 100, type: ProgressType.Linear })
            .color(platformColor(t.platform))
            .width('100%')
            .height(5)
          Row() {
            Text(`${Math.floor(t.progress * 100)}%`)
              .fontSize(11)
              .fontColor(MUTED)
            Blank()
            if (t.speed !== '') {
              Text(t.speed)
                .fontSize(11)
                .fontColor(MUTED)
            }
            if (t.size !== '' && t.size !== '--') {
              Text(`  ${t.size}`)
                .fontSize(11)
                .fontColor(MUTED)
            }
          }
          .width('100%')
        }

        if (t.status === TaskStatus.DONE && t.size !== '') {
          Text(`已保存 · ${t.size}`)
            .fontSize(12)
            .fontColor(statusColor(TaskStatus.DONE))
            .width('100%')
        }

        if (t.errorMsg !== '') {
          Text(t.errorMsg)
            .fontSize(12)
            .fontColor(statusColor(TaskStatus.ERROR))
            .maxLines(3)
            .width('100%')
        }

        Row({ space: 10 }) {
          if (t.status === TaskStatus.RUNNING || t.status === TaskStatus.PARSING
            || t.status === TaskStatus.PENDING) {
            this.actionBtn('取消', () => {
              TaskManager.cancel(t.taskId);
            })
          }
          if (t.status === TaskStatus.ERROR || t.status === TaskStatus.CANCELLED) {
            this.actionBtn('重试', () => {
              TaskManager.retry(t.taskId);
            })
          }
          Blank()
          this.actionBtn('删除', () => {
            TaskManager.remove(t.taskId);
          })
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding(12)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
    .clip(true)
  }

  @Builder
  actionBtn(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor($r('sys.color.font_secondary'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius(8)
      .onClick(action)
  }
}
