#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# claude-code-termux — Termux (Android aarch64) 一键安装/更新/卸载官方 Claude Code CLI
# 纯脚本方案, 不发布 npm 分发包, 无需 glibc/grun
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/claude-code-termux/main/install.sh)
#   bash install.sh
#   bash install.sh --uninstall
#
# 原理:
#   官方 @anthropic-ai/claude-code-linux-arm64-musl 是 musl 动态链接二进制,
#   用 patchelf 把 interpreter 改成 Termux 的 musl loader 即可直跑,
#   与 opencode 同一套适配思路, 完全不需要 glibc-runner (grun)。
#
# 更新策略 (与官方机制差异):
#   官方 Claude Code 是启动 CLI 之后在后台自动升级;
#   本方案采用 codex-termux 同款: 启动前先查版本、有新版先升级再进程序,
#   并在 wrapper 中设 DISABLE_AUTOUPDATER=1 关闭官方后台更新。
#
# DNS 复用 codex-termux 的成熟方案:
#   有 root → dns53 本地转发器 (127.0.0.1:53, 自动跟随手机 DNS);
#   无 root → dns-bootstrap 实测校验 + proot 绑定 resolv.conf。
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CLAUDE_DIR="$HOME_DIR/.local/claude-code"
CLAUDE_BIN="$CLAUDE_DIR/claude"
VERSION_FILE="$CLAUDE_DIR/.version"
MODE_FILE="$CLAUDE_DIR/.mode"   # native (patchelf) / proot-bind
WRAPPER_PATH="$HOME_DIR/.local/bin/claude"
# 本脚本所在目录: 有本地仓库时优先使用仓库里的 dns53/ 组件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
NPM_PKG="@anthropic-ai/claude-code-linux-arm64-musl"
CERT_FILE="$PREFIX/etc/tls/cert.pem"
MUSL_LOADER="$PREFIX/lib/ld-musl-aarch64.so.1"
RESOLV_CONF="$PREFIX/etc/resolv.conf"
# Alpine 镜像 (动态解析版本, 不硬编码 — 见 install_musl_loader 上方说明)
ALPINE_MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/main/aarch64"
    "https://mirrors.aliyun.com/alpine/latest-stable/main/aarch64"
    "https://mirrors.ustc.edu.cn/alpine/latest-stable/main/aarch64"
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64"
)
UPSTREAM_DOCS_URL="https://docs.anthropic.com/en/docs/claude-code"

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------- root 判定 ----------
# Android 上有 root 不等于装了 Termux 的 sudo 包: Magisk/KernelSU 只提供 su。
# 只判断 `sudo -n` 会把「有 su、没 sudo」的设备误判成无 root。
have_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] && return 0
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
    if command -v su >/dev/null 2>&1; then
        local u=""
        u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1)" || true
        [ "$u" = "0" ] && return 0
    fi
    return 1
}

# ---------- 进度显示 ----------
# 背景: npm pack / npm install 全程不显示进度, 300MB 的包会让用户以为卡死。
# ① 下载: 先用 `npm view <spec> dist.tarball` 拿真实 URL —— 该命令跟随用户
#    配置的 registry (如 npmmirror) —— 再用 curl --progress-bar 下载,
#    有进度条/速度/剩余时间; 失败换另一个镜像, 最后才回退 npm pack (无进度)。
# ② 其它无输出的长步骤 (如 npm install -g): 用转圈 + 已耗时提示。
SPIN_CHARS='|/-\'
SPIN_LOG=""

# $1=提示语, 其余=要执行的命令; 输出存入 $SPIN_LOG, 失败时自动打印
run_with_spinner() {
    local msg="$1"; shift
    SPIN_LOG="${TMPDIR:-$PREFIX/tmp}/spin.$$.log"
    "$@" >"$SPIN_LOG" 2>&1 &
    local pid=$! i=0 t0=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K%s %s (%ds)' "$msg" "${SPIN_CHARS:$((i++ % 4)):1}" "$((SECONDS - t0))"
        sleep 0.5
    done
    wait "$pid"; local rc=$?
    printf '\r\033[K'
    if [ "$rc" -ne 0 ]; then
        warn "$msg 失败, 输出如下:"
        cat "$SPIN_LOG" >&2
    else
        echo -e "${msg} ${GRN}完成${NC} (${SECONDS}秒)"
    fi
    return $rc
}

# $1=npm spec → 输出 tarball URL (跟随 registry 配置)
npm_tarball_url() { npm view "$1" dist.tarball 2>/dev/null | tail -1; }

# $1=npm spec  $2=输出文件
download_npm_tarball() {
    local spec="$1" out="$2" url="" alt=""
    url="$(npm_tarball_url "$spec")"
    if [ -n "$url" ]; then
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$url" -o "$out" && return 0
        # 换镜像再试一次: npmjs ↔ npmmirror
        case "$url" in
            *registry.npmjs.org*)     alt="${url/registry.npmjs.org/registry.npmmirror.com}" ;;
            *registry.npmmirror.com*) alt="${url/registry.npmmirror.com/registry.npmjs.org}" ;;
        esac
        if [ -n "$alt" ] && [ "$alt" != "$url" ]; then
            warn "直连失败, 换镜像重试…"
            curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$alt" -o "$out" && return 0
        fi
    fi
    info "直连失败, 回退 npm pack (此方式无进度显示)…"
    (cd "$(dirname "$out")" && npm pack "$spec" --silent >/dev/null 2>&1) || return 1
    local packed
    packed="$(ls "$(dirname "$out")"/*.tgz 2>/dev/null | head -1)"
    [ -n "$packed" ] || return 1
    [ "$packed" = "$out" ] || mv -f "$packed" "$out"
    return 0
}

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。普通 Linux 请直接: npm install -g @anthropic-ai/claude-code"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64) 架构, 当前: $(uname -m)"
    command -v curl >/dev/null || { info "安装 curl…"; pkg install -y curl; }
    info "环境检查通过 (Termux aarch64)"
}

