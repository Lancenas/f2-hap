/**
 * 链接识别与短链展开。
 *
 * 正则与 macOS 版 PlatformDetector.PATTERNS 一致，额外做两件桌面版没做的事：
 *   1. 从任意文本里抠出 URL —— 手机上用户多数是从分享面板粘贴一整段
 *      「xx 复制此链接，打开抖音搜索…… https://v.douyin.com/xxx/ ……」。
 *   2. 短链展开 —— v.douyin.com / t.cn / vm.tiktok.com / t.co 都要跟 302。
 */

import { Platform } from '../model/Models';
import { HttpClient } from '../net/HttpClient';
import { Logger } from '../util/Logger';

/** 从一段文本里抓第一个 http(s) 链接。 */
export function extractUrl(text: string): string {
  const m: RegExpMatchArray | null = text.match(/https?:\/\/[^\s\u4e00-\u9fa5，。、！？；："'）】]+/);
  if (m === null || m.length === 0) {
    return '';
  }
  // 结尾常粘上中文标点或多余的 /
  return m[0].replace(/[.,;:!?)\]】）]+$/, '');
}

/** 抓出文本里所有链接，供批量粘贴使用。 */
export function extractUrls(text: string): string[] {
  const re = /https?:\/\/[^\s\u4e00-\u9fa5，。、！？；："'）】]+/g;
  const out: string[] = [];
  let m: RegExpExecArray | null = re.exec(text);
  while (m !== null) {
    out.push(m[0].replace(/[.,;:!?)\]】）]+$/, ''));
    m = re.exec(text);
  }
  return out;
}

export function detectPlatform(url: string): Platform {
  const u: string = url.toLowerCase();
  if (u.includes('douyin.com') || u.includes('iesdouyin.com')) {
    return Platform.DOUYIN;
  }
  if (u.includes('tiktok.com')) {
    return Platform.TIKTOK;
  }
  if (u.includes('twitter.com') || u.includes('x.com') || u.includes('t.co/')) {
    return Platform.TWITTER;
  }
  if (u.includes('weibo.com') || u.includes('weibo.cn') || u.includes('t.cn/')) {
    return Platform.WEIBO;
  }
  return Platform.UNKNOWN;
}

/** 是否需要跟 302 才能拿到作品 ID。 */
export function isShortLink(url: string): boolean {
  const u: string = url.toLowerCase();
  return u.includes('v.douyin.com') || u.includes('vm.tiktok.com') ||
    u.includes('vt.tiktok.com') || u.includes('t.cn/') || u.includes('t.co/');
}

/** 短链就展开，长链原样返回。 */
export async function expandUrl(url: string, userAgent: string): Promise<string> {
  if (!isShortLink(url)) {
    return url;
  }
  const headers: Record<string, string> = {
    'User-Agent': userAgent,
    'Accept': 'text/html,application/xhtml+xml,*/*',
  };
  const finalUrl: string = await HttpClient.resolveFinalUrl(url, headers);
  Logger.info(`短链展开：${url} → ${finalUrl.substring(0, 120)}`);
  return finalUrl;
}
