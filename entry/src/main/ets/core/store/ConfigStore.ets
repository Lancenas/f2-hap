/**
 * 配置持久化，基于 @kit.ArkData 的 preferences。
 *
 * 对应 macOS 版 src/core/config.py 的 ConfigManager，字段尽量对齐，
 * 但去掉了桌面端才有的 save_dir / theme（手机端固定沙箱 + 系统深浅色）。
 *
 * Cookie 是抖音等平台能否解析成功的关键：没有 Cookie 时签名接口大概率返回空。
 *
 * Cookie 备份/还原（对应 macOS 版 cookie_manager 的备份环）：
 *   - 每次覆盖写入前自动备份当前值（空值不备份），最多保留 MAX_BACKUPS 份；
 *   - 设置页可一键「还原上一份」，避免手抖把好的 Cookie 覆盖了。
 */

import { preferences } from '@kit.ArkData';
import { Logger } from '../util/Logger';

const STORE_NAME: string = 'f2_config';

const K_COOKIE_DOUYIN: string = 'cookie_douyin';
const K_COOKIE_TIKTOK: string = 'cookie_tiktok';
const K_COOKIE_TWITTER: string = 'cookie_twitter';
const K_COOKIE_WEIBO: string = 'cookie_weibo';
const K_CONCURRENT: string = 'concurrent_downloads';
const K_SAVE_TO_GALLERY: string = 'save_to_gallery';
const K_NOTIFY: string = 'notify_on_complete';
const K_NAME_FORMAT: string = 'name_format';
const K_USER_AGENT: string = 'user_agent';

/** Cookie 备份环前缀：cookie_backup_douyin 等，值为 JSON 数组。 */
const K_BACKUP_PREFIX: string = 'cookie_backup_';
/** 每个平台最多保留的备份份数。 */
const MAX_BACKUPS: number = 3;

/** 单份 Cookie 备份。 */
export interface CookieBackup {
  cookie: string;
  /** 写入时间戳（毫秒）。 */
  at: number;
}

/** 默认 UA。签名与请求头必须用同一个，所以集中放在配置里。 */
export const DEFAULT_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';

/** 命名模板占位符：{author} {title} {id} */
export const DEFAULT_NAME_FORMAT: string = '{author}-{title}';

export class AppConfig {
  cookieDouyin: string = '';
  cookieTiktok: string = '';
  cookieTwitter: string = '';
  cookieWeibo: string = '';
  concurrentDownloads: number = 2;
  saveToGallery: boolean = true;
  notifyOnComplete: boolean = true;
  nameFormat: string = DEFAULT_NAME_FORMAT;
  userAgent: string = DEFAULT_UA;
  // 备份环（内存缓存，reload 时从 preferences 载入）
  backupDouyin: CookieBackup[] = [];
  backupTiktok: CookieBackup[] = [];
  backupTwitter: CookieBackup[] = [];
  backupWeibo: CookieBackup[] = [];
}

class ConfigStoreImpl {
  private store: preferences.Preferences | null = null;
  private cache: AppConfig = new AppConfig();
  private ready: boolean = false;

