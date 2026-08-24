/**
 * 「日志」页 —— 对应 macOS 版 LogView。
 *
 * 日志同时进 hilog（用 hdc hilog 抓）和内存缓冲（这里展示）。
 * 手机上排查问题不方便接电脑，所以「复制全部」很关键。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { LogLevel, LogLine, Logger } from '../core/util/Logger';
import { CARD_RADIUS, ERR_COLOR, MUTED, OK_COLOR, PAGE_PADDING, WARN_COLOR } from './Theme';

@Component
export struct LogsTab {
  @State lines: LogLine[] = [];
  @State levelFilter: number = 0;  // 0 全部 1 INFO+ 2 WARN+ 3 ERROR
  @State autoScroll: boolean = true;
  private unsub: (() => void) | null = null;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.lines = Logger.all();
    this.unsub = Logger.subscribe((l: LogLine[]) => {
      this.lines = l.slice(0);
      if (this.autoScroll) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    });
  }

  aboutToDisappear(): void {
    if (this.unsub !== null) {
      this.unsub();
      this.unsub = null;
    }
  }

  private rank(l: LogLevel): number {
    switch (l) {
      case LogLevel.DEBUG: return 0;
      case LogLevel.INFO: return 1;
      case LogLevel.WARN: return 2;
      default: return 3;
    }
  }

  private visible(): LogLine[] {
    if (this.levelFilter === 0) {
      return this.lines;
    }
    return this.lines.filter((l: LogLine) => this.rank(l.level) >= this.levelFilter);
  }

  private colorOf(l: LogLevel): ResourceColor {
    switch (l) {
      case LogLevel.ERROR: return ERR_COLOR;
      case LogLevel.WARN: return WARN_COLOR;
      case LogLevel.INFO: return OK_COLOR;
      default: return MUTED;
    }
  }

  build() {
    Column() {
      Row() {
        Text('日志')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text('复制')
          .fontSize(13)
          .fontColor(MUTED)
          .padding({ right: 14 })
          .onClick(() => {
            this.copyAll();
          })
        Text('清空')
          .fontSize(13)
          .fontColor(MUTED)
          .onClick(() => {
            Logger.clear();
          })
      }
      .width('100%')
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 8, bottom: 10 })

      Row({ space: 8 }) {
        this.chip('全部', 0)
        this.chip('信息', 1)
        this.chip('警告', 2)
        this.chip('错误', 3)
        Blank()
        Row({ space: 4 }) {
          Toggle({ type: ToggleType.Switch, isOn: this.autoScroll })
            .width(36)
            .height(20)
            .onChange((v: boolean) => {
              this.autoScroll = v;
            })
          Text('跟随')
            .fontSize(12)
            .fontColor(MUTED)
        }
      }
      .width('100%')
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: 10 })

      if (this.visible().length === 0) {
        Column() {
          Text('暂无日志')
            .fontSize(14)
            .fontColor(MUTED)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.scroller) {
          Column({ space: 6 }) {
            ForEach(this.visible(), (l: LogLine) => {
              Row({ space: 8 }) {
                Text(l.time)
                  .fontSize(11)
                  .fontColor(MUTED)
                  .fontFamily('monospace')
                Text(l.level)
                  .fontSize(10)
                  .fontColor(this.colorOf(l.level))
                  .width(40)
                Text(l.text)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_primary'))
                  .layoutWeight(1)
                  .textOverflow({ overflow: TextOverflow.Clip })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (l: LogLine, idx: number) => `${l.time}_${idx}_${l.text.length}`)
          }
          .width('100%')
          .padding(12)
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(CARD_RADIUS)
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  chip(label: string, idx: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.levelFilter === idx ? Color.White : $r('sys.color.font_secondary'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(this.levelFilter === idx
        ? $r('sys.color.font_primary')
        : $r('sys.color.comp_background_tertiary'))
      .borderRadius(12)
      .onClick(() => {
        this.levelFilter = idx;
      })
  }

  private copyAll(): void {
    const text: string = Logger.export();
    if (text === '') {
      promptAction.showToast({ message: '没有日志可复制', duration: 1500 });
      return;
    }
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data, (err) => {
      const ok: boolean = err === undefined || err === null;
      promptAction.showToast({ message: ok ? '日志已复制' : '复制失败', duration: 1500 });
    });
  }
}
