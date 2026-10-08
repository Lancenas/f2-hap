# 【HarmonyOS NEXT】从 0 到 1 把 Python 版下载器移植成 ArkTS 原生应用：抖音签名、X/微博免登录解析、流式下载与相册入库全流程

> **摘要**：博主之前用 `SwiftUI + Python` 写过一个 macOS 版视频下载器。最近把它移植到了 HarmonyOS NEXT 上——**没有 Python 运行时、没有第三方解析 API**，全部签名与解析逻辑用 ArkTS 在手机本机重写。本文记录整个移植过程的关键决策与踩坑：抖音 `a_bogus` 签名在 ArkTS 里的三个致命细节、X（Twitter）免登录的两条路线、微博转发下潜、流式下载 `writeSync` 偏移坑、不申请受限权限也能存相册的方案，以及「签名口令绝不入库」的 git hook 工程实践。文末附完整源码与报错对照表。
>
> **关键词**：HarmonyOS NEXT、ArkTS、ArkUI、国密 SM3、流式下载、photoAccessHelper、hvigor 签名、ArkTS 严格模式
>
> **开源地址**：https://github.com/Lancenas/f2-hap　　**License**：Apache-2.0　　**SDK**：API 24（6.1.1）

---

## 一、前言：为什么要重写一遍

先说清楚起点。博主原本有一个 macOS 桌面版下载器，架构是三段式：

```
SwiftUI 界面  ──▶  Python 常驻服务（f2 库）  ──▶  文件队列落盘
```

这套架构在桌面上能跑，但有两个老毛病：

1. **跨进程通信会丢状态**。Python 子进程退出后 daemon 线程被杀，界面上的任务会一直卡在「等待中」，用户以为在下载其实已经死了。
2. **搬到鸿蒙上直接不成立**。HarmonyOS NEXT 上压根没有 Python 运行时，也不允许你塞一个解释器进去。所有签名算法、解析逻辑必须**用 ArkTS 在设备本机重写**。

于是有了这个项目：**F2 HAP**。

它和桌面版最大的区别是——**全部逻辑跑在同一个 ArkTS 运行时里**，联网只跟平台自家接口打交道，没有中间服务器、没有第三方解析 API。代价很明确：签名算法得自己在 ArkTS 里再实现一遍。

先上能力清单，方便你判断这篇值不值得读下去：

| 平台 | 视频 | 图集 | 登录要求 | 实现路线 |
|---|:--:|:--:|---|---|
| 抖音 Douyin | ✅ | ✅ | 需 Cookie | 本机 `a_bogus` 签名（SM3 + 自定义 RC4），走 `aweme/v1/web/aweme/detail` |
| X (Twitter) | ✅ | ✅ | **免登录** | 主路线 `cdn.syndication.twimg.com`；兜底 guest_token + GraphQL |
| 微博 Weibo | ✅ | ✅ | 需 Cookie | `weibo.com/ajax/statuses/show`，自动下潜转发原文 |
| TikTok | ⚠️ | ⚠️ | — | 需 XBogus 签名 + 设备注册，**当前未移植** |

---

## 二、整体架构：一条链路跑在同一个运行时里

桌面版的进程边界没了，链路变成这样：

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

工程结构（共约 6000 行 ArkTS）：

```
entry/src/main/ets/
├── core/
│   ├── crypto/         # SM3.ets(165行)、ABogus.ets(480行) —— 抖音签名算法本机实现
│   ├── model/          # DownloadTask / MediaItem / ResolveResult / 枚举
│   ├── net/            # HttpClient.ets：统一 GET/POST、重试、UA、Cookie 注入
│   ├── platform/       # 四个 Resolver + PlatformDetector + ResolverRegistry
│   ├── download/       # Downloader(流式) / GallerySaver(相册) / TaskManager(队列)
│   ├── cookie/         # CookieDoctor：Cookie 健康度体检
│   ├── store/          # ConfigStore：preferences 持久化
│   └── util/           # Logger：环形缓冲 + 订阅推送
├── entryability/       # 初始化 + 接收系统分享
├── pages/              # Index(四 Tab) / CookieLoginPage
└── views/              # Download / Tasks / Logs / Settings / Theme
```

**没有进程边界，任务不会凭空停住**——这是这次移植最大的收益。

---

## 三、硬骨头：抖音签名算法在 ArkTS 里重写

