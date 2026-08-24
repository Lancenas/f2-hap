/**
 * 抖音解析器。
 *
 * 走签名后的 web 接口 /aweme/v1/web/aweme/detail/，这是当前唯一可靠的路径：
 * iesdouyin 分享页的 _ROUTER_DATA 已被抖音清空（loaderData 里 item_list 为空数组），
 * 纯抓 HTML 拿不到直链了。
 *
 * 已实测通过（Node 侧用同一份 ABogus.ets 验证）：
 *   - a_bogus 由本机 ArkTS 生成即可被服务端接受，status_code=0
 *   - msToken 用随机 126 位 + '=='（假值）就够，无需再移植 msToken 换取接口
 *   - Cookie 里必须有 ttwid，否则 aweme_detail 返回 null
 *   - 直链回源需要 Referer: https://www.douyin.com/ 且 UA 与签名时一致
 *   - CDN 支持 Range（返回 206），所以下载器可以断点续传
 */

import { MediaItem, MediaType, ParseResult, Platform } from '../model/Models';
import { HttpClient, HttpResult } from '../net/HttpClient';
import { ConfigStore } from '../store/ConfigStore';
import { Logger } from '../util/Logger';
import { ABogus } from '../crypto/ABogus';
import {
  Resolver, ResolveError, buildQuery, emptyResult, falseMsToken, matchFirst, sanitizeName,
} from './Resolver';

const DETAIL_API: string = 'https://www.douyin.com/aweme/v1/web/aweme/detail/';
const REFERER: string = 'https://www.douyin.com/';

/** 接口响应结构，只声明用得到的字段。 */
interface DyPlayAddr {
  url_list?: string[];
  data_size?: number;
}

interface DyBitRate {
  bit_rate?: number;
  play_addr?: DyPlayAddr;
  format?: string;
}

interface DyUrlList {
  url_list?: string[];
}

interface DyVideo {
  play_addr?: DyPlayAddr;
  cover?: DyUrlList;
  bit_rate?: DyBitRate[];
  duration?: number;
}

interface DyAuthor {
  nickname?: string;
  unique_id?: string;
  short_id?: string;
}

interface DyImage {
  url_list?: string[];
}

interface DyMusic {
  title?: string;
  play_url?: DyPlayAddr;
}

interface DyAwemeDetail {
  aweme_id?: string;
  desc?: string;
  aweme_type?: number;
  author?: DyAuthor;
  video?: DyVideo;
  images?: DyImage[];
  music?: DyMusic;
}

interface DyDetailResp {
  status_code?: number;
  status_msg?: string;
  aweme_detail?: DyAwemeDetail;
}

export class DouyinResolver implements Resolver {
  platform: Platform = Platform.DOUYIN;

  /** 从各种形态的抖音链接里抠出作品 ID。 */
  static extractAwemeId(url: string): string {
    return matchFirst(url, [
      /\/video\/(\d{15,25})/,
      /\/share\/video\/(\d{15,25})/,
      /\/note\/(\d{15,25})/,
      /\/share\/note\/(\d{15,25})/,
      /\/slides\/(\d{15,25})/,
      /modal_id=(\d{15,25})/,
      /aweme_id=(\d{15,25})/,
      /(\d{18,22})/,
    ]);
  }

  /**
   * 构造 detail 接口参数。
   *
   * 顺序必须固定：a_bogus 是对拼好的整串签名的，任何重排都会导致校验失败。
   * 字段集与 f2 的 BaseRequestModel + PostDetail 一致。
   */
  private buildParams(awemeId: string): string {
    return buildQuery([
      ['device_platform', 'webapp'],
      ['aid', '6383'],
      ['channel', 'channel_pc_web'],
      ['pc_client_type', '1'],
      ['publish_video_strategy_type', '2'],
      ['pc_libra_divert', 'Windows'],
      ['version_code', '290100'],
      ['version_name', '29.1.0'],
      ['cookie_enabled', 'true'],
      ['screen_width', '1920'],
      ['screen_height', '1080'],
      ['browser_language', 'zh-CN'],
      ['browser_platform', 'Win32'],
      ['browser_name', 'Edge'],
      ['browser_version', '130.0.0.0'],
      ['browser_online', 'true'],
      ['engine_name', 'Blink'],
      ['engine_version', '130.0.0.0'],
      ['os_name', 'Windows'],
      ['os_version', '10'],
      ['cpu_core_num', '12'],
      ['device_memory', '8'],
      ['platform', 'PC'],
      ['downlink', '10'],
      ['effective_type', '4g'],
      ['round_trip_time', '100'],
      ['aweme_id', awemeId],
      ['msToken', falseMsToken()],
    ]);
  }

