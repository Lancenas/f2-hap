/**
 * 视觉常量。
 *
 * 手机端不做深浅色两套配色表，直接用 HarmonyOS 的系统资源色
 * （$r('sys.color.…')），系统切深色时会自动跟随，比自己维护两份色板可靠。
 * 只有品牌强调色和平台标识色是自定义的。
 */

import { Platform, TaskStatus } from '../core/model/Models';

/** 品牌色：取抖音的青粉之间的中间调，深浅色下都不刺眼。 */
export const BRAND: string = '#FF2C55';
export const BRAND_SOFT: string = '#1AFF2C55';

export const OK_COLOR: string = '#1F9E4F';
export const WARN_COLOR: string = '#E08A00';
export const ERR_COLOR: string = '#D93A3A';
export const MUTED: string = '#8A8A8E';

export const PAGE_PADDING: number = 16;
export const CARD_RADIUS: number = 14;
export const GAP: number = 12;

/** 各平台的标识色，任务卡片左侧色条用。 */
export function platformColor(p: Platform): string {
  switch (p) {
    case Platform.DOUYIN: return '#FF2C55';
    case Platform.TIKTOK: return '#25F4EE';
    case Platform.TWITTER: return '#1D9BF0';
    case Platform.WEIBO: return '#E6162D';
    default: return MUTED;
  }
}

/** 状态色，与 statusLabel 配合。 */
export function statusColor(s: TaskStatus): string {
  switch (s) {
    case TaskStatus.DONE: return OK_COLOR;
    case TaskStatus.ERROR: return ERR_COLOR;
    case TaskStatus.CANCELLED: return MUTED;
    case TaskStatus.RUNNING: return '#1D9BF0';
    case TaskStatus.PARSING: return WARN_COLOR;
    default: return MUTED;
  }
}

/** 平台首字，没有图标资源时当作标识。 */
export function platformBadge(p: Platform): string {
  switch (p) {
    case Platform.DOUYIN: return '抖';
    case Platform.TIKTOK: return 'TT';
    case Platform.TWITTER: return 'X';
    case Platform.WEIBO: return '微';
    default: return '?';
  }
}
