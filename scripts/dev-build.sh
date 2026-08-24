#!/usr/bin/env bash
#
# f2-hap 本地构建脚本
#
# 作用：
#   1. 自动定位 DevEco Studio 自带 JDK（hvigor 的 PackageHap 阶段依赖 Java）
#   2. 自动定位 HarmonyOS SDK（DEVECO_SDK_HOME 必须指向 .../<SdkDir>/default 的父级）
#   3. 从 ~/.ohos/config 读取 DevEco 自动签名生成的调试证书，临时注入 build-profile.json5
#   4. 校验 .p7b profile 绑定的 bundleName 是否与 AppScope/app.json5 一致
#      - 一致  -> 直接签名，产出 entry-default-signed.hap
#      - 不一致 -> 默认产出「未签名」HAP（不静默改包名，避免覆盖同机其它应用）
#                 如确实想借用他人 profile 真机试跑，显式加 --borrow-profile
#   5. 构建结束后无条件还原 build-profile.json5，保证本机口令不会写进仓库
#
# 用法：
#   bash scripts/dev-build.sh                            # 构建 debug HAP
#   bash scripts/dev-build.sh release                    # 构建 release HAP
#   bash scripts/dev-build.sh debug install              # 构建并安装到已连接设备
#   bash scripts/dev-build.sh debug install --borrow-profile
#                                                        # 借用现有 profile 的包名签名（会改包名！）
#
# 口令来源（任选其一）：
#   a) export OHOS_KEY_PASSWORD=... OHOS_STORE_PASSWORD=...
#   b) 把 DevEco 自动签名生成的 material 片段存为 build-profile.local.json5（已 gitignore）
#
set -euo pipefail

BUILD_MODE="debug"
DO_INSTALL=""
BORROW_PROFILE=0

for arg in "$@"; do
  case "$arg" in
    debug|release)     BUILD_MODE="$arg" ;;
    install)           DO_INSTALL="install" ;;
    --borrow-profile)  BORROW_PROFILE=1 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${PROJECT_ROOT}/build-profile.json5"
BACKUP="${PROJECT_ROOT}/build-profile.json5.bak"

