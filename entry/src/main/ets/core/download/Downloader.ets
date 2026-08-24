/**
 * 流式下载器。
 *
 * 用 http.requestInStream + on('dataReceive') 边收边写，而不是 request() 把整个
 * 文件读进内存 —— 手机上一条 4K 视频几百 MB，一次性进内存必 OOM。
 *
 * 关键点：
 *   1. dataReceive 回调里用 fileIo.writeSync 同步写。writeSync 的 offset 是
 *      「相对当前 filePointer」的，所以不能传 bytesWritten，否则会翻倍跳位置 ——
 *      直接不传，让 filePointer 自然前进。
 *   2. 进度走 on('dataReceiveProgress')，拿 receiveSize / totalSize。有些 CDN
 *      不给 Content-Length，totalSize 会是 0，这时按「已下载字节数」显示，不显示百分比。
 *   3. 取消 = req.destroy()，会让 requestInStream 的 Promise reject，统一走异常出口。
 *   4. 先写 .part 临时文件，全部成功后再 rename 成正式名字，避免半截文件被当成成品。
 */

import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { MediaItem } from '../model/Models';
import { Logger } from '../util/Logger';
import { errText } from '../store/ConfigStore';

/** 进度回调：已下载字节、总字节（未知为 0）、瞬时速度（字节/秒）。 */
export type ProgressFn = (received: number, total: number, bytesPerSec: number) => void;

const CONNECT_TIMEOUT: number = 15000;
const READ_TIMEOUT: number = 120000;

/** 单个文件的下载句柄，支持外部取消。 */
export class DownloadHandle {
  private req: http.HttpRequest | null = null;
  private cancelled: boolean = false;

  cancel(): void {
    this.cancelled = true;
    if (this.req !== null) {
      this.req.destroy();
      this.req = null;
    }
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  /** 内部用：绑定底层请求，便于 cancel() 生效。 */
  attach(r: http.HttpRequest): void {
    this.req = r;
    if (this.cancelled) {
      // 绑定前就被取消了
      r.destroy();
    }
  }

  detach(): void {
    this.req = null;
  }
}

export class DownloadError extends Error {
  status: number = 0;

  constructor(message: string, status: number = 0) {
    super(message);
    this.name = 'DownloadError';
    this.status = status;
  }
}

export class Downloader {
  /**
   * 下载一个 MediaItem 到指定绝对路径。
   *
   * @param item 含直链和必需请求头（抖音/微博的 CDN 少了 Referer 就 403）
   * @param destPath 目标绝对路径（沙箱内），父目录必须已存在
   * @param handle 取消句柄
   * @param onProgress 进度回调，约 500ms 节流一次
   * @returns 实际写入的字节数
   */
  static async fetchToFile(item: MediaItem, destPath: string, handle: DownloadHandle,
                           onProgress: ProgressFn): Promise<number> {
    const partPath: string = destPath + '.part';
    removeIfExists(partPath);

    const file: fileIo.File = fileIo.openSync(
      partPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    const fd: number = file.fd;

    const req: http.HttpRequest = http.createHttp();
    handle.attach(req);

    let written: number = 0;
    let total: number = 0;
    let writeErr: string = '';
    let lastTick: number = Date.now();
    let lastBytes: number = 0;

    const onData = (buf: ArrayBuffer): void => {
      if (writeErr !== '') {
        return;
      }
      try {
        // 不传 offset：WriteOptions.offset 是相对 filePointer 的偏移
        written += fileIo.writeSync(fd, buf);
      } catch (e) {
        writeErr = errText(e as object);
      }
    };

    const onProg = (info: http.DataReceiveProgressInfo): void => {
      total = info.totalSize;
      const now: number = Date.now();
      const dt: number = now - lastTick;
      if (dt >= 500) {
        const speed: number = Math.floor((info.receiveSize - lastBytes) * 1000 / dt);
        lastTick = now;
        lastBytes = info.receiveSize;
        onProgress(info.receiveSize, info.totalSize, speed);
      }
    };

    try {
      req.on('dataReceive', onData);
      req.on('dataReceiveProgress', onProg);

      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: item.headers,
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: READ_TIMEOUT,
        usingCache: false,
        maxRedirects: 5,
      };
      const code: number = await req.requestInStream(item.url, opts);
      if (code < 200 || code >= 300) {
        throw new DownloadError(`服务端返回 ${code}`, code);
      }
      if (writeErr !== '') {
        throw new DownloadError(`写文件失败：${writeErr}`);
      }
      if (written === 0) {
        throw new DownloadError('服务端没返回任何数据（直链可能已过期，重新解析一次）');
      }
      if (total > 0 && written < total) {
        throw new DownloadError(`数据不完整：收到 ${written} / ${total} 字节`);
      }
    } catch (e) {
      closeQuiet(file);
      removeIfExists(partPath);
      if (handle.isCancelled()) {
        throw new DownloadError('已取消');
      }
      if (e instanceof DownloadError) {
        throw e;
      }
      throw new DownloadError(errText(e as object));
    } finally {
      req.off('dataReceive', onData);
      req.off('dataReceiveProgress', onProg);
      req.destroy();
      handle.detach();
    }

    closeQuiet(file);
    // .part → 正式名
    removeIfExists(destPath);
    try {
      fileIo.renameSync(partPath, destPath);
    } catch (e) {
      // rename 跨设备会失败，退到复制
      try {
        fileIo.copyFileSync(partPath, destPath);
        removeIfExists(partPath);
      } catch (e2) {
        throw new DownloadError(`落盘失败：${errText(e2 as object)}`);
      }
    }
    onProgress(written, total > 0 ? total : written, 0);
    Logger.info(`下载完成 ${written} 字节 → ${destPath}`);
    return written;
  }
}

function closeQuiet(f: fileIo.File): void {
  try {
    fileIo.closeSync(f);
  } catch (e) {
    // 已关闭，忽略
  }
}

function removeIfExists(path: string): void {
  try {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (e) {
    // 不存在或无权限，忽略
  }
}