  async init(context: Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      this.store = await preferences.getPreferences(context, STORE_NAME);
      await this.reload();
      this.ready = true;
      Logger.info('配置已加载');
    } catch (e) {
      Logger.error(`配置初始化失败：${errText(e)}`);
    }
  }

  private async reload(): Promise<void> {
    const s = this.store;
    if (s === null) {
      return;
    }
    const c = new AppConfig();
    c.cookieDouyin = await getStr(s, K_COOKIE_DOUYIN, '');
    c.cookieTiktok = await getStr(s, K_COOKIE_TIKTOK, '');
    c.cookieTwitter = await getStr(s, K_COOKIE_TWITTER, '');
    c.cookieWeibo = await getStr(s, K_COOKIE_WEIBO, '');
    c.concurrentDownloads = await getNum(s, K_CONCURRENT, 2);
    c.saveToGallery = await getBool(s, K_SAVE_TO_GALLERY, true);
    c.notifyOnComplete = await getBool(s, K_NOTIFY, true);
    c.nameFormat = await getStr(s, K_NAME_FORMAT, DEFAULT_NAME_FORMAT);
    c.userAgent = await getStr(s, K_USER_AGENT, DEFAULT_UA);
    c.backupDouyin = await this.readBackups(s, 'douyin');
    c.backupTiktok = await this.readBackups(s, 'tiktok');
    c.backupTwitter = await this.readBackups(s, 'twitter');
    c.backupWeibo = await this.readBackups(s, 'weibo');
    this.cache = c;
  }

  get(): AppConfig {
    return this.cache;
  }

  /** 读取某平台当前 Cookie（内存缓存，写入即更新）。 */
  getCookie(platform: string): string {
    const c = this.cache;
    if (platform === 'douyin') {
      return c.cookieDouyin;
    } else if (platform === 'tiktok') {
      return c.cookieTiktok;
    } else if (platform === 'twitter') {
      return c.cookieTwitter;
    } else if (platform === 'weibo') {
      return c.cookieWeibo;
    }
    return '';
  }

  /** 读取某平台的备份列表（内存缓存）。 */
  getBackups(platform: string): CookieBackup[] {
    const c = this.cache;
    if (platform === 'douyin') {
      return c.backupDouyin;
    } else if (platform === 'tiktok') {
      return c.backupTiktok;
    } else if (platform === 'twitter') {
      return c.backupTwitter;
    } else if (platform === 'weibo') {
      return c.backupWeibo;
    }
    return [];
  }

  /** Cookie 常带换行（用户从浏览器粘贴），必须清掉，否则请求头非法。 */
  async setCookie(platform: string, raw: string): Promise<void> {
    const clean: string = sanitizeCookie(raw);
    const prev: string = this.getCookie(platform);

    // 覆盖前自动备份（镜像 macOS「每次覆盖前备份」；空值不备份）
    if (prev !== '' && prev !== clean) {
      await this.pushBackup(platform);
    }

    let key: string = '';
    if (platform === 'douyin') {
      key = K_COOKIE_DOUYIN;
      this.cache.cookieDouyin = clean;
    } else if (platform === 'tiktok') {
      key = K_COOKIE_TIKTOK;
      this.cache.cookieTiktok = clean;
    } else if (platform === 'twitter') {
      key = K_COOKIE_TWITTER;
      this.cache.cookieTwitter = clean;
    } else if (platform === 'weibo') {
      key = K_COOKIE_WEIBO;
      this.cache.cookieWeibo = clean;
    } else {
      return;
    }
    await this.put(key, clean);
  }

  /** 把当前值压入备份环（最多 MAX_BACKUPS 份，最新在前）。 */
  async pushBackup(platform: string): Promise<void> {
    const current: string = this.getCookie(platform);
    if (current === '') {
      return;
    }
    const list: CookieBackup[] = this.cacheBackups(platform);
    list.unshift({ cookie: current, at: Date.now() });
    const trimmed: CookieBackup[] = list.slice(0, MAX_BACKUPS);
    this.setCacheBackups(platform, trimmed);
    await this.put(K_BACKUP_PREFIX + platform, JSON.stringify(trimmed));
  }

  /** 从某份备份还原（默认还原最新一份 index=0）。 */
  async restoreFromBackup(platform: string, index: number = 0): Promise<boolean> {
    const list: CookieBackup[] = this.cacheBackups(platform);
    if (index < 0 || index >= list.length) {
      return false;
    }
    const cookie: string = list[index].cookie;
    // 还原前把「被覆盖的那份」也备份一下，保证可撤销
    await this.setCookie(platform, cookie);
    Logger.info(`${platform} Cookie 已还原（来自 ${list[index].at} 的备份）`);
    return true;
  }

  async setConcurrent(n: number): Promise<void> {
    const v: number = n < 1 ? 1 : (n > 5 ? 5 : Math.floor(n));
    this.cache.concurrentDownloads = v;
    await this.put(K_CONCURRENT, v);
  }

  async setSaveToGallery(v: boolean): Promise<void> {
    this.cache.saveToGallery = v;
    await this.put(K_SAVE_TO_GALLERY, v);
  }

  async setNotify(v: boolean): Promise<void> {
    this.cache.notifyOnComplete = v;
    await this.put(K_NOTIFY, v);
  }

  async setNameFormat(v: string): Promise<void> {
    const s: string = v.trim() === '' ? DEFAULT_NAME_FORMAT : v.trim();
    this.cache.nameFormat = s;
    await this.put(K_NAME_FORMAT, s);
  }

  async setUserAgent(v: string): Promise<void> {
    const s: string = v.trim() === '' ? DEFAULT_UA : v.trim();
    this.cache.userAgent = s;
    await this.put(K_USER_AGENT, s);
  }

  private async put(key: string, value: string | number | boolean): Promise<void> {
    const s = this.store;
    if (s === null) {
      return;
    }
    try {
      await s.put(key, value);
      await s.flush();
    } catch (e) {
      Logger.error(`配置写入失败 ${key}：${errText(e)}`);
    }
  }

  // ---------- 备份读写辅助 ----------

  private cacheBackups(platform: string): CookieBackup[] {
    const c = this.cache;
    if (platform === 'douyin') return c.backupDouyin;
    if (platform === 'tiktok') return c.backupTiktok;
    if (platform === 'twitter') return c.backupTwitter;
    if (platform === 'weibo') return c.backupWeibo;
    return [];
  }

  private setCacheBackups(platform: string, list: CookieBackup[]): void {
    const c = this.cache;
    if (platform === 'douyin') c.backupDouyin = list;
    else if (platform === 'tiktok') c.backupTiktok = list;
    else if (platform === 'twitter') c.backupTwitter = list;
    else if (platform === 'weibo') c.backupWeibo = list;
  }

  private async readBackups(s: preferences.Preferences, platform: string): Promise<CookieBackup[]> {
    try {
      const v: preferences.ValueType = await s.get(K_BACKUP_PREFIX + platform, '');
      const raw: string = typeof v === 'string' ? (v as string) : '';
      if (raw === '') {
        return [];
      }
      const arr: CookieBackup[] = JSON.parse(raw) as CookieBackup[];
      return Array.isArray(arr) ? arr : [];
    } catch (e) {
      return [];
    }
  }
}