log()  { printf '\033[36m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. JDK
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
  for candidate in \
    "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home" \
    "${HOME}/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home" \
    "/opt/deveco-studio/jbr"
  do
    if [ -x "${candidate}/bin/java" ]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi
[ -x "${JAVA_HOME:-}/bin/java" ] || die "找不到 JDK。hvigor 的 PackageHap 阶段需要 Java，请安装 JDK 17+ 或设置 JAVA_HOME。"
export PATH="${JAVA_HOME}/bin:${PATH}"
log "JAVA_HOME = ${JAVA_HOME}"

# ---------------------------------------------------------------- 2. SDK
if [ -z "${DEVECO_SDK_HOME:-}" ] || [ ! -d "${DEVECO_SDK_HOME:-}/default" ]; then
  for candidate in \
    "${HOME}/Library/Huawei/Sdk/HarmonyOS-NEXT2" \
    "${HOME}/Library/Huawei/Sdk" \
    "/Applications/DevEco-Studio.app/Contents/sdk"
  do
    if [ -d "${candidate}/default" ]; then
      export DEVECO_SDK_HOME="$candidate"
      break
    fi
  done
fi
[ -d "${DEVECO_SDK_HOME:-}/default" ] || die "找不到 HarmonyOS SDK。请设置 DEVECO_SDK_HOME 指向含 default/ 子目录的 SDK 路径。"
log "DEVECO_SDK_HOME = ${DEVECO_SDK_HOME}"

# ---------------------------------------------------------------- 3. hvigor
HVIGORW=""
for candidate in \
  "/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw" \
  "${HOME}/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw" \
  "${PROJECT_ROOT}/hvigorw"
do
  [ -x "$candidate" ] && HVIGORW="$candidate" && break
done
[ -n "$HVIGORW" ] || die "找不到 hvigorw。请确认已安装 DevEco Studio。"

# ---------------------------------------------------------------- 4. 签名证书
CER="$(ls "${HOME}"/.ohos/config/default_harmony_*.cer 2>/dev/null | head -1 || true)"
P12="$(ls "${HOME}"/.ohos/config/default_harmony_*.p12 2>/dev/null | head -1 || true)"
P7B="$(ls "${HOME}"/.ohos/config/default_harmony_*.p7b 2>/dev/null | head -1 || true)"

APP_BUNDLE="$(sed -n 's/.*"bundleName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${PROJECT_ROOT}/AppScope/app.json5" | head -1)"
EFFECTIVE_BUNDLE="$APP_BUNDLE"

SIGNED=0
if [ -n "$CER" ] && [ -n "$P12" ] && [ -n "$P7B" ]; then
  SIGNED=1
  log "发现调试证书: $(basename "$CER")"
else
  warn "未在 ~/.ohos/config 找到调试证书，将产出 *未签名* HAP。"
  warn "请先在 DevEco Studio 中执行一次自动签名（File > Project Structure > Signing Configs）。"
fi

restore_profile() {
  if [ -f "$BACKUP" ]; then
    mv -f "$BACKUP" "$PROFILE"
    log "已还原 build-profile.json5"
  fi
}
trap restore_profile EXIT INT TERM

KEY_PASSWORD=""
STORE_PASSWORD=""
if [ "$SIGNED" = "1" ]; then
  KEY_PASSWORD="${OHOS_KEY_PASSWORD:-}"
  STORE_PASSWORD="${OHOS_STORE_PASSWORD:-}"
  LOCAL_CFG="${PROJECT_ROOT}/build-profile.local.json5"
  if [ -z "$KEY_PASSWORD" ] && [ -f "$LOCAL_CFG" ]; then
    KEY_PASSWORD="$(sed -n 's/.*"keyPassword"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'     "$LOCAL_CFG" | head -1)"
    STORE_PASSWORD="$(sed -n 's/.*"storePassword"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LOCAL_CFG" | head -1)"
  fi
  if [ -z "$KEY_PASSWORD" ] || [ -z "$STORE_PASSWORD" ]; then
    warn "缺少 keystore 口令，本次产出未签名 HAP。补齐方式："
    warn "  a) export OHOS_KEY_PASSWORD=... OHOS_STORE_PASSWORD=..."
    warn "  b) 把 DevEco 自动签名的 material 片段存为 build-profile.local.json5"
    warn "  c) 直接在 DevEco Studio 里 Build > Build Hap(s)"
    SIGNED=0
  fi
fi

