# F2 HAP

抖音 / X(Twitter) / 微博 无水印视频与图集下载器 —— **HarmonyOS NEXT** 原生应用。

由 macOS 版 [F2 Downloader](https://github.com/Lancenas) 移植而来。与桌面版最大的区别：**没有 Python 运行时，没有第三方解析 API**，全部签名算法与解析逻辑都用 ArkTS 在设备本机重写，联网只跟平台自家接口打交道。

---

## 能做什么

| 平台 | 视频 | 图集 | 登录要求 | 说明 |
|---|:--:|:--:|---|---|
| 抖音 Douyin | ✅ | ✅ | 需 Cookie | 本机 `a_bogus` 签名（SM3 + 自定义 RC4），走 `aweme/v1/web/aweme/detail` |
| X (Twitter) | ✅ | ✅ | **免登录** | 主路线 `cdn.syndication.twimg.com`；兜底 guest_token + GraphQL |
| 微博 Weibo | ✅ | ✅ | 需 Cookie | `weibo.com/ajax/statuses/show`，自动下潜转发原文 |
| TikTok | ⚠️ | ⚠️ | — | 需 XBogus 签名 + 设备注册，**当前版本未移植**，成功率极低 |

其它能力：

- **系统分享接入** —— 在抖音/微博里点「分享 → F2 HAP」直接建任务，无需手动复制
- **剪贴板自动识别** —— 打开应用即读剪贴板，识别到链接自动填入
- **短链展开** —— `v.douyin.com` / `t.cn` / `t.co` 自动跟随跳转，展开后重新判定平台
- **多档码率择优** —— 视频取 `video/mp4` 中 bitrate 最高档，跳过 m3u8；图片取原图（`?name=orig` / `largest`）
- **存入系统相册** —— 走 `showAssetsCreationDialog` 弹窗授权，**不申请受限权限**，无需 ACL 审批
- **断点式落盘** —— 流式写 `.part` 临时文件，完成后 rename，避免半成品混入
- **并发闸门** —— 1~5 可调，任务队列常驻同一 ArkTS 运行时
- **实时日志** —— 分级过滤、一键复制，解析失败能直接看到是哪一步断的

---

## 快速上手

```bash
git clone https://github.com/Lancenas/f2-hap.git
cd f2-hap
bash scripts/dev-build.sh debug            # 构建
bash scripts/dev-build.sh debug install    # 构建并安装到已连接设备
```

详细的环境要求、签名配置与常见构建报错见 **[docs/BUILD.md](docs/BUILD.md)**。

首次使用需要在「设置」页填 Cookie（抖音、微博）。X(Twitter) 不需要，可直接下载。Cookie 获取方式在设置页每一项下方都有说明。

---

## 工程结构

```
f2-hap/
├── AppScope/                       # 应用级配置（bundleName / versionName / 图标）
├── entry/src/main/
│   ├── ets/
│   │   ├── core/
│   │   │   ├── crypto/             # SM3.ets、ABogus.ets —— 抖音签名算法本机实现
│   │   │   ├── model/Models.ets    # DownloadTask / MediaItem / ResolveResult / 枚举
│   │   │   ├── net/HttpClient.ets  # 统一 GET/POST、重试、UA、Cookie 注入
│   │   │   ├── platform/           # 四个 Resolver + PlatformDetector + ResolverRegistry
│   │   │   ├── download/           # Downloader（流式）、GallerySaver（相册）、TaskManager（队列）
│   │   │   ├── store/ConfigStore   # preferences 持久化（Cookie / UA / 并发 / 开关）
│   │   │   └── util/Logger.ets     # 环形缓冲 + 订阅推送
│   │   ├── entryability/           # EntryAbility：初始化 + 接收系统分享
│   │   ├── pages/Index.ets         # 四 Tab 主入口
│   │   └── views/                  # DownloadTab / TasksTab / LogsTab / SettingsTab / Theme
│   ├── module.json5                # 权限、分享 skills 声明
│   └── resources/
├── scripts/dev-build.sh            # 一键构建 + 签名注入 + 安装
└── docs/{BUILD.md, ARCHITECTURE.md}
```

## 与 macOS 版的架构差异

桌面版是 **Swift 进程 + Python 常驻服务 + 文件队列** 三段式，跨进程通信曾导致「任务一直停在等待中」（Python 子进程退出后 daemon 线程被杀）。

HAP 版全部跑在同一个 ArkTS 运行时里：

```
UI (ArkUI)  ──订阅──▶  TaskManager（内存队列 + 并发闸门）
                            │
                    ResolverRegistry ──▶ Douyin / Twitter / Weibo / TikTok Resolver
                            │                        │
                            │                   HttpClient（UA + Cookie + 重试）
                            ▼
                       Downloader（requestInStream 流式落盘）
                            ▼
                       GallerySaver（showAssetsCreationDialog）
```

没有进程边界，任务不会凭空停住；代价是签名算法必须自己在 ArkTS 里重写一遍。

## 隐私

- Cookie 只存在应用沙箱的 `preferences` 里，不上传、不出设备
- 除目标平台自家域名外，不连任何服务器；没有统计、没有埋点
- 下载文件落在沙箱 `filesDir/downloads`，存相册需要你在系统弹窗里逐次确认

## 免责声明

仅供个人学习与备份自己可访问的公开内容使用。请遵守各平台服务条款与著作权法，不要用于批量抓取或商业分发。

## License

Apache-2.0
