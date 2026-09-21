#!/usr/bin/env bash
#
# 一键脚本：同步上游主分支最新代码并重新打包 Linux AppImage
#
# 用法：
#   ./scripts/sync-and-build-linux.sh
#
# 行为：
#   1. 获取并发锁（防止多次运行互相覆盖 dist/ 产物）
#   2. 校验工作区是否干净（有未提交改动则中止，避免丢失工作）
#   3. 拉取上游主分支最新代码
#   4. 把当前分支 rebase 到最新上游主分支之上
#   5. 安装依赖
#   6. 从 build/icon.png 重新生成多尺寸图标集 build/icons/
#   7. 清理旧产物后重新打包 AppImage
#      （build:linux:local 内含 npm run compile，无需在此单独编译）
#   8. 校验产物确为本次新生成
#   9. 恢复构建期被 compile 改动的 tracked 生成物（保持工作区干净）
#
# 依赖：flock（util-linux）、ImageMagick（magick 或 convert）。
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

# ---- 0. 获取并发锁 ----
if ! command -v flock >/dev/null 2>&1; then
  err "未找到 flock（util-linux），无法获取构建锁。请安装 util-linux 后重试。"
  exit 1
fi
LOCK_FILE="${TMPDIR:-/tmp}/cuckoo-sync-build-$(printf '%s' "${REPO_ROOT}" | cksum | cut -d' ' -f1).lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  err "另一个同步/构建进程正在运行（锁文件：${LOCK_FILE}）。"
  err "请等待其结束后重试；若确认无残留进程，可删除该锁文件。"
  exit 1
fi
log "已获取构建锁：${LOCK_FILE}"

# ---- 1. 记录当前分支 ----
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" = "${MAIN_BRANCH}" ]; then
  err "当前处于主分支 ${MAIN_BRANCH}，为安全起见请先切到特性分支再运行本脚本。"
  exit 1
fi
log "当前分支：${CURRENT_BRANCH}"

# ---- 2. 校验工作区干净 ----
if [ -n "$(git status --porcelain)" ]; then
  err "工作区存在未提交改动，请先提交或 stash 后再运行。"
  git status --short
  exit 1
fi
log "工作区干净。"

PRE_REBASE_SHA="$(git rev-parse HEAD)"
log "rebase 前 HEAD：${PRE_REBASE_SHA}"

# ---- 3. 拉取上游主分支最新代码 ----
log "拉取 ${UPSTREAM_REMOTE}/${MAIN_BRANCH} ..."
git fetch --prune "${UPSTREAM_REMOTE}" "${MAIN_BRANCH}"

# ---- 4. rebase 到最新上游主分支 ----
log "rebase ${CURRENT_BRANCH} 到 ${UPSTREAM_REMOTE}/${MAIN_BRANCH} ..."
if ! git rebase "${UPSTREAM_REMOTE}/${MAIN_BRANCH}"; then
  err "rebase 出现冲突，请手动解决后执行：git rebase --continue"
  err "（若想放弃：git rebase --abort）"
  err "（恢复点：${PRE_REBASE_SHA}，可用 git reset --hard ${PRE_REBASE_SHA} 回到 rebase 前）"
  exit 1
fi
log "rebase 完成。"

# ---- 5. 安装依赖 ----
log "安装依赖 (npm install) ..."
# npm 12+ 默认策略 allow-remote=none 会拒绝从远程拉包；显式放开以便正常安装。
# 对旧版 npm 该环境变量无副作用。
if ! npm_config_allow_remote=all npm install; then
  err "npm install 失败。"
  exit 1
fi

# ---- 6. 从 PNG 重新生成图标集 ----
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

# ---- 7. 清理旧产物后打包 ----
# 注：build:linux:local 已内含 `npm run compile`（上游约定：重构后入口在 out/），
# 此处不再单独编译，避免重复。若该前缀被移除，需在此恢复显式编译。
log "清理 dist/ 旧产物 ..."
rm -f dist/*.AppImage
rm -rf dist/__appImage-* dist/linux-unpacked.tmp dist/linux-unpacked.tmp.lock

BUILD_MARKER="$(mktemp)"
log "打包 Linux AppImage ..."
if ! npm run build:linux:local; then
  rm -f "${BUILD_MARKER}"
  err "打包失败。"
  exit 1
fi

# ---- 8. 校验产物 ----
log "校验产物 ..."
APPIMAGE="$(find dist -maxdepth 1 -name '*.AppImage' -newer "${BUILD_MARKER}" -print -quit 2>/dev/null || true)"
rm -f "${BUILD_MARKER}"

if [ -z "${APPIMAGE}" ] || [ ! -s "${APPIMAGE}" ]; then
  err "未找到本次新生成的 AppImage 产物，构建可能失败。dist/ 当前内容："
  ls -la dist/
  exit 1
fi

log "打包完成，产物："
ls -lh "${APPIMAGE}"

# ---- 9. 恢复构建期被改动的 tracked 生成物 ----
# compile（含在 build:linux:local 内）会重新生成下列 tracked 文件。若上游提交的
# 生成物与其源不完全一致（例如上游源已是 LF、但生成物仍含转义 CRLF），compile 后
# 工作区会变脏，导致下次运行时“工作区干净”检查失败。这些生成物由上游维护，本地
# 构建不应改变它们，故构建完成后恢复。
GENERATED_FILES=(
  src/overlay/template.generated.ts
  src/providers/generated/hook-sources.ts
  src/tools/api.d.ts
  src/tools/runtime/bootstrap.generated.ts
)
RESTORED=0
for f in "${GENERATED_FILES[@]}"; do
  if [ -f "${f}" ] && ! git diff --quiet -- "${f}" 2>/dev/null; then
    git checkout -- "${f}" 2>/dev/null && RESTORED=$((RESTORED + 1)) || true
  fi
done
if [ "${RESTORED}" -gt 0 ]; then
  log "已恢复 ${RESTORED} 个构建期改动的生成物，工作区保持干净。"
fi

log "全部完成 ✅"