# 调试 profile 与 bundleName 强绑定（错配会在 SignHap 阶段报 00303074）
if [ "$SIGNED" = "1" ]; then
  PROFILE_BUNDLE="$(strings "$P7B" | sed -n 's/.*"bundle-name":"\([^"]*\)".*/\1/p' | head -1 || true)"
  log "app.json5 bundleName = ${APP_BUNDLE}"
  log "profile   bundleName = ${PROFILE_BUNDLE:-<解析失败>}"
  if [ -n "$PROFILE_BUNDLE" ] && [ "$PROFILE_BUNDLE" != "$APP_BUNDLE" ]; then
    if [ "$BORROW_PROFILE" = "1" ]; then
      warn "已启用 --borrow-profile：本次构建把包名覆盖为 ${PROFILE_BUNDLE}"
      warn "注意 —— 安装后会覆盖设备上同包名的应用，仅用于本机临时验证！"
      EFFECTIVE_BUNDLE="$PROFILE_BUNDLE"
    else
      warn "包名不匹配，无法签名（调试 profile 与 bundleName 强绑定）。"
      warn "本次产出 *未签名* HAP。要拿到可安装的签名包，二选一："
      warn "  1) 在 DevEco Studio 打开本工程，为 ${APP_BUNDLE} 执行自动签名（推荐）"
      warn "  2) bash scripts/dev-build.sh ${BUILD_MODE} --borrow-profile （借用 ${PROFILE_BUNDLE} 包名）"
      SIGNED=0
    fi
  fi
fi

if [ "$SIGNED" = "1" ]; then
  BUNDLE_OVERRIDE=""
  if [ "$EFFECTIVE_BUNDLE" != "$APP_BUNDLE" ]; then
    BUNDLE_OVERRIDE="\"bundleName\": \"${EFFECTIVE_BUNDLE}\","
  fi
  cp -f "$PROFILE" "$BACKUP"
  cat > "$PROFILE" <<EOF
{
  "app": {
    "signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "certpath": "${CER}",
          "keyAlias": "debugKey",
          "keyPassword": "${KEY_PASSWORD}",
          "profile": "${P7B}",
          "signAlg": "SHA256withECDSA",
          "storeFile": "${P12}",
          "storePassword": "${STORE_PASSWORD}"
        }
      }
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
        ${BUNDLE_OVERRIDE}
        "targetSdkVersion": "6.1.1(24)",
        "compatibleSdkVersion": "6.1.1(24)",
        "runtimeOS": "HarmonyOS",
        "buildOption": {
          "strictMode": {
            "caseSensitiveCheck": true,
            "useNormalizedOHMUrl": true
          }
        }
      }
    ],
    "buildModeSet": [
      { "name": "debug" },
      { "name": "release" }
    ]
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        { "name": "default", "applyToProducts": ["default"] }
      ]
    }
  ]
}
EOF
fi

# ---------------------------------------------------------------- 5. 构建
log "开始构建（buildMode=${BUILD_MODE}）..."
cd "$PROJECT_ROOT"
"$HVIGORW" --no-daemon assembleHap -p product=default -p "buildMode=${BUILD_MODE}"

OUT_DIR="${PROJECT_ROOT}/entry/build/default/outputs/default"
HAP="${OUT_DIR}/entry-default-signed.hap"
[ -f "$HAP" ] || HAP="${OUT_DIR}/entry-default-unsigned.hap"
[ -f "$HAP" ] || die "构建结束但未找到 HAP 产物。"

VERSION="$(sed -n 's/.*"versionName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${PROJECT_ROOT}/AppScope/app.json5" | head -1)"
mkdir -p "${PROJECT_ROOT}/dist"
SUFFIX="$BUILD_MODE"
case "$HAP" in *unsigned*) SUFFIX="${SUFFIX}-unsigned";; esac
DEST="${PROJECT_ROOT}/dist/f2-hap-${VERSION}-${SUFFIX}.hap"
cp -f "$HAP" "$DEST"
log "产物: ${DEST} ($(du -h "$DEST" | cut -f1))"

# ---------------------------------------------------------------- 6. 安装
if [ "$DO_INSTALL" = "install" ]; then
  case "$DEST" in
    *unsigned*) die "未签名 HAP 无法安装。请先解决签名问题（见上文提示）。" ;;
  esac
  HDC="${DEVECO_SDK_HOME}/default/openharmony/toolchains/hdc"
  [ -x "$HDC" ] || die "找不到 hdc: ${HDC}"
  TARGET="$("$HDC" list targets 2>/dev/null | grep -v '^\[' | head -1 | tr -d '\r')"
  [ -n "$TARGET" ] && [ "$TARGET" != "[Empty]" ] || die "没有检测到已连接的设备。"
  log "安装到设备 ${TARGET} ..."
  "$HDC" -t "$TARGET" install -r "$DEST"
  log "安装完成。请解锁设备后手动打开应用，或执行："
  log "  ${HDC} -t ${TARGET} shell aa start -a EntryAbility -b ${EFFECTIVE_BUNDLE}"
fi

log "完成。"
