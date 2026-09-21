#!/usr/bin/env bash
#
# 一键脚本：同步上游主分支最新代码并重新打包 Linux AppImage
#
# 用法：
#   ./scripts/sync-and-build-linux.sh
#
# 行为：
#   1. 校验工作区是否干净（有未提交改动则中止，避免丢失工作）
#   2. 拉取上游主分支最新代码
#   3. 把当前分支 rebase 到最新上游主分支之上
#   4. 安装依赖
#   5. 从 build/icon.png 重新生成多尺寸图标集 build/icons/
#   6. 编译 TypeScript（npm run compile）
#   7. 重新打包 AppImage
#
# 依赖：ImageMagick（magick 或 convert）用于生成图标集。
#
# 注意：本脚本不会改动/推送主分支，只在当前分支上工作。

set -euo pipefail

# ---- 可配置项 ----
UPSTREAM_REMOTE="origin"      # 上游远程名
MAIN_BRANCH="master"          # 上游主分支名

# ---- 切换到脚本所在仓库根目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

log()  { printf '\033[1;34m[sync-build]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[sync-build]\033[0m %s\n' "$*" >&2; }

# ---- 0. 记录当前分支 ----
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" = "${MAIN_BRANCH}" ]; then
  err "当前处于主分支 ${MAIN_BRANCH}，为安全起见请先切到特性分支再运行本脚本。"
  exit 1
fi
log "当前分支：${CURRENT_BRANCH}"

# ---- 1. 校验工作区干净 ----
if [ -n "$(git status --porcelain)" ]; then
  err "工作区存在未提交改动，请先提交或 stash 后再运行。"
  git status --short
  exit 1
fi
log "工作区干净。"

# ---- 2. 拉取上游主分支最新代码 ----
log "拉取 ${UPSTREAM_REMOTE}/${MAIN_BRANCH} ..."
git fetch "${UPSTREAM_REMOTE}" "${MAIN_BRANCH}"

# ---- 3. rebase 到最新上游主分支 ----
log "rebase ${CURRENT_BRANCH} 到 ${UPSTREAM_REMOTE}/${MAIN_BRANCH} ..."
if ! git rebase "${UPSTREAM_REMOTE}/${MAIN_BRANCH}"; then
  err "rebase 出现冲突，请手动解决后执行：git rebase --continue"
  err "（若想放弃：git rebase --abort）"
  exit 1
fi
log "rebase 完成。"

# ---- 4. 安装依赖 ----
log "安装依赖 (npm install) ..."
# npm 12+ 默认策略 allow-remote=none 会拒绝从远程拉包；显式放开以便正常安装。
# 对旧版 npm 该环境变量无副作用。
npm_config_allow_remote=all npm install

# ---- 5. 从 PNG 重新生成图标集 ----
ICON_SRC="build/icon.png"
ICON_DIR="build/icons"
if [ -f "${ICON_SRC}" ]; then
  if command -v magick >/dev/null 2>&1; then
    IM_CMD="magick"
  elif command -v convert >/dev/null 2>&1; then
    IM_CMD="convert"
  else
    IM_CMD=""
  fi

  if [ -n "${IM_CMD}" ]; then
    log "从 ${ICON_SRC} 重新生成图标集到 ${ICON_DIR}/ ..."
    mkdir -p "${ICON_DIR}"
    for size in 16 32 48 64 128 256 512; do
      # -strip -define png:exclude-chunk=time 确保输出确定性，避免重复生成产生无意义 diff
      "${IM_CMD}" "${ICON_SRC}" -background none -resize "${size}x${size}" -depth 8 \
        -strip -define png:exclude-chunk=time "${ICON_DIR}/${size}x${size}.png"
    done
    log "图标集生成完成。"
  else
    err "未找到 ImageMagick（magick/convert），跳过图标集生成，将使用现有 ${ICON_DIR}/。"
  fi
else
  log "未找到 ${ICON_SRC}，跳过图标集生成，将使用现有 ${ICON_DIR}/。"
fi

# ---- 6. 编译 TypeScript ----
log "编译 TypeScript (npm run compile) ..."
npm run compile

# ---- 7. 打包 ----
log "打包 Linux AppImage ..."
npm run build:linux:local

# ---- 8. 输出产物 ----
log "打包完成，产物："
ls -lh dist/*.AppImage 2>/dev/null || log "未找到 AppImage 产物，请检查上方日志。"

log "全部完成 ✅"
