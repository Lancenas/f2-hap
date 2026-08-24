/**
 * X / Twitter 解析器。
 *
 * 两条路线，都不需要用户 Cookie（实测确认）：
 *
 *   主路线 —— syndication 接口 cdn.syndication.twimg.com/tweet-result
 *     官方给第三方嵌入推文用的，无需 bearer / guest token，返回 mediaDetails[]。
 *     实测 id=1349129669258448897 拿到 photo，id=719944021058060289 拿到 4 档
 *     video variants（含 application/x-mpegURL 和 3 档 video/mp4）。
 *
 *   兜底路线 —— GraphQL TweetResultByRestId + guest token
 *     先 POST /1.1/guest/activate.json 换 guest_token（实测 200），再带
 *     Bearer + x-guest-token 请求 GraphQL。queryId 是会变的，当前实测可用的是
 *     0hWvDhmW8YQ-S_ib3azIrw；另外几个候选返回 422/404，所以只留这一个。
 *     推文不存在时返回 {"data":{"tweetResult":{}}}，据此判定「已删除」。
 *
 * 视频取 content_type == video/mp4 里 bitrate 最高的那一档，m3u8 直接跳过
 * （手机端没有本地转封装能力，拉下来也播不了）。
 */

import { MediaItem, MediaType, ParseResult, Platform } from '../model/Models';
import { HttpClient, HttpResult } from '../net/HttpClient';
import { ConfigStore } from '../store/ConfigStore';
import { Logger } from '../util/Logger';
import { Resolver, ResolveError, emptyResult, matchFirst, sanitizeName } from './Resolver';

const SYN_API: string = 'https://cdn.syndication.twimg.com/tweet-result';
const GUEST_API: string = 'https://api.twitter.com/1.1/guest/activate.json';
const GQL_QUERY_ID: string = '0hWvDhmW8YQ-S_ib3azIrw';
const GQL_API: string = `https://api.twitter.com/graphql/${GQL_QUERY_ID}/TweetResultByRestId`;

/** 公开的 web 端 bearer，长期未变，非用户凭证。 */
const PUBLIC_BEARER: string =
  'AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';

const GQL_FEATURES: string = '{"creator_subscriptions_tweet_preview_api_enabled":true,'
  + '"tweetypie_unmention_optimization_enabled":true,"responsive_web_edit_tweet_api_enabled":true,'
  + '"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,'
  + '"longform_notetweets_consumption_enabled":true,'
  + '"responsive_web_twitter_article_tweet_consumption_enabled":false,"tweet_awards_web_tipping_enabled":false,'
  + '"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,'
  + '"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,'
  + '"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,'
  + '"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,'
  + '"responsive_web_media_download_video_enabled":false,'
  + '"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,'
  + '"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_enhance_cards_enabled":false}';

// ---------- syndication 响应 ----------

interface TwVariant {
  content_type?: string;
  bitrate?: number;
  url?: string;
}

interface TwVideoInfo {
  variants?: TwVariant[];
  duration_millis?: number;
}

interface TwMediaDetail {
  type?: string;
  media_url_https?: string;
  video_info?: TwVideoInfo;
}

interface TwUser {
  screen_name?: string;
  name?: string;
}

interface TwSynResp {
  id_str?: string;
  text?: string;
  user?: TwUser;
  mediaDetails?: TwMediaDetail[];
  __typename?: string;
}

// ---------- GraphQL 响应 ----------

interface TwEntities {
  media?: TwMediaDetail[];
}

interface TwLegacy {
  full_text?: string;
  id_str?: string;
  extended_entities?: TwEntities;
  entities?: TwEntities;
}

interface TwUserCore {
  screen_name?: string;
  name?: string;
}

interface TwUserResult {
  legacy?: TwUserCore;
  core?: TwUserCore;
}

interface TwUserResults {
  result?: TwUserResult;
}

interface TwCore {
  user_results?: TwUserResults;
}

interface TwTweetResult {
  __typename?: string;
  legacy?: TwLegacy;
  core?: TwCore;
  tweet?: TwTweetResult;
}

interface TwTweetResultWrap {
  result?: TwTweetResult;
}

interface TwGqlData {
  tweetResult?: TwTweetResultWrap;
}

interface TwGqlResp {
  data?: TwGqlData;
}

interface TwGuestResp {
  guest_token?: string;
}

export class TwitterResolver implements Resolver {
  platform: Platform = Platform.TWITTER;

  /** twitter.com / x.com 的 /status/<id>，也兼容裸 ID。 */
  static extractTweetId(url: string): string {
    return matchFirst(url, [
      /\/status(?:es)?\/(\d{5,25})/,
      /\/i\/web\/status\/(\d{5,25})/,
      /^\s*(\d{10,25})\s*$/,
    ]);
  }

