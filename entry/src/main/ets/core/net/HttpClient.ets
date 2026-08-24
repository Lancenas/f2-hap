/**
 * HTTP 客户端，基于 @kit.NetworkKit 的 http 模块。
 *
 * 这个 SDK 里没有 rcp（@kit.RemoteCommunicationKit 不存在），所以统一用 http。
 * 关键能力：
 *   1. 手动重定向 —— 短链（v.douyin.com / t.cn / vm.tiktok.com / t.co）必须读 302 的
 *      Location 头才能拿到作品 ID，因此用 maxRedirects: 0 拿原始 302 再自己跳。
 *   2. 指数退避重试 —— 网络错误、429、5xx 才重试，4xx 直接失败（重试无意义）。
 *   3. 每个请求用完立即 destroy()，http.HttpRequest 是有限资源。
 */

import { http } from '@kit.NetworkKit';
import { Logger } from '../util/Logger';
import { errText } from '../store/ConfigStore';

const MAX_RETRY: number = 3;
const CONNECT_TIMEOUT: number = 15000;
const READ_TIMEOUT: number = 30000;
const MAX_REDIRECT_HOPS: number = 6;

export class HttpResult {
  status: number = 0;
  body: string = '';
  headers: Record<string, string> = {};

  /** 2xx 视为成功。 */
  ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  /** 3xx 且带 Location。 */
  redirectTo(): string {
    if (this.status < 300 || this.status >= 400) {
      return '';
    }
    return headerOf(this.headers, 'location');
  }
}

/** 响应头大小写不统一，统一按小写查找。 */
export function headerOf(h: Record<string, string>, name: string): string {
  const lower: string = name.toLowerCase();
  const keys: string[] = Object.keys(h);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === lower) {
      const v: string | undefined = h[keys[i]];
      return v === undefined ? '' : v;
    }
  }
  return '';
}

function normalizeHeaders(raw: Object | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === undefined || raw === null) {
    return out;
  }
  const rec = raw as Record<string, string | string[]>;
  const keys: string[] = Object.keys(rec);
  for (let i = 0; i < keys.length; i++) {
    const v: string | string[] | undefined = rec[keys[i]];
    if (v === undefined) {
      continue;
    }
    out[keys[i]] = Array.isArray(v) ? (v as string[]).join(', ') : (v as string);
  }
  return out;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 值得重试：网络层抛错（status 0）、429、5xx。 */
function shouldRetry(status: number): boolean {
  return status === 0 || status === 429 || (status >= 500 && status < 600);
}

export class HttpClient {
  /**
   * 单次 GET，不跟随重定向。
   *
   * @param url 完整 URL
   * @param headers 请求头；Douyin 直链必须带与签名一致的 User-Agent 和 Referer
   * @param followRedirect true 时交给底层跟随（最多 5 跳），false 时返回原始 3xx
   */
  static async get(url: string, headers: Record<string, string>,
                   followRedirect: boolean = true): Promise<HttpResult> {
    let lastStatus: number = 0;
    let lastErr: string = '';

    for (let attempt = 0; attempt < MAX_RETRY; attempt++) {
      if (attempt > 0) {
        const backoff: number = 300 * Math.pow(3, attempt - 1);
        await sleep(backoff);
        Logger.warn(`重试第 ${attempt} 次（${lastStatus !== 0 ? lastStatus : lastErr}）：${shortUrl(url)}`);
      }

      const req = http.createHttp();
      try {
        const opts: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: headers,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: CONNECT_TIMEOUT,
          readTimeout: READ_TIMEOUT,
          usingCache: false,
          maxRedirects: followRedirect ? 5 : 0,
        };
        const resp: http.HttpResponse = await req.request(url, opts);
        const r = new HttpResult();
        r.status = resp.responseCode as number;
        r.headers = normalizeHeaders(resp.header);
        r.body = typeof resp.result === 'string' ? resp.result as string : '';

        if (r.ok() || !shouldRetry(r.status)) {
          return r;
        }
        lastStatus = r.status;
      } catch (e) {
        lastErr = errText(e as object);
        lastStatus = 0;
        // 2300047 重定向超限：重试无意义，直接终止循环
        if (lastErr.includes('2300047') || lastErr.toLowerCase().includes('redirection')) {
          break;
        }
      } finally {
        req.destroy();
      }
    }

