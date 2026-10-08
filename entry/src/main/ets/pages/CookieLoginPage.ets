/**
 * CookieLoginPage —— 应用内登录获取 Cookie。
 *
 * 这是鸿蒙版对 macOS「从浏览器自动获取 Cookie」的等价实现：桌面端读本机浏览器
 * Cookie 库，鸿蒙没有桌面浏览器，所以改为在应用内用 ArkWeb 打开平台登录页，
 * 用户登录后调用 WebCookieManager.fetchCookie 抓取登录态，再写回 preferences。
 *
 * 关键点：
 *  - Web 组件默认共用应用级 Cookie 仓库，登录成功后 fetchCookie 能直接拿到；
 *  - 写入前用 CookieDoctor 体检，过期则拒绝保存并引导先在网页里重新登录；
 *  - 写完后 bump AppStorage.cookieVersion，设置页通过 @StorageLink 自动刷新体检卡。
 */

import { webview } from '@kit.ArkWeb';
// AppStorage 是全局单例（SDK 里 declare class，无 export），不能从 @kit.ArkUI 具名导入。
import { router, promptAction } from '@kit.ArkUI';
import { ConfigStore } from '../core/store/ConfigStore';
import {
  analyzeCookie, platformMeta, CookieReport,
} from '../core/cookie/CookieDoctor';
import { Logger } from '../core/util/Logger';

