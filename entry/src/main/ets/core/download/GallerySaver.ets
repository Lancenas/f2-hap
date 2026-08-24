/**
 * 保存到系统相册。
 *
 * 用 photoAccessHelper.showAssetsCreationDialog：弹一次系统授权弹窗，用户确认后
 * 返回媒体库里的目标 uri，应用再把沙箱文件内容拷进去。
 *
 * 为什么不用 MediaAssetChangeRequest.createAssetRequest：那条路要
 * ohos.permission.WRITE_IMAGEVIDEO，这是受限权限（restricted），调试证书要单独
 * 申请 ACL 才能装上去，做起来很折腾。showAssetsCreationDialog 走的是「用户当场
 * 授权」模型，一个权限都不用申请，代价只是多一次弹窗 —— 手机端可接受。
 *
 * 因此这里按「一个任务攒一批」调用，而不是一个文件弹一次。
 */

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { MediaType } from '../model/Models';
import { Logger } from '../util/Logger';
import { errText } from '../store/ConfigStore';

/** 待入库的一个文件。 */
export class PendingAsset {
  /** 沙箱内绝对路径 */
  path: string = '';
  /** 不含扩展名的标题 */
  title: string = '';
  /** 扩展名，不带点 */
  ext: string = 'mp4';
  type: MediaType = MediaType.VIDEO;

  constructor(path: string = '', title: string = '', ext: string = 'mp4',
              type: MediaType = MediaType.VIDEO) {
    this.path = path;
    this.title = title;
    this.ext = ext;
    this.type = type;
  }
}

export class GallerySaveResult {
  saved: number = 0;
  failed: number = 0;
  message: string = '';
}

export class GallerySaver {
  /**
   * 批量入库。
   *
   * @param ctx UIAbilityContext —— 弹窗必须挂在 UIAbility 上，用 ApplicationContext 会失败
   * @param assets 待入库文件
   */
  static async saveBatch(ctx: common.UIAbilityContext,
                         assets: PendingAsset[]): Promise<GallerySaveResult> {
    const out = new GallerySaveResult();
    if (assets.length === 0) {
      out.message = '没有待入库的文件';
      return out;
    }

    const srcUris: string[] = [];
    const configs: photoAccessHelper.PhotoCreationConfig[] = [];
    const usable: PendingAsset[] = [];

    for (let i = 0; i < assets.length; i++) {
      const a: PendingAsset = assets[i];
      if (!existsQuiet(a.path)) {
        Logger.warn(`入库跳过（文件不存在）：${a.path}`);
        out.failed++;
        continue;
      }
      usable.push(a);
      srcUris.push(fileUri.getUriFromPath(a.path));
      configs.push({
        title: a.title,
        fileNameExtension: a.ext,
        photoType: a.type === MediaType.IMAGE
          ? photoAccessHelper.PhotoType.IMAGE
          : photoAccessHelper.PhotoType.VIDEO,
      } as photoAccessHelper.PhotoCreationConfig);
    }

    if (usable.length === 0) {
      out.message = '文件都不存在，无法入库';
      return out;
    }

    try {
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const targets: string[] = await helper.showAssetsCreationDialog(srcUris, configs);
      if (targets.length === 0) {
        out.message = '用户取消了相册授权，文件仍保留在应用内';
        Logger.warn(out.message);
        return out;
      }
      const n: number = Math.min(targets.length, usable.length);
      for (let i = 0; i < n; i++) {
        if (copyInto(usable[i].path, targets[i])) {
          out.saved++;
        } else {
          out.failed++;
        }
      }
      out.message = out.failed === 0
        ? `已存入相册 ${out.saved} 个文件`
        : `入库 ${out.saved} 成功、${out.failed} 失败`;
      Logger.info(out.message);
      return out;
    } catch (e) {
      out.failed = usable.length;
      out.message = `相册入库失败：${errText(e as object)}`;
      Logger.error(out.message);
      return out;
    }
  }
}

/** 把沙箱文件内容写进媒体库返回的 uri。 */
function copyInto(srcPath: string, destUri: string): boolean {
  let dst: fileIo.File | null = null;
  try {
    dst = fileIo.openSync(destUri, fileIo.OpenMode.WRITE_ONLY);
    fileIo.copyFileSync(srcPath, dst.fd);
    return true;
  } catch (e) {
    Logger.error(`写入相册失败 ${srcPath}：${errText(e as object)}`);
    return false;
  } finally {
    if (dst !== null) {
      try {
        fileIo.closeSync(dst);
      } catch (e2) {
        // 忽略
      }
    }
  }
}

function existsQuiet(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (e) {
    return false;
  }
}
