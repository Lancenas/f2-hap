/**
 * 「下载」页 —— 对应 macOS 版 DownloadView。
 *
 * 手机端的核心交互差异：桌面版是手动粘贴 URL 到输入框，手机端多数是从抖音分享
 * 面板复制一整段文案。所以这里：
 *   1. 进页面自动读剪贴板（pasteboard），识别到支持的链接就直接填进去
 *   2. 支持一次粘贴多条链接 → 批量建任务
 *   3. 收到系统分享（AppStorage 的 sharedUrl）时自动填入
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { Platform, TaskStatus, platformLabel } from '../core/model/Models';
import { detectPlatform } from '../core/platform/PlatformDetector';
import { ResolverRegistry } from '../core/platform/ResolverRegistry';
import { TaskManager } from '../core/download/TaskManager';
import { ConfigStore } from '../core/store/ConfigStore';
import { Logger } from '../core/util/Logger';
import { errText } from '../core/store/ConfigStore';
import { BRAND, BRAND_SOFT, CARD_RADIUS, GAP, MUTED, PAGE_PADDING, platformBadge, platformColor } from './Theme';

@Component
export struct DownloadTab {
  @State input: string = '';
  @State detected: Platform = Platform.UNKNOWN;
  @State busy: boolean = false;
  @State activeCount: number = 0;
  @StorageLink('sharedUrl') sharedUrl: string = '';
  private unsub: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsub = TaskManager.subscribe(() => {
      this.activeCount = TaskManager.activeCount();
    });
    this.tryClipboard(false);
  }

  aboutToDisappear(): void {
    if (this.unsub !== null) {
      this.unsub();
      this.unsub = null;
    }
  }

  /** StorageLink 变化时 ArkUI 会重建，这里顺手把分享来的链接消费掉。 */
  private consumeShared(): void {
    if (this.sharedUrl !== '') {
      this.input = this.sharedUrl;
      this.detected = detectPlatform(this.sharedUrl);
      this.sharedUrl = '';
    }
  }

  /** 读剪贴板。手动点按钮时 silent=false，会给出提示。 */
  private tryClipboard(loud: boolean): void {
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      board.getData((err, data) => {
        if (err !== undefined && err !== null) {
          if (loud) {
            this.toast('读不到剪贴板内容');
          }
          return;
        }
        const text: string = data.getPrimaryText();
        if (text === undefined || text === null || text === '') {
          if (loud) {
            this.toast('剪贴板是空的');
          }
          return;
        }
        const urls: string[] = ResolverRegistry.pickUrls(text);
        if (urls.length === 0) {
          if (loud) {
            this.toast('剪贴板里没有可识别的链接');
          }
          return;
        }
        this.input = text.length > 500 ? urls.join('\n') : text;
        this.detected = detectPlatform(urls[0]);
        if (loud) {
          this.toast(`已粘贴 ${urls.length} 个链接`);
        }
      });
    } catch (e) {
      Logger.warn(`剪贴板读取异常：${errText(e as object)}`);
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2000 });
  }

  private submit(): void {
    const text: string = this.input.trim();
    if (text === '') {
      this.toast('先粘贴链接');
      return;
    }
    this.busy = true;
    const n: number = TaskManager.addFromText(text);
    this.busy = false;
    if (n > 0) {
      this.toast(n === 1 ? '已加入下载队列' : `已加入 ${n} 个任务`);
      this.input = '';
      this.detected = Platform.UNKNOWN;
    }
  }

  build() {
    Column() {
      this.header()

      Scroll() {
        Column({ space: GAP }) {
          this.inputCard()
          this.platformCard()
          this.tipsCard()
        }
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .onAppear(() => {
      this.consumeShared();
    })
  }

  @Builder
  header() {
    Row() {
      Column({ space: 2 }) {
        Text('F2 下载器')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text('抖音 / 微博 / X 视频与图集')
          .fontSize(12)
          .fontColor(MUTED)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.activeCount > 0) {
        Row({ space: 6 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(BRAND)
          Text(`${this.activeCount}`)
            .fontSize(13)
            .fontColor(BRAND)
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(BRAND_SOFT)
        .borderRadius(12)
      }
    }
    .width('100%')
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 8, bottom: 12 })
  }

  @Builder
  inputCard() {
    Column({ space: 10 }) {
      Row() {
        Text('粘贴分享链接')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        if (this.input !== '') {
          Text('清空')
            .fontSize(13)
            .fontColor(MUTED)
            .onClick(() => {
              this.input = '';
              this.detected = Platform.UNKNOWN;
            })
        }
      }
      .width('100%')

      TextArea({
        text: this.input,
        placeholder: '直接粘贴整段分享文案也可以，会自动抠出链接\n多行可批量下载',
      })
        .height(110)
        .fontSize(14)
        .borderRadius(10)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .onChange((v: string) => {
          this.input = v;
          const urls: string[] = ResolverRegistry.pickUrls(v);
          this.detected = urls.length > 0 ? detectPlatform(urls[0]) : Platform.UNKNOWN;
        })

      Row({ space: 10 }) {
        Button('读剪贴板')
          .fontSize(15)
          .height(44)
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.tryClipboard(true);
          })

        Button(this.busy ? '处理中…' : '开始下载')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .height(44)
          .layoutWeight(1.4)
          .backgroundColor(BRAND)
          .enabled(!this.busy)
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  platformCard() {
    Column({ space: 10 }) {
      Text('识别结果')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')

      Row({ space: 10 }) {
        Text(platformBadge(this.detected))
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .fontSize(this.detected === Platform.TIKTOK ? 13 : 16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .backgroundColor(platformColor(this.detected))
          .borderRadius(10)

        Column({ space: 2 }) {
          Text(this.detected === Platform.UNKNOWN ? '等待链接' : platformLabel(this.detected))
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
          Text(this.hintFor(this.detected))
            .fontSize(12)
            .fontColor(MUTED)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  private hintFor(p: Platform): string {
    const cfg = ConfigStore.get();
    switch (p) {
      case Platform.DOUYIN:
        return cfg.cookieDouyin === '' ? '需要先在设置里填 Cookie' : '已配置 Cookie，可直接下载';
      case Platform.WEIBO:
        return cfg.cookieWeibo === '' ? '需要先在设置里填 Cookie' : '已配置 Cookie，可直接下载';
      case Platform.TWITTER:
        return '无需 Cookie，直接解析';
      case Platform.TIKTOK:
        return '本版本尚未移植 XBogus 签名，成功率低';
      default:
        return '支持抖音、微博、X（Twitter）';
    }
  }

  @Builder
  tipsCard() {
    Column({ space: 8 }) {
      Text('说明')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      this.tipLine('1', '抖音与微博的接口对游客关闭，必须在「设置」粘贴浏览器 Cookie。')
      this.tipLine('2', '文件先落在应用沙箱，随后按「设置」里的开关弹一次系统授权存入相册。')
      this.tipLine('3', '解析出的直链有时效，任务失败时直接重试会重新解析一遍。')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  tipLine(no: string, text: string) {
    Row({ space: 8 }) {
      Text(no)
        .width(18)
        .height(18)
        .textAlign(TextAlign.Center)
        .fontSize(11)
        .fontColor(BRAND)
        .backgroundColor(BRAND_SOFT)
        .borderRadius(9)
      Text(text)
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('sys.color.font_secondary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}
