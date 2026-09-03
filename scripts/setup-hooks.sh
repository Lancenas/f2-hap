#!/usr/bin/env bash
#
# 启用仓库自带的 git hooks。
#
# 作用：把 core.hooksPath 指向 .githooks/，让 pre-commit（拦截 DevEco 自动签名
# 写入的本机证书路径与 keystore 口令）生效。
#
# hooks 不随 clone 自动启用（git 的安全设计），所以新克隆一份后要跑一次：
#
#     bash scripts/setup-hooks.sh
#
# 关闭： bash scripts/setup-hooks.sh --off
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${1:-}" = "--off" ]; then
  git config --unset core.hooksPath 2>/dev/null || true
  printf '\033[33m[hooks]\033[0m 已关闭，回退到 .git/hooks/\n'
  exit 0
fi

chmod +x .githooks/pre-commit

# 备份 .git/hooks 下已有的同名钩子，避免设置 hooksPath 后被静默忽略
if [ -f .git/hooks/pre-commit ] && [ ! -f .git/hooks/pre-commit.disabled-by-repo ]; then
  mv .git/hooks/pre-commit .git/hooks/pre-commit.disabled-by-repo
  printf '\033[33m[hooks]\033[0m 原有 .git/hooks/pre-commit 已备份为 pre-commit.disabled-by-repo\n'
fi

git config core.hooksPath .githooks

printf '\033[32m[hooks]\033[0m 已启用 .githooks/（core.hooksPath=.githooks）\n'
printf '\033[32m[hooks]\033[0m pre-commit 会在提交前剥离 build-profile.json5 里的本机签名配置\n'
printf '\033[36m[hooks]\033[0m 自测：故意把签名配置写进 build-profile.json5 后 git add && git commit，应看到剥离提示\n'
