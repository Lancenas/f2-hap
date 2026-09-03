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
import { router, promptAction, AppStorage } from '@kit.ArkUI';
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
      const ok: boolean = webview.WebCookieManager.clearAllCookies();
      Logger.info(`清除 Web Cookie: ${ok}`);
    } catch (e) {
      Logger.warn(`清除 Web Cookie 失败：${errText(e)}`);
    }
    try {
      this.controller.clearCache();
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
    }
    if (!cookie || cookie.trim().length === 0) {
      promptAction.showToast({
        message: `没拿到 Cookie，请确认已在网页内登录 ${this.name}`,
        duration: 2200,
      });
      return;
    }

    const report: CookieReport = analyzeCookie(cookie, this.platform);
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

  private applyCookie(cookie: string): void {
    ConfigStore.setCookie(this.platform, cookie);
    // 通知设置页体检卡刷新
    const v: number = (AppStorage.get('cookieVersion') as number) || 0;
    AppStorage.set('cookieVersion', v + 1);
    Logger.info(`${this.name} Cookie 已通过应用内登录写入（${cookie.length} 字符）`);
    promptAction.showToast({ message: `${this.name} Cookie 已保存`, duration: 1500 });
    router.back();
  }
}

/** 异常文本提取（避免与 ConfigStore 耦合，这里内联一份）。 */
function errText(e: object | undefined): string {
  if (e === undefined || e === null) {
    return 'unknown';
  }
  const be = e as { code?: number; message?: string };
  if (be.message !== undefined) {
    return be.code !== undefined ? `[${be.code}] ${be.message}` : be.message;
  }
  return JSON.stringify(e);
}
