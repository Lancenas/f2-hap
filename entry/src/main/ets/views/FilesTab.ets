/**
 * 「已下载」页 —— 直接读应用沙箱 filesDir/downloads 下的真实文件。
 *
 * 为什么需要它：下载任务跑完只把文件落盘到沙箱，并把状态写进「任务」历史。
 * 但「任务」页只展示历史卡片，没有任何打开/导出入口；而「存入系统相册」依赖
 * 系统弹窗让用户当场确认，一旦没确认或被遮挡，文件就卡在沙箱里取不出来。
 * 于是用户既在应用内找不到已下载视频，也进不了相册。
 *
 * 本页绕开这套不确定性，直接列磁盘上的文件，提供四个动作：
 *   1. 打开       —— 用系统播放器/看图打开（viewData + 授权读 uri）
 *   2. 存入相册   —— 复用 GallerySaver，手动补一次入库（相册弹窗没确认时的兜底）
 *   3. 分享       —— 系统分享面板（sendData + 授权读 uri）
 *   4. 删除       —— 直接从沙箱移除
 */

import { fileIo } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { abilityAccessCtrl, common, Permissions, Want, wantConstant } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { TaskManager } from '../core/download/TaskManager';
import { GallerySaver, PendingAsset } from '../core/download/GallerySaver';
import { MediaType, Platform, formatSize } from '../core/model/Models';
import { Logger } from '../core/util/Logger';
import { errText } from '../core/store/ConfigStore';
import { BRAND, CARD_RADIUS, GAP, MUTED, PAGE_PADDING, platformBadge, platformColor } from './Theme';

/** 沙箱内一个已下载文件。 */
interface LocalFile {
  path: string;
  name: string;
  platform: string;
  ext: string;
  size: number;
  isImage: boolean;
  mtime: number;
}

const IMAGE_EXTS: string[] = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'];

