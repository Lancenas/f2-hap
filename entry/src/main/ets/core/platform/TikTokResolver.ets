/**
 * TikTok 解析器 —— 尽力而为，当前版本不保证可用。
 *
 * 为什么：抖音用 a_bogus（已完整移植，SM3 + RC4 + 自定义 base64），但 TikTok 用的是
 * 另一套 XBogus + 设备注册（device_id / iid 要先走 register 接口换），这套还没移植。
 *
 * 三条免签名路线都实测失败：
 *   1. 分享页 SSR —— 返回 44KB 的 webmssdk 验证壳，没有
 *      __UNIVERSAL_DATA_FOR_REHYDRATION__，拿不到 itemStruct
 *   2. /api/item/detail/?itemId=… —— HTTP 200 但 body 长度 0
 *   3. api16-normal…/aweme/v1/feed/ —— 429 ratelimit triggered
 *
 * 所以这里保留一次 best-effort 尝试（网络环境/风控策略是会变的，能过就直接用），
 * 失败时抛一条说清原因的错误，而不是让用户对着「解析失败」猜。
 */

import { MediaItem, MediaType, ParseResult, Platform } from '../model/Models';
import { HttpClient, HttpResult } from '../net/HttpClient';
import { ConfigStore } from '../store/ConfigStore';
import { Logger } from '../util/Logger';
import { Resolver, ResolveError, emptyResult, matchFirst, sanitizeName } from './Resolver';

const SSR_TAG_START: string = '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__"';
const DETAIL_API: string = 'https://www.tiktok.com/api/item/detail/';

interface TtAuthor {
  uniqueId?: string;
  nickname?: string;
}

interface TtVideo {
  playAddr?: string;
  downloadAddr?: string;
  cover?: string;
}

interface TtImage {
  imageURL?: TtImageUrl;
}

interface TtImageUrl {
  urlList?: string[];
}

interface TtImagePost {
  images?: TtImage[];
}

interface TtItemStruct {
  id?: string;
  desc?: string;
  author?: TtAuthor;
  video?: TtVideo;
  imagePost?: TtImagePost;
}

interface TtItemInfo {
  itemStruct?: TtItemStruct;
}

interface TtVideoDetail {
  statusCode?: number;
  statusMsg?: string;
  itemInfo?: TtItemInfo;
}

interface TtDefaultScope {
  webappVideoDetail?: TtVideoDetail;
}

interface TtUniversalData {
  __DEFAULT_SCOPE__?: TtDefaultScope;
}

interface TtDetailResp {
  statusCode?: number;
  itemInfo?: TtItemInfo;
}

export class TikTokResolver implements Resolver {
  platform: Platform = Platform.TIKTOK;

  static extractItemId(url: string): string {
    return matchFirst(url, [
      /\/video\/(\d{15,25})/,
      /\/photo\/(\d{15,25})/,
      /[?&]item_id=(\d{15,25})/,
      /(\d{18,22})/,
    ]);
  }

  async resolve(url: string): Promise<ParseResult> {
    const itemId: string = TikTokResolver.extractItemId(url);
    const cfg = ConfigStore.get();
    const ua: string = cfg.userAgent;
    const cookie: string = cfg.cookieTiktok;

    Logger.info(`尝试解析 TikTok ${itemId === '' ? url : itemId}（免签名路线，成功率有限）`);

    // 路线 1：分享页 SSR
    const viaSsr: ParseResult | null = await this.trySsr(url, ua, cookie);
    if (viaSsr !== null) {
      return viaSsr;
    }

    // 路线 2：web detail 接口
    if (itemId !== '') {
      const viaApi: ParseResult | null = await this.tryDetailApi(itemId, ua, cookie);
      if (viaApi !== null) {
        return viaApi;
      }
    }

    throw new ResolveError(
      'TikTok 当前无法解析：官方接口要求 XBogus 签名与设备注册，本版本尚未移植（抖音走的 a_bogus 是另一套算法）。'
      + '建议先用抖音链接，或在「设置」里填入有效的 TikTok Cookie 后重试。',
      cookie === '');
  }

  private async trySsr(url: string, ua: string, cookie: string): Promise<ParseResult | null> {
    const headers: Record<string, string> = {
      'User-Agent': ua,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
    };
    if (cookie !== '') {
      headers['Cookie'] = cookie;
    }
    const resp: HttpResult = await HttpClient.get(url, headers, true);
    if (!resp.ok()) {
      Logger.warn(`TikTok 分享页返回 ${resp.status}`);
      return null;
    }
    const json: string = extractSsrJson(resp.body);
    if (json === '') {
      Logger.warn('TikTok 分享页没有 SSR 数据（大概率是风控验证壳）');
      return null;
    }
    let data: TtUniversalData;
    try {
      // 原始 JSON 键含连字符（webapp.video-detail），ArkTS 禁止索引访问，
      // 先替换成合法标识符字段名再解析。
      const fixed: string = json.replace(/"webapp\.video-detail"/g, '"webappVideoDetail"');
      data = JSON.parse(fixed) as TtUniversalData;
    } catch (e) {
      return null;
    }
    const vd: TtVideoDetail | undefined = data.__DEFAULT_SCOPE__?.webappVideoDetail;
    if (vd === undefined || vd === null) {
      return null;
    }
    if (vd.statusCode !== undefined && vd.statusCode !== 0) {
      Logger.warn(`TikTok SSR statusCode=${vd.statusCode} ${vd.statusMsg === undefined ? '' : vd.statusMsg}`);
      return null;
    }
    const it: TtItemStruct | undefined = vd.itemInfo?.itemStruct;
    return it === undefined || it === null ? null : this.toResult(it, ua, cookie);
  }