抖音 web 端接口要求请求带上 `a_bogus` 参数，它由一套「SM3 摘要 + 自定义 RC4 + 置换表变换」的算法生成。Python 版 f2 里有现成实现（`f2/utils/abogus.py`，Apache-2.0），照着移植即可——但 **ArkTS 不是 Python**，中间有三个坑，踩中任何一个，签名都是「看着对、服务端就是不认」。

### 3.1 坑一：位运算会先把操作数截断成 int32

Python 的整数是任意精度的，ArkTS/JS 的位运算会先把操作数截断成 int32。而算法里要取**毫秒时间戳**的各个字节——毫秒时间戳约 `1.79e12`，远超 int32 范围。

```typescript
// ❌ 直觉写法：val 是毫秒时间戳，>> 会先被截断成 int32
const b = (val >> 24) & 255;

// ✅ 实际采用：用浮点除法显式表达，语义清晰
function byteAt(val: number, shift: number): number {
  return Math.floor(val / Math.pow(2, shift)) % 256;
}
```

> 有意思的是，直接写 `(val >> 24) & 255` **结果其实仍然正确**：截断只让数值相差 2^32 的整数倍，右移 ≤24 位后是 256 的倍数，恰好被 `& 255` 抹掉。但这是一个**不显眼的巧合**——一旦以后有人把 shift 改成 >24 或去掉掩码，就会静默出错且不报错。所以宁可写得啰嗦一点。

### 3.2 坑二：`bigArray` 置换表是有状态的

`transformBytes` 会**就地修改** bigArray。Python 版每次调用都新建对象所以没暴露问题；我在 ArkTS 里一开始把它做成模块级常量复用，结果**第一次签名正确、第二次开始全错**。

```typescript
class CryptoUtility {
  constructor(alphabets: string[]) {
    this.alphabets = alphabets;
    // 必须是副本：transformBytes 会就地修改它
    this.bigArray = BIG_ARRAY_SEED.slice();
  }
}

// 生成签名时：每次都用全新的 CryptoUtility
generate(params: string, request: string = ''): ABogusResult {
  const cu = new CryptoUtility([CHARACTER_1, CHARACTER_2]);
  ...
}
```

**经验**：移植带状态的算法时，先问一句「这个数组/对象会被修改吗」。

### 3.3 坑三：Python 的 `chr()/ord()` 中间值可以 > 255

Python 版用 `chr()/ord()` 在「字节值」和「字符」之间来回转换，中间值可能超过 255（例如毫秒时间戳 / 256^4 ≈ 407）。如果用 `Uint8Array` 或字符串来承载，就会被静默截断或者编码歧义。

解决办法：**内部统一用 `number[]` 表示码点序列**，不用 Uint8Array，也不用字符串。

```typescript
/** 字符串 → 码点数组（对应 Python 的 [ord(c) for c in s]） */
function toCodes(s: string): number[] {
  const out: number[] = new Array<number>(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i);
  }
  return out;
}
```

### 3.4 实测结论（省得你再试一遍）

这几个结论都是真机跑出来的，不是猜的：

| 项 | 结论 |
|---|---|
| `a_bogus` | 本机 ArkTS 生成的签名服务端直接接受，`status_code=0` |
| `msToken` | 用随机 126 位 + `'=='` 的假值就够，**不必**再移植 msToken 换取接口 |
| Cookie | 必须含 `ttwid`，否则 `aweme_detail` 返回 `null` |
| 直链回源 | 需要 `Referer: https://www.douyin.com/`，且 UA 要与签名时**完全一致** |
| CDN | 支持 Range（返回 206），下载器可做断点续传 |
| 参数顺序 | **必须固定**。签名是对拼好的整串做的，任何重排都校验失败 |

另外，抖音分享页 HTML 里的 `_ROUTER_DATA` 已经被清空（`loaderData` 的 `item_list` 是空数组），**纯抓 HTML 这条路已经走不通了**，只能走签名接口。

---

## 四、X（Twitter）：两条路线，都不需要登录

这是移植过程中最惊喜的部分——**完全不需要用户 Cookie**。

### 4.1 主路线：syndication 接口

```
https://cdn.syndication.twimg.com/tweet-result?id=<tweet_id>&lang=en&token=...
```

这是官方给第三方网站**嵌入推文**用的公开接口，不需要 bearer、不需要 guest token，直接返回 `mediaDetails[]`。

