#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# claude-code-termux — 在 Termux (Android aarch64) 上一键安装官方 Claude Code CLI
# 方案: 官方 glibc 二进制 + glibc-runner (grun) 转译, 纯脚本安装, 不发布 npm 包
#
# 用法:
#   bash install.sh
#   bash install.sh --uninstall
#
# 原理:
#   Claude Code 官方只发布 glibc 版二进制 (@anthropic-ai/claude-code-linux-arm64),
#   Android 上没有 glibc, 需经 Termux 的 glibc-runner (grun) 转译运行。
#   官方 npm 包装的 bin 是 node 脚本且 shebang 是 /usr/bin/env (Termux 没有),
#   直接用 grun 跑官方二进制即可, 不需要任何第三方分发包。
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CLAUDE_DIR="$HOME_DIR/.local/claude-code"
CLAUDE_BIN="$CLAUDE_DIR/claude"
WRAPPER_PATH="$HOME_DIR/.local/bin/claude"
VERSION_FILE="$CLAUDE_DIR/.version"
CERT_FILE="$PREFIX/etc/tls/cert.pem"

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。普通 Linux 请直接: npm install -g @anthropic-ai/claude-code"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64) 架构, 当前: $(uname -m)"
    command -v curl >/dev/null || { info "安装 curl…"; pkg install -y curl; }
    info "环境检查通过 (Termux aarch64)"
}

# ---------- 依赖: nodejs + glibc-runner ----------
install_dependencies() {
    local need=()
    command -v node >/dev/null || need+=(nodejs-lts)
    command -v npm >/dev/null || need+=(nodejs-lts)
    command -v curl >/dev/null || need+=(curl)
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    fi
    # glibc-runner (grun) 从独立仓库装
    if ! command -v grun >/dev/null 2>&1 && [ ! -x "$PREFIX/glibc/bin/grun" ]; then
        info "安装 glibc-repo + glibc-runner (grun)…"
        pkg install -y glibc-repo || true
        pkg update -y
        pkg install -y glibc-runner || fail "glibc-runner 安装失败"
    fi
    if ! command -v grun >/dev/null 2>&1 && [ ! -x "$PREFIX/glibc/bin/grun" ]; then
        fail "grun (glibc-runner) 未就绪, 请手动: pkg install glibc-repo && pkg update && pkg install glibc-runner"
    fi
    ok "依赖已就绪 (node $(node --version), grun)"
}

# ---------- glibc 侧 DNS ----------
# glibc 程序经 grun 转译后读 /usr/glibc/etc/resolv.conf (Android 无 /etc/resolv.conf)。
# 写入国内公共 DNS; 有 root 且装了 dns53 时由 127.0.0.1:53 兜底。
fix_dns() {
    local glibc_resolv="$PREFIX/glibc/etc/resolv.conf"
    mkdir -p "$(dirname "$glibc_resolv")"
    if [ ! -s "$glibc_resolv" ] || ! grep -q 'nameserver' "$glibc_resolv" 2>/dev/null; then
        printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 114.114.114.114\n' > "$glibc_resolv"
        info "glibc resolv.conf 已写入国内 DNS: $glibc_resolv"
    else
        ok "glibc resolv.conf 已存在: $(grep nameserver "$glibc_resolv" | tr '\n' ' ')"
    fi
}