    const fail = new HttpResult();
    fail.status = lastStatus;
    fail.body = lastErr;
    Logger.error(`请求失败（已重试 ${MAX_RETRY} 次）：${shortUrl(url)} → ${lastStatus !== 0 ? lastStatus : lastErr}`);
    return fail;
  }

  /**
   * 单次 POST。目前只有 Twitter 换 guest_token 用到（空 body）。
   *
   * 不做重试：换 token 失败时上层会退到别的解析路线，重试只是拖慢。
   */
  static async post(url: string, headers: Record<string, string>, body: string = ''): Promise<HttpResult> {
    const req = http.createHttp();
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: READ_TIMEOUT,
        usingCache: false,
      };
      const resp: http.HttpResponse = await req.request(url, opts);
      const r = new HttpResult();
      r.status = resp.responseCode as number;
      r.headers = normalizeHeaders(resp.header);
      r.body = typeof resp.result === 'string' ? resp.result as string : '';
      return r;
    } catch (e) {
      const fail = new HttpResult();
      fail.status = 0;
      fail.body = errText(e as object);
      Logger.error(`POST 失败：${shortUrl(url)} → ${fail.body}`);
      return fail;
    } finally {
      req.destroy();
    }
  }

  /**
   * 逐跳跟随重定向，返回最终 URL。
   *
   * 短链解析必须用这个：抖音 v.douyin.com 的 302 Location 里带 /share/video/<awemeId>/，
   * 而底层自动跟随后拿不到中间的 Location。
   *
   * 重要坑：本机 SDK 的 http 模块在 `maxRedirects: 0` 时对 302 并非返回响应，
   * 而是抛 `2300047 The number of redirections reaches the maximum allowed`（底层仍尝试跟随）。
   * 因此这里注册 `headersReceive` 事件，在抛错前先把 302 的 Location 抓出来，
   * catch 里用它继续下一跳，而不是依赖返回值。
   */
  static async resolveFinalUrl(url: string, headers: Record<string, string>): Promise<string> {
    let current: string = url;
    for (let hop = 0; hop < MAX_REDIRECT_HOPS; hop++) {
      const req = http.createHttp();
      let caughtLocation: string = '';
      try {
        req.on('headersReceive', (hdr: Object) => {
          const h: Record<string, string> = normalizeHeaders(hdr);
          const loc: string = headerOf(h, 'location');
          if (loc !== '') {
            caughtLocation = loc;
          }
        });
        const opts: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: headers,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: CONNECT_TIMEOUT,
          readTimeout: READ_TIMEOUT,
          usingCache: false,
          maxRedirects: 0,
        };
        const resp: http.HttpResponse = await req.request(current, opts);
        // 部分 SDK 版本会直接返回 3xx（不抛错），此时走返回值路径
        const r = new HttpResult();
        r.status = resp.responseCode as number;
        r.headers = normalizeHeaders(resp.header);
        const next: string = r.redirectTo();
        if (next === '') {
          return current;
        }
        current = absolutize(current, next);
        Logger.debug(`重定向 → ${shortUrl(current)}`);
      } catch (e) {
        if (caughtLocation !== '') {
          // 底层抛 2300047 但事件里已拿到 Location，继续下一跳
          current = absolutize(current, caughtLocation);
          Logger.debug(`重定向(事件) → ${shortUrl(current)}`);
        } else {
          // 真的失败了（DNS/TLS/连接），停止展开，返回当前 URL
          Logger.warn(`短链展开在 ${hop + 1} 跳失败：${errText(e as object)}`);
          return current;
        }
      } finally {
        req.destroy();
      }
    }
    return current;
  }

  /** 拉取二进制，用于封面等小文件。大文件走 Downloader 的流式通道。 */
  static async getBuffer(url: string, headers: Record<string, string>): Promise<ArrayBuffer | null> {
    const req = http.createHttp();
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: READ_TIMEOUT,
        usingCache: false,
      };
      const resp: http.HttpResponse = await req.request(url, opts);
      const code: number = resp.responseCode as number;
      if (code < 200 || code >= 300) {
        return null;
      }
      return resp.result as ArrayBuffer;
    } catch (e) {
      Logger.error(`二进制拉取失败：${errText(e as object)}`);
      return null;
    } finally {
      req.destroy();
    }
  }
}

/** 相对 Location 补全成绝对 URL。 */
export function absolutize(base: string, location: string): string {
  if (location.startsWith('http://') || location.startsWith('https://')) {
    return location;
  }
  const schemeEnd: number = base.indexOf('://');
  if (schemeEnd < 0) {
    return location;
  }
  const hostStart: number = schemeEnd + 3;
  const pathStart: number = base.indexOf('/', hostStart);
  const origin: string = pathStart < 0 ? base : base.substring(0, pathStart);
  if (location.startsWith('/')) {
    return origin + location;
  }
  const dir: string = pathStart < 0 ? origin + '/' : base.substring(0, base.lastIndexOf('/') + 1);
  return dir + location;
}

/** 日志里不打完整 URL（含 Cookie/签名，且很长）。 */
export function shortUrl(url: string): string {
  const q: number = url.indexOf('?');
  const head: string = q < 0 ? url : url.substring(0, q);
  return head.length > 80 ? head.substring(0, 80) + '…' : head;
}
