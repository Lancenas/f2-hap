/**
 * 任务管理器：解析 → 下载 → 入库 的总调度。
 *
 * 与 macOS 版最大的架构差异：桌面版是 Swift 进程 + Python 后台服务 + 文件队列
 * （因为 Process 每次新起 Python，daemon 线程会随进程退出被杀，这也是当初「任务
 * 一直等待中」的根因）。鸿蒙这边全在同一个 ArkTS 运行时里跑，不需要跨进程队列，
 * 直接内存里维护 pending 队列 + 并发闸门即可，任务不会凭空停住。
 *
 * 并发控制：running 计数 + 队列，不用信号量库。
 * 落盘位置：filesDir/downloads/<平台>/，再按开关批量入相册。
 * 历史持久化：任务列表序列化进 preferences，重启后还能看到记录（进度不恢复，
 *   直链是有时效的，恢复到一半没意义 —— 未完成的一律标成失败并提示重下）。
 */

import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  DownloadTask, MediaItem, MediaType, ParseResult, Platform, TaskStatus,
  formatSize, formatSpeed,
} from '../model/Models';
import { ConfigStore, errText } from '../store/ConfigStore';
import { Logger } from '../util/Logger';
import { ResolveError, applyNameFormat } from '../platform/Resolver';
import { ResolveOutcome, ResolverRegistry } from '../platform/ResolverRegistry';
import { DownloadError, DownloadHandle, Downloader } from './Downloader';
import { GallerySaveResult, GallerySaver, PendingAsset } from './GallerySaver';

const HISTORY_STORE: string = 'f2_history';
const K_TASKS: string = 'tasks';
const MAX_HISTORY: number = 200;

/** UI 订阅用的通知回调。 */
export type TasksListener = (tasks: DownloadTask[]) => void;
/** 一次性提示（Toast）回调。 */
export type ToastListener = (msg: string) => void;

/** 序列化用的扁平结构，@Observed 类不能直接 JSON.parse 回来。 */
interface TaskJson {
  taskId: string;
  url: string;
  platform: string;
  title: string;
  author: string;
  status: string;
  progress: number;
  speed: string;
  size: string;
  savePath: string;
  errorMsg: string;
  isBatch: boolean;
  batchTotal: number;
  batchDone: number;
  createdAt: string;
}

class TaskManagerImpl {
  private tasks: DownloadTask[] = [];
  private queue: string[] = [];
  private running: number = 0;
  private handles: Map<string, DownloadHandle> = new Map<string, DownloadHandle>();
  private listeners: TasksListener[] = [];
  private toastListeners: ToastListener[] = [];
  private store: preferences.Preferences | null = null;
  private ctx: common.UIAbilityContext | null = null;
  private baseDir: string = '';
  private seq: number = 0;

  // ---------- 生命周期 ----------

  async init(ctx: common.UIAbilityContext): Promise<void> {
    this.ctx = ctx;
    this.baseDir = `${ctx.filesDir}/downloads`;
    ensureDir(this.baseDir);
    try {
      this.store = await preferences.getPreferences(ctx, HISTORY_STORE);
      await this.loadHistory();
    } catch (e) {
      Logger.error(`历史记录加载失败：${errText(e as object)}`);
    }
    Logger.info(`任务管理器就绪，下载目录 ${this.baseDir}`);
  }

  // ---------- 订阅 ----------

  subscribe(cb: TasksListener): () => void {
    this.listeners.push(cb);
    cb(this.snapshot());
    return () => {
      const i: number = this.listeners.indexOf(cb);
      if (i >= 0) {
        this.listeners.splice(i, 1);
      }
    };
  }

  onToast(cb: ToastListener): () => void {
    this.toastListeners.push(cb);
    return () => {
      const i: number = this.toastListeners.indexOf(cb);
      if (i >= 0) {
        this.toastListeners.splice(i, 1);
      }
    };
  }

  /** 返回新数组，让 @State 能感知到变化。 */
  snapshot(): DownloadTask[] {
    return this.tasks.slice(0);
  }

