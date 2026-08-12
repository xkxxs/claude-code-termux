# claude-code-termux

在 Termux (Android ARM64) 上一键安装**官方** Claude Code CLI 最新版，纯脚本方案，不发布 npm 分发包，**无需 glibc/grun**。

> 使用官方 `@anthropic-ai/claude-code-linux-arm64-musl` 二进制（Anthropic 官方发布的 musl 构建），
> 像 opencode 一样用 patchelf 把 interpreter 指向 Termux 的 musl loader 后直跑。
> 更新策略与 codex-termux 相同：**启动前自动检查最新版，有新版先升级再进程序**。

## 前置要求

- Termux + aarch64 (ARM64)
- 无需 root
- 无需 glibc / glibc-runner

> 需要 `patchelf` 和 musl 动态链接器（`ld-musl-aarch64.so.1`），脚本自动安装；
> 如果之前装过 opencode，musl loader 已存在，会直接复用。

## 为什么选这个方案？

| 对比项 | **本方案（官方 musl + patchelf）** | 旧方案（glibc + grun） | proot + Ubuntu | 社区 NDK fork | DamnSit npm 分发包 |
|---|---|---|---|---|---|
| 依赖 | ✅ 只需 Termux + patchelf + musl loader | ❌ 整套 glibc 包族（~500MB） | ❌ 额外装 ~5GB Ubuntu | ✅ | ⚠️ npm 包装层 |
| 运行方式 | ✅ 官方二进制零修改（只改 interpreter） | ✅ 官方二进制 + grun 转译 | proot 整机转译，性能损耗大 | 非官方源码重编译 | 同一二进制 + grun |
| 更新 | ✅ **启动前自动检查 + 自动升级** | ⚠️ 依赖 grun 环境 | 手动 | ⚠️ 停更即死路 | 手动 `npm --force` 重装 |
| DNS | ✅ 复用 codex-termux 方案（root→dns53 / 无 root→proot） | ✅ 读 glibc 侧 resolv.conf | 完整环境 | ✅ | 自带代理（硬绕） |
| 存储占用 | ✅ 几百 MB（无 glibc 包族） | ❌ 二进制 + glibc 包族 | ❌ ~5GB+ | ✅ | ❌ 二进制 + glibc 包族 |

**一句话**：Anthropic 官方已经发布 musl 构建，直接在 Termux 上 patchelf 直跑即可，不需要为了它装一整套餐 glibc。

## 与官方 Claude Code 更新机制的区别（重要）

官方 Claude Code 是**启动 CLI 之后在后台自动升级**；本方案改成 codex-termux 的方式：**启动前检查，有新版先升级再进程序**，并在 wrapper 里设 `DISABLE_AUTOUPDATER=1` 关闭官方后台更新，避免两套机制互相打架。

| | 官方 | 本 wrapper |
|---|---|---|
| 更新时机 | 启动后后台自动升级 | 启动前检查，先升级再启动 |
| 更新方式 | Claude 自管 | 下载 npm musl 平台包 tarball → patchelf → 验证 → 原子替换 |
| 冲突处理 | — | `DISABLE_AUTOUPDATER=1` 关闭官方后台更新 |
| 失败策略 | — | 更新失败不阻塞，继续用旧版本启动 |
| 跳过检查 | — | `CLAUDE_NO_AUTO_UPDATE=1 claude ...` |

