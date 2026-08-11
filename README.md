# claude-code-termux

在 Termux (Android ARM64) 上一键安装**官方** Claude Code CLI,纯脚本方案,不发布 npm 分发包。

> 官方 glibc 二进制 + glibc-runner (`grun`) 转译,直接调用官方二进制本体,
> 不需要任何第三方 npm 包装层。

## 与社区方案 (DamnSit/claude-code-termux) 的区别

| 对比项 | **本方案 (纯脚本)** | DamnSit (npm 分发包) |
|---|---|---|
| 运行方式 | 同一官方 glibc 二进制,经 grun 转译 | 相同 |
| 安装 | 单个 `install.sh`,本地生成 bash wrapper | 需发布/安装 npm 包 `@xurxuo/claude-code-termux` |
| 启动器 | 纯 bash,零依赖 | node cjs 脚本,shebang `/usr/bin/env` 在 Termux 下易坏 |
| 更新 | `claude update` 内嵌完整流程 (查版→下载→验证→替换) | npm `--force` 重装 |
| DNS | 复用 glibc 侧 `resolv.conf` (国内 DNS) | 自带 DNS 转发器 + HTTP CONNECT 代理 (硬绕) |
| 残留清理 | 自动检测并移除第三方损坏的 `/usr/bin/claude` | 需手动 `npm uninstall` |

## 前置要求

- Termux + aarch64 (ARM64)
- 无需 root

## 安装

```bash
git clone https://github.com/<USER>/claude-code-termux
cd claude-code-termux
bash install.sh
```

## 使用

```bash
claude                     # 启动
claude update              # 更新到最新版
bash install.sh            # 重跑即更新 (幂等)
bash install.sh --uninstall  # 卸载 (保留 ~/.claude 配置)
```

## 配置 (DeepSeek 等 Anthropic 兼容端点)

```bash
export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
export ANTHROPIC_AUTH_TOKEN=sk-你的Key
export ANTHROPIC_MODEL=deepseek-v4-flash
# 持久化: 追加到 ~/.bashrc
```

## 原理

- Claude Code 官方发布 `@anthropic-ai/claude-code-linux-arm64` npm 平台包,内含约 300MB 的 glibc 动态链接二进制 (`package/claude`)
- Android 无 glibc,用 Termux 的 `glibc-runner` (`grun`, 需先 `pkg install glibc-repo` + `glibc-runner`) 转译运行
- 官方 npm 包装的 bin 是 node 脚本且 shebang 是 `/usr/bin/env` (Termux 没有该路径),直接用 `grun` 跑二进制即可,无需第三方包装
- 下载走 `npm pack` (跟随用户配置的 registry 镜像,国内通常 npmmirror 速度快),失败回退官方 registry 直连
- DNS: glibc 程序经 grun 后读 `/usr/glibc/etc/resolv.conf` (Android 无 `/etc/resolv.conf`),脚本自动写入国内公共 DNS (阿里/腾讯/114)
- 证书: glibc 侧 CA 位于 `/usr/glibc/etc/ssl/cert.pem`,wrapper 注入 `SSL_CERT_FILE`

## 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| `claude: /usr/bin/env: bad interpreter` | 第三方 npm 包装的损坏残留 | 重跑 `bash install.sh` (自动清理) |
| `Error from glibc-runner: 'X' not found` | grun 转译 shell 环境精简 | 正常,直接运行 `claude` 而非 grun 子命令 |
| API 连接失败 | glibc 侧 DNS 未配置 | 重跑 `bash install.sh` (自动写入 resolv.conf) |

## 许可证

MIT