  private notify(): void {
    const snap: DownloadTask[] = this.snapshot();
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](snap);
    }
  }

  private toast(msg: string): void {
    for (let i = 0; i < this.toastListeners.length; i++) {
      this.toastListeners[i](msg);
    }
  }

  // ---------- 对外操作 ----------

  /**
   * 粘贴一段文本，抠出里面所有支持的链接并逐个建任务。
   * @returns 新建的任务数
   */
  addFromText(text: string): number {
    const urls: string[] = ResolverRegistry.pickUrls(text);
    if (urls.length === 0) {
      this.toast('没识别到链接');
      return 0;
    }
    for (let i = 0; i < urls.length; i++) {
      this.addUrl(urls[i]);
    }
    return urls.length;
  }

  addUrl(url: string): string {
    this.seq++;
    const id: string = `t${Date.now()}_${this.seq}`;
    const t = new DownloadTask(id, url, Platform.UNKNOWN);
    t.title = url.length > 48 ? url.substring(0, 48) + '…' : url;
    t.status = TaskStatus.PENDING;
    this.tasks.unshift(t);
    this.trimHistory();
    this.queue.push(id);
    this.notify();
    this.pump();
    return id;
  }

  cancel(taskId: string): void {
    const h: DownloadHandle | undefined = this.handles.get(taskId);
    if (h !== undefined) {
      h.cancel();
    }
    const qi: number = this.queue.indexOf(taskId);
    if (qi >= 0) {
      this.queue.splice(qi, 1);
    }
    const t: DownloadTask | null = this.find(taskId);
    if (t !== null && t.status !== TaskStatus.DONE) {
      t.status = TaskStatus.CANCELLED;
      t.speed = '';
      this.notify();
      this.persist();
    }
  }

  retry(taskId: string): void {
    const t: DownloadTask | null = this.find(taskId);
    if (t === null) {
      return;
    }
    t.status = TaskStatus.PENDING;
    t.progress = 0;
    t.errorMsg = '';
    t.speed = '';
    t.batchDone = 0;
    this.queue.push(taskId);
    this.notify();
    this.pump();
  }

  remove(taskId: string): void {
    this.cancel(taskId);
    const i: number = this.tasks.findIndex((x: DownloadTask) => x.taskId === taskId);
    if (i >= 0) {
      this.tasks.splice(i, 1);
    }
    this.notify();
    this.persist();
  }

  clearFinished(): void {
    this.tasks = this.tasks.filter((t: DownloadTask) =>
      t.status !== TaskStatus.DONE && t.status !== TaskStatus.ERROR && t.status !== TaskStatus.CANCELLED);
    this.notify();
    this.persist();
  }

  find(taskId: string): DownloadTask | null {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].taskId === taskId) {
        return this.tasks[i];
      }
    }
    return null;
  }

  countByStatus(s: TaskStatus): number {
    let n: number = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === s) {
        n++;
      }
    }
    return n;
  }

  activeCount(): number {
    return this.countByStatus(TaskStatus.PENDING)
      + this.countByStatus(TaskStatus.PARSING)
      + this.countByStatus(TaskStatus.RUNNING);
  }

  // ---------- 调度 ----------

  /** 有空位就从队列取任务开跑。 */
  private pump(): void {
    const limit: number = ConfigStore.get().concurrentDownloads;
    while (this.running < limit && this.queue.length > 0) {
      const id: string | undefined = this.queue.shift();
      if (id === undefined) {
        break;
      }
      const t: DownloadTask | null = this.find(id);
      if (t === null || t.status === TaskStatus.CANCELLED) {
        continue;
      }
      this.running++;
      // 故意不 await：让并发真正并行；异常在 runTask 内部兜住
      this.runTask(t).then(() => {
        this.running--;
        this.pump();
      }).catch((e: Object) => {
        this.running--;
        Logger.error(`任务调度异常：${errText(e)}`);
        this.pump();
      });
    }
  }

  private async runTask(t: DownloadTask): Promise<void> {
    const handle = new DownloadHandle();
    this.handles.set(t.taskId, handle);
    try {
      // --- 解析 ---
      t.status = TaskStatus.PARSING;
      t.errorMsg = '';
      this.notify();

      const outcome: ResolveOutcome = await ResolverRegistry.resolveUrl(t.url);
      const pr: ParseResult | null = outcome.result;
      if (pr === null || pr.items.length === 0) {
        throw new ResolveError('解析成功但没有可下载的媒体');
      }
      t.platform = outcome.platform;
      t.title = pr.title;
      t.author = pr.author;
      t.isBatch = pr.items.length > 1;
      t.batchTotal = pr.items.length;
      t.batchDone = 0;

      if (handle.isCancelled()) {
        throw new DownloadError('已取消');
      }

      // --- 下载 ---
      t.status = TaskStatus.RUNNING;
      this.notify();

      const cfg = ConfigStore.get();
      const dir: string = `${this.baseDir}/${pr.platform}`;
      ensureDir(dir);

      const saved: PendingAsset[] = [];
      let totalBytes: number = 0;

      for (let i = 0; i < pr.items.length; i++) {
        if (handle.isCancelled()) {
          throw new DownloadError('已取消');
        }
        const item: MediaItem = pr.items[i];
        const base: string = applyNameFormat(cfg.nameFormat, pr.author, item.name, pr.awemeId);
        const fileName: string = pr.items.length > 1
          ? `${base}_${i + 1 < 10 ? '0' : ''}${i + 1}.${item.ext}`
          : `${base}.${item.ext}`;
        const dest: string = `${dir}/${fileName}`;

        const idxLabel: string = pr.items.length > 1 ? `[${i + 1}/${pr.items.length}] ` : '';
        Logger.info(`${idxLabel}开始下载 ${fileName}`);

        const bytes: number = await Downloader.fetchToFile(item, dest, handle,
          (received: number, total: number, speed: number) => {
            // 批量时把单文件进度折算进整体
            const single: number = total > 0 ? received / total : 0;
            t.progress = pr.items.length > 1
              ? (i + single) / pr.items.length
              : single;
            t.speed = formatSpeed(speed);
            t.size = total > 0 ? formatSize(total) : formatSize(received);
            this.notify();
          });

        totalBytes += bytes;
        t.batchDone = i + 1;
        t.savePath = dest;
        saved.push(new PendingAsset(dest, base, item.ext,
          item.type === MediaType.IMAGE ? MediaType.IMAGE : MediaType.VIDEO));
        this.notify();
      }

      t.progress = 1;
      t.speed = '';
      t.size = formatSize(totalBytes);
      t.status = TaskStatus.DONE;
      this.notify();
      Logger.info(`任务完成：${t.title}（${formatSize(totalBytes)}）`);

      // --- 入相册 ---
      if (cfg.saveToGallery && this.ctx !== null && saved.length > 0) {
        const res: GallerySaveResult = await GallerySaver.saveBatch(this.ctx, saved);
        if (res.saved > 0) {
          this.toast(res.message);
        } else if (res.message !== '') {
          this.toast(res.message);
        }
      } else if (cfg.notifyOnComplete) {
        this.toast(`已下载：${t.title}`);
      }
    } catch (e) {
      if (handle.isCancelled()) {
        t.status = TaskStatus.CANCELLED;
        t.speed = '';
        Logger.warn(`任务已取消：${t.title}`);
      } else {
        t.status = TaskStatus.ERROR;
        t.speed = '';
        t.errorMsg = describe(e);
        Logger.error(`任务失败：${t.title} → ${t.errorMsg}`);
        this.toast(t.errorMsg);
      }
      this.notify();
    } finally {
      this.handles.delete(t.taskId);
      this.persist();
    }
  }

  // ---------- 持久化 ----------

  private trimHistory(): void {
    if (this.tasks.length > MAX_HISTORY) {
      this.tasks = this.tasks.slice(0, MAX_HISTORY);
    }
  }

  private persist(): void {
    const s: preferences.Preferences | null = this.store;
    if (s === null) {
      return;
    }
    const arr: TaskJson[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      arr.push(toJson(this.tasks[i]));
    }
    s.put(K_TASKS, JSON.stringify(arr))
      .then(() => s.flush())
      .catch((e: Object) => {
        Logger.warn(`历史写入失败：${errText(e)}`);
      });
  }

  private async loadHistory(): Promise<void> {
    const s: preferences.Preferences | null = this.store;
    if (s === null) {
      return;
    }
    const raw: preferences.ValueType = await s.get(K_TASKS, '');
    if (typeof raw !== 'string' || (raw as string) === '') {
      return;
    }
    try {
      const arr = JSON.parse(raw as string) as TaskJson[];
      const out: DownloadTask[] = [];
      for (let i = 0; i < arr.length; i++) {
        out.push(fromJson(arr[i]));
      }
      this.tasks = out;
      Logger.info(`恢复历史任务 ${out.length} 条`);
      this.notify();
    } catch (e) {
      Logger.warn('历史记录格式异常，已忽略');
    }
  }

  /** 应用内已下载的文件总占用，设置页展示用。 */
  diskUsage(): number {
    return dirSize(this.baseDir);
  }

  downloadDir(): string {
    return this.baseDir;
  }

  /** 清空应用内下载目录（不动已入相册的副本）。 */
  clearDownloads(): number {
    let n: number = 0;
    try {
      const names: string[] = fileIo.listFileSync(this.baseDir);
      for (let i = 0; i < names.length; i++) {
        n += removeRecursive(`${this.baseDir}/${names[i]}`);
      }
    } catch (e) {
      Logger.error(`清空下载目录失败：${errText(e as object)}`);
    }
    Logger.info(`已清理 ${n} 个文件`);
    return n;
  }
}