## 一行命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/claude-code-termux/main/install.sh)
```

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64 |
| 镜像源适配 | 官方源 + 国内主流镜像逐个测速，自动切换最快者（幂等） |
| 全量升级 | `pkg upgrade -y` 把软件包升到最新 |
| 依赖安装 | `nodejs-lts` + `patchelf`；musl loader 缺失时从 Alpine 拉取；无 root 自动补 proot |
| 证书 | 使用 Termux 原生 `$PREFIX/etc/tls/cert.pem` |
| **DNS（复用 codex-termux）** | 有 root：`dns53.js` 本地转发器 + `.bashrc` 常驻（自动跟随手机 DNS）；无 root：`dns-bootstrap.js` 实测校验 + proot 绑定 |
| 清理残留 | 自动检测并移除第三方损坏的 `$PREFIX/bin/claude`（如 @xurxuo 包残留） |
| 安装 Claude | `npm pack @anthropic-ai/claude-code-linux-arm64-musl` → patchelf 改 interpreter → 直跑验证 → 放入 `~/.local/claude-code/claude` |
| 生成 wrapper | `~/.local/bin/claude`：启动前自动检查更新、注入证书、`unset LD_PRELOAD`、DNS 自选、`claude update` 手动升级 |
| 验证 | `claude --version` |

## 使用

```bash
claude                     # 启动：先检查最新版，非最新自动更新再启动（已最新直接启动）
claude update              # 手动更新到最新版
claude update -f           # 强制重装当前版本
CLAUDE_NO_AUTO_UPDATE=1 claude ...   # 临时跳过启动时更新检查
bash <(curl -fsSL …/install.sh)              # 重跑即更新（幂等）
bash <(curl -fsSL …/install.sh) --uninstall  # 卸载
```

> **自动更新说明**：每次执行 `claude` 时，wrapper 会先查一次 npm 上的最新版
> （10 秒内快速失败，网络差时静默跳过），与本地版本比较（`sort -V`）：
> - 有新版 → 下载 musl tarball → patchelf → 直跑验证 → 原子替换 → 继续启动
> - 更新失败（网络中断等）→ 不阻塞，直接用现有版本启动，下次再试
> - 已是最新 → 直接启动，零额外等待

## DNS（复用 codex-termux 成熟方案）

Claude 的 musl 二进制和 codex/opencode 行为一致：读不到 `/etc/resolv.conf`（Android 没有）就回退 `127.0.0.1:53`。wrapper 启动前自动选择：

- **有 root**：确保 `dns53.js` 在 `127.0.0.1:53` 监听。dns53 每 60 秒用 `getprop` + `dumpsys connectivity` 探测手机当前 DNS 并刷新上游，坏应答自动降级，全挂时 netd 兜底——客户端永远查本地，网络切换实时跟随
- **无 root**：确保 `dns-bootstrap.js` 常驻（每 60s 实测公网 DNS 质量并重写 `$PREFIX/etc/resolv.conf`），再用 `proot -b` 绑定成 `/etc/resolv.conf` 启动

与 codex-termux 共用同一套 DNS 脚本和常驻逻辑，互不冲突。

## 原理

- 官方 `@anthropic-ai/claude-code-linux-arm64-musl`（`libc: musl`，约 298MB）是 **musl 动态链接** 二进制：interpreter 为 `/lib/ld-musl-aarch64.so.1`，仅依赖 `libc.musl-aarch64.so.1`
- 不是纯静态（与 codex 不同），所以需要：`patchelf --set-interpreter $PREFIX/lib/ld-musl-aarch64.so.1` + 运行时 `unset LD_PRELOAD`（termux-exec 的 bionic 预加载和 musl 冲突）——与 opencode 同一套适配思路，且不需要 rpath/额外 C++ 库
- 已实测：2.1.228 打补丁后直接 `./claude --version` → `2.1.228 (Claude Code)`，无 glibc、无 grun
- 官方直链（备用）：`https://downloads.claude.ai/.../linux-arm64-musl/claude`

## 配置（DeepSeek 等 Anthropic 兼容端点）

```bash
export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
export ANTHROPIC_AUTH_TOKEN=sk-你的Key
export ANTHROPIC_MODEL=deepseek-v4-flash[1m]
# 持久化: 追加到 ~/.bashrc
```

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/claude-code-termux/main/install.sh) --uninstall
# 如需删除配置: rm -rf ~/.claude
# dns53/dns-bootstrap 为 codex/opencode 共用, 默认保留
```

## 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| `cannot execute: required file not found` | musl loader 缺失或 interpreter 未打补丁 | 重跑 `bash install.sh`（自动装 loader + patchelf） |
| 加载时报 `libtermux-exec` 相关错误 | LD_PRELOAD 未清 | wrapper 已 `unset LD_PRELOAD`；直接运行 `claude` 而非原始二进制 |
| API 连接失败 | DNS 未配置 / 网络切换 | 有 root 走 dns53（重开终端自动拉起）；无 root 走 dns-bootstrap + proot |
| 启动时没自动升级 | 网络差，npm 查询 10s 内快速失败 | 静默跳过，下次启动重试；或 `claude update` |
| 更新下载一半失败 | 网络中断 | 旧版保留，不阻塞启动，下次自动重试 |
| 图片/音频功能异常 | Claude 内置原生 `.node` 插件是 glibc 编译的 | 基础 CLI 不受影响；此类功能需 glibc 垫片（社区有方案，持续跟进） |
| `claude: /usr/bin/env: bad interpreter` | 第三方 npm 包装的损坏残留 | 重跑 `bash install.sh`（自动清理） |

## 许可证

MIT
