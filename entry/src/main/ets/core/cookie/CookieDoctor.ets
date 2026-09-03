/**
 * Cookie 体检与平台元信息 —— 对应 macOS 版 src/core/cookie_manager.py 的 analyze_cookie。
 *
 * 设计取舍：
 *  - 鸿蒙版没有桌面浏览器，所以「自动获取」改为「应用内 Web 登录后抓取」（见 CookieLoginPage），
 *    但 Cookie 健康判定逻辑与桌面版完全一致：本地解析 sid_guard，不依赖网络，离线即可算出到期时间。
 *  - 抖音 sid_guard 结构：sessionid|<签发时间戳>|<有效秒数>|<到期时间>，可精确算出过期时间；
 *    微博只有 SUB/SUBP，无法判断到期，只判定「是否已登录」。
 *
 * 本模块是纯函数，不碰 preferences、不碰 UI，方便在设置页与解析前复用。
 */

/** Cookie 健康度。 */
export type CookieHealth = 'empty' | 'anonymous' | 'expired' | 'expiring' | 'ok';

/** 平台元信息，绑定登录页、抓取域名与判定用的登录态字段。 */
export interface CookiePlatform {
  key: string;
  name: string;
  /** 用于 Web 登录与抓取 Cookie 的域名（带点，匹配 cookie 作用域） */
  domain: string;
  /** 抓取 Cookie 用的完整源站 URL（取登录页的 scheme+host） */
  cookieUrl: string;
  loginUrl: string;
  /** 是否必须带登录态才能解析（抖音/微博需要） */
  needsCookie: boolean;
  /** 命中任一即视为已登录 */
  loginKeys: string[];
  /** 应用内 Web 登录获取是否有意义（tiktok 本版本未移植，关掉） */
  inAppLogin: boolean;
}

export const COOKIE_PLATFORMS: CookiePlatform[] = [
  {
    key: 'douyin',
    name: '抖音',
    domain: 'douyin.com',
    cookieUrl: 'https://www.douyin.com',
    loginUrl: 'https://www.douyin.com/',
    needsCookie: true,
    loginKeys: ['sessionid', 'sessionid_ss', 'sid_tt', 'sid_guard'],
    inAppLogin: true,
  },
  {
    key: 'weibo',
    name: '微博',
    domain: 'weibo.com',
    cookieUrl: 'https://weibo.com',
    loginUrl: 'https://weibo.com/login.php',
    needsCookie: true,
    loginKeys: ['SUB', 'SUBP'],
    inAppLogin: true,
  },
  {
    key: 'twitter',
    name: 'X / Twitter',
    domain: 'twitter.com',
    cookieUrl: 'https://x.com',
    loginUrl: 'https://x.com/login',
    needsCookie: false,
    loginKeys: ['auth_token', 'ct0'],
    inAppLogin: false,
  },
  {
    key: 'tiktok',
    name: 'TikTok',
    domain: 'tiktok.com',
    cookieUrl: 'https://www.tiktok.com',
    loginUrl: 'https://www.tiktok.com/login',
    needsCookie: false,
    loginKeys: ['sessionid', 'sessionid_ss', 'sid_tt'],
    inAppLogin: false,
  },
];

/** 距离到期多少天内提示「即将过期」。 */
const EXPIRING_SOON_DAYS: number = 7;

/** 一份 Cookie 的体检报告。 */
export interface CookieReport {
  health: CookieHealth;
  hasCookie: boolean;
  loggedIn: boolean;
  loginKeysFound: string[];
  loginKeysExpected: string[];
  length: number;
  keyCount: number;
  /** 到期时间戳（秒）；0 表示无法判断 */
  expireTs: number;
  expireStr: string;
  /** 剩余天数；NaN 表示无法判断 */
  daysLeft: number;
  reason: string;
}

/** 按 key 查找平台元信息。 */
export function platformMeta(key: string): CookiePlatform | undefined {
  for (let i = 0; i < COOKIE_PLATFORMS.length; i++) {
    if (COOKIE_PLATFORMS[i].key === key) {
      return COOKIE_PLATFORMS[i];
    }
  }
  return undefined;
}

/** 把 Cookie 字符串解析成字典（值做 URL 解码，便于解析 sid_guard）。 */
export function parseCookie(cookie: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!cookie || cookie.length === 0) {
    return out;
  }
  const parts: string[] = cookie.split(';');
  for (let i = 0; i < parts.length; i++) {
    let part: string = parts[i].trim();
    if (part.length === 0 || part.indexOf('=') < 0) {
      continue;
    }
    const eq: number = part.indexOf('=');
    const k: string = part.substring(0, eq).trim();
    if (k.length === 0) {
      continue;
    }
    let v: string = part.substring(eq + 1).trim();
    try {
      v = decodeURIComponent(v);
    } catch (e) {
      // 解码失败就保留原始值
    }
    out[k] = v;
  }
  return out;
}

