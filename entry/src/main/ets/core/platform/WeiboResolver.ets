/**
 * 微博解析器。
 *
 * 走 web 端 ajax 接口 /ajax/statuses/show?id=<mblogid|idstr>，字段路径与 f2 的
 * apps/weibo/filter.py 对齐：
 *   idstr        → $.idstr          （纯数字 ID）
 *   mblogid      → $.mblogid        （字母数字短 ID，URL 里常见的那个）
 *   文案          → $.text_raw
 *   图片          → $.pic_infos[picId].largest.url，顺序按 $.pic_ids
 *   视频          → $.page_info.media_info.playback_list[*].play_info.{url,quality_class,bitrate}
 *
 * Cookie 是必须的：实测无 Cookie 和 Cookie 过期都返回
 *   {"ok":-100,"url":"https://weibo.com/login.php?..."}
 * 而 m.weibo.cn 的 container 接口直接 432（风控），所以没有游客路线可走。
 * 这里专门识别 ok:-100 并提示去更新 Cookie，而不是抛一个含义模糊的解析失败。
 *
 * 转发微博（retweeted_status）里的媒体也会被取到 —— 原微博没媒体时自动下潜一层。
 */

import { MediaItem, MediaType, ParseResult, Platform } from '../model/Models';
import { HttpClient, HttpResult } from '../net/HttpClient';
import { ConfigStore } from '../store/ConfigStore';
import { Logger } from '../util/Logger';
import { Resolver, ResolveError, emptyResult, matchFirst, sanitizeName } from './Resolver';

const SHOW_API: string = 'https://weibo.com/ajax/statuses/show';
const REFERER: string = 'https://weibo.com/';

interface WbPicSize {
  url?: string;
  width?: number;
  height?: number;
}

interface WbPicInfo {
  largest?: WbPicSize;
  original?: WbPicSize;
  mw2000?: WbPicSize;
  type?: string;
  video?: string;
}

interface WbUser {
  screen_name?: string;
  idstr?: string;
}

interface WbPlayInfo {
  url?: string;
  quality_class?: string;
  quality_label?: string;
  bitrate?: number;
  size?: number;
  mime?: string;
}

interface WbPlayback {
  play_info?: WbPlayInfo;
}

interface WbMediaInfo {
  playback_list?: WbPlayback[];
  stream_url?: string;
  stream_url_hd?: string;
  duration?: number;
}

interface WbPageInfo {
  type?: string;
  title?: string;
  media_info?: WbMediaInfo;
}

interface WbStatus {
  ok?: number;
  idstr?: string;
  mblogid?: string;
  text_raw?: string;
  text?: string;
  user?: WbUser;
  pic_ids?: string[];
  pic_infos?: Record<string, WbPicInfo>;
  page_info?: WbPageInfo;
  retweeted_status?: WbStatus;
}

export class WeiboResolver implements Resolver {
  platform: Platform = Platform.WEIBO;

  /**
   * 抠出微博 ID。show 接口同时接受 mblogid（字母数字）和 idstr（纯数字），
   * 所以两种都能直接用。
   */
  static extractWeiboId(url: string): string {
    // /detail/5012345678901234、/status/ABCdefGhi
    const byPath: string = matchFirst(url, [
      /weibo\.com\/detail\/(\d{10,25})/,
      /m\.weibo\.cn\/detail\/(\d{10,25})/,
      /m\.weibo\.cn\/status\/([A-Za-z0-9]{6,20})/,
      /weibo\.com\/\d+\/([A-Za-z0-9]{6,20})/,
      /weibo\.cn\/\d+\/([A-Za-z0-9]{6,20})/,
      /[?&]mid=(\d{10,25})/,
      /[?&]weibo_id=([A-Za-z0-9]{6,25})/,
    ]);
    if (byPath !== '') {
      return byPath;
    }
    return matchFirst(url, [/(\d{16,25})/]);
  }