# ---------- 镜像源适配 ----------
# 刚装的 Termux 默认官方源, 国内经常慢/不可达。本函数对候选源逐个探测 + 测速,
# 再按"新鲜度优先、速度兜底"选一个自动切换 (幂等; 切换后 apt update 失败会回滚)。
#
# 排序规则 —— 每一条都是实测踩出来的:
#   1) 可用性: HTTP 200 **且 Release 里能解析出 Date: 字段**
#      华为云是反例: /termux/... 路径下 Release 与 Packages 都返回 200, 内容却是
#      一个 12KB 的 HTML 页面。只校验状态码的话它会被算进候选。
#   2) 绝对陈旧: Release 日期距今超过 MIRROR_MAX_AGE 的直接判废。
#      腾讯云实测停留在 4 个月前 (2831 包 vs 官方 3009 包, python 3.13 vs 3.14)。
#   3) 新鲜度优先: Release 日期落后"最新的那个候选"超过 MIRROR_FRESH_GRACE 就不要。
#      实测 2026-10-19 —— 快慢和新鲜度并不一致:
#        官方/清华      python 3.14.8   nodejs 26.4.0-1   patchelf 0.19.2
#        中科大/阿里云  python 3.14.6-1 (其余同上)
#        腾讯云         python 3.13.13  nodejs 26.3.1    patchelf 0.19.0
#      只看速度很容易切到一个包版本偏旧的源。
#   4) 落在宽限窗口内的多个候选 → 选最快的。
MIRROR_FRESH_GRACE="${MIRROR_FRESH_GRACE:-43200}"   # 12 小时
MIRROR_MAX_AGE="${MIRROR_MAX_AGE:-2592000}"         # 30 天

# $1=Release 文件路径 → 输出 Unix 时间戳; 解析不出返回非零
release_ts() {
    local d
    d=$(awk -F': ' '/^Date: /{print $2; exit}' "$1" 2>/dev/null) || d=""
    [ -n "$d" ] || return 1
    date -d "$d" +%s 2>/dev/null || return 1
}