  /**
   * syndication 的弱校验 token，由 id 推导。
   * 官方前端算法：((id / 1e15) * PI) 转 36 进制后去掉 0 和小数点。
   */
  private static synToken(id: string): string {
    const n: number = Number.parseFloat(id);
    if (Number.isNaN(n)) {
      return '0';
    }
    return ((n / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '');
  }

  async resolve(url: string): Promise<ParseResult> {
    const id: string = TwitterResolver.extractTweetId(url);
    if (id === '') {
      throw new ResolveError('链接里没找到推文 ID，确认形如 x.com/用户名/status/数字');
    }
    Logger.info(`解析推文 ${id}`);

    const ua: string = ConfigStore.get().userAgent;

    // 主路线
    const viaSyn: ParseResult | null = await this.trySyndication(id, ua);
    if (viaSyn !== null) {
      return viaSyn;
    }
    Logger.warn('syndication 路线没拿到数据，改走 GraphQL guest token');

    // 兜底路线
    const viaGql: ParseResult | null = await this.tryGraphql(id, ua);
    if (viaGql !== null) {
      return viaGql;
    }
    throw new ResolveError('两条路线都没拿到推文内容：可能已删除、设为私密，或需要登录查看');
  }

  private async trySyndication(id: string, ua: string): Promise<ParseResult | null> {
    const reqUrl: string = `${SYN_API}?id=${id}&lang=zh-cn&token=${TwitterResolver.synToken(id)}`;
    const headers: Record<string, string> = {
      'User-Agent': ua,
      'Accept': 'application/json',
      'Referer': 'https://platform.twitter.com/',
    };
    const resp: HttpResult = await HttpClient.get(reqUrl, headers, true);
    if (!resp.ok()) {
      Logger.warn(`syndication 返回 ${resp.status}`);
      return null;
    }
    let d: TwSynResp;
    try {
      d = JSON.parse(resp.body) as TwSynResp;
    } catch (e) {
      return null;
    }
    const media: TwMediaDetail[] | undefined = d.mediaDetails;
    if (media === undefined || media === null || media.length === 0) {
      // 纯文字推文也算解析成功，但没东西可下 —— 明确告诉用户，而不是报解析失败
      if (d.user !== undefined) {
        throw new ResolveError('这条推文只有文字，没有可下载的图片或视频');
      }
      return null;
    }
    const r: ParseResult = emptyResult(Platform.TWITTER);
    r.awemeId = d.id_str === undefined ? id : d.id_str;
    r.author = d.user?.name === undefined || d.user.name === ''
      ? (d.user?.screen_name === undefined ? 'twitter' : d.user.screen_name)
      : d.user.name;
    r.title = sanitizeName(cleanTweetText(d.text === undefined ? '' : d.text, r.awemeId));
    return fillMedia(r, media, ua);
  }

  private async tryGraphql(id: string, ua: string): Promise<ParseResult | null> {
    const token: string = await this.guestToken(ua);
    if (token === '') {
      return null;
    }
    const variables: string =
      `{"tweetId":"${id}","withCommunity":false,"includePromotedContent":false,"withVoice":false}`;
    const reqUrl: string = `${GQL_API}?variables=${encodeURIComponent(variables)}`
      + `&features=${encodeURIComponent(GQL_FEATURES)}`
      + `&fieldToggles=${encodeURIComponent('{"withArticleRichContentState":false}')}`;
    const headers: Record<string, string> = {
      'Authorization': `Bearer ${PUBLIC_BEARER}`,
      'x-guest-token': token,
      'User-Agent': ua,
      'Content-Type': 'application/json',
      'x-twitter-active-user': 'yes',
      'x-twitter-client-language': 'zh-cn',
      'Accept': '*/*',
    };
    const resp: HttpResult = await HttpClient.get(reqUrl, headers, true);
    if (!resp.ok()) {
      Logger.warn(`GraphQL 返回 ${resp.status}`);
      return null;
    }
    let d: TwGqlResp;
    try {
      d = JSON.parse(resp.body) as TwGqlResp;
    } catch (e) {
      return null;
    }
    let res: TwTweetResult | undefined = d.data?.tweetResult?.result;
    if (res === undefined || res === null || res.__typename === undefined) {
      // {"data":{"tweetResult":{}}} —— 实测这是「推文不存在/已删除」的返回
      return null;
    }
    if (res.tweet !== undefined && res.tweet !== null) {
      res = res.tweet;  // TweetWithVisibilityResults 会多包一层
    }
    const lg: TwLegacy | undefined = res.legacy;
    if (lg === undefined || lg === null) {
      return null;
    }
    const userRes: TwUserResult | undefined = res.core?.user_results?.result;
    const nick: string = userRes?.legacy?.name !== undefined ? (userRes.legacy.name as string)
      : (userRes?.core?.name !== undefined ? (userRes.core.name as string) : 'twitter');

    const r: ParseResult = emptyResult(Platform.TWITTER);
    r.awemeId = lg.id_str === undefined ? id : lg.id_str;
    r.author = nick;
    r.title = sanitizeName(cleanTweetText(lg.full_text === undefined ? '' : lg.full_text, r.awemeId));

    const media: TwMediaDetail[] | undefined =
      lg.extended_entities?.media !== undefined ? lg.extended_entities.media : lg.entities?.media;
    if (media === undefined || media === null || media.length === 0) {
      throw new ResolveError('这条推文只有文字，没有可下载的图片或视频');
    }
    return fillMedia(r, media, ua);
  }

  private async guestToken(ua: string): Promise<string> {
    const headers: Record<string, string> = {
      'Authorization': `Bearer ${PUBLIC_BEARER}`,
      'User-Agent': ua,
      'Content-Length': '0',
    };
    const resp: HttpResult = await HttpClient.post(GUEST_API, headers, '');
    if (!resp.ok()) {
      Logger.warn(`换取 guest_token 失败：${resp.status}`);
      return '';
    }
    try {
      const d = JSON.parse(resp.body) as TwGuestResp;
      return d.guest_token === undefined ? '' : d.guest_token;
    } catch (e) {
      return '';
    }
  }
}

/** 把 mediaDetails / extended_entities.media 转成 MediaItem 列表。 */
function fillMedia(r: ParseResult, media: TwMediaDetail[], ua: string): ParseResult {
  const headers: Record<string, string> = {
    'User-Agent': ua,
    'Referer': 'https://x.com/',
  };
  let picIdx: number = 0;
  let vidIdx: number = 0;
  for (let i = 0; i < media.length; i++) {
    const m: TwMediaDetail = media[i];
    const type: string = m.type === undefined ? '' : m.type;
    if (type === 'photo') {
      const u: string = m.media_url_https === undefined ? '' : m.media_url_https;
      if (u === '') {
        continue;
      }
      picIdx++;
      const item = new MediaItem();
      // ?name=orig 拿原图，Twitter 默认给的是压过的
      item.url = u.includes('?') ? `${u}&name=orig` : `${u}?name=orig`;
      item.type = MediaType.IMAGE;
      item.name = media.length > 1 ? `${r.title}_${pad2(picIdx)}` : r.title;
      item.ext = extOf(u, 'jpg');
      item.headers = headers;
      r.items.push(item);
      if (r.cover === '') {
        r.cover = u;
      }
      continue;
    }
    // video / animated_gif
    const best: TwVariant | null = pickBestMp4(m.video_info);
    if (best === null || best.url === undefined) {
      continue;
    }
    vidIdx++;
    const item = new MediaItem();
    item.url = best.url;
    item.type = MediaType.VIDEO;
    item.name = media.length > 1 ? `${r.title}_${pad2(vidIdx)}` : r.title;
    item.ext = 'mp4';
    item.headers = headers;
    r.items.push(item);
    if (r.cover === '' && m.media_url_https !== undefined) {
      r.cover = m.media_url_https;
    }
  }
  if (r.items.length === 0) {
    throw new ResolveError('推文里的媒体只有 m3u8 流，当前版本不支持直播/流式内容');
  }
  Logger.info(`推文解析出 ${r.items.length} 条媒体`);
  return r;
}

/** 只要 video/mp4，取 bitrate 最高；m3u8 一律跳过。 */
function pickBestMp4(vi: TwVideoInfo | undefined): TwVariant | null {
  if (vi === undefined || vi === null || vi.variants === undefined) {
    return null;
  }
  const vs: TwVariant[] = vi.variants;
  let best: TwVariant | null = null;
  let bestRate: number = -1;
  for (let i = 0; i < vs.length; i++) {
    const ct: string = vs[i].content_type === undefined ? '' : (vs[i].content_type as string);
    if (ct !== 'video/mp4') {
      continue;
    }
    const br: number = vs[i].bitrate === undefined ? 0 : (vs[i].bitrate as number);
    if (br > bestRate) {
      bestRate = br;
      best = vs[i];
    }
  }
  return best;
}

/** 去掉推文尾部的 t.co 短链和多余空白，作为文件名基底。 */
function cleanTweetText(text: string, id: string): string {
  let s: string = text.replace(/https?:\/\/t\.co\/\w+/g, ' ').replace(/\s+/g, ' ').trim();
  if (s.length > 50) {
    s = s.substring(0, 50);
  }
  return s === '' ? `twitter_${id}` : s;
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
