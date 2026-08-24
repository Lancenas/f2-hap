/**
 * 「设置」页 —— 对应 macOS 版 SettingsView。
 *
 * 手机端去掉了保存目录选择（沙箱固定）和主题切换（跟随系统），
 * 增加了「存入相册」开关和存储占用统计。
 *
 * Cookie 输入是这一页的重点：抖音/微博没 Cookie 就完全解析不了，
 * 所以每个平台都给了「怎么拿」的一句话说明，而不是只放一个空输入框。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { AppConfig, ConfigStore, DEFAULT_NAME_FORMAT, DEFAULT_UA } from '../core/store/ConfigStore';
import { TaskManager } from '../core/download/TaskManager';
import { formatSize } from '../core/model/Models';
import { Logger } from '../core/util/Logger';
import { BRAND, CARD_RADIUS, GAP, MUTED, PAGE_PADDING } from './Theme';

@Component
export struct SettingsTab {
  @State cookieDouyin: string = '';
  @State cookieWeibo: string = '';
  @State cookieTwitter: string = '';
  @State cookieTiktok: string = '';
  @State concurrent: number = 2;
  @State saveToGallery: boolean = true;
  @State notify: boolean = true;
  @State nameFormat: string = DEFAULT_NAME_FORMAT;
  @State usage: string = '--';
  @State editingUA: boolean = false;
  @State userAgent: string = DEFAULT_UA;

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    const c: AppConfig = ConfigStore.get();
    this.cookieDouyin = c.cookieDouyin;
    this.cookieWeibo = c.cookieWeibo;
    this.cookieTwitter = c.cookieTwitter;
    this.cookieTiktok = c.cookieTiktok;
    this.concurrent = c.concurrentDownloads;
    this.saveToGallery = c.saveToGallery;
    this.notify = c.notifyOnComplete;
    this.nameFormat = c.nameFormat;
    this.userAgent = c.userAgent;
    this.usage = formatSize(TaskManager.diskUsage());
  }

  build() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 8, bottom: 10 })

      Scroll() {
        Column({ space: GAP }) {
          this.cookieSection()
          this.behaviorSection()
          this.storageSection()
          this.aboutSection()
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
  }

  // ---------- Cookie ----------

  @Builder
  cookieSection() {
    Column({ space: 12 }) {
      this.sectionTitle('平台 Cookie', '在电脑浏览器登录后，开发者工具 → Network → 任一请求 → 复制 Cookie 整行')

      this.cookieRow('抖音', this.cookieDouyin, 'ttwid 必须在里面', (v: string) => {
        this.cookieDouyin = v;
        ConfigStore.setCookie('douyin', v);
      })
      this.cookieRow('微博', this.cookieWeibo, '需要 SUB / SUBP，游客直接跳登录', (v: string) => {
        this.cookieWeibo = v;
        ConfigStore.setCookie('weibo', v);
      })
      this.cookieRow('X (Twitter)', this.cookieTwitter, '可留空，走公开接口即可解析', (v: string) => {
        this.cookieTwitter = v;
        ConfigStore.setCookie('twitter', v);
      })
      this.cookieRow('TikTok', this.cookieTiktok, '本版本尚未移植 XBogus，填了也可能失败', (v: string) => {
        this.cookieTiktok = v;
        ConfigStore.setCookie('tiktok', v);
      })
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  cookieRow(label: string, value: string, hint: string, onSave: (v: string) => void) {
    Column({ space: 6 }) {
      Row() {
        Text(label)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(value === '' ? '未设置' : `已设置 ${value.length} 字符`)
          .fontSize(11)
          .fontColor(value === '' ? MUTED : BRAND)
      }
      .width('100%')

      Text(hint)
        .fontSize(11)
        .fontColor(MUTED)
        .width('100%')

      Row({ space: 8 }) {
        Button('从剪贴板粘贴')
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.pasteInto(label, onSave);
          })
        Button('清除')
          .fontSize(13)
          .height(36)
          .width(72)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor(MUTED)
          .onClick(() => {
            onSave('');
            promptAction.showToast({ message: `${label} Cookie 已清除`, duration: 1500 });
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  private pasteInto(label: string, onSave: (v: string) => void): void {
    pasteboard.getSystemPasteboard().getData((err, data) => {
      if (err !== undefined && err !== null) {
        promptAction.showToast({ message: '读不到剪贴板', duration: 1500 });
        return;
      }
      const text: string = data.getPrimaryText();
      if (text === undefined || text === null || text.trim() === '') {
        promptAction.showToast({ message: '剪贴板是空的', duration: 1500 });
        return;
      }
      if (!text.includes('=')) {
        promptAction.showToast({ message: '看起来不像 Cookie（没有 key=value）', duration: 2000 });
        return;
      }
      onSave(text);
      Logger.info(`${label} Cookie 已更新（${text.length} 字符）`);
      promptAction.showToast({ message: `${label} Cookie 已保存`, duration: 1500 });
    });
  }

  // ---------- 行为 ----------

  @Builder
  behaviorSection() {
    Column({ space: 14 }) {
      this.sectionTitle('下载行为', '')

      Row() {
        Column({ space: 2 }) {
          Text('存入系统相册')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text('每个任务完成后弹一次系统授权')
            .fontSize(11)
            .fontColor(MUTED)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.saveToGallery })
          .selectedColor(BRAND)
          .onChange((v: boolean) => {
            this.saveToGallery = v;
            ConfigStore.setSaveToGallery(v);
          })
      }
      .width('100%')

      Row() {
        Column({ space: 2 }) {
          Text('完成后提示')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text('关掉后只在日志里记录')
            .fontSize(11)
            .fontColor(MUTED)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.notify })
          .selectedColor(BRAND)
          .onChange((v: boolean) => {
            this.notify = v;
            ConfigStore.setNotify(v);
          })
      }
      .width('100%')

      Column({ space: 6 }) {
        Row() {
          Text('同时下载数')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          Text(`${this.concurrent}`)
            .fontSize(14)
            .fontColor(BRAND)
        }
        .width('100%')
        Slider({
          value: this.concurrent,
          min: 1,
          max: 5,
          step: 1,
          style: SliderStyle.OutSet,
        })
          .selectedColor(BRAND)
          .showTips(true)
          .onChange((v: number) => {
            this.concurrent = Math.round(v);
            ConfigStore.setConcurrent(this.concurrent);
          })
        Text('移动网络下建议 1~2，太多容易被限流')
          .fontSize(11)
          .fontColor(MUTED)
          .width('100%')
      }
      .width('100%')

      Column({ space: 6 }) {
        Text('文件命名模板')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        TextInput({ text: this.nameFormat, placeholder: DEFAULT_NAME_FORMAT })
          .fontSize(13)
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .onChange((v: string) => {
            this.nameFormat = v;
          })
          .onSubmit(() => {
            ConfigStore.setNameFormat(this.nameFormat);
            promptAction.showToast({ message: '命名模板已保存', duration: 1500 });
          })
        Row({ space: 8 }) {
          Text('可用占位符：{author} {title} {id}')
            .fontSize(11)
            .fontColor(MUTED)
            .layoutWeight(1)
          Text('保存')
            .fontSize(12)
            .fontColor(BRAND)
            .onClick(() => {
              ConfigStore.setNameFormat(this.nameFormat);
              promptAction.showToast({ message: '命名模板已保存', duration: 1500 });
            })
        }
        .width('100%')
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  // ---------- 存储 ----------

  @Builder
  storageSection() {
    Column({ space: 12 }) {
      this.sectionTitle('存储', '')

      Row() {
        Column({ space: 2 }) {
          Text('应用内已占用')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text(TaskManager.downloadDir())
            .fontSize(10)
            .fontColor(MUTED)
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.usage)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(BRAND)
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('刷新占用')
          .fontSize(13)
          .height(38)
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.usage = formatSize(TaskManager.diskUsage());
          })
        Button('清空应用内文件')
          .fontSize(13)
          .height(38)
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor('#D93A3A')
          .onClick(() => {
            this.confirmClear();
          })
      }
      .width('100%')

      Text('已存入相册的副本不会被删除')
        .fontSize(11)
        .fontColor(MUTED)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空应用内文件',
      message: `将删除 ${TaskManager.downloadDir()} 下的所有文件。已存入相册的副本不受影响。`,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '确认删除',
        fontColor: '#D93A3A',
        action: () => {
          const n: number = TaskManager.clearDownloads();
          this.usage = formatSize(TaskManager.diskUsage());
          promptAction.showToast({ message: `已删除 ${n} 个文件`, duration: 1800 });
        },
      },
    });
  }

  // ---------- 关于 ----------

  @Builder
  aboutSection() {
    Column({ space: 10 }) {
      this.sectionTitle('关于', '')
      this.kv('版本', '0.1.0')
      this.kv('解析方式', '纯本机 ArkTS，无 Python 运行时、无第三方 API')
      this.kv('抖音签名', 'a_bogus（SM3 + RC4 + 自定义 base64）已移植')
      this.kv('X (Twitter)', 'syndication 接口 + guest token 兜底，免登录')
      this.kv('TikTok', '需 XBogus 签名与设备注册，暂未移植')

      Column({ space: 6 }) {
        Row() {
          Text('请求 User-Agent')
            .fontSize(13)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          Text(this.editingUA ? '收起' : '修改')
            .fontSize(12)
            .fontColor(BRAND)
            .onClick(() => {
              this.editingUA = !this.editingUA;
            })
        }
        .width('100%')
        if (this.editingUA) {
          TextArea({ text: this.userAgent })
            .height(72)
            .fontSize(11)
            .borderRadius(8)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .onChange((v: string) => {
              this.userAgent = v;
            })
          Row({ space: 8 }) {
            Text('签名与请求头必须同一个 UA，改错会导致抖音解析失败')
              .fontSize(11)
              .fontColor(MUTED)
              .layoutWeight(1)
            Text('保存')
              .fontSize(12)
              .fontColor(BRAND)
              .onClick(() => {
                ConfigStore.setUserAgent(this.userAgent);
                promptAction.showToast({ message: 'UA 已保存', duration: 1500 });
              })
          }
          .width('100%')
        } else {
          Text(this.userAgent)
            .fontSize(10)
            .fontColor(MUTED)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  @Builder
  sectionTitle(title: string, sub: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (sub !== '') {
        Text(sub)
          .fontSize(11)
          .fontColor(MUTED)
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  kv(k: string, v: string) {
    Row({ space: 10 }) {
      Text(k)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width(84)
      Text(v)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}