/** 去掉 Cookie 里的换行与首尾空白。macOS 版踩过 Illegal header value 的坑。 */
export function sanitizeCookie(raw: string): string {
  return raw.replace(/[\r\n]+/g, '').trim();
}

async function getStr(s: preferences.Preferences, k: string, def: string): Promise<string> {
  const v: preferences.ValueType = await s.get(k, def);
  return typeof v === 'string' ? v as string : def;
}

async function getNum(s: preferences.Preferences, k: string, def: number): Promise<number> {
  const v: preferences.ValueType = await s.get(k, def);
  return typeof v === 'number' ? v as number : def;
}

async function getBool(s: preferences.Preferences, k: string, def: boolean): Promise<boolean> {
  const v: preferences.ValueType = await s.get(k, def);
  return typeof v === 'boolean' ? v as boolean : def;
}

/** 统一的异常文本提取，ArkTS 的 catch 参数是 unknown。 */
export function errText(e: object | undefined): string {
  if (e === undefined || e === null) {
    return 'unknown';
  }
  const be = e as BusinessErrorLike;
  if (be.message !== undefined) {
    return be.code !== undefined ? `[${be.code}] ${be.message}` : be.message;
  }
  return JSON.stringify(e);
}

interface BusinessErrorLike {
  code?: number;
  message?: string;
}

export const ConfigStore: ConfigStoreImpl = new ConfigStoreImpl();
