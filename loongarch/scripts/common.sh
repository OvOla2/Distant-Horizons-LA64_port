#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Distant Horizons - LoongArch64 移植：公共函数库
#
# 被同目录下的脚本 source 使用，不单独执行。
#
# 代理说明（仅本地需要；CI 中不要设置）：
#   export PROXY_URL="http://127.0.0.1:20171"     # 默认值即此
#   export PROXY_URL=""                            # 显式关闭代理
# 支持的变量：
#   PROXY_URL              HTTP/HTTPS 代理地址，默认 http://127.0.0.1:20171
#   DH_SKIP_GRADLE_PROXY   设为 1 时不改写 $GRADLE_USER_HOME/gradle.properties
#   GRADLE_USER_HOME       Gradle 用户目录，默认 ~/.gradle
# ---------------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "错误：请使用 bash 运行本脚本（bash <script>）" >&2
    exit 1
fi

set -o pipefail

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _DH_C_INFO=$'\033[36m'; _DH_C_OK=$'\033[32m'
    _DH_C_WARN=$'\033[33m'; _DH_C_ERR=$'\033[31m'; _DH_C_OFF=$'\033[0m'
else
    _DH_C_INFO=""; _DH_C_OK=""; _DH_C_WARN=""; _DH_C_ERR=""; _DH_C_OFF=""
fi

dh_info() { printf '%s[info]%s %s\n' "$_DH_C_INFO" "$_DH_C_OFF" "$*"; }
dh_ok()   { printf '%s[ ok ]%s %s\n' "$_DH_C_OK" "$_DH_C_OFF" "$*"; }
dh_warn() { printf '%s[warn]%s %s\n' "$_DH_C_WARN" "$_DH_C_OFF" "$*" >&2; }
dh_die()  { printf '%s[error]%s %s\n' "$_DH_C_ERR" "$_DH_C_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
# dh_require_cmds "git" "make" ...
dh_require_cmds() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        dh_die "缺少必要工具: ${missing[*]}（请先用系统包管理器安装）"
    fi
}

# 校验仓库根目录（脚本位于 <repo>/loongarch/scripts/）
dh_detect_repo_root() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local root
    root="$(cd "$here/../.." && pwd)"
    [ -f "$root/gradle.properties" ] || dh_die "无法定位仓库根目录（$root 下没有 gradle.properties）"
    printf '%s\n' "$root"
}

# ---------------------------------------------------------------------------
# 版本读取：必须从 DH 构建文件动态获取，不硬编码
# ---------------------------------------------------------------------------
# dh_read_gradle_prop <file> <key>
dh_read_gradle_prop() {
    local file="$1" key="$2" value=""
    [ -f "$file" ] || return 1
    value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | tail -n 1 | tr -d '\r')"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# 从 DH 的 gradle.properties 读取 sqlite-jdbc 版本；
# 找不到时再从 *.gradle 中的 sqlite_jdbc_version 定义里兜底。
dh_sqlite_jdbc_version() {
    local root="$1" value=""
    if value="$(dh_read_gradle_prop "$root/gradle.properties" "sqlite_jdbc_version")"; then
        printf '%s\n' "$value"
        return 0
    fi
    value="$(grep -rhoE "sqlite_jdbc_version[[:space:]]*=[[:space:]]*['\"]?[0-9][0-9A-Za-z.\-]*" \
        "$root" --include="*.gradle" --include="*.gradle.kts" --include="*.toml" 2>/dev/null \
        | sed -E "s/.*=[[:space:]]*['\"]?//" | head -n 1 || true)"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# ---------------------------------------------------------------------------
# JDK / 代理
# ---------------------------------------------------------------------------
dh_ensure_java_home() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
        export JAVA_HOME
        return 0
    fi
    command -v java >/dev/null 2>&1 || dh_die "未找到 java，请安装 JDK 或设置 JAVA_HOME"
    local java_bin real
    java_bin="$(command -v java)"
    # 解析符号链接（AOSC: /usr/bin/java -> /usr/lib/java-XX/bin/java）
    real="$(readlink -f "$java_bin" 2>/dev/null || printf '%s' "$java_bin")"
    JAVA_HOME="$(cd "$(dirname "$real")/.." && pwd)"
    [ -x "$JAVA_HOME/bin/javac" ] || dh_die "无法从 $java_bin 推断 JAVA_HOME（缺少 javac），请显式设置 JAVA_HOME"
    export JAVA_HOME
}

# 解析 PROXY_URL：
#   - 显式设置（含空串）则尊重用户选择
#   - 未设置时：本地默认 http://127.0.0.1:20171；CI（CI=true）默认不使用代理
dh_resolve_proxy_url() {
    if [ -z "${PROXY_URL+set}" ]; then
        if [ -n "${CI:-}" ]; then
            PROXY_URL=""
        else
            PROXY_URL="http://127.0.0.1:20171"
        fi
    fi
}

