/**
 * 解析器公共契约与工具。
 *
 * 每个平台实现 Resolver.resolve(url) → ParseResult。
 * 失败时抛 ResolveError，上层统一转成任务的 errorMsg，不让异常穿到 UI。
 */

import { ParseResult, Platform } from '../model/Models';

export class ResolveError extends Error {
  /** 是否属于「缺 Cookie / Cookie 失效」，UI 会引导去设置页 */
  needCookie: boolean = false;

  constructor(message: string, needCookie: boolean = false) {
    super(message);
    this.name = 'ResolveError';
    this.needCookie = needCookie;
  }
}

export interface Resolver {
  platform: Platform;
  /** 传入的 url 已经过短链展开 */
  resolve(url: string): Promise<ParseResult>;
}

/** 随机字符串，用于伪造 msToken / verifyFp 一类不校验内容的参数。 */
export function randomStr(len: number): string {
  const abc: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let s: string = '';
  for (let i = 0; i < len; i++) {
    s += abc.charAt(Math.floor(Math.random() * abc.length));
  }
  return s;
}

/**
 * 假 msToken：随机 126 位 + '=='。
 *
 * 对应 f2 的 gen_false_msToken。已实测：只要 Cookie 里有 ttwid，
 * 假 msToken 也能正常拿到 aweme_detail，所以不必移植真 msToken 换取接口。
 */
export function falseMsToken(): string {
  return randomStr(126) + '==';
}

/** 把有序键值拼成 query，值做 URL 编码。顺序必须稳定 —— a_bogus 是对整串签名的。 */
export function buildQuery(kv: Array<[string, string]>): string {
  const parts: string[] = [];
  for (let i = 0; i < kv.length; i++) {
    parts.push(`${kv[i][0]}=${encodeURIComponent(kv[i][1])}`);
  }
  return parts.join('&');
}

/** 从 URL 路径里按正则取第一个捕获组。 */
export function matchFirst(url: string, patterns: RegExp[]): string {
  for (let i = 0; i < patterns.length; i++) {
    const m: RegExpMatchArray | null = url.match(patterns[i]);
    if (m !== null && m.length > 1) {
      return m[1];
    }
  }
  return '';
}

/** 文件名里不能出现的字符统一换成下划线，并限制长度。 */
export function sanitizeName(raw: string): string {
  let s: string = raw.replace(/[\/\\:*?"<>|\r\n\t]/g, '_').trim();
  s = s.replace(/\s+/g, ' ');
  if (s.length > 60) {
    s = s.substring(0, 60);
  }
  return s === '' ? 'untitled' : s;
}

/** 按模板生成文件名。占位符：{author} {title} {id} */
export function applyNameFormat(tpl: string, author: string, title: string, id: string): string {
  const s: string = tpl
    .replace(/\{author\}/g, sanitizeName(author))
    .replace(/\{title\}/g, sanitizeName(title))
    .replace(/\{id\}/g, id);
  return sanitizeName(s);
}

/** 空结果，便于解析器逐步填充。 */
export function emptyResult(p: Platform): ParseResult {
  const r = new ParseResult();
  r.platform = p;
  return r;
}