fix_mirror() {
    local sources_file="$PREFIX/etc/apt/sources.list"
    [ -f "$sources_file" ] || { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 候选: "显示名 base URL" (路径各不相同, 已逐个实测 HTTP 200)
    local candidates=(
        "官方 https://packages.termux.dev/apt/termux-main"
        "清华 https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
        "中科大 https://mirrors.ustc.edu.cn/termux/apt/termux-main"
        "阿里云 https://mirrors.aliyun.com/termux/termux-main"
        "北大 https://mirrors.pku.edu.cn/termux/termux-main"
        "南科大 https://mirrors.sustech.edu.cn/termux/apt/termux-main"
        "南阳理工 https://mirror.nyist.edu.cn/termux/apt/termux-main"
    )

    local work entry name url code ts age t1 t2 t i cut
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/mirror.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    local now n=0 newest=0
    local -a NAMES=() URLS=() TIMES=() STAMPS=()
    now=$(date +%s)

    for entry in "${candidates[@]}"; do
        name="${entry%% *}"
        url="${entry##* }"
        code=$(curl -s -o "$work/rel" -w '%{http_code}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || code=000
        if [ "$code" != "200" ]; then
            info "跳过 $name (Release HTTP $code)"
            continue
        fi
        # 关键在于必须解析得出 Date —— 挡掉返回 HTML 却给 200 的假源
        ts=$(release_ts "$work/rel") || {
            info "跳过 $name (Release 里没有 Date 字段 —— 多半是个返回网页的假源)"
            continue
        }
        age=$(( now - ts ))
        if [ "$age" -gt "$MIRROR_MAX_AGE" ]; then
            info "跳过 $name (同步于 $(( age / 86400 )) 天前, 太陈旧)"
            continue
        fi
        t1=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t1=999
        t2=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t2=999
        t=$(printf '%s\n%s\n' "$t1" "$t2" | sort -n | head -1)
        info "候选 $name: ${t}s, 同步于 $(( age / 3600 )) 小时前"
        [ "$ts" -gt "$newest" ] && newest=$ts
        NAMES+=("$name"); URLS+=("$url"); TIMES+=("$t"); STAMPS+=("$ts")
        n=$(( n + 1 ))
    done

    if [ "$n" -eq 0 ]; then
        warn "所有候选源都不可用, 保持当前配置 (可手动: pkg change-repo)"
        return
    fi

    # 只保留"新鲜度落在宽限窗口内"的, 再从中选最快的
    local best_name="" best_url="" best_t=999999 best_ts=0
    cut=$(( newest - MIRROR_FRESH_GRACE ))
    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${STAMPS[$i]}" -ge "$cut" ]; then
            t="${TIMES[$i]}"
            if [ -z "$best_url" ] || awk "BEGIN{exit !($t < $best_t)}"; then
                best_name="${NAMES[$i]}"; best_url="${URLS[$i]}"; best_t="$t"; best_ts="${STAMPS[$i]}"
            fi
        fi
        i=$(( i + 1 ))
    done

    if [ -z "$best_url" ]; then
        warn "候选源的同步时间都超出宽限窗口, 保持当前配置"
        return
    fi
    ok "选定源: $best_name (${best_t}s, 同步于 $(( (now - best_ts) / 3600 )) 小时前)"

    # 当前已是选定源 → 不动
    if grep -qF "$best_url" "$sources_file" 2>/dev/null; then
        ok "当前源已是选定源, 无需切换"
        return
    fi

    local backup="$sources_file.bak.$(date +%s)"
    cp "$sources_file" "$backup"
    warn "切换源: $(grep -oE 'https://[^ ]+' "$sources_file" | head -1) → $best_name"
    {
        echo "# 由 install.sh 自动切换 (选定: $best_name ${best_t}s, Release $(( (now - best_ts) / 3600 )) 小时前)"
        echo "deb $best_url stable main"
    } > "$sources_file"

    if DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1; then
        ok "apt update 成功 ($best_name), 原配置备份: $(basename "$backup")"
    else
        warn "apt update 失败, 已自动回滚到原配置"
        cp "$backup" "$sources_file"
        DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 || true
    fi
}

upgrade_packages() {
    info "更新软件包索引并升级全部软件包…"
    info "提示: 全新 Termux 首次升级可能耗时数分钟 (下载量大), 请耐心等待, 不要打断"
    if DEBIAN_FRONTEND=noninteractive pkg upgrade -y; then
        ok "软件包已是最新"
    else
        warn "pkg upgrade 未完全成功, 请稍后重试 (pkg upgrade -y)"
    fi
}


# ---------- musl loader ----------
# 官方 musl 二进制动态链接 /lib/ld-musl-aarch64.so.1, Termux 没有, 从 Alpine 拉。
# (opencode 方案同款; 已存在则跳过)
# ---------- Alpine 源: 动态版本 + 多镜像回退 ----------
# 不能硬编码 apk 版本号: Alpine 的 edge 是滚动分支, 旧版本会被直接轮掉
# (musl-1.2.6-r2 在 edge 已经 404 了), 所以固定用 latest-stable 分支,
# 并从 APKINDEX.tar.gz (解压出来是纯文本索引) 取当前版本号。
ALPINE_BASE=""

apk_mirror_host() { local h="${1#https://}"; printf '%s' "${h%%/*}"; }

# $1=索引保存路径; 成功后把选中的镜像放进 ALPINE_BASE
alpine_select_mirror() {
    local m
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 30 "$m/APKINDEX.tar.gz" -o "$1"; then
            ALPINE_BASE="$m"
            ok "Alpine 镜像: $(apk_mirror_host "$m")"
            return 0
        fi
        warn "镜像不可用: $(apk_mirror_host "$m")"
    done
    fail "所有 Alpine 镜像都取不到 APKINDEX (网络问题?)"
}

# $1=索引路径 $2=包名 → 当前版本号; 解析失败则输出空串。
# 关键: 不能让 set -e 因为 pipeline 非零而"静默"退出 —— 曾出现过
# "没有任何报错、脚本直接结束" 的情况 (某些 tar 不认 apk 的扩展头会报错退出)。
alpine_version() {
    local idx="$1" pkg="$2" out=""
    # 注意: awk 打完就 exit, tar 会收到 SIGPIPE(141); 在 pipefail 下整条 pipeline 非零,
    # 若写成 `out=$(...) || out=""` 会把已经取到的值清空, 且 set -e 会让脚本"静默结束"。
    # 因此一律用 `|| true`: 保留已捕获的输出, 只吃掉非零退出码。
    out=$( { tar -xzOf "$idx" APKINDEX 2>/dev/null || true; } \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    # 回退: 用 gzip 先解压再喂给 tar, 绕开 tar 对 APK-TOOLS.checksum.SHA1 扩展头的处理差异
    [ -n "$out" ] || out=$( { gzip -dc "$idx" 2>/dev/null || true; } | tar -xOf - APKINDEX 2>/dev/null \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    printf '%s' "$out"
}

# $1=索引路径 $2=包名 $3=输出文件
alpine_fetch_apk() {
    local idx="$1" pkg="$2" out="$3" ver="" m
    ver="$(alpine_version "$idx" "$pkg")" || true
    if [ -z "$ver" ]; then
        warn "解析 $pkg 版本号失败, 下面是 tar 的真实输出:"
        tar -xzOf "$idx" APKINDEX >/dev/null || true
        fail "无法从 APKINDEX 解析 $pkg 的版本号"
    fi
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 120 "$m/$pkg-$ver.apk" -o "$out"; then
            info "$pkg-$ver.apk ← $(apk_mirror_host "$m")"
            return 0
        fi
        warn "$pkg-$ver.apk 下载失败: $(apk_mirror_host "$m")"
    done
    fail "$pkg.apk 下载失败 (已试 ${#ALPINE_MIRRORS[@]} 个镜像)"
}

install_musl_loader() {
    [ -x "$MUSL_LOADER" ] && { ok "musl loader 已存在: $MUSL_LOADER"; return 0; }
    info "下载 musl 动态链接器 (Alpine)…"
    local tmp idx
    tmp="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/musl-loader.XXXXXX")"
    idx="$tmp/APKINDEX.tar.gz"
    # 必须双引号: 让路径在设置时就展开成字面量。
    # 单引号版本会在"函数返回时"才求值, 而 RETURN trap 还会泄漏到调用方
    # (调用方返回时再次触发), 那时 $tmp 已出作用域 → set -u 报 unbound variable。
    trap "rm -rf '$tmp'" RETURN
    alpine_select_mirror "$idx"
    alpine_fetch_apk "$idx" musl "$tmp/musl.apk"
    (cd "$tmp" && tar xzf musl.apk) || fail "musl apk 解压失败"
    [ -f "$tmp/lib/ld-musl-aarch64.so.1" ] || fail "apk 中未找到 ld-musl-aarch64.so.1"
    cp "$tmp/lib/ld-musl-aarch64.so.1" "$PREFIX/lib/"
    chmod +x "$MUSL_LOADER"
    ok "musl loader 已安装: $MUSL_LOADER"
}

# ---------- 依赖 ----------
# 注意: 不再需要 glibc-repo / glibc-runner (grun), 只需要 nodejs(npm) + patchelf。
install_dependencies() {
    local need=()
    command -v curl >/dev/null || need+=(curl)
    command -v node >/dev/null || need+=(nodejs-lts)
    command -v npm >/dev/null || need+=(nodejs-lts)
    command -v patchelf >/dev/null || need+=(patchelf)
    if have_root; then
        # 有 root 也装 proot: dns53 挂掉时用它绑 resolv.conf 兜底 DNS
        command -v proot >/dev/null 2>&1 || need+=(proot)
    elif command -v sudo >/dev/null 2>&1; then
        if ! sudo -n true 2>/dev/null; then
            need+=(proot)
        fi
    else
        need+=(sudo)
    fi
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    fi
    # 重新探测 root: 有 root 但缺 proot 也要补 (DNS 兜底); 无 root 则必须 proot
    command -v proot >/dev/null 2>&1 || {
        if have_root; then
            info "有 root 但缺少 proot, 安装 DNS 兜底…"
        else
            info "未检测到 root, 安装 proot 兜底…"
        fi
        pkg install -y proot
    }
    if ! have_root; then
        warn "未检测到 root: 将使用 proot 兜底方案 (性能略降)"
    fi
    install_musl_loader
    ok "依赖已就绪 (node $(node --version), patchelf)"
}

# ---------- 证书 ----------
fix_cert() {
    if [ ! -f "$CERT_FILE" ]; then
        warn "未找到 CA 证书 ($CERT_FILE), 尝试安装 ca-certificates…"
        pkg install -y ca-certificates
    fi
    ok "证书路径: $CERT_FILE"
}

# ---------- dns53 独立组件 ----------
# dns53 (musl 程序的 DNS 兜底) 不再内嵌在本脚本、也不再写入任何 agent 目录,
# 而是作为独立组件安装到 ~/.local/share/dns53, 源码与安装器见仓库 dns53/。
# 其他 agent 可复用同一目录, 也可直接运行:
#   bash ~/.local/share/dns53/install.sh
DNS53_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/dns53"
DNS53_RAW_BASES=(
    "https://cdn.jsdelivr.net/gh/xkxxs/claude-code-termux@main/dns53"
    "https://raw.githubusercontent.com/xkxxs/claude-code-termux/main/dns53"
)
DNS53_FILES=(install.sh VERSION root.sh dns53.js dns-bootstrap.js dnsq.js check_dns.sh dns53-aaaa)

fetch_dns53_payload() {
    local dst="$1" base f all
    mkdir -p "$dst"
    for base in "${DNS53_RAW_BASES[@]}"; do
        all=1
        for f in "${DNS53_FILES[@]}"; do
            if ! curl -fsSL --connect-timeout 10 --max-time 60 "$base/$f" -o "$dst/$f"; then
                all=0
                break
            fi
        done
        if [ "$all" = "1" ]; then
            return 0
        fi
        warn "dns53 组件下载失败, 换源: $base"
    done
    return 1
}

install_dns53() {
    local src="" tmp=""
    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/dns53/install.sh" ]; then
        src="$SCRIPT_DIR/dns53"
        info "dns53 组件: 使用本地仓库 dns53/"
    else
        tmp="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/dns53.XXXXXX")" || tmp=""
        if [ -n "$tmp" ] && fetch_dns53_payload "$tmp"; then
            src="$tmp"
            info "dns53 组件: 已从仓库下载"
        else
            if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
            tmp=""
            if [ -f "$DNS53_DIR/install.sh" ]; then
                src="$DNS53_DIR"
                warn "dns53 组件下载失败, 沿用已安装版本"
            else
                warn "dns53 组件获取失败, 跳过 DNS 配置 (可稍后重跑本脚本)"
                return 0
            fi
        fi
    fi
    if ! bash "$src/install.sh"; then
        warn "dns53 组件安装异常 (详见上方输出)"
    fi
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}


# ---------- 清理第三方残留 ----------
# 旧版/第三方安装 (如 @xurxuo/claude-code-termux) 可能在 $PREFIX/bin/claude
# 留下 shebang 损坏的 node 脚本/符号链接, 会遮蔽本 wrapper。
cleanup_legacy() {
    if [ -L "$PREFIX/bin/claude" ] || [ -f "$PREFIX/bin/claude" ]; then
        local target
        target="$(readlink "$PREFIX/bin/claude" 2>/dev/null || true)"
        case "$target" in
            *@xurxuo*|*claude-code-termux*)
                warn "检测到第三方残留 ($PREFIX/bin/claude → $target), 移除…"
                rm -f "$PREFIX/bin/claude"
                if npm ls -g @xurxuo/claude-code-termux >/dev/null 2>&1; then
                    npm uninstall -g @xurxuo/claude-code-termux >/dev/null 2>&1 || true
                fi
                ;;
        esac
    fi
}

# ---------- patchelf 补丁 (两种实现) ----------
# Termux 默认的 patchelf 是 0.19.2, 它会把某些大体积 musl 二进制改坏: 退出码
# 是 0 (看起来成功), 但产物一跑就 SIGSEGV (opencode V2 / qoder 上都复现过)。
# glibc 环境里的 patchelf 是 0.19.1, 实测产物能原生直跑。所以验证不过时,
# 先换 glibc 版再试一次, 都不行才退到 proot-bind。
GLIBC_PATCHELF="$PREFIX/glibc/bin/patchelf"

# 确保 glibc 版 patchelf 可用; 首次安装需下载约 33MB、占用约 214MB 磁盘
install_glibc_patchelf() {
    if command -v grun >/dev/null 2>&1 && [ -x "$GLIBC_PATCHELF" ]; then
        return 0
    fi
    info "安装 glibc 版 patchelf (0.19.1, 能正确处理该二进制)…"
    info "提示: 需下载约 33MB、占用约 214MB 磁盘, 首次会慢一些"
    pkg install -y patchelf-glibc glibc glibc-runner gcc-libs-glibc >/dev/null 2>&1 || true
    command -v grun >/dev/null 2>&1 && [ -x "$GLIBC_PATCHELF" ]
}

# ---------- proot 绑定运行 (patchelf 靠不住时的兜底) ----------
# Termux 的 patchelf 0.19.2 会把某些大体积 musl 二进制改坏 (打完补丁一跑就
# SIGSEGV, opencode V2 上已复现)。此时二进制保持官方原样, 改由 proot 把
# musl loader / 运行库绑到它原本要找的标准路径上 —— 完全不需要 patchelf。
proot_bind_run() {
    local bin="$1"; shift
    local opts=(-b "${MUSL_LOADER:-$PREFIX/lib/ld-musl-aarch64.so.1}:/lib/ld-musl-aarch64.so.1")
    if [ -f "${PREFIX}/lib/musl/libstdc++.so.6" ]; then
        opts+=(-b "${PREFIX}/lib/musl/libstdc++.so.6:/usr/lib/libstdc++.so.6")
    fi
    if [ -f "${PREFIX}/lib/musl/libgcc_s.so.1" ]; then
        opts+=(-b "${PREFIX}/lib/musl/libgcc_s.so.1:/usr/lib/libgcc_s.so.1")
    fi
    if [ -f "${PREFIX}/etc/resolv.conf" ]; then
        opts+=(-b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf")
    fi
    proot "${opts[@]}" env -u LD_PRELOAD SSL_CERT_FILE="$CERT_FILE" "$bin" "$@"
}

# ---------- 安装官方 Claude Code (musl) ----------
install_claude() {
    local version tarball
    info "查询最新版本…"
    version="$(npm view "$NPM_PKG" version)" || fail "无法获取版本号 (网络问题?)"

    if [ -x "$CLAUDE_BIN" ] && [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$version" ]; then
        ok "Claude Code $version 已是最新"
        return 0
    fi

    info "下载 $NPM_PKG v${version} (约 300MB, 可能较慢)…"
    work="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/claude-install.XXXXXX")"
    # 同上: 双引号让路径立即展开, 避免 EXIT 触发时 $work 已出作用域
    trap "rm -rf '$work'" EXIT

    tarball="$work/claude.tgz"
    download_npm_tarball "$NPM_PKG@${version}" "$tarball" \
        || fail "下载失败 (curl 直连 / 换镜像 / npm pack 均不可用)"

    tar xzf "$tarball" -C "$work"
    [ -f "$work/package/claude" ] || fail "tarball 内容异常 (缺少 package/claude)"

    local mode=native
    cp "$work/package/claude" "$work/claude.orig"   # 留一份未打补丁的

    info "打补丁: interpreter → $MUSL_LOADER …"
    patchelf --set-interpreter "$MUSL_LOADER" "$work/package/claude" \
        || warn "patchelf 失败 (将改用 proot 绑定模式)"
    chmod +x "$work/package/claude"

    info "验证新二进制 (直跑, 无 grun)…"
    # 无 root 时 musl 二进制被 Android seccomp 拦截 → Bad system call, 需走 proot
    local verify_ok=0
    if have_root; then
        env -u LD_PRELOAD SSL_CERT_FILE="$CERT_FILE" "$work/package/claude" --version >/dev/null 2>&1 && verify_ok=1
    elif command -v proot >/dev/null 2>&1; then
        proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" \
            env -u LD_PRELOAD SSL_CERT_FILE="$CERT_FILE" \
            "$work/package/claude" --version >/dev/null 2>&1 && verify_ok=1
    else
        env -u LD_PRELOAD SSL_CERT_FILE="$CERT_FILE" "$work/package/claude" --version >/dev/null 2>&1 && verify_ok=1
    fi

    if [ "$verify_ok" -ne 1 ]; then
        # 0.19.2 不行 → 换 glibc 版 0.19.1 再试一次 (实测它能正确处理)
        if install_glibc_patchelf; then
            info "改用 glibc 版 patchelf ($(grun "$GLIBC_PATCHELF" --version 2>/dev/null | head -1)) 重打补丁…"
            cp -f "$work/claude.orig" "$work/package/claude"
            grun "$GLIBC_PATCHELF" --set-interpreter "$MUSL_LOADER" "$work/package/claude" 2>/dev/null || true
            chmod +x "$work/package/claude"
            if have_root; then
                env -u LD_PRELOAD SSL_CERT_FILE="$CERT_FILE" "$work/package/claude" --version >/dev/null 2>&1 && verify_ok=1
            elif command -v proot >/dev/null 2>&1; then
                proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" \
                    env -u LD_PRELOAD SSL_CERT_FILE="$CERT_FILE" \
                    "$work/package/claude" --version >/dev/null 2>&1 && verify_ok=1
            else
                env -u LD_PRELOAD SSL_CERT_FILE="$CERT_FILE" "$work/package/claude" --version >/dev/null 2>&1 && verify_ok=1
            fi
            [ "$verify_ok" -eq 1 ] && ok "glibc 版 patchelf 补丁验证通过"
        fi
    fi

    if [ "$verify_ok" -ne 1 ]; then
        warn "两种 patchelf 都跑不起来 (0.19.2 会改坏大体积 musl 二进制)"
        info "改用 proot 绑定运行库模式 (二进制保持官方原样, 由 proot 绑 musl loader)"
        if ! command -v proot >/dev/null 2>&1; then
            info "安装 proot…"
            pkg install -y proot || true
        fi
        command -v proot >/dev/null 2>&1 \
            || fail "该模式需要 proot, 但安装失败。请手动: pkg install proot"
        chmod +x "$work/claude.orig"
        if proot_bind_run "$work/claude.orig" --version >/dev/null 2>&1; then
            cp -f "$work/claude.orig" "$work/package/claude"
            chmod +x "$work/package/claude"
            mode=proot-bind
            ok "proot 绑定模式验证通过"
        else
            fail "二进制验证失败 (patchelf 与 proot 绑定两种模式都不行)"
        fi
    fi

    mkdir -p "$CLAUDE_DIR"
    mv -f "$work/package/claude" "$CLAUDE_BIN"
    chmod +x "$CLAUDE_BIN"
    echo "$version" > "$VERSION_FILE"
    echo "$mode" > "$MODE_FILE"
    ok "Claude Code $version 已安装 (运行模式: $mode)"
    rm -rf "$work"
}

# ---------- 启动 wrapper ----------
write_wrapper() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$WRAPPER_PATH" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# claude wrapper for Termux (由 claude-code-termux/install.sh 生成)
# - 官方 musl 二进制, patchelf 直跑, 无需 glibc/grun
# - 启动前自动检查最新版本, 非最新则自动更新再启动
#   (可用 CLAUDE_NO_AUTO_UPDATE=1 跳过检查)
# - 关闭 Claude 自带的后台自动更新 (DISABLE_AUTOUPDATER=1),
#   统一由本 wrapper 在启动前升级, 避免两套机制冲突
# - 注入 SSL_CERT_FILE; unset LD_PRELOAD (termux-exec 与 musl 冲突)
# - DNS: 有 root → dns53; 无 root → dns-bootstrap + proot (同 codex-termux)
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
CLAUDE_BIN="$HOME/.local/claude-code/claude"
VERSION_FILE="$HOME/.local/claude-code/.version"
MODE_FILE="$HOME/.local/claude-code/.mode"   # native (patchelf) / proot-bind
# dns53 独立组件 (与 agent 目录解耦)
DNS53_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"
NPM_PKG="@anthropic-ai/claude-code-linux-arm64-musl"

# root 判定/执行后端: 由 dns53 组件的 root.sh 统一处理 direct/sudo/su
# (Android 上 Magisk/KernelSU 只提供 su, 不能只判断 Termux 的 sudo 包)
DNS_DIR="$DNS53_DIR"
if [ -f "$DNS53_DIR/root.sh" ]; then
    . "$DNS53_DIR/root.sh"
    dns53_load_root_mode 0 || true
fi
if declare -F dns53_have_root >/dev/null 2>&1; then
    have_root() { dns53_have_root; }
else
    have_root() {
        [ "$(id -u 2>/dev/null)" = "0" ] && return 0
        command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
        if command -v su >/dev/null 2>&1; then
            local u=""
            u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1)" || true
            [ "$u" = "0" ] && return 0
        fi
        return 1
    }
    # root.sh 缺失时的最小兜底 (旧行为: 只认 sudo -n / 本身已是 root)
    dns53_alive() {
        local f="$DNS53_DIR/.alive" now mt
        [ -f "$f" ] || return 1
        now=$(date +%s)
        mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        [ $((now - mt)) -lt 90 ]
    }
    dns53_root_exec() {
        if [ "$(id -u 2>/dev/null)" = "0" ]; then "$@"
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then sudo -n "$@"
        else return 1; fi
    }
fi

export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
export DISABLE_AUTOUPDATER=1
# 兜底: claude 的 shell 集成需要可执行的入口路径, 固定指向 wrapper
export CLAUDE_CODE_EXECPATH="$HOME/.local/bin/claude"
# termux-exec 的 bionic LD_PRELOAD 会让 musl 加载器报错, 必须清掉
unset LD_PRELOAD

[ -x "$CLAUDE_BIN" ] || { echo "未安装 Claude Code, 请重跑安装脚本" >&2; exit 1; }

# ---------- 下载进度 ----------
# npm pack 不显示进度 (300MB 的包会让人以为卡死): 先用 npm view 拿真实 URL
# (跟随 registry 配置), 再用 curl --progress-bar 下载; 失败换镜像, 再回退 npm pack。
npm_tarball_url() { npm view "$1" dist.tarball 2>/dev/null | tail -1; }

download_npm_tarball() {
    local spec="$1" out="$2" url="" alt=""
    url="$(npm_tarball_url "$spec")"
    if [ -n "$url" ]; then
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$url" -o "$out" && return 0
        case "$url" in
            *registry.npmjs.org*)     alt="${url/registry.npmjs.org/registry.npmmirror.com}" ;;
            *registry.npmmirror.com*) alt="${url/registry.npmmirror.com/registry.npmjs.org}" ;;
        esac
        if [ -n "$alt" ] && [ "$alt" != "$url" ]; then
            echo "!! 直连失败, 换镜像重试…" >&2
            curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$alt" -o "$out" && return 0
        fi
    fi
    echo "→ 直连失败, 回退 npm pack (无进度显示)…" >&2
    (cd "$(dirname "$out")" && npm pack "$spec" --silent >/dev/null 2>&1) || return 1
    local packed
    packed="$(ls "$(dirname "$out")"/*.tgz 2>/dev/null | head -1)"
    [ -n "$packed" ] || return 1
    [ "$packed" = "$out" ] || mv -f "$packed" "$out"
    return 0
}