# ---------- 安装官方 Claude Code 二进制 ----------
install_claude() {
    info "查询 @anthropic-ai/claude-code-linux-arm64 最新版本…"
    local version
    version=$(npm view @anthropic-ai/claude-code-linux-arm64 version) || fail "无法获取版本号"
    info "最新版本: $version"

    local installed=""
    [ -f "$VERSION_FILE" ] && installed=$(cat "$VERSION_FILE" 2>/dev/null || true)
    if [ -x "$CLAUDE_BIN" ] && [ "$installed" = "$version" ]; then
        ok "已是最新版本 v$version, 跳过下载"
        return
    fi

    local tarball work
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/claude-install.XXXXXX")
    tarball="$work/claude.tgz"
    # npm pack 走用户配置的 registry (国内通常 npmmirror, 快)
    if ! (cd "$work" && npm pack "@anthropic-ai/claude-code-linux-arm64@${version}" --silent >/dev/null 2>&1); then
        # 回退: 直接 curl 官方 registry
        warn "npm pack 失败, 回退官方 registry 下载…"
        curl -fsSL --connect-timeout 15 --max-time 300 \
            "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64/-/claude-code-linux-arm64-${version}.tgz" \
            -o "$tarball" || fail "下载失败 (v${version})"
    else
        tarball=$(ls "$work"/*.tgz | head -1)
    fi

    tar xzf "$tarball" -C "$work"
    [ -f "$work/package/claude" ] || fail "tarball 内未找到 package/claude"

    mkdir -p "$CLAUDE_DIR"
    # 验证能跑才替换
    local testout
    if ! testout=$(grun "$work/package/claude" --version 2>&1); then
        rm -rf "$work"
        fail "二进制验证失败: $testout"
    fi

    mv -f "$work/package/claude" "$CLAUDE_BIN.tmp"
    mv -f "$CLAUDE_BIN.tmp" "$CLAUDE_BIN"
    chmod +x "$CLAUDE_BIN"
    echo "$version" > "$VERSION_FILE"
    rm -rf "$work"
    ok "Claude Code v$version 二进制已安装 (${testout})"
}

# ---------- 启动 wrapper ----------
# 仿 codex-termux 思路: 本地 bash 脚本, 不用 npm 分发包
write_wrapper() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$WRAPPER_PATH" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# claude wrapper for Termux (由 claude-code-termux/install.sh 生成)
# - 官方 glibc 二进制经 grun 转译运行
# - claude update 一键更新 (下载 → 验证 → 替换)
# - 注入 SSL_CERT_FILE (glibc 程序不认 Android 的 CA 路径)
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CLAUDE_BIN="$HOME/.local/claude-code/claude"
VERSION_FILE="$HOME/.local/claude-code/.version"

# glibc 程序不认 Android 的 CA 路径, 指定 glibc 侧证书
export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/glibc/etc/ssl/cert.pem}"

# grun 可能不在 PATH ($PREFIX/glibc/bin 默认不加入)
find_grun() {
    command -v grun 2>/dev/null || { [ -x "$PREFIX/glibc/bin/grun" ] && echo "$PREFIX/glibc/bin/grun"; } || echo "$PREFIX/bin/grun"
}
GRUN="$(find_grun)"

[ -x "$CLAUDE_BIN" ] || { echo "未安装 Claude Code, 请重跑安装脚本" >&2; exit 1; }

case "${1:-}" in
    --update|-u|update|upgrade)
        echo "→ 更新 @anthropic-ai/claude-code …"
        VERSION="$(npm view @anthropic-ai/claude-code-linux-arm64 version 2>/dev/null || true)"
        if [ -z "$VERSION" ]; then echo "!! 无法获取最新版本" >&2; exit 1; fi
        if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$VERSION" ]; then
            echo "✓ 已是最新版本 v$VERSION"
            exit 0
        fi
        echo "→ 下载 v$VERSION …"
        WORK="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/claude-update.XXXXXX")"
        trap 'rm -rf "$WORK"' EXIT
        if ! (cd "$WORK" && npm pack "@anthropic-ai/claude-code-linux-arm64@${VERSION}" --silent >/dev/null 2>&1); then
            TARBALL="$WORK/claude.tgz"
            curl -fsSL --connect-timeout 15 --max-time 300 \
                "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64/-/claude-code-linux-arm64-${VERSION}.tgz" \
                -o "$TARBALL" || { echo "!! 下载失败" >&2; exit 1; }
        else
            TARBALL="$(ls "$WORK"/*.tgz | head -1)"
        fi
        tar xzf "$TARBALL" -C "$WORK"
        [ -f "$WORK/package/claude" ] || { echo "!! tarball 内容异常" >&2; exit 1; }
        echo "→ 验证新二进制 …"
        if ! "$GRUN" "$WORK/package/claude" --version >/dev/null 2>&1; then
            echo "!! 新二进制验证失败, 已回滚" >&2
            exit 1
        fi
        mv -f "$WORK/package/claude" "$CLAUDE_BIN"
        chmod +x "$CLAUDE_BIN"
        echo "$VERSION" > "$VERSION_FILE"
        echo "✓ 已更新到 v$VERSION"
        ;;
    *)
        exec "$GRUN" "$CLAUDE_BIN" "$@"
        ;;
esac
WRAPPER_EOF
    chmod +x "$WRAPPER_PATH"

    if ! grep -q '\.local/bin' "$HOME_DIR/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
        info "~/.local/bin 已加入 PATH (~/.bashrc)"
    fi
    ok "启动 wrapper 已生成: $WRAPPER_PATH"
}

# ---------- 清理 DamnSit 残留 ----------
# /usr/bin/claude 若是第三方包的损坏符号链接 (shebang /usr/bin/env), 会遮蔽 wrapper
cleanup_legacy() {
    if [ -L "$PREFIX/bin/claude" ] || [ -f "$PREFIX/bin/claude" ]; then
        local target
        target=$(readlink "$PREFIX/bin/claude" 2>/dev/null || true)
        case "$target" in
            *@xurxuo*|*claude-code-termux*)
                warn "检测到第三方残留 ($PREFIX/bin/claude → $target), 移除…"
                rm -f "$PREFIX/bin/claude"
                if npm ls -g @xurxuo/claude-code-termux >/dev/null 2>&1; then
                    npm uninstall -g @xurxuo/claude-code-termux >/dev/null 2>&1 || true
                    warn "已卸载 npm 包 @xurxuo/claude-code-termux"
                fi
                ;;
        esac
    fi
}

# ---------- 验证 ----------
verify() {
    local ver
    ver=$(PATH="$HOME_DIR/.local/bin:$PATH" "$WRAPPER_PATH" --version 2>/dev/null) \
        || fail "验证失败: claude 无法运行"
    ok "安装成功: $ver"
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 Claude Code 并移除 wrapper…"
    rm -f "$WRAPPER_PATH"
    rm -rf "$CLAUDE_DIR"
    ok "已卸载。配置目录 (~/.claude) 保留, 如需删除: rm -rf ~/.claude"
    exit 0
}

# ---------- 配置指引 ----------
show_guide() {
    echo
    echo "=============================================================="
    echo "  安装完成! 下一步: 配置 API Key"
    echo "=============================================================="
    echo
    echo "  export ANTHROPIC_API_KEY=sk-ant-你的Key"
    echo "  (持久化: echo 'export ANTHROPIC_API_KEY=sk-ant-你的Key' >> ~/.bashrc)"
    echo
    echo "  常用命令:"
    echo "    claude            启动"
    echo "    claude update     更新到最新版"
    echo "    重跑本脚本即更新    (bash install.sh)"
    echo "    重跑本脚本 --uninstall 卸载"
    echo
    echo "  官方文档: https://docs.anthropic.com/en/docs/claude-code"
    echo "=============================================================="
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall) uninstall ;;
esac

info "claude-code-termux 安装脚本 — 仅支持 Termux aarch64"
check_environment
install_dependencies
fix_dns
cleanup_legacy
install_claude
write_wrapper
verify
show_guide
