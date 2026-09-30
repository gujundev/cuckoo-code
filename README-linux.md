# Linux AppImage 构建说明

本文件说明本 fork（`gujundev/cuckoo-code`）中 **Linux AppImage 打包**的相关流程。

> 本分支基于上游 [wangyongpeng90/cuckoo-code](https://github.com/wangyongpeng90/cuckoo-code)，
> 额外提供 Linux 打包支持与一个 Wayland 布局修复。上游本身**不发布 Linux 版本**。

---

## 目录

- [产物在哪](#产物在哪)
- [三种触发方式](#三种触发方式)
- [发新版本](#发新版本)
- [本地开发与同步](#本地开发与同步)
- [冲突处理](#冲突处理)
- [已知限制](#已知限制)
- [相关文件](#相关文件)

---

## 产物在哪

**方式一：下载已发布的 Release**

https://github.com/gujundev/cuckoo-code/releases

**方式二：下载 Actions 构建产物**

1. 打开 https://github.com/gujundev/cuckoo-code/actions
2. 选择左侧 **Linux AppImage**
3. 点进某次成功的运行，页面底部 **Artifacts** 区域下载 `Cuckoo-Code-Linux-AppImage`
   （保留 30 天）

**运行 AppImage**

```bash
chmod +x Cuckoo-Code-*.AppImage
./Cuckoo-Code-*.AppImage
```

> 部分发行版需要 `libfuse2` 才能运行 AppImage：
> - Debian/Ubuntu：`sudo apt install libfuse2`
> - Fedora：`sudo dnf install fuse-libs`

---

## 三种触发方式

workflow 文件：`.github/workflows/linux-appimage.yml`

| 触发 | 条件 | 行为 |
|------|------|------|
| **推送分支** | push 到 `feat/linux-packaging` | 直接构建，产物上传为 Artifact |
| **打 tag** | 推送 `linux-v*` 格式的 tag | 构建 + **自动创建 GitHub Release** 并附上 AppImage |
| **定时** | 每天 UTC 02:00（北京 10:00） | 同步上游 master → rebase 本分支 → 构建 |
| **手动** | Actions 页面点 "Run workflow" | 同"定时" |

---

## 发新版本

### 步骤 1：确认基于最新上游

可以等**定时任务**自动同步，也可以**手动触发**一次（Actions 页面 → Linux AppImage → Run workflow）。

### 步骤 2：确认版本号

产物文件名取自 `package.json` 的 `version` 字段。检查当前版本：

```bash
node -e "console.log(require('./package.json').version)"
```

### 步骤 3：打 tag 并推送

tag 名建议跟随版本号，例如版本是 `0.8.6` 就打 `linux-v0.8.6`：

```bash
git tag linux-v0.8.6
git push origin linux-v0.8.6
```

推送后会自动：
1. 构建 AppImage
2. 创建 Release `linux-v0.8.6`
3. 把 `Cuckoo-Code-0.8.6.AppImage` 挂到 Release

> ⚠️ **不要用 `v*` 开头的 tag**（如 `v0.8.6`）。上游自带的 `release.yml` 会响应 `v*`，
> 尝试构建并发布 Windows/macOS 版本，造成噪音。始终用 `linux-v*` 前缀。

---

## 本地开发与同步

### 远程配置

```bash
git remote -v
# origin    https://github.com/gujundev/cuckoo-code.git      （你的 fork）
# upstream  https://github.com/wangyongpeng90/cuckoo-code.git （上游）
```

若尚未配置：

```bash
git remote set-url origin https://github.com/gujundev/cuckoo-code.git
git remote add upstream https://github.com/wangyongpeng90/cuckoo-code.git
```

### 一键：同步上游并本地打包

脚本 `scripts/sync-and-build-linux.sh` 会：

1. 获取并发锁（防止多次运行互相覆盖产物）
2. 校验工作区干净
3. `git fetch upstream master` + `git rebase upstream/master`
4. `npm install`
5. 从 `build/icon.png` 生成多尺寸图标集
6. 清理旧产物并打包 AppImage
7. 校验产物确为本次新生成
8. 恢复构建期被改动的生成物（保持工作区干净）

```bash
npm run sync:build:linux
# 或
./scripts/sync-and-build-linux.sh
```

### CI 替你 rebase 后，本地如何跟上

workflow 的 `sync` job（定时/手动触发时）会自动 rebase `feat/linux-packaging`
并强制推送。所以本地可能落后，同步方式：

```bash
git fetch origin
git checkout feat/linux-packaging
git reset --hard origin/feat/linux-packaging
```

> ⚠️ `reset --hard` 会丢弃本地未提交/未推送的改动。执行前确认工作区干净。

---

## 冲突处理

### 最可能冲突的文件：`src/app/entry.ts`

上游在积极开发这个文件（Harness 纯净模式、侧边栏、飞书同步等），
而本分支的 **Wayland 最大化布局修复**也改在这里。

**冲突特征**：属于"改同一区域、意图独立"，两侧改动通常并不矛盾，只是 git 无法自动合并。

**解决原则**：

1. **保留上游的新结构**（如侧边栏参数 `SIDEBAR_WIDTH`、Harness 相关代码）
2. **叠加我们的 Wayland 修复**，即：
   - 核心逻辑函数命名为 `applyLayout`
   - 外层 `layoutView` 做"立即 + `setImmediate` + 100ms 兜底"重布局
   - 保留 5 个事件监听：`resize` / `maximize` / `unmaximize` / `enter-full-screen` / `leave-full-screen`
   - `(mainWindow as any).__ckLayout = layoutView` 指向延迟版

**解决后验证**：

```bash
npm run typecheck
git diff origin/master..HEAD -- src/app/entry.ts   # 应只剩 Wayland 修复
```

### CI 自动 rebase 失败时

`sync` job 会输出警告并**跳过本次构建**（不会破坏分支）。此时需要你手动解决：

```bash
git fetch upstream master
git rebase upstream/master
# 解决冲突后：
git add <冲突文件>
git rebase --continue
git push origin feat/linux-packaging --force-with-lease
```

### 根治建议

若冲突过于频繁，可考虑把 Wayland 修复**提交到上游**（发 PR）。合入上游后，
本分支就不必再带这个补丁，冲突源随之消失。

---

## 已知限制

### 1. 自带运行时（uv/node）不支持 Linux

上游通过 `scripts/fetch-runtime.mjs` 下载 uv/node 到 `resources/runtime/`，
但该脚本**只支持 win-x64 / mac-x64 / mac-arm64**，Linux 会直接报错；
`src/infra/paths.ts` 的 `resolveRuntimeBinDir()` 对 Linux 也返回 `null`。

**影响**：
- 构建时会有 `file source doesn't exist: resources/runtime` 警告（可忽略）
- Linux 上 MCP 的 `uvx`/`npx` 会**回退到用户系统 PATH**，即要求用户自行安装 uv/node

**这是上游的限制，不是本分支的问题。**

### 2. 仅构建 x64

当前 `build.linux.target` 只配置了 `x64`。如需 arm64，修改 `package.json`
的 `build.linux.target`：

```json
{ "target": "AppImage", "arch": ["x64", "arm64"] }
```

### 3. tag 名与产物版本号需手动保持一致

workflow **不会**根据 tag 名修改 `package.json` 的 version（上游的
`scripts/sync-version.js` 未在 Linux workflow 中调用）。产物文件名来自
`package.json`，所以打 tag 前请确认两者一致。

---

## 相关文件

| 文件 | 说明 |
|------|------|
| `.github/workflows/linux-appimage.yml` | Linux 构建 workflow（本 fork 新增） |
| `scripts/sync-and-build-linux.sh` | 本地一键同步 + 打包脚本 |
| `build/icon.png` | 图标源文件（来自上游） |
| `build/icons/` | 多尺寸图标集（由 icon.png 生成，供 Linux 图标注册） |
| `package.json` | `build.linux` 配置、`build:linux*` 脚本、`desktopName` |

---

## 上游相关 workflow（勿动）

本 fork 继承了上游的 3 个 workflow，**不要修改**（改了每次 rebase 都会冲突）：

| 文件 | 触发 | 说明 |
|------|------|------|
| `release.yml` | `v*` tag | 上游的 win/mac 发布流程 |
| `quality.yml` | push/PR 到 master | lint + typecheck |
| `coverage.yml` | push/PR 到 master | 测试覆盖率 |

它们只在 push 到 `master` 或打 `v*` tag 时触发，与本分支的 Linux 构建互不干扰。