# 运行 claude 二进制: 有 root 直跑, 无 root 走 proot (避免 seccomp 拦截 musl 系统调用)
run_claude() {
    local bin="$1"; shift
    # proot-bind 模式 (patchelf 把二进制改坏时的兜底): 二进制未打补丁,
    # 必须经 proot 把 musl loader 绑到 /lib/ld-musl-aarch64.so.1 才能跑
    if [ "$(cat "$MODE_FILE" 2>/dev/null || echo native)" = "proot-bind" ] \
       && command -v proot >/dev/null 2>&1; then
        proot_bind_run "$bin" "$@"
    elif have_root; then
        "$bin" "$@"
    elif command -v proot >/dev/null 2>&1; then
        proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" "$bin" "$@"
    else
        "$bin" "$@"
    fi
}

# 本地已记录版本; 无记录时从二进制本身探测 (可能为空)
current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        run_claude "$CLAUDE_BIN" --version 2>/dev/null \
            | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n1 || true
    fi
}

# npm 源上的最新版本; 失败时为空 (快速失败, 不拖慢启动)
latest_version() {
    npm view "$NPM_PKG" version --fetch-timeout=10000 --fetch-retries=0 2>/dev/null || true
}

# 版本比较: $1 >= $2 返回 0 (sort -V 语义)
version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# 下载 → patchelf → 验证 → 原子替换。失败返回 1, 保留旧二进制。
do_update() {
    local VERSION="$1" WORK TARBALL NEW_BIN
    WORK="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/claude-update.XXXXXX")" || return 1
    # 同上: 双引号让路径立即展开, 避免 RETURN trap 泄漏到调用方后 $WORK 未绑定
    trap "rm -rf '$WORK'" RETURN
    echo "→ 下载 $NPM_PKG v${VERSION} (约 300MB, 可能较慢)…"
    TARBALL="$WORK/claude.tgz"
    download_npm_tarball "$NPM_PKG@${VERSION}" "$TARBALL" \
        || { echo "!! 下载失败 (curl 直连 / 换镜像 / npm pack 均不可用)" >&2; return 1; }
    tar xzf "$TARBALL" -C "$WORK" || { echo "!! 解压失败" >&2; return 1; }
    NEW_BIN="$WORK/package/claude"
    [ -f "$NEW_BIN" ] || { echo "!! tarball 内容异常" >&2; return 1; }
    patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" "$NEW_BIN" || return 1
    chmod +x "$NEW_BIN"
    if ! run_claude "$NEW_BIN" --version >/dev/null 2>&1; then
        echo "!! 新二进制验证失败, 已回滚 (旧版保留)" >&2
        return 1
    fi
    mkdir -p "$(dirname "$CLAUDE_BIN")"
    mv -f "$NEW_BIN" "$CLAUDE_BIN"
    chmod +x "$CLAUDE_BIN"
    echo "$VERSION" > "$VERSION_FILE"
    echo "✓ 已更新到 v$VERSION"
}

