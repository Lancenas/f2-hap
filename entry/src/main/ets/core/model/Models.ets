/**
 * 全局数据模型。
 *
 * 对应 macOS 版 src/core/downloader.py 里的 Platform / TaskStatus / DownloadTask。
 * ArkTS 严格模式不允许无类型字面量，所以这里全部用 class + 默认值，
 * 便于 @Observed / @Track 直接观测。
 */

/** 支持的平台。 */
export enum Platform {
  DOUYIN = 'douyin',
  TIKTOK = 'tiktok',
  TWITTER = 'twitter',
  WEIBO = 'weibo',
  UNKNOWN = 'unknown',
}

/** 平台中文名，用于 UI 展示。 */
export function platformLabel(p: Platform): string {
  switch (p) {
    case Platform.DOUYIN: return '抖音';
    case Platform.TIKTOK: return 'TikTok';
    case Platform.TWITTER: return 'X / Twitter';
    case Platform.WEIBO: return '微博';
    default: return '未知';
  }
}

/** 任务状态。 */
export enum TaskStatus {
  PENDING = 'pending',
  PARSING = 'parsing',
  RUNNING = 'running',
  DONE = 'done',
  ERROR = 'error',
  CANCELLED = 'cancelled',
}

export function statusLabel(s: TaskStatus): string {
  switch (s) {
    case TaskStatus.PENDING: return '等待中';
    case TaskStatus.PARSING: return '解析中';
    case TaskStatus.RUNNING: return '下载中';
    case TaskStatus.DONE: return '已完成';
    case TaskStatus.ERROR: return '失败';
    case TaskStatus.CANCELLED: return '已取消';
    default: return '未知';
  }
}

/** 媒体类型。 */
export enum MediaType {
  VIDEO = 'video',
  IMAGE = 'image',
  AUDIO = 'audio',
}

/**
 * 一条可下载的媒体。
 *
 * 抖音图集会解析出多条 IMAGE；普通视频只有一条 VIDEO。
 * `headers` 里带的 Referer / UA 必须与签名时一致，否则 CDN 会 403。
 */
@Observed
export class MediaItem {
  /** 直链地址 */
  url: string = '';
  type: MediaType = MediaType.VIDEO;
  /** 建议的文件名（不含扩展名） */
  name: string = '';
  /** 扩展名，如 mp4 / jpg */
  ext: string = 'mp4';
  /** 拉取该直链所需的请求头 */
  headers: Record<string, string> = {};
  /** 服务端声明的字节数，未知则为 0 */
  size: number = 0;
}

/** 解析结果：一个链接 → 作者信息 + N 条媒体。 */
@Observed
export class ParseResult {
  platform: Platform = Platform.UNKNOWN;
  title: string = '';
  author: string = '';
  /** 作品 ID，用于命名与去重 */
  awemeId: string = '';
  cover: string = '';
  items: MediaItem[] = [];
}

/** 下载任务。字段与 macOS 版 DownloadTask 对齐，方便两端行为一致。 */
@Observed
export class DownloadTask {
  taskId: string = '';
  url: string = '';
  platform: Platform = Platform.UNKNOWN;
  title: string = '';
  author: string = '';
  status: TaskStatus = TaskStatus.PENDING;
  /** 0 ~ 1 */
  progress: number = 0;
  /** 已格式化的速度，如 "2.4 MB/s" */
  speed: string = '';
  /** 已格式化的大小，如 "64.2 MB" */
  size: string = '';
  savePath: string = '';
  errorMsg: string = '';
  /** 图集/合集会拆成多个子文件 */
  isBatch: boolean = false;
  batchTotal: number = 0;
  batchDone: number = 0;
  createdAt: string = '';

  constructor(taskId: string = '', url: string = '', platform: Platform = Platform.UNKNOWN) {
    this.taskId = taskId;
    this.url = url;
    this.platform = platform;
    this.createdAt = formatClock(new Date());
  }
}

/** HH:mm:ss */
export function formatClock(d: Date): string {
  const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** 字节数 → 人类可读。 */
export function formatSize(bytes: number): string {
  if (bytes <= 0) {
    return '--';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB'];
  let v: number = bytes;
  let i: number = 0;
  while (v >= 1024 && i < units.length - 1) {
    v = v / 1024;
    i++;
  }
  return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}

/** 字节/秒 → 人类可读速度。 */
export function formatSpeed(bytesPerSec: number): string {
  if (bytesPerSec <= 0) {
    return '';
  }
  return `${formatSize(bytesPerSec)}/s`;
}