实测：`id=1349129669258448897` 能拿到图片，`id=719944021058060289` 能拿到 4 档 video variants（含 `application/x-mpegURL` 和 3 档 `video/mp4`）。

### 4.2 兜底路线：guest token + GraphQL

主路线挂了就走这条，两步：

1. `POST https://api.twitter.com/1.1/guest/activate.json` 换 `guest_token`（实测 200）
2. 带 `Authorization: Bearer <PUBLIC_BEARER>` + `x-guest-token` 请求 GraphQL

```typescript
const GQL_QUERY_ID: string = '0hWvDhmW8YQ-S_ib3azIrw';
const GQL_API: string = `https://api.twitter.com/graphql/${GQL_QUERY_ID}/TweetResultByRestId`;
```

> 注意：GraphQL 的 `queryId` **是会变的**。我试了几个候选，只有一个当前可用，另外几个返回 422/404，所以代码里只保留这一个。推文不存在时接口返回 `{"data":{"tweetResult":{}}}`，据此可以判定「已删除」而不是「解析失败」——这个区分对用户体验很重要。

### 4.3 码率择优

视频取 `content_type == video/mp4` 里 `bitrate` **最高**的那一档，**m3u8 直接跳过**——手机端没有本地转封装能力，拉下来也播不了。

```typescript
// 视频：取 video/mp4 中 bitrate 最高档，跳过 m3u8
```

---

## 五、微博与短链：转发下潜 + 平台再判定

微博相对简单，走 `weibo.com/ajax/statuses/show`。值得一提的是一个体验细节：**自动下潜转发原文**。用户分享的常常是一条转发微博，直链在原文里，所以解析时会递归往回找一层。

短链则是另一个必须处理的环节。`v.douyin.com` / `t.cn` / `t.co` 这类短链无法直接提取 ID，必须**自动跟随跳转**，展开成真实 URL 后**重新判定平台**——因为短链和目标站不一定是同一个平台。

```
输入 URL ──▶ PlatformDetector 判定
                │
                ├── 是短链？──▶ 跟随跳转 ──▶ 用最终 URL 重新判定
                │
                └── 提取 ID ──▶ ResolverRegistry 分发到对应 Resolver
```

---

## 六、下载与落盘：别让几百 MB 进内存

手机上一条 4K 视频几百 MB，`http.request()` 把整个文件读进内存必 OOM。必须用 `requestInStream` 边收边写。

### 6.1 流式落盘的实现

```typescript
const req: http.HttpRequest = http.createHttp();
handle.attach(req);

const onData = (buf: ArrayBuffer): void => {
  if (writeErr !== '') { return; }
  try {
    // 关键：不传 offset
    written += fileIo.writeSync(fd, buf);
  } catch (e) {
    writeErr = errText(e as object);
  }
};