@Entry
@Component
struct CookieLoginPage {
  @State platform: string = 'douyin';
  @State name: string = '';
  @State loginUrl: string = '';
  @State cookieUrl: string = '';
  @State progress: number = 0;
  @State loading: boolean = true;
  controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object> | undefined;
    const key: string = params !== undefined && typeof params['platform'] === 'string'
      ? (params['platform'] as string) : 'douyin';
    const meta = platformMeta(key);
    if (meta !== undefined) {
      this.platform = meta.key;
      this.name = meta.name;
      this.loginUrl = meta.loginUrl;
      this.cookieUrl = meta.cookieUrl;
    }
  }

  build() {
    Column() {
      // 顶部返回 + 标题
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#FF2C55')
          .onClick(() => {
            router.back();
          })
        Text(`${this.name} · 登录获取 Cookie`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('')
          .width(48)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 8 })

      Text('在下方网页登录你的账号，登录成功后点「获取 Cookie」。应用只读取登录态，不会上传任何信息。')
        .fontSize(12)
        .fontColor('#8A8A8E')
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 })

      Web({ src: this.loginUrl, controller: this.controller })
        .layoutWeight(1)
        .width('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onProgressChange((e) => {
          if (e) {
            this.progress = e.newProgress;
          }
        })
        .onPageBegin(() => {
          this.loading = true;
        })
        .onPageEnd(() => {
          this.loading = false;
        })

      // 底部操作条
      Column({ space: 8 }) {
        if (this.loading) {
          Text(`加载中… ${this.progress}%`)
            .fontSize(12)
            .fontColor('#8A8A8E')
            .width('100%')
        }
        Row({ space: 8 }) {
          Button('清除登录态重登')
            .fontSize(13)
            .layoutWeight(1)
            .height(42)
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .fontColor($r('sys.color.font_primary'))
            .onClick(() => {
              this.clearLogin();
            })
          Button('获取 Cookie')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#FF2C55')
            .fontColor(Color.White)
            .onClick(() => {
              this.fetchAndSave();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
      .backgroundColor($r('sys.color.comp_background_primary'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }

  /** 清除应用内 Web Cookie 并清缓存，便于重新登录（不影响下载用的显式 Cookie 头）。 */
  private clearLogin(): void {
    try {
      // clearAllCookies() 是异步的（返回 Promise<void>），这里要同步等结果，
      // 用官方 @useinstead 指向的 clearAllCookiesSync()。
      webview.WebCookieManager.clearAllCookiesSync();
      Logger.info('清除 Web Cookie：完成');
    } catch (e) {
      Logger.warn(`清除 Web Cookie 失败：${errText(e)}`);
    }
    try {
      // WebviewController 没有 clearCache()，清缓存是 removeCache(是否清 ROM 缓存)。
      this.controller.removeCache(true);
    } catch (e) {
      // 忽略
    }
    promptAction.showToast({ message: '已清除，请重新登录', duration: 1500 });
  }

  /** 抓取并保存 Cookie。 */
  private async fetchAndSave(): Promise<void> {
    const meta = platformMeta(this.platform);
    if (meta === undefined) {
      return;
    }
    let cookie: string = '';
    try {
      cookie = await webview.WebCookieManager.fetchCookie(this.cookieUrl);
    } catch (e) {
      Logger.warn(`fetchCookie 失败：${errText(e)}`);
      promptAction.showToast({
        message: `抓取 Cookie 失败（${errText(e)}），请重试或在设置里手动粘贴`,
        duration: 2200,
      });
      return;
    }
    if (!cookie || cookie.trim().length === 0) {
      promptAction.showToast({
        message: `没拿到 Cookie，请确认已在网页内登录 ${this.name}`,
        duration: 2200,
      });
      return;
    }

    const report: CookieReport = analyzeCookie(cookie, this.platform);
    // 诊断日志：只打字段名，绝不打印 cookie 值（可能含 session 令牌）。
    Logger.info(`抓取结果：共 ${report.keyCount} 个字段，` +
      `登录态字段命中 [${report.loginKeysFound.join(' / ') || '无'}]，` +
      `期望 [${report.loginKeysExpected.join(' / ')}]`);
    // 抓到了 cookie 但没有登录态字段：网页内大概率还没真正登录完（扫码/SSO 跳转未完成）。
    // 不能当成功存盘，否则设置页会一直显示「缺登录态」误导用户。
    if (report.health === 'anonymous') {
      Logger.warn(`抓取到的 Cookie 缺登录态字段，疑似网页内尚未真正登录`);
      AlertDialog.show({
        title: '还没登录成功',
        message: `已抓到 Cookie（${report.keyCount} 个字段），但其中没有登录态字段（${report.loginKeysExpected.join(' / ')}）。` +
          `这通常说明网页里还没真正登录，或登录跳转还没完成。请先在网页内完成登录（页面加载完成、已看到账号态），再点「获取 Cookie」。`,
        primaryButton: {
          value: '知道了',
          action: () => {
          },
        },
      });
      return;
    }
    if (report.health === 'expired') {
      AlertDialog.show({
        title: 'Cookie 已过期',
        message: `网页里的登录态同样已过期（${report.expireStr}）。建议先在网页内重新登录，再点获取。仍要保存这份过期 Cookie 吗？`,
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '仍要保存',
          fontColor: '#D93A3A',
          action: () => {
            this.applyCookie(cookie);
          },
        },
      });
      return;
    }
    this.applyCookie(cookie);
  }

  private async applyCookie(cookie: string): Promise<void> {
    // 必须 await：setCookie 是异步的，且内部会在更新内存缓存前先 await pushBackup。
    // 若不等写入完成就 bump cookieVersion，设置页 @Watch('reload') 会读到尚未更新的空缓存，
    // 体检卡误判为 empty → 显示「未设置」。所以先 await 落盘，再通知刷新并退出。
    await ConfigStore.setCookie(this.platform, cookie);
    // 通知设置页体检卡刷新
    const v: number = (AppStorage.get('cookieVersion') as number) || 0;
    AppStorage.set('cookieVersion', v + 1);
    Logger.info(`${this.name} Cookie 已通过应用内登录写入（${cookie.length} 字符）`);
    promptAction.showToast({ message: `${this.name} Cookie 已保存`, duration: 1500 });
    router.back();
  }
}

/** 异常的可能形状。ArkTS 不允许拿对象字面量直接当类型声明（arkts-no-obj-literals-as-types）。 */
interface ErrorLike {
  code?: number;
  message?: string;
}

/** 异常文本提取（避免与 ConfigStore 耦合，这里内联一份）。 */
function errText(e: object | undefined): string {
  if (e === undefined || e === null) {
    return 'unknown';
  }
  const be = e as ErrorLike;
  if (be.message !== undefined) {
    return be.code !== undefined ? `[${be.code}] ${be.message}` : be.message;
  }
  return JSON.stringify(e);
}