  async resolve(url: string): Promise<ParseResult> {
    const awemeId: string = DouyinResolver.extractAwemeId(url);
    if (awemeId === '') {
      throw new ResolveError('链接里没找到抖音作品 ID，确认是作品链接而不是主页链接');
    }

    const cfg = ConfigStore.get();
    const cookie: string = cfg.cookieDouyin;
    if (cookie === '') {
      throw new ResolveError('抖音需要 Cookie 才能解析，请到「设置」粘贴浏览器 Cookie', true);
    }
    if (!cookie.includes('ttwid=')) {
      Logger.warn('抖音 Cookie 里没有 ttwid，解析可能返回空');
    }

    const params: string = this.buildParams(awemeId);
    // 签名与请求头必须用同一个 UA
    const ua: string = cfg.userAgent;
    const ab = new ABogus(ua, '', [0, 1, 14]);
    const signed = ab.generate(params, 'GET');
    const reqUrl: string = `${DETAIL_API}?${params}&a_bogus=${encodeURIComponent(signed.abogus)}`;

    const headers: Record<string, string> = {
      'User-Agent': ua,
      'Referer': REFERER,
      'Cookie': cookie,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    };

    Logger.info(`解析抖音作品 ${awemeId}`);
    const resp: HttpResult = await HttpClient.get(reqUrl, headers, true);
    if (!resp.ok()) {
      throw new ResolveError(`抖音接口返回 ${resp.status}，可能是 Cookie 失效或被限流`, resp.status === 403);
    }

    let parsed: DyDetailResp;
    try {
      parsed = JSON.parse(resp.body) as DyDetailResp;
    } catch (e) {
      throw new ResolveError('抖音接口返回的不是 JSON，通常意味着 Cookie 已失效', true);
    }

    const detail: DyAwemeDetail | undefined = parsed.aweme_detail;
    if (detail === undefined || detail === null) {
      const code: number = parsed.status_code === undefined ? -1 : parsed.status_code;
      throw new ResolveError(`抖音未返回作品数据（status_code=${code}），请更新 Cookie 后重试`, true);
    }

    return this.toResult(detail, ua);
  }

  private toResult(d: DyAwemeDetail, ua: string): ParseResult {
    const r: ParseResult = emptyResult(Platform.DOUYIN);
    r.awemeId = d.aweme_id === undefined ? '' : d.aweme_id;
    r.title = sanitizeName(d.desc === undefined || d.desc === '' ? `douyin_${r.awemeId}` : d.desc);
    r.author = d.author === undefined || d.author.nickname === undefined ? '未知作者' : d.author.nickname;

    const cover: string[] | undefined = d.video?.cover?.url_list;
    r.cover = cover !== undefined && cover.length > 0 ? cover[0] : '';

    // 直链回源必须带这两个头，否则 403
    const mediaHeaders: Record<string, string> = {
      'User-Agent': ua,
      'Referer': REFERER,
    };

    const images: DyImage[] | undefined = d.images;
    if (images !== undefined && images !== null && images.length > 0) {
      // 图集：每张图一条 MediaItem
      for (let i = 0; i < images.length; i++) {
        const list: string[] | undefined = images[i].url_list;
        if (list === undefined || list.length === 0) {
          continue;
        }
        const item = new MediaItem();
        item.url = list[list.length - 1];  // 最后一个通常是最高清
        item.type = MediaType.IMAGE;
        item.name = `${r.title}_${pad2(i + 1)}`;
        item.ext = 'jpg';
        item.headers = mediaHeaders;
        r.items.push(item);
      }
      if (r.items.length > 0) {
        Logger.info(`图集，共 ${r.items.length} 张`);
        return r;
      }
    }

    // 视频：优先码率最高的，回退到 play_addr
    const best: DyPlayAddr | null = pickBestVideo(d.video);
    if (best === null || best.url_list === undefined || best.url_list.length === 0) {
      throw new ResolveError('作品里没有可下载的视频或图片直链');
    }
    const item = new MediaItem();
    item.url = best.url_list[0];
    item.type = MediaType.VIDEO;
    item.name = r.title;
    item.ext = 'mp4';
    item.headers = mediaHeaders;
    item.size = best.data_size === undefined ? 0 : best.data_size;
    r.items.push(item);
    return r;
  }
}

/** bit_rate 里挑码率最高的；没有就用 play_addr。 */
function pickBestVideo(v: DyVideo | undefined): DyPlayAddr | null {
  if (v === undefined || v === null) {
    return null;
  }
  const rates: DyBitRate[] | undefined = v.bit_rate;
  if (rates !== undefined && rates !== null && rates.length > 0) {
    let bestIdx: number = -1;
    let bestRate: number = -1;
    for (let i = 0; i < rates.length; i++) {
      const pa: DyPlayAddr | undefined = rates[i].play_addr;
      if (pa === undefined || pa.url_list === undefined || pa.url_list.length === 0) {
        continue;
      }
      const br: number = rates[i].bit_rate === undefined ? 0 : (rates[i].bit_rate as number);
      if (br > bestRate) {
        bestRate = br;
        bestIdx = i;
      }
    }
    if (bestIdx >= 0) {
      const pa: DyPlayAddr | undefined = rates[bestIdx].play_addr;
      if (pa !== undefined) {
        return pa;
      }
    }
  }
  return v.play_addr === undefined ? null : v.play_addr;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}