  private async tryDetailApi(itemId: string, ua: string, cookie: string): Promise<ParseResult | null> {
    const reqUrl: string = `${DETAIL_API}?itemId=${itemId}&aid=1988&app_name=tiktok_web`
      + '&device_platform=web_pc&region=US&language=en&channel=tiktok_web&os=windows'
      + '&browser_language=en-US&browser_platform=Win32&browser_name=Mozilla&browser_online=true'
      + '&cookie_enabled=true&screen_width=1920&screen_height=1080&from_page=video';
    const headers: Record<string, string> = {
      'User-Agent': ua,
      'Referer': 'https://www.tiktok.com/',
      'Accept': 'application/json, text/plain, */*',
    };
    if (cookie !== '') {
      headers['Cookie'] = cookie;
    }
    const resp: HttpResult = await HttpClient.get(reqUrl, headers, true);
    // 实测：无签名时 HTTP 200 但 body 为空
    if (!resp.ok() || resp.body.trim() === '') {
      Logger.warn(`TikTok detail 接口无有效响应（status=${resp.status}, len=${resp.body.length}）`);
      return null;
    }
    let d: TtDetailResp;
    try {
      d = JSON.parse(resp.body) as TtDetailResp;
    } catch (e) {
      return null;
    }
    const it: TtItemStruct | undefined = d.itemInfo?.itemStruct;
    return it === undefined || it === null ? null : this.toResult(it, ua, cookie);
  }

  private toResult(it: TtItemStruct, ua: string, cookie: string): ParseResult {
    const r: ParseResult = emptyResult(Platform.TIKTOK);
    r.awemeId = it.id === undefined ? '' : it.id;
    r.author = it.author?.nickname !== undefined && it.author.nickname !== ''
      ? it.author.nickname
      : (it.author?.uniqueId === undefined ? 'tiktok' : it.author.uniqueId);
    const desc: string = it.desc === undefined || it.desc === '' ? `tiktok_${r.awemeId}` : it.desc;
    r.title = sanitizeName(desc);
    r.cover = it.video?.cover === undefined ? '' : it.video.cover;

    // TikTok 直链回源要带 Referer，且很多情况下还要 Cookie
    const headers: Record<string, string> = {
      'User-Agent': ua,
      'Referer': 'https://www.tiktok.com/',
    };
    if (cookie !== '') {
      headers['Cookie'] = cookie;
    }

    const imgs: TtImage[] | undefined = it.imagePost?.images;
    if (imgs !== undefined && imgs !== null && imgs.length > 0) {
      for (let i = 0; i < imgs.length; i++) {
        const list: string[] | undefined = imgs[i].imageURL?.urlList;
        if (list === undefined || list.length === 0) {
          continue;
        }
        const item = new MediaItem();
        item.url = list[0];
        item.type = MediaType.IMAGE;
        item.name = `${r.title}_${i + 1 < 10 ? '0' : ''}${i + 1}`;
        item.ext = 'jpg';
        item.headers = headers;
        r.items.push(item);
      }
      if (r.items.length > 0) {
        return r;
      }
    }

    const dl: string = it.video?.downloadAddr !== undefined && it.video.downloadAddr !== ''
      ? it.video.downloadAddr
      : (it.video?.playAddr === undefined ? '' : it.video.playAddr);
    if (dl === '') {
      throw new ResolveError('TikTok 作品里没有可下载的直链');
    }
    const item = new MediaItem();
    item.url = dl;
    item.type = MediaType.VIDEO;
    item.name = r.title;
    item.ext = 'mp4';
    item.headers = headers;
    r.items.push(item);
    return r;
  }
}

/** 从 HTML 里抠 __UNIVERSAL_DATA_FOR_REHYDRATION__ 的 JSON 正文。 */
function extractSsrJson(html: string): string {
  const start: number = html.indexOf(SSR_TAG_START);
  if (start < 0) {
    return '';
  }
  const gt: number = html.indexOf('>', start);
  if (gt < 0) {
    return '';
  }
  const end: number = html.indexOf('</script>', gt);
  if (end < 0) {
    return '';
  }
  return html.substring(gt + 1, end).trim();
}
