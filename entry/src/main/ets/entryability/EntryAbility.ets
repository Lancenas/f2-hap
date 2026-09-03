/**
 * 应用入口 Ability。
 *
 * 除了常规拉起首页，还负责两件事：
 *   1. 在 onCreate 里把 ConfigStore / TaskManager 初始化好 —— 这两个都依赖
 *      UIAbilityContext（preferences 要 context，相册弹窗要 UIAbilityContext），
 *      不能在页面里临时拿。
 *   2. 接收系统分享（module.json5 里声明了 ohos.want.action.sendData 与 http/https
 *      scheme）。用户在抖音里点「分享 → F2」时，链接会从 want.parameters 进来，
 *      直接塞进 AppStorage，首页读到就自动填进输入框。
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window, AppStorage } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { ConfigStore } from '../core/store/ConfigStore';
import { TaskManager } from '../core/download/TaskManager';
import { Logger } from '../core/util/Logger';
import { extractUrl } from '../core/platform/PlatformDetector';

const DOMAIN: number = 0xF2D;
const TAG: string = 'F2Hap';

/** 首页会监听这个 key，收到非空就自动填入输入框。 */
export const SHARED_URL_KEY: string = 'sharedUrl';

/** 读取剪贴板需要的隐私权限（user_grant，必须动态申请）。 */
const PERMS: Array<Permissions> = ['ohos.permission.READ_PASTEBOARD'];

export default class EntryAbility extends UIAbility {
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    AppStorage.setOrCreate<string>(SHARED_URL_KEY, '');
    // 设置页用它监听「应用内登录获取」写回的 Cookie，自动刷新体检卡
    AppStorage.setOrCreate<number>('cookieVersion', 0);
    await this.requestPasteboardPerm();
    await ConfigStore.init(this.context);
    await TaskManager.init(this.context);
    this.pickSharedUrl(want);
  }

  /** 动态申请剪贴板读取权限；已授权时系统不会再弹窗，失败仅告警（不影响其它功能）。 */
  private async requestPasteboardPerm(): Promise<void> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(this.context, PERMS);
    } catch (e) {
      Logger.warn(`申请剪贴板权限失败：${(e as Error).message}`);
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用已在后台时再次分享，走这里
    this.pickSharedUrl(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
  }

  onBackground(): void {
  }

  /** 从 want 的各个可能位置里找链接：uri、parameters 里的纯文本字段。 */
  private pickSharedUrl(want: Want): void {
    let candidate: string = '';
    if (want.uri !== undefined && want.uri !== null && want.uri !== '') {
      candidate = want.uri;
    }
    const params = want.parameters;
    if (candidate === '' && params !== undefined && params !== null) {
      const keys: string[] = ['ability.want.params.text', 'text', 'url', 'shareText'];
      for (let i = 0; i < keys.length; i++) {
        const v: Object | undefined = params[keys[i]];
        if (typeof v === 'string' && (v as string) !== '') {
          candidate = v as string;
          break;
        }
      }
    }
    if (candidate === '') {
      return;
    }
    const url: string = extractUrl(candidate);
    const final: string = url === '' ? candidate : url;
    AppStorage.setOrCreate<string>(SHARED_URL_KEY, final);
    Logger.info(`收到系统分享：${final.substring(0, 80)}`);
  }
}