case "${1:-}" in
    --update|-u|update|upgrade)
        FORCE=0
        if [ "${2:-}" = "--force" ] || [ "${2:-}" = "-f" ]; then FORCE=1; fi
        VERSION="$(latest_version)"
        [ -n "$VERSION" ] || { echo "!! 无法获取最新版本 (网络问题?)" >&2; exit 1; }
        CURRENT="$(current_version)"
        if [ "$FORCE" -eq 0 ] && [ -n "$CURRENT" ] && version_ge "$CURRENT" "$VERSION"; then
            echo "✓ 已是最新 ($CURRENT)"
            exit 0
        fi
        do_update "$VERSION" || exit 1
        ;;
    *)
        # 自动更新: 启动前查一次最新版 (失败静默跳过),
        # 非最新则自动更新; 更新失败不阻塞, 用现有版本启动
        if [ "${CLAUDE_NO_AUTO_UPDATE:-0}" != "1" ] && command -v npm >/dev/null 2>&1; then
            LATEST="$(latest_version)"
            if [ -n "$LATEST" ]; then
                CURRENT="$(current_version)"
                if [ -z "$CURRENT" ] || ! version_ge "$CURRENT" "$LATEST"; then
                    echo "→ 检测到新版本 v${LATEST} (当前 ${CURRENT:-未知}), 自动更新…"
                    if do_update "$LATEST"; then
                        echo "→ 更新完毕, 继续启动 claude…"
                    else
                        echo "!! 自动更新失败, 继续使用现有版本启动" >&2
                    fi
                fi
            fi
        fi
        # proot-bind 模式: 二进制未打补丁, 靠 proot 把 musl loader 绑到标准路径
        if [ "$(cat "$MODE_FILE" 2>/dev/null || echo native)" = "proot-bind" ] \
           && command -v proot >/dev/null 2>&1; then
            BINDS=(-b "${PREFIX}/lib/ld-musl-aarch64.so.1:/lib/ld-musl-aarch64.so.1")
            [ -f "${PREFIX}/lib/musl/libstdc++.so.6" ] \
                && BINDS+=(-b "${PREFIX}/lib/musl/libstdc++.so.6:/usr/lib/libstdc++.so.6")
            [ -f "${PREFIX}/lib/musl/libgcc_s.so.1" ] \
                && BINDS+=(-b "${PREFIX}/lib/musl/libgcc_s.so.1:/usr/lib/libgcc_s.so.1")
            [ -f "${PREFIX}/etc/resolv.conf" ] \
                && BINDS+=(-b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf")
            exec proot "${BINDS[@]}" "$CLAUDE_BIN" "$@"
        fi
        # DNS: 与 codex-termux 相同策略
        if have_root; then
            # 有 root 但 dns53 没在跑: 先尽力拉起 (direct/sudo/su 均可);
            # 起不来时 native 直跑会没有可用 DNS, 改走 proot + dns-bootstrap。
            if ! dns53_alive; then
                if [ -f "$DNS53_DIR/dns53.js" ]; then
                    mkdir -p "$DNS53_DIR/logs"
                    dns53_root_exec nohup node "$DNS53_DIR/dns53.js" >> "$DNS53_DIR/logs/dns53.log" 2>&1 &
                    sleep 1
                fi
            fi
            if dns53_alive; then
                exec "$CLAUDE_BIN" "$@"
            elif command -v proot >/dev/null 2>&1; then
                [ -f "${PREFIX}/etc/resolv.conf" ] || { echo "缺少 ${PREFIX}/etc/resolv.conf, 请重跑安装脚本" >&2; exit 1; }
                if [ -f "$DNS53_DIR/dns-bootstrap.js" ]; then
                    node "$DNS53_DIR/dns-bootstrap.js" \
                        || echo "!! 网络 DNS 全部不可用 (UDP 53 被拦截?), 已用公共 DNS 兜底继续启动" >&2
                fi
                exec proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" "$CLAUDE_BIN" "$@"
            else
                # 最后兜底: 有 root 但既无 dns53 也无 proot, 只能直跑
                exec "$CLAUDE_BIN" "$@"
            fi
        elif command -v proot >/dev/null 2>&1; then
            [ -f "${PREFIX}/etc/resolv.conf" ] || { echo "缺少 ${PREFIX}/etc/resolv.conf, 请重跑安装脚本" >&2; exit 1; }
            if [ -f "$DNS53_DIR/dns-bootstrap.js" ] && ! pgrep -f "dns-bootstrap[.]js.*daemon" > /dev/null 2>&1; then
                node "$DNS53_DIR/dns-bootstrap.js" \
                    || echo "!! 网络 DNS 全部不可用 (UDP 53 被拦截?), 已用公共 DNS 兜底继续启动" >&2
            fi
            exec proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" "$CLAUDE_BIN" "$@"
        else
            echo "未检测到 root 且缺少 proot, 请先安装: pkg install proot" >&2
            exit 1
        fi
        ;;
esac
WRAPPER_EOF
    chmod +x "$WRAPPER_PATH"

    # 确保 ~/.local/bin 在 PATH 中且优先
    if ! grep -q '\.local/bin' "$HOME_DIR/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
        info "~/.local/bin 已加入 PATH (~/.bashrc)"
    fi
    ok "启动 wrapper 已生成: $WRAPPER_PATH"
}

