/**
 * 解析入口：一段文本 → ParseResult。
 *
 * 负责三件事：
 *   1. 从粘贴的分享文案里抠出链接（手机上几乎没人只粘纯链接）
 *   2. 短链展开（v.douyin.com / t.cn / t.co / vm.tiktok.com 的 302）
 *   3. 按平台派发到具体 Resolver
 *
 * 展开短链时用 t.cn 会跳到 weibo.com、t.co 跳到 x.com，所以平台判定必须在
 * 展开之后再做一次 —— 否则 t.cn 链接会被当成微博主页链接处理。
 */

import { ParseResult, Platform, platformLabel } from '../model/Models';
import { ConfigStore } from '../store/ConfigStore';
import { Logger } from '../util/Logger';
import { detectPlatform, expandUrl, extractUrl, extractUrls } from './PlatformDetector';
import { Resolver, ResolveError } from './Resolver';
import { DouyinResolver } from './DouyinResolver';
import { TikTokResolver } from './TikTokResolver';
import { TwitterResolver } from './TwitterResolver';
import { WeiboResolver } from './WeiboResolver';

/** 一次解析的完整上下文，UI 需要知道最终用的是哪个平台、哪个真实链接。 */
export class ResolveOutcome {
  finalUrl: string = '';
  platform: Platform = Platform.UNKNOWN;
  result: ParseResult | null = null;
}

class ResolverRegistryImpl {
  private douyin: DouyinResolver = new DouyinResolver();
  private tiktok: TikTokResolver = new TikTokResolver();
  private twitter: TwitterResolver = new TwitterResolver();
  private weibo: WeiboResolver = new WeiboResolver();

  private pick(p: Platform): Resolver | null {
    switch (p) {
      case Platform.DOUYIN: return this.douyin;
      case Platform.TIKTOK: return this.tiktok;
      case Platform.TWITTER: return this.twitter;
      case Platform.WEIBO: return this.weibo;
      default: return null;
    }
  }

  /** 从任意粘贴文本里取出所有可识别的链接。 */
  pickUrls(text: string): string[] {
    const all: string[] = extractUrls(text);
    const out: string[] = [];
    for (let i = 0; i < all.length; i++) {
      if (detectPlatform(all[i]) !== Platform.UNKNOWN) {
        out.push(all[i]);
      }
    }
    // 一个链接都没认出来时，仍把第一个链接交回去，让解析器报更具体的错
    if (out.length === 0 && all.length > 0) {
      out.push(all[0]);
    }
    return out;
  }

  /**
   * 解析一段文本（内含链接）。
   *
   * @throws ResolveError 文本里没链接、平台不认识、或平台解析器失败
   */
  async resolveText(text: string): Promise<ResolveOutcome> {
    const raw: string = extractUrl(text.trim());
    const url: string = raw === '' ? text.trim() : raw;
    if (url === '' || !url.startsWith('http')) {
      throw new ResolveError('没识别到链接，直接粘贴分享文案或链接都可以');
    }
    return this.resolveUrl(url);
  }

  async resolveUrl(url: string): Promise<ResolveOutcome> {
    const out = new ResolveOutcome();
    const ua: string = ConfigStore.get().userAgent;

    // 短链展开后平台可能变（t.cn → weibo.com，t.co → x.com）
    let finalUrl: string = url;
    try {
      finalUrl = await expandUrl(url, ua);
    } catch (e) {
      Logger.warn('短链展开失败，直接用原链接试');
    }
    out.finalUrl = finalUrl;

    let p: Platform = detectPlatform(finalUrl);
    if (p === Platform.UNKNOWN) {
      p = detectPlatform(url);  // 展开失败时回退到原链接的判定
    }
    out.platform = p;

    const r: Resolver | null = this.pick(p);
    if (r === null) {
      throw new ResolveError('不支持这个平台，当前支持抖音 / 微博 / X(Twitter)，TikTok 待完善');
    }
    Logger.info(`平台判定：${platformLabel(p)}`);
    out.result = await r.resolve(finalUrl);
    return out;
  }
}

export const ResolverRegistry: ResolverRegistryImpl = new ResolverRegistryImpl();