# 设置 http(s)_proxy 环境变量（供 git/curl/make 使用）
dh_export_proxy_env() {
    dh_resolve_proxy_url
    if [ -n "${PROXY_URL:-}" ]; then
        export http_proxy="$PROXY_URL"  https_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL"  HTTPS_PROXY="$PROXY_URL"
        export no_proxy="${no_proxy:-localhost,127.0.0.1,::1}"
        export NO_PROXY="${NO_PROXY:-$no_proxy}"
        dh_info "使用代理: $PROXY_URL"
    fi
}

# 让 Gradle 守护进程也能走代理。
# Gradle 不读取 http_proxy 环境变量，需要在 $GRADLE_USER_HOME/gradle.properties
# 中写入 systemProp.* 配置；这里以带标记的托管块方式追加，可重复执行。
# 关闭方式：DH_SKIP_GRADLE_PROXY=1
dh_configure_gradle_proxy() {
    dh_resolve_proxy_url
    [ -n "${PROXY_URL:-}" ] || return 0
    [ "${DH_SKIP_GRADLE_PROXY:-0}" = "1" ] && { dh_warn "已跳过 Gradle 代理配置（DH_SKIP_GRADLE_PROXY=1）"; return 0; }

    local ghome="${GRADLE_USER_HOME:-$HOME/.gradle}"
    local target="$ghome/gradle.properties"
    local hp="${PROXY_URL#*://}"; hp="${hp%%/*}"
    local host="${hp%%:*}" port="${hp##*:}"
    [ -n "$host" ] || { dh_warn "无法解析 PROXY_URL，跳过 Gradle 代理配置"; return 0; }
    if [ "$port" = "$host" ]; then
        case "$PROXY_URL" in https://*) port=443 ;; *) port=80 ;; esac
    fi

    mkdir -p "$ghome"
    local begin="# >>> dh-loongarch gradle proxy (managed) >>>"
    local end="# <<< dh-loongarch gradle proxy (managed) <<<"
    local tmp; tmp="$(mktemp)"
    if [ -f "$target" ]; then
        awk -v b="$begin" -v e="$end" '
            $0==b {skip=1; next}
            $0==e {skip=0; next}
            skip!=1 {print}
        ' "$target" > "$tmp"
    fi
    {
        printf '%s\n' "$begin"
        printf 'systemProp.http.proxyHost=%s\n'  "$host"
        printf 'systemProp.http.proxyPort=%s\n'  "$port"
        printf 'systemProp.https.proxyHost=%s\n' "$host"
        printf 'systemProp.https.proxyPort=%s\n' "$port"
        printf 'systemProp.http.nonProxyHosts=localhost|127.0.0.1\n'
        printf '%s\n' "$end"
    } >> "$tmp"
    mv "$tmp" "$target"
    dh_info "已写入 Gradle 代理配置: $target"
}

# ---------------------------------------------------------------------------
# 杂项
# ---------------------------------------------------------------------------
dh_abs_path() { ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" ); }

# 收集本机已安装的 JDK 目录，供 Gradle toolchain 使用。
# 背景：DH 的 foojay 解析器在 loongarch64 上不可用，构建 1.20.1（需要 JDK 17）
# 时必须显式告知 Gradle 本机 JDK 位置，否则报 ToolchainProvisioningException。
dh_detect_jdk_paths() {
    local dirs=() d
    local -a candidates=(
        /usr/lib/java-*
        /usr/lib/jvm/*
        /opt/java/*
        "${HOME:-/root}"/.sdkman/candidates/java/*
        "${HOME:-/root}"/.jdks/*
    )
    shopt -s nullglob
    for d in "${candidates[@]}"; do
        if [ -x "$d/bin/javac" ] && [ -x "$d/bin/java" ]; then
            dirs+=("$d")
        fi
    done
    shopt -u nullglob
    ( IFS=,; printf '%s' "${dirs[*]}" )
}

dh_mkdir() { mkdir -p "$1"; }

# 校验 jar 中是否包含指定 entry
# 注意：不要用 `... | grep -q`，pipefail 下上游可能因 SIGPIPE 返回非零导致误判。
dh_jar_has_entry() {
    local jar="$1" entry="$2" listing
    listing="$(unzip -l "$jar" 2>/dev/null)" || return 1
    printf '%s\n' "$listing" \
        | awk -v want="$entry" 'NR > 3 && $4 == want { found = 1 } END { exit(found ? 0 : 1) }'
}

# 输出说明：调用方脚本自己负责 print 最终路径