# ---------- 验证 ----------
verify() {
    local ver
    ver="$(PATH="$HOME_DIR/.local/bin:$PATH" "$WRAPPER_PATH" --version 2>/dev/null)" \
        || fail "验证失败: claude 无法运行"
    ok "安装成功: $ver"
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 Claude Code 并移除 wrapper…"
    npm uninstall -g "$NPM_PKG" >/dev/null 2>&1 || true
    rm -f "$WRAPPER_PATH"
    rm -rf "$CLAUDE_DIR"
    ok "已卸载。配置目录 (~/.claude) 保留, 如需删除: rm -rf ~/.claude"
    warn "dns53 独立组件已保留 — codex/opencode 等其他 musl 程序可能依赖它"
    warn "如需一并移除: bash ~/.local/share/dns53/install.sh --uninstall"
    exit 0
}

# ---------- 配置指引 ----------
show_guide() {
    echo
    echo "=============================================================="
    echo "  安装完成! 下一步: 配置 API Key"
    echo "=============================================================="
    echo
    echo "  DeepSeek (Anthropic 兼容网关) 示例:"
    echo "    export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic"
    echo "    export ANTHROPIC_AUTH_TOKEN=sk-ant-你的Key"
    echo "    export ANTHROPIC_MODEL=deepseek-v4-flash[1m]"
    echo "  (持久化: 把上面三行追加到 ~/.bashrc)"
    echo
    echo "  常用命令:"
    echo "    claude               启动 (启动前自动检查更新)"
    echo "    claude update        手动更新到最新版"
    echo "    claude update -f     强制重装当前版本"
    echo "    CLAUDE_NO_AUTO_UPDATE=1 claude   跳过启动时更新检查"
    echo "    重跑本脚本即更新      (bash install.sh)"
    echo "    重跑本脚本 --uninstall 卸载"
    echo
    echo "  官方文档: $UPSTREAM_DOCS_URL"
    echo "=============================================================="
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall) uninstall ;;
esac

info "claude-code-termux 安装脚本 (musl 直跑版) — 仅支持 Termux aarch64"
mkdir -p "$HOME_DIR/.codex" "$HOME_DIR/.local/bin"
check_environment
fix_mirror
upgrade_packages
install_dependencies
fix_cert
install_dns53
cleanup_legacy
install_claude
write_wrapper
verify
show_guide