  async resolve(url: string): Promise<ParseResult> {
    const id: string = WeiboResolver.extractWeiboId(url);
    if (id === '') {
      throw new ResolveError('链接里没找到微博 ID，确认形如 weibo.com/用户号/短ID 或 weibo.com/detail/数字');
    }

    const cfg = ConfigStore.get();
    const cookie: string = cfg.cookieWeibo;
    if (cookie === '') {
      throw new ResolveError('微博必须带 Cookie 才能解析（官方接口对游客直接跳登录），请到「设置」粘贴', true);
    }
    if (!cookie.includes('SUB=')) {
      Logger.warn('微博 Cookie 里没有 SUB，几乎肯定会被判为未登录');
    }

    const ua: string = cfg.userAgent;
    const reqUrl: string = `${SHOW_API}?id=${encodeURIComponent(id)}&locale=zh-CN&isGetLongText=true`;
    const headers: Record<string, string> = {
      'User-Agent': ua,
      'Referer': REFERER,
      'Cookie': cookie,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'x-requested-with': 'XMLHttpRequest',
    };

    Logger.info(`解析微博 ${id}`);
    const resp: HttpResult = await HttpClient.get(reqUrl, headers, true);
    if (!resp.ok()) {
      throw new ResolveError(`微博接口返回 ${resp.status}`, resp.status === 403 || resp.status === 401);
    }

    let d: WbStatus;
    try {
      d = JSON.parse(resp.body) as WbStatus;
    } catch (e) {
      throw new ResolveError('微博接口返回的不是 JSON，通常是被风控拦了，稍后再试', false);
    }

    // 实测的失效信号
    if (d.ok !== undefined && d.ok === -100) {
      throw new ResolveError('微博 Cookie 已失效（接口跳登录页），请重新登录 weibo.com 后复制 Cookie', true);
    }
    if (d.idstr === undefined && d.mblogid === undefined) {
      throw new ResolveError('微博没返回内容，可能已删除或仅对粉丝可见', false);
    }

    return this.toResult(d, ua);
  }

  private toResult(d: WbStatus, ua: string): ParseResult {
    const r: ParseResult = emptyResult(Platform.WEIBO);
    r.awemeId = d.mblogid !== undefined && d.mblogid !== '' ? d.mblogid
      : (d.idstr === undefined ? '' : d.idstr);
    r.author = d.user?.screen_name === undefined ? '未知用户' : d.user.screen_name;
    const raw: string = d.text_raw !== undefined ? d.text_raw : (d.text === undefined ? '' : d.text);
    r.title = sanitizeName(cleanDesc(raw, r.awemeId));

    const headers: Record<string, string> = {
      'User-Agent': ua,
      'Referer': REFERER,
    };

    // 先在本条里找媒体，找不到再下潜到被转发的原微博
    let filled: boolean = collect(r, d, headers);
    if (!filled && d.retweeted_status !== undefined && d.retweeted_status !== null) {
      Logger.info('本条无媒体，下潜到被转发的原微博');
      const rt: WbStatus = d.retweeted_status;
      if (r.title.startsWith('weibo_')) {
        const rtRaw: string = rt.text_raw !== undefined ? rt.text_raw : '';
        r.title = sanitizeName(cleanDesc(rtRaw, r.awemeId));
      }
      filled = collect(r, rt, headers);
    }
    if (!filled) {
      throw new ResolveError('这条微博只有文字，没有可下载的图片或视频');
    }
    Logger.info(`微博解析出 ${r.items.length} 条媒体`);
    return r;
  }
}