/** 异常 → 用户能看懂的一句话。 */
function describe(e: Object): string {
  if (e instanceof ResolveError) {
    return (e as ResolveError).message;
  }
  if (e instanceof DownloadError) {
    return (e as DownloadError).message;
  }
  return errText(e);
}

function toJson(t: DownloadTask): TaskJson {
  return {
    taskId: t.taskId, url: t.url, platform: t.platform as string, title: t.title,
    author: t.author, status: t.status as string, progress: t.progress, speed: '',
    size: t.size, savePath: t.savePath, errorMsg: t.errorMsg, isBatch: t.isBatch,
    batchTotal: t.batchTotal, batchDone: t.batchDone, createdAt: t.createdAt,
  };
}

function fromJson(j: TaskJson): DownloadTask {
  const t = new DownloadTask(j.taskId, j.url, j.platform as Platform);
  t.title = j.title;
  t.author = j.author;
  // 重启后未完成的任务一律标失败：直链有时效，恢复到一半没意义
  const st: TaskStatus = j.status as TaskStatus;
  if (st === TaskStatus.RUNNING || st === TaskStatus.PARSING || st === TaskStatus.PENDING) {
    t.status = TaskStatus.ERROR;
    t.errorMsg = '应用重启前未完成，直链已失效，请重新下载';
  } else {
    t.status = st;
  }
  t.progress = j.progress;
  t.size = j.size;
  t.savePath = j.savePath;
  if (t.errorMsg === '') {
    t.errorMsg = j.errorMsg;
  }
  t.isBatch = j.isBatch;
  t.batchTotal = j.batchTotal;
  t.batchDone = j.batchDone;
  t.createdAt = j.createdAt;
  return t;
}

function ensureDir(path: string): void {
  try {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path, true);
    }
  } catch (e) {
    Logger.error(`创建目录失败 ${path}：${errText(e as object)}`);
  }
}

function dirSize(path: string): number {
  let total: number = 0;
  try {
    if (!fileIo.accessSync(path)) {
      return 0;
    }
    const st: fileIo.Stat = fileIo.statSync(path);
    if (!st.isDirectory()) {
      return st.size;
    }
    const names: string[] = fileIo.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      total += dirSize(`${path}/${names[i]}`);
    }
  } catch (e) {
    // 忽略单个文件的统计失败
  }
  return total;
}

function removeRecursive(path: string): number {
  let n: number = 0;
  try {
    const st: fileIo.Stat = fileIo.statSync(path);
    if (st.isDirectory()) {
      const names: string[] = fileIo.listFileSync(path);
      for (let i = 0; i < names.length; i++) {
        n += removeRecursive(`${path}/${names[i]}`);
      }
      fileIo.rmdirSync(path);
    } else {
      fileIo.unlinkSync(path);
      n = 1;
    }
  } catch (e) {
    // 忽略
  }
  return n;
}

export const TaskManager: TaskManagerImpl = new TaskManagerImpl();
