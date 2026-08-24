/**
 * 内存日志缓冲 + hilog 双写。
 *
 * macOS 版有一个「日志」面板，手机版同样保留，所以日志不能只进 hilog，
 * 还要留一份在内存里供 UI 读取。上限 500 条，超出丢弃最旧的。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { formatClock } from '../model/Models';

const DOMAIN: number = 0xF2D;
const TAG: string = 'F2Hap';
const MAX_LINES: number = 500;

export enum LogLevel {
  DEBUG = 'DEBUG',
  INFO = 'INFO',
  WARN = 'WARN',
  ERROR = 'ERROR',
}

export class LogLine {
  time: string = '';
  level: LogLevel = LogLevel.INFO;
  text: string = '';

  constructor(level: LogLevel, text: string) {
    this.time = formatClock(new Date());
    this.level = level;
    this.text = text;
  }
}

export type LogListener = (lines: LogLine[]) => void;

class LoggerImpl {
  private lines: LogLine[] = [];
  private listeners: LogListener[] = [];

  private push(level: LogLevel, msg: string): void {
    const line = new LogLine(level, msg);
    this.lines.push(line);
    if (this.lines.length > MAX_LINES) {
      this.lines.splice(0, this.lines.length - MAX_LINES);
    }
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](this.lines);
    }
  }

  debug(msg: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', msg);
    this.push(LogLevel.DEBUG, msg);
  }

  info(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
    this.push(LogLevel.INFO, msg);
  }

  warn(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
    this.push(LogLevel.WARN, msg);
  }

  error(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
    this.push(LogLevel.ERROR, msg);
  }

  all(): LogLine[] {
    return this.lines.slice();
  }

  clear(): void {
    this.lines = [];
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](this.lines);
    }
  }

  /** 返回反注册函数。 */
  subscribe(cb: LogListener): () => void {
    this.listeners.push(cb);
    return () => {
      const idx: number = this.listeners.indexOf(cb);
      if (idx >= 0) {
        this.listeners.splice(idx, 1);
      }
    };
  }

  /** 导出为纯文本，便于「复制日志」。 */
  export(): string {
    let s: string = '';
    for (let i = 0; i < this.lines.length; i++) {
      const l: LogLine = this.lines[i];
      s += `[${l.time}] ${l.level} ${l.text}\n`;
    }
    return s;
  }
}

export const Logger: LoggerImpl = new LoggerImpl();