/**
 * 离线分析一份 Cookie 的健康状况。
 *
 * 与桌面版 analyze_cookie 一一对应：
 *  - empty      未配置
 *  - anonymous  有 Cookie 但没有登录态字段（只能下载公开内容）
 *  - expired    登录态已过期
 *  - expiring   登录态即将过期（7 天内）
 *  - ok         登录态正常
 */
export function analyzeCookie(cookie: string, platformKey: string): CookieReport {
  const meta: CookiePlatform | undefined = platformMeta(platformKey);
  const loginKeys: string[] = meta !== undefined ? meta.loginKeys : [];

  const data: Record<string, string> = parseCookie(cookie);
  const present: string[] = [];
  for (let i = 0; i < loginKeys.length; i++) {
    const k: string = loginKeys[i];
    if (data[k] !== undefined && data[k].length > 0) {
      present.push(k);
    }
  }

  const report: CookieReport = {
    health: 'empty',
    hasCookie: !!(cookie && cookie.trim().length > 0),
    loggedIn: present.length > 0,
    loginKeysFound: present,
    loginKeysExpected: loginKeys,
    length: cookie !== undefined ? cookie.length : 0,
    keyCount: Object.keys(data).length,
    expireTs: 0,
    expireStr: '',
    daysLeft: NaN,
    reason: '未配置 Cookie',
  };

  if (!report.hasCookie) {
    return report;
  }

  // 解析 sid_guard：sessionid|签发时间戳|有效秒数|到期时间
  const sidGuard: string = data['sid_guard'] !== undefined ? data['sid_guard'] : '';
  const m: RegExpMatchArray | null = sidGuard.match(/^([0-9a-zA-Z]+)\|(\d+)\|(\d+)\|/);
  let expireTs: number = 0;
  if (m !== null) {
    const issueTs: number = Number(m[2]);
    const validSec: number = Number(m[3]);
    expireTs = issueTs + validSec;
  } else if (data['login_time'] !== undefined) {
    // 兜底：抖音登录态默认约 60 天
    try {
      const issueTs: number = Number(data['login_time']) / 1000;
      expireTs = issueTs + 60 * 24 * 3600;
    } catch (e) {
      expireTs = 0;
    }
  }

  if (expireTs > 0) {
    report.expireTs = expireTs;
    report.expireStr = tsToStr(expireTs);
    report.daysLeft = Math.round(((expireTs - Date.now() / 1000) / 86400) * 10) / 10;
  }

  if (!report.loggedIn) {
    report.health = 'anonymous';
    report.reason = '未包含登录态字段（' + loginKeys.join(' / ') + '），仅能下载公开内容';
    return report;
  }

  const daysLeft: number = report.daysLeft;
  if (isNaN(daysLeft)) {
    report.health = 'ok';
    report.reason = '包含登录态字段，但无法判断到期时间';
  } else if (daysLeft <= 0) {
    report.health = 'expired';
    report.reason = `登录态已于 ${report.expireStr} 过期`;
  } else if (daysLeft <= EXPIRING_SOON_DAYS) {
    report.health = 'expiring';
    report.reason = `登录态将在 ${daysLeft} 天后（${report.expireStr}）过期`;
  } else {
    report.health = 'ok';
    report.reason = `登录态有效，剩余 ${Math.floor(daysLeft)} 天`;
  }
  return report;
}

/** 健康度中文标签。 */
export function healthLabel(h: CookieHealth): string {
  switch (h) {
    case 'empty': return '未设置';
    case 'anonymous': return '缺登录态';
    case 'expired': return '已过期';
    case 'expiring': return '即将过期';
    case 'ok': return '正常';
    default: return '未知';
  }
}

/** 健康度对应的颜色（与主题色板一致）。 */
export function healthColor(h: CookieHealth): string {
  switch (h) {
    case 'empty': return '#8A8A8E';
    case 'anonymous': return '#E08A00';
    case 'expired': return '#D93A3A';
    case 'expiring': return '#E08A00';
    case 'ok': return '#1F9E4F';
    default: return '#8A8A8E';
  }
}

/** 该平台是否需要用户关注（需要登录却处于 empty/expired/anonymous）。 */
export function needsAttention(platformKey: string, cookie: string): boolean {
  const meta: CookiePlatform | undefined = platformMeta(platformKey);
  if (meta === undefined || !meta.needsCookie) {
    return false;
  }
  const r: CookieReport = analyzeCookie(cookie, platformKey);
  return r.health === 'empty' || r.health === 'expired' || r.health === 'anonymous';
}

/** 时间戳（秒）→ 可读字符串。 */
function tsToStr(ts: number): string {
  const d: Date = new Date(ts * 1000);
  const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