@Component
export struct FilesTab {
  @State files: LocalFile[] = [];
  @State total: number = 0;
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    // 用 EntryAbility 存进 AppStorage 的真正 UIAbilityContext：showAssetsCreationDialog 的弹窗
    // 必须挂在 UIAbility 上；组件内 getContext(this) 拿到的是组件 context，挂相册 UIExtension 会
    // 瞬间 detach，导致弹窗一弹就关（hilog 表现为 photosSaveUIExtensionAbility 秒级 DESTRUCTION）。
    this.ctx = (AppStorage.get('uiAbilityContext') as common.UIAbilityContext | undefined) ?? null;
    this.refresh();
  }

  /** 递归读磁盘，按修改时间倒序。 */
  private refresh(): void {
    const root: string = TaskManager.downloadDir();
    const out: LocalFile[] = [];
    this.walk(root, out);
    out.sort((a: LocalFile, b: LocalFile) => b.mtime - a.mtime);
    this.files = out;
    let sum: number = 0;
    for (let i = 0; i < out.length; i++) {
      sum += out[i].size;
    }
    this.total = sum;
  }

  private walk(dir: string, out: LocalFile[]): void {
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const full: string = `${dir}/${name}`;
      let st: fileIo.Stat | null = null;
      try {
        st = fileIo.statSync(full);
      } catch (e) {
        continue;
      }
      if (st.isDirectory()) {
        this.walk(full, out);
        continue;
      }
      const ext: string = name.includes('.') ? name.split('.').pop()!.toLowerCase() : '';
      const isImage: boolean = IMAGE_EXTS.includes(ext);
      // 路径形如 …/downloads/<平台>/<文件>，取 downloads 下第一段作为平台名
      const seg: string[] = dir.split('/');
      const platform: string = seg.length >= 2 ? seg[seg.length - 1] : '';
      out.push({
        path: full,
        name: name,
        platform: platform,
        ext: ext,
        size: st.size,
        isImage: isImage,
        mtime: st.mtime,
      });
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2200 });
  }

  /**
   * 打开/分享/存相册前确保媒体读写权限已授予。
   * READ_MEDIA / WRITE_MEDIA 是 user_grant，需弹窗让用户确认；已授权时系统不再弹窗。
   * 本方法只负责「申请」，不阻塞后续动作：即使被拒也继续（NEXT 上 showAssetsCreationDialog
   * 可走系统授权模型，viewData/sendData 用 FLAG_AUTH_READ_URI_PERMISSION 授权单文件 URI）。
   */
  private async ensureMediaPerm(): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    const perms: Array<Permissions> = [
      'ohos.permission.READ_MEDIA',
      'ohos.permission.WRITE_MEDIA',
    ];
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(this.ctx, perms);
    } catch (e) {
      Logger.warn(`申请媒体权限失败：${errText(e as object)}`);
    }
  }

  /** 用系统播放器/看图打开（video/* 或 image/*）。 */
  private async openFile(f: LocalFile): Promise<void> {
    if (this.ctx === null) {
      this.toast('上下文不可用，无法打开');
      return;
    }
    // 打开系统查看器读取沙箱文件前，先确保媒体读权限已授予（部分系统版本需要）。
    await this.ensureMediaPerm();
    const mime: string = f.isImage ? 'image/*' : 'video/*';
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: fileUri.getUriFromPath(f.path),
      type: mime,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
    };
    try {
      this.ctx.startAbility(want);
      Logger.info(`打开文件：${f.path}`);
    } catch (e) {
      this.toast(`打开失败：${errText(e as object)}`);
    }
  }

  /** 存相册：复用 GallerySaver 的弹窗式入库。 */
  private async saveToAlbum(f: LocalFile): Promise<void> {
    if (this.ctx === null) {
      this.toast('上下文不可用，无法存相册');
      return;
    }
    // 相册保存窗（showAssetsCreationDialog）在部分系统版本需要 WRITE_MEDIA 已授予，
    // 弹窗前先申请；即便被拒也继续尝试（NEXT 上该弹窗可走系统授权模型）。
    await this.ensureMediaPerm();
    const titleNoExt: string = f.name.replace(/\.[^.]+$/, '');
    const asset: PendingAsset = new PendingAsset(f.path, titleNoExt, f.ext,
      f.isImage ? MediaType.IMAGE : MediaType.VIDEO);
    try {
      const res = await GallerySaver.saveBatch(this.ctx, [asset]);
      this.toast(res.message === '' ? '已处理' : res.message);
    } catch (e) {
      Logger.error(`存相册异常：${errText(e as object)}`);
      this.toast(`存相册失败：${errText(e as object)}`);
    }
  }

  /** 系统分享面板。 */
  private async shareFile(f: LocalFile): Promise<void> {
    if (this.ctx === null) {
      this.toast('上下文不可用，无法分享');
      return;
    }
    await this.ensureMediaPerm();
    const mime: string = f.isImage ? 'image/*' : 'video/*';
    const want: Want = {
      action: 'ohos.want.action.sendData',
      uri: fileUri.getUriFromPath(f.path),
      type: mime,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
    };
    try {
      this.ctx.startAbility(want);
      Logger.info(`分享文件：${f.path}`);
    } catch (e) {
      this.toast(`分享失败：${errText(e as object)}`);
    }
  }

  private deleteFile(f: LocalFile): void {
    try {
      fileIo.unlinkSync(f.path);
      this.toast('已删除');
      Logger.info(`删除文件：${f.path}`);
      this.refresh();
    } catch (e) {
      this.toast(`删除失败：${errText(e as object)}`);
    }
  }

  private fmtDate(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const d: Date = new Date(ms);
    const p = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getMonth() + 1}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  build() {
    Column() {
      Row() {
        Text('已下载')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(this.total > 0 ? formatSize(this.total) : '')
          .fontSize(13)
          .fontColor(MUTED)
      }
      .width('100%')
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 8, bottom: 10 })

      if (this.files.length === 0) {
        Column({ space: 10 }) {
          Text('还没有已下载的文件')
            .fontSize(16)
            .fontColor($r('sys.color.font_secondary'))
          Text('到「下载」页粘贴链接，完成后文件会落在这里')
            .fontSize(13)
            .fontColor(MUTED)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: GAP }) {
          ForEach(this.files, (f: LocalFile) => {
            ListItem() {
              this.fileCard(f)
            }
          }, (f: LocalFile) => f.path)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING, bottom: PAGE_PADDING })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .onAppear(() => {
      this.refresh();
    })
  }

  @Builder
  fileCard(f: LocalFile) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(platformBadge(this.platformToEnum(f.platform)))
          .fontSize(11)
          .fontColor(Color.White)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(platformColor(this.platformToEnum(f.platform)))
          .borderRadius(5)
        Text(f.name)
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (f.isImage) {
          Text('图')
            .fontSize(11)
            .fontColor(Color.White)
            .backgroundColor('#34C759')
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        } else {
          Text('视频')
            .fontSize(11)
            .fontColor(Color.White)
            .backgroundColor(BRAND)
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        }
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(formatSize(f.size))
          .fontSize(12)
          .fontColor(MUTED)
        Text(this.fmtDate(f.mtime))
          .fontSize(12)
          .fontColor(MUTED)
        Blank()
      }
      .width('100%')

      Row({ space: 8 }) {
        this.actBtn('打开', () => {
          this.openFile(f);
        })
        this.actBtn('存相册', () => {
          this.saveToAlbum(f);
        })
        this.actBtn('分享', () => {
          this.shareFile(f);
        })
        Blank()
        this.actBtn('删除', () => {
          this.deleteFile(f);
        }, true)
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(CARD_RADIUS)
  }

  private platformToEnum(p: string): Platform {
    const k: string = (p || '').toLowerCase();
    if (k === 'douyin') {
      return Platform.DOUYIN;
    }
    if (k === 'weibo') {
      return Platform.WEIBO;
    }
    if (k === 'twitter') {
      return Platform.TWITTER;
    }
    if (k === 'tiktok') {
      return Platform.TIKTOK;
    }
    return Platform.UNKNOWN;
  }

  @Builder
  actBtn(label: string, action: () => void, danger: boolean = false) {
    Text(label)
      .fontSize(13)
      .fontColor(danger ? '#D93A3A' : $r('sys.color.font_secondary'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius(8)
      .onClick(action)
  }
}