/** 把一条微博里的图片/视频塞进结果，返回是否有收获。 */
function collect(r: ParseResult, d: WbStatus, headers: Record<string, string>): boolean {
  const before: number = r.items.length;

  // 视频优先：有视频的微博一般不会同时有图集
  const pb: WbPlayback[] | undefined = d.page_info?.media_info?.playback_list;
  if (pb !== undefined && pb !== null && pb.length > 0) {
    const best: WbPlayInfo | null = pickBestPlay(pb);
    if (best !== null && best.url !== undefined && best.url !== '') {
      const item = new MediaItem();
      item.url = best.url;
      item.type = MediaType.VIDEO;
      item.name = r.title;
      item.ext = 'mp4';
      item.headers = headers;
      item.size = best.size === undefined ? 0 : best.size;
      r.items.push(item);
      const t: string | undefined = d.page_info?.title;
      if (t !== undefined && t !== '' && r.title.startsWith('weibo_')) {
        r.title = sanitizeName(t);
        item.name = r.title;
      }
      return true;
    }
  }
  // playback_list 为空时退到 stream_url_hd / stream_url
  const mi: WbMediaInfo | undefined = d.page_info?.media_info;
  if (mi !== undefined && mi !== null) {
    const su: string = mi.stream_url_hd !== undefined && mi.stream_url_hd !== ''
      ? mi.stream_url_hd : (mi.stream_url === undefined ? '' : mi.stream_url);
    if (su !== '') {
      const item = new MediaItem();
      item.url = su;
      item.type = MediaType.VIDEO;
      item.name = r.title;
      item.ext = 'mp4';
      item.headers = headers;
      r.items.push(item);
      return true;
    }
  }

  // 图片
  const infos: Record<string, WbPicInfo> | undefined = d.pic_infos;
  if (infos !== undefined && infos !== null) {
    const order: string[] = d.pic_ids !== undefined && d.pic_ids !== null && d.pic_ids.length > 0
      ? d.pic_ids : Object.keys(infos);
    let idx: number = 0;
    for (let i = 0; i < order.length; i++) {
      const info: WbPicInfo | undefined = infos[order[i]];
      if (info === undefined || info === null) {
        continue;
      }
      const u: string = pickBestPic(info);
      if (u === '') {
        continue;
      }
      idx++;
      const item = new MediaItem();
      item.url = u;
      item.type = MediaType.IMAGE;
      item.name = order.length > 1 ? `${r.title}_${pad2(idx)}` : r.title;
      item.ext = extOf(u, info.type === 'gif' ? 'gif' : 'jpg');
      item.headers = headers;
      item.size = info.largest?.width !== undefined ? 0 : 0;
      r.items.push(item);
      if (r.cover === '') {
        r.cover = u;
      }
    }
  }
  return r.items.length > before;
}

/** 清晰度排序：bitrate 优先，没有 bitrate 时按 quality_class 的常见档位排。 */
function qualityRank(q: string): number {
  switch (q.toLowerCase()) {
    case 'fhd': return 5;
    case 'hd': return 4;
    case 'sd': return 3;
    case 'ld': return 2;
    default: return 1;
  }
}

function pickBestPlay(list: WbPlayback[]): WbPlayInfo | null {
  let best: WbPlayInfo | null = null;
  let bestScore: number = -1;
  for (let i = 0; i < list.length; i++) {
    const pi: WbPlayInfo | undefined = list[i].play_info;
    if (pi === undefined || pi === null || pi.url === undefined || pi.url === '') {
      continue;
    }
    // m3u8 跳过，手机端不做转封装
    if (pi.url.includes('.m3u8')) {
      continue;
    }
    const br: number = pi.bitrate === undefined ? 0 : pi.bitrate;
    const score: number = br > 0 ? br : qualityRank(pi.quality_class === undefined ? '' : pi.quality_class);
    if (score > bestScore) {
      bestScore = score;
      best = pi;
    }
  }
  return best;
}

/** largest > mw2000 > original。 */
function pickBestPic(info: WbPicInfo): string {
  const cands: Array<WbPicSize | undefined> = [info.largest, info.mw2000, info.original];
  for (let i = 0; i < cands.length; i++) {
    const c: WbPicSize | undefined = cands[i];
    if (c !== undefined && c !== null && c.url !== undefined && c.url !== '') {
      return c.url;
    }
  }
  return '';
}

/** 微博文案里的话题、@、超链接标记去掉，只留正文当文件名。 */
function cleanDesc(raw: string, id: string): string {
  let s: string = raw
    .replace(/https?:\/\/\S+/g, ' ')
    .replace(/#([^#]{1,30})#/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
  if (s.length > 50) {
    s = s.substring(0, 50);
  }
  return s === '' ? `weibo_${id}` : s;
}

function extOf(url: string, fallback: string): string {
  const q: number = url.indexOf('?');
  const path: string = q < 0 ? url : url.substring(0, q);
  const dot: number = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/')) {
    return fallback;
  }
  const ext: string = path.substring(dot + 1).toLowerCase();
  return ext.length >= 2 && ext.length <= 4 ? ext : fallback;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}
