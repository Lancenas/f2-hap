# 构建与签名

## 1. 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| DevEco Studio | 6.x | 自带 JBR（JDK 21），hvigor 的 `PackageHap` 阶段需要 Java |
| HarmonyOS SDK | API 24 (6.1.1) | 路径形如 `~/Library/Huawei/Sdk/<SdkDir>`，必须含 `default/` 子目录 |
| 调试证书 | — | DevEco 自动签名生成在 `~/.ohos/config/default_harmony_*.{cer,p12,p7b}` |

三个环境变量（`scripts/dev-build.sh` 会自动探测，一般不用手设）：

| 变量 | 要求 | 为什么 |
|---|---|---|
| `JAVA_HOME` | JDK 17+ 根目录 | 不设会在打包阶段报 `00308018`，真实原因藏在日志里是 `Unable to locate a Java Runtime` |
| `DEVECO_SDK_HOME` | 指向**含** `default/` 的**父级**目录 | hvigor 会自己拼 `<SDK>/default`，指到 `default` 本身会找不到 |
| `PATH` | 含 `$JAVA_HOME/bin` | 工具子进程调用 |

## 2. 一键构建

```bash
bash scripts/dev-build.sh                              # debug HAP
bash scripts/dev-build.sh release                      # release HAP
bash scripts/dev-build.sh debug install                # 构建并安装到已连接设备
bash scripts/dev-build.sh debug install --borrow-profile   # 借用现有 profile 的包名签名
```

脚本做的事：

1. 探测 JDK / SDK / hvigorw
2. 从 `~/.ohos/config` 读调试证书
3. 校验 `.p7b` 里绑的 bundleName 与 `AppScope/app.json5` 是否一致
4. 一致 → 临时写入签名配置并构建；不一致 → 产出未签名 HAP 并给出两条修复路径
5. `trap` 无条件还原 `build-profile.json5`（本机口令绝不入库）
6. 产物复制到 `dist/f2-hap-<version>-<mode>.hap`

## 3. 签名：调试 profile 与包名强绑定

**这是最容易卡住的一步。** HarmonyOS 的调试 `.p7b` profile 里写死了 `bundle-name`，包名不匹配时 `SignHap` 阶段直接报：

```
ERROR: 00303074 Configuration Error
The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs.
```

查 profile 实际绑的包名：

```bash
strings ~/.ohos/config/default_harmony_*.p7b \
  | sed -n 's/.*"bundle-name":"\([^"]*\)".*/\1/p' | head -1
```

本工程包名是 `cn.lancenas.f2hap`。三种处理方式：

### 方式 A（推荐）：为本工程重新自动签名

DevEco Studio 打开本工程 → `File > Project Structure > Project > Signing Configs` → 勾选 **Automatically generate signature** → 登录华为账号，它会为 `cn.lancenas.f2hap` 申请一份新的调试 profile。

之后 DevEco 会把签名配置（含**密文**口令）写进 `build-profile.json5`。把其中 `material` 片段另存为 `build-profile.local.json5`（已在 `.gitignore`），命令行脚本就能复用：

```json5
{
  "keyPassword": "0000001B....",
  "storePassword": "0000001B...."
}
```

### 方式 B：借用已有 profile 的包名

本机若已有别的工程的调试 profile，可以借来临时验证：

```bash
bash scripts/dev-build.sh debug install --borrow-profile
```

⚠️ 这会把 HAP 的包名改成 profile 里绑的那个，**安装后会覆盖设备上同包名的应用**。仅用于本机快速验证，别用它出包。

### 方式 C：只要未签名产物

不传 `--borrow-profile` 且包名不匹配时，脚本默认走这条路，产出 `dist/f2-hap-<ver>-debug-unsigned.hap`。可用于校验编译是否通过、体积多大，但**不能安装**。

## 4. 手动构建（不用脚本）

```bash
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
export DEVECO_SDK_HOME="$HOME/Library/Huawei/Sdk/HarmonyOS-NEXT2"
export PATH="$JAVA_HOME/bin:$PATH"

/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --no-daemon assembleHap -p product=default -p buildMode=debug
```

产物：`entry/build/default/outputs/default/entry-default-{signed,unsigned}.hap`

## 5. 真机安装与调试

```bash
HDC="$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc"
TARGET="$($HDC list targets | head -1)"

$HDC -t "$TARGET" install -r dist/f2-hap-0.1.0-debug.hap
$HDC -t "$TARGET" shell aa start -a EntryAbility -b cn.lancenas.f2hap
$HDC -t "$TARGET" shell "hilog | grep F2HAP"          # 看应用日志
```

设备需先在「设置 → 系统 → 开发者选项」开启 USB 调试，并把设备 UDID 加进 AGC 的调试设备列表（否则调试 profile 不含该设备，安装会被拒）。

## 6. 常见报错对照表

| 报错 | 真实原因 | 解法 |
|---|---|---|
| `00308018 Unknown Error` + `Unable to locate a Java Runtime` | 没设 `JAVA_HOME` | 指向 DevEco 自带 JBR |
| `00308018` + `The "data" argument must be of type string ... Received undefined` | 模块缺 `oh-package.json5` | 给每个模块目录（如 `entry/`）补上 |
| `00303074 Configuration Error` | 调试 profile 包名与 app.json5 不一致 | 见第 3 节 |
| `10106102 ... screen is locked` | `aa start` 时设备锁屏 | 手动解锁后再拉起（`install` 本身不受影响） |
| `Cannot find module 'pages/Index'` | `main_pages.json` 指的页面文件不存在 | 确认 `entry/src/main/ets/pages/Index.ets` 在 |
| ArkTS 报 `arkts-no-untyped-obj-literals` 等 | 严格模式限制 | 见下节 |

## 7. ArkTS 严格模式速查

移植过程中反复撞到的限制：

| 限制 | 禁止 | 替代 |
|---|---|---|
| `arkts-no-indexed-signatures` | `interface Q { [k: string]: T }` | `type Q = Record<string, T>` |
| `arkts-identifiers-as-prop-names` | `{ 'Content-Type': v }` | 先声明常量再 `obj[KEY] = v` |
| `arkts-no-untyped-obj-literals` | 字段不全的对象字面量 | class 构造函数 / 工厂函数 |
| `arkts-no-destruct-decls` | `const [a, b] = s.split('_')` | 用下标 |
| `arkts-no-structural-typing` | 结构相同即可赋值 | 显式构造目标类型 |
| `arkts-no-is` | `x is T` 类型谓词 | 返回 `boolean`，调用方自行收窄 |
| `String.replace` 回调重载 | `s.replace(re, (m) => ...)` | 手写字符扫描 |
| 模板字面量函数类型 | `f: (n: number) => \`${n} 条\`` | 改成 `static f(n: number): string` 方法体 |

## 8. 推送仓库前自查

```bash
# 敏感文件不能入库
git ls-files | grep -E "local\.json5|\.p12|\.p7b|\.cer"
# 密文口令（DevEco 形如 0000001B + 20位十六进制）
git diff --cached | grep -c "0000001B[0-9A-F]\{20,\}"
# build/ dist/ .hvigor/ 已在 .gitignore
```