req.on('dataReceive', onData);
req.on('dataReceiveProgress', onProg);
const code: number = await req.requestInStream(item.url, opts);
```

### 6.2 `writeSync` 的 offset 是个陷阱

`WriteOptions.offset` 是**相对当前 filePointer** 的偏移，不是绝对位置。如果照直觉传 `bytesWritten`，写指针会**翻倍跳位置**，文件直接写花。

正确做法是**干脆不传**，让 filePointer 自然前进。

### 6.3 先写 `.part`，成功再 rename

避免半截文件被后续流程当成成品：

```typescript
const partPath: string = destPath + '.part';
// ... 全部写入成功 ...
fileIo.renameSync(partPath, destPath);
```

`rename` 跨设备可能失败，所以兜了一层 `copyFileSync`。

### 6.4 进度与取消

- 进度走 `on('dataReceiveProgress')`，取 `receiveSize / totalSize`，**约 500ms 节流一次**（不节流会把 UI 刷爆）
- 有些 CDN 不给 `Content-Length`，`totalSize` 会是 **0**——这时按「已下载字节数」显示，**不要显示百分比**
- 取消 = `req.destroy()`，Promise 会 reject，统一走异常出口，清理 `.part`

---

## 七、存系统相册：一个受限权限都不申请

这是鸿蒙开发里很实用的一招，值得单独讲。

### 7.1 常规路子走不通

常规做法是 `MediaAssetChangeRequest.createAssetRequest`，但它要求 `ohos.permission.WRITE_IMAGEVIDEO`——这是**受限权限（restricted）**，调试证书要单独申请 ACL 才能装上，流程很折腾。

### 7.2 换一条路：`showAssetsCreationDialog`

改用「用户当场授权」模型：弹一次系统弹窗，用户确认后返回媒体库的目标 uri，应用再把沙箱文件拷进去。

```typescript
const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
const targets: string[] = await helper.showAssetsCreationDialog(srcUris, configs);
```

**一个权限都不用申请**，代价只是多一次弹窗。所以这里按「**一个任务攒一批**」调用，而不是一个文件弹一次——否则下一个 20 图的图集会弹 20 次，用户直接崩溃。

> ⚠️ 另一个坑：弹窗必须挂在 **UIAbilityContext** 上，传 ApplicationContext 会失败。

### 7.3 最终申请的权限只有 4 个

```json5
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" },
  { "name": "ohos.permission.GET_NETWORK_INFO" },
  { "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" },
  { "name": "ohos.permission.READ_PASTEBOARD" }
]
```

---

## 八、体验细节：分享接入、剪贴板、日志

- **系统分享接入**：`module.json5` 里声明 `ohos.want.action.sendData` + `https`/`http` scheme，在抖音/微博里点「分享 → F2 HAP」直接建任务，不用手动复制链接。
- **剪贴板自动识别**：打开应用就读剪贴板，识别到链接自动填入。
- **并发闸门**：1~5 可调，任务队列常驻同一运行时。
- **实时日志**：分级过滤、一键复制。这个功能是自利的——解析失败时能**直接看到是哪一步断的**，调试效率差很多。
- **Cookie 体检**：设置页每个平台实时显示健康状态（正常 / 即将过期 / 已过期 / 缺登录态），启动时抖音/微博 Cookie 过期会弹一次提醒，覆盖前自动备份、可一键还原。
- **应用内登录获取**：抖音/微博支持在应用内网页登录后自动抓取登录态，免去手工从开发者工具复制的麻烦，且带过期检测——网页里 Cookie 已过期会拒绝保存。

---

## 九、工程化：签名口令绝不入库

这一节跟算法无关，但**我认为是本项目最该被抄走的部分**。

### 9.1 问题

DevEco Studio 每次执行「自动签名」，都会把**本机证书路径**和 **keystore 口令**写进 `build-profile.json5`。两个致命后果：

1. 口令外泄
2. 绝对路径（`/Users/<某人>/.ohos/config/...`）在别人机器上不存在，clone 后无法构建

### 9.2 方案：pre-commit 钩子自动剥离

仓库里**始终**保持 `"signingConfigs": []`。提交前由 `.githooks/pre-commit` 自动剥离：

```
.githooks/pre-commit      # 提交前剥离本机签名配置
scripts/strip-signing.py  # 剥离 + 语义归一化
scripts/setup-hooks.sh    # 一键启用
```

关键设计是——**只改索引、不动工作区**。所以 DevEco 照样能构建签名包，本地开发完全不受影响。口令不会丢，会留存到已 gitignore 的 `build-profile.local.json5`，`dev-build.sh` 构建时自动读取。

还有一个细节：剥离后如果与 HEAD 已经没有实质差异（只剩 DevEco 的格式重排），这次提交会**直接跳过该文件**，不产生无意义的 diff。

### 9.3 一键构建脚本

```bash
bash scripts/setup-hooks.sh               # 启用 hooks（一次性）
bash scripts/dev-build.sh debug           # 构建
bash scripts/dev-build.sh debug install   # 构建并安装到已连接设备
```

脚本做 6 件事：探测 JDK/SDK/hvigorw → 读调试证书 → 校验 `.p7b` 里绑的 bundleName 与 `app.json5` 是否一致 → 临时写入签名配置并构建 → `trap` **无条件还原** `build-profile.json5` → 产物复制到 `dist/`。

---

## 十、踩坑速查表

### 10.1 构建报错对照表

| 报错 | 真实原因 | 解法 |
|---|---|---|
| `00308018 Unknown Error` + `Unable to locate a Java Runtime` | 没设 `JAVA_HOME` | 指向 DevEco 自带 JBR |
| `00308018` + `The "data" argument must be of type string` | 模块缺 `oh-package.json5` | 给每个模块目录补上 |
| `00303074 Configuration Error` | 调试 profile 包名与 `app.json5` 不一致 | 重新自动签名，或 `--borrow-profile` 临时验证 |
| `11014003 Init keystore failed` | **证书与口令不同源**（`~/.ohos/config` 里可能有多套同工程证书） | 按「口令来源里的 certpath → 最新一套」顺序挑选 |
| `10106102 screen is locked` | `aa start` 时设备锁屏 | 手动解锁后再拉起 |
| `Cannot find module 'pages/Index'` | `main_pages.json` 指的页面不存在 | 确认文件在 |

> **最容易漏的一步**：即使 `app.signingConfigs` 配好了，如果 `app.products[]` 里**没有** `"signingConfig": "default"` 这一行，hvigor 不知道用哪份配置，会**静默产出未签名包**（安装时报 `9568320 / no signature file`）。DevEco 自动签名通常只填数组、不补这个引用，得手动加。
>
> **另一个反直觉的点**：DevEco 写入的 `0000001B…` 口令 hvigor 能直接用，但 `openssl` 解不开（报 `bad decrypt`）。**别拿 openssl 的结果断言口令无效。**

### 10.2 ArkTS 严格模式速查（API 24 实测）

从 TypeScript/Python 过来必撞：

| 限制 | 禁止 | 替代 |
|---|---|---|
| `arkts-no-indexed-signatures` | `interface Q { [k: string]: T }` | `type Q = Record<string, T>` |
| `arkts-identifiers-as-prop-names` | `{ 'Content-Type': v }` | 先声明常量再 `obj[KEY] = v` |
| `arkts-no-untyped-obj-literals` | 字段不全的对象字面量 | class 构造函数 / 工厂函数 |
| `arkts-no-destruct-decls` | `const [a, b] = s.split('_')` | 用下标 |
| `arkts-no-structural-typing` | 结构相同即可赋值 | 显式构造目标类型 |
| `arkts-no-is` | `x is T` 类型谓词 | 返回 `boolean`，调用方自行收窄 |
| `String.replace` 回调重载 | `s.replace(re, (m) => ...)` | 手写字符扫描 |
| `@Builder` 内声明变量 | `const` 局部变量 | 拆成两个 builder，把值当参数传 |

另外几个 API 层面的坑：

- `AppStorage`（V1）是全局 `declare class`，**不能**从 `@kit.ArkUI` 具名导入（那个 Kit 只导出 `AppStorageV2` / `PersistenceV2`）
- `WebCookieManager.clearAllCookies()` 是异步的，同步场景用 `clearAllCookiesSync()`
- `WebviewController` 清缓存是 `removeCache(clearRom: boolean)`，**没有** `clearCache()`

---

## 十一、还没做完的事

坦白列出，避免你 clone 下来发现不对：

- **TikTok 未移植**。需要 XBogus 签名 + 设备注册，当前版本成功率极低，代码留在仓库但默认不走。
- **m3u8 不支持**。手机端无本地转封装能力。
- **后台下载受系统调度约束**。已申请 `KEEP_BACKGROUND_RUNNING`，但仍受系统策略限制。
- **Cookie 需手动配置**（抖音、微博）。X/Twitter 免登录可直接下载。

---

## 十二、隐私与免责

- Cookie 只存在应用沙箱的 `preferences` 里，**不上传、不出设备**
- 除目标平台自家域名外，不连任何服务器；**没有统计、没有埋点**
- 下载文件落在沙箱 `filesDir/downloads`，存相册需要你在系统弹窗里逐次确认
- **仅供个人学习与备份自己可访问的公开内容使用**。请遵守各平台服务条款与著作权法，不要用于批量抓取或商业分发

---

## 总结

回头看，这次移植真正的难点**不在算法有多复杂，而在「换了一门语言后，那些 Python 里理所当然的语义全都不成立」**：

1. 位运算会截断 int32 —— 毫秒时间戳直接踩中
2. `chr()/ord()` 中间值可以 > 255 —— Uint8Array 和字符串都会害你
3. 有状态的置换表 —— 第二次签名悄悄出错
4. `writeSync` 的 offset 是相对的 —— 传了就写花
5. 受限权限 —— 换个 API 就能绕开整套 ACL 审批

如果你也在做「把别的语言的库移植到 ArkTS」这类事，希望这张踩坑清单能帮你少花两天。

**如果这篇文章对你有帮助，欢迎点赞 + 收藏 + 关注，你的支持是我继续写下去的动力 🌟**

有问题欢迎在评论区交流，我会尽量回复。

---

> **版权声明**：本文为博主原创文章，遵循 CC 4.0 BY-SA 版权协议，转载请附上原文出处链接和本声明。
>
> **原文链接**：https://github.com/Lancenas/f2-hap
