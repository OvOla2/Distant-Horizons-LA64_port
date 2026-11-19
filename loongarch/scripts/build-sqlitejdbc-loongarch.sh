#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-sqlitejdbc-loongarch.sh
#
# 从源码构建 sqlite-jdbc 的 LoongArch64 原生库（libsqlitejdbc.so），并把
# libsqlitejdbc.so（以及在需要时重新编译的 OSInfo.class）注入 sqlite-jdbc jar。
#
# 版本来自 DH 的 gradle.properties（sqlite_jdbc_version），也可用环境变量覆盖：
#   SQLITE_JDBC_VERSION=3.53.2.1 ./loongarch/scripts/build-sqlitejdbc-loongarch.sh
#
# 代理（仅本地需要，CI 中不要设置）：
#   export PROXY_URL="http://127.0.0.1:20171"   # 默认值
#   export PROXY_URL=""                          # 关闭
#   # 或者沿用已有的 export http_proxy/https_proxy，脚本不会覆盖已设置的 PROXY_URL
#
# 交叉编译（CI 用）：
#   CROSS_PREFIX=loongarch64-linux-gnu- ./loongarch/scripts/build-sqlitejdbc-loongarch.sh
#
# 产物：
#   <repo>/loongarch/.build/sqlite-jdbc-<version>-loongarch.jar
#   <repo>/loongarch/.build/sqlite-jdbc-loongarch.env
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DH_ROOT="$(dh_detect_repo_root)"
LOONGARCH_DIR="$DH_ROOT/loongarch"
BUILD_DIR="${DH_LOONGARCH_BUILD_DIR:-$LOONGARCH_DIR/.build}"
PATCH_FILE="${SQLITE_JDBC_PATCH:-$LOONGARCH_DIR/patches/sqlitejdbc-loongarch64.patch}"
SQLITE_JDBC_REPO="${SQLITE_JDBC_REPO:-https://github.com/xerial/sqlite-jdbc.git}"
SQLITE_JDBC_MAVEN="${SQLITE_JDBC_MAVEN:-https://repo1.maven.org/maven2}"
OS_NAME="Linux"
OS_ARCH="loongarch64"
# GCC 14+ 默认把隐式函数声明当错误（sqlite3.c 的扩展注册函数没有前置声明），
# 这里降级为警告；对老版本 GCC 只是多一个无害的 -Wno-*。
SQLITE_CFLAGS="${SQLITE_CFLAGS:--Wno-implicit-function-declaration -Wno-implicit-int}"

CROSS_PREFIX="${CROSS_PREFIX:-}"
VERSION_OVERRIDE="${SQLITE_JDBC_VERSION:-}"
SRC_OVERRIDE="${SQLITE_JDBC_SRC:-}"
APPLY_PATCH=1
CLEAN=0

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

可选参数：
  --version <ver>        覆盖 sqlite-jdbc 版本（默认读取 gradle.properties）
  --src <dir>            复用已存在的源码目录
  --cross-prefix <pfx>   交叉编译工具链前缀，如 loongarch64-linux-gnu-
  --no-patch             不应用 loongarch 补丁（仅注入 so）
  --clean                构建前删除源码目录，强制重新 clone
  -h, --help             显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)        VERSION_OVERRIDE="${2:?--version 需要参数}"; shift 2 ;;
        --src)            SRC_OVERRIDE="${2:?--src 需要参数}"; shift 2 ;;
        --cross-prefix)   CROSS_PREFIX="${2:?--cross-prefix 需要参数}"; shift 2 ;;
        --no-patch)       APPLY_PATCH=0; shift ;;
        --clean)          CLEAN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                dh_die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

if [ -n "$VERSION_OVERRIDE" ]; then
    SQLITE_JDBC_VERSION="$VERSION_OVERRIDE"
else
    SQLITE_JDBC_VERSION="$(dh_sqlite_jdbc_version "$DH_ROOT")" \
        || dh_die "无法从 $DH_ROOT/gradle.properties 读取 sqlite_jdbc_version"
fi
dh_info "sqlite-jdbc 版本: $SQLITE_JDBC_VERSION（来源: DH 构建文件 / 环境变量）"

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
dh_require_cmds git make curl unzip
dh_ensure_java_home
[ -x "$JAVA_HOME/bin/javac" ] || dh_die "JAVA_HOME 下没有 javac: $JAVA_HOME"
[ -x "$JAVA_HOME/bin/jar" ]   || dh_die "JAVA_HOME 下没有 jar: $JAVA_HOME"
if [ -n "$CROSS_PREFIX" ]; then
    dh_export_proxy_env
    command -v "${CROSS_PREFIX}gcc" >/dev/null 2>&1 \
        || dh_die "找不到交叉编译器 ${CROSS_PREFIX}gcc（请先安装 LoongArch64 工具链并加入 PATH）"
    command -v "${CROSS_PREFIX}strip" >/dev/null 2>&1 \
        || dh_warn "找不到 ${CROSS_PREFIX}strip，make native 可能在 strip 步骤失败"
    dh_info "交叉编译: ${CROSS_PREFIX}gcc ($("${CROSS_PREFIX}gcc" -dumpmachine 2>/dev/null || echo unknown))"
else
    command -v gcc >/dev/null 2>&1 || dh_die "未找到 gcc，请先安装本机 LoongArch64 编译工具链"
    dh_info "本机编译: gcc ($(gcc -dumpmachine))"
fi
dh_info "JAVA_HOME: $JAVA_HOME"

mkdir -p "$BUILD_DIR" "$BUILD_DIR/downloads"

# ---------------------------------------------------------------------------
# 1. 源码
# ---------------------------------------------------------------------------
SRC_DIR="${SRC_OVERRIDE:-$BUILD_DIR/sqlite-jdbc-src/sqlite-jdbc-$SQLITE_JDBC_VERSION}"
if [ "$CLEAN" = "1" ]; then
    dh_info "清理源码目录: $SRC_DIR"
    rm -rf "$SRC_DIR"
fi

clone_source() {
    dh_info "clone sqlite-jdbc $SQLITE_JDBC_VERSION -> $SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    rm -rf "$SRC_DIR"
    local attempt
    for attempt in 1 2 3; do
        if git clone --filter=blob:none --depth 1 --branch "$SQLITE_JDBC_VERSION" \
                "$SQLITE_JDBC_REPO" "$SRC_DIR" 2>/dev/null; then
            return 0
        fi
        dh_warn "git clone 失败（第 $attempt 次），重试..."
        rm -rf "$SRC_DIR"
        sleep 3
    done
    # 代理/网络不稳定时退回源码压缩包（内容与 tag 一致）
    dh_warn "git clone 重试均失败，改用 GitHub 源码压缩包"
    local tarball="$BUILD_DIR/downloads/sqlite-jdbc-$SQLITE_JDBC_VERSION.tar.gz"
    local url="https://codeload.github.com/xerial/sqlite-jdbc/tar.gz/refs/tags/$SQLITE_JDBC_VERSION"
    for attempt in 1 2 3; do
        if curl -fsSL --http1.1 -C - -o "$tarball" "$url" && tar -tzf "$tarball" >/dev/null 2>&1; then
            break
        fi
        dh_warn "下载源码包失败（第 $attempt 次），重试..."
        sleep 3
    done
    [ -s "$tarball" ] || dh_die "无法下载 sqlite-jdbc 源码包: $url"
    local tmp="$BUILD_DIR/downloads/extract-$$"
    rm -rf "$tmp"; mkdir -p "$tmp"
    tar -xzf "$tarball" -C "$tmp"
    mv "$tmp/sqlite-jdbc-$SQLITE_JDBC_VERSION" "$SRC_DIR"
    rm -rf "$tmp"
}

if [ ! -f "$SRC_DIR/Makefile" ]; then
    clone_source
fi
if [ ! -f "$SRC_DIR/Makefile" ]; then
    dh_die "源码目录不可用: $SRC_DIR"
fi

# ---------------------------------------------------------------------------
# 2. 补丁（若存在则应用；已应用则跳过）
# ---------------------------------------------------------------------------
PATCHED="no"
if [ "$APPLY_PATCH" = "1" ] && [ -f "$PATCH_FILE" ]; then
    if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        if git -C "$SRC_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
            dh_info "补丁已应用，跳过"
            PATCHED="yes"
        elif git -C "$SRC_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
            dh_info "应用补丁: $PATCH_FILE"
            git -C "$SRC_DIR" apply "$PATCH_FILE"
            PATCHED="yes"
        else
            dh_die "补丁无法应用（源码版本与补丁不匹配？）: $PATCH_FILE"
        fi
    else
        if patch -d "$SRC_DIR" -p1 --dry-run -R -s -f <"$PATCH_FILE" >/dev/null 2>&1; then
            dh_info "补丁已应用，跳过"
            PATCHED="yes"
        elif patch -d "$SRC_DIR" -p1 --dry-run -s -f <"$PATCH_FILE" >/dev/null 2>&1; then
            dh_info "应用补丁（patch -p1）: $PATCH_FILE"
            patch -d "$SRC_DIR" -p1 -s <"$PATCH_FILE"
            PATCHED="yes"
        else
            dh_die "补丁无法应用（源码版本与补丁不匹配？）: $PATCH_FILE"
        fi
    fi
else
    dh_info "未应用 OSInfo 补丁（--no-patch 或补丁文件不存在）"
fi

# ---------------------------------------------------------------------------
# 3. make native（原始符号，供独立使用 sqlite-jdbc 时加载）
# ---------------------------------------------------------------------------
dh_export_proxy_env

# 保证从原始源码开始：上一次运行可能把 NativeDB.c 改成了重定位版本
NATIVE_DB_C_PRE="$SRC_DIR/src/main/java/org/sqlite/core/NativeDB.c"
if grep -q "Java_dh_1sqlite" "$NATIVE_DB_C_PRE" 2>/dev/null; then
    if git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        dh_warn "源码中残留上次的符号改名，已从 git 还原"
        git -C "$SRC_DIR" checkout -- src/main/java/org/sqlite/core/NativeDB.c
    else
        dh_die "源码已被改名但无法还原（非 git 仓库），请加 --clean 重新获取源码"
    fi
fi
# 强制从原始 Java 类重新生成 JNI 头
rm -f "$SRC_DIR/target/common-lib/NativeDB.h"

dh_info "执行 make native（OS_NAME=$OS_NAME OS_ARCH=$OS_ARCH${CROSS_PREFIX:+ CROSS_PREFIX=$CROSS_PREFIX}）"
MAKE_ARGS=(native "OS_NAME=$OS_NAME" "OS_ARCH=$OS_ARCH" "SQLITE_FLAGS=$SQLITE_CFLAGS")
if [ -n "$CROSS_PREFIX" ]; then
    MAKE_ARGS+=("CROSS_PREFIX=$CROSS_PREFIX")
fi
make -C "$SRC_DIR" "${MAKE_ARGS[@]}"

SO_FILE="$SRC_DIR/src/main/resources/org/sqlite/native/$OS_NAME/$OS_ARCH/libsqlitejdbc.so"
[ -f "$SO_FILE" ] || dh_die "make native 未产出 $SO_FILE"

NATIVE_DIR="$BUILD_DIR/native"
mkdir -p "$NATIVE_DIR"
cp -f "$SO_FILE" "$NATIVE_DIR/libsqlitejdbc.so"

# ---------------------------------------------------------------------------
# 4. 构建 DH 重定位版本的 so（JNI 符号在编译期改名）
#
# DH 的 shadow 会把 org.sqlite 重定位成 dh_sqlite，并把 native 里的
# org/sqlite -> dh_sqlite、org_sqlite -> dh_1sqlite。
# 直接在成品 so 上做字符串替换会破坏 ELF 的 .gnu.hash，导致
# dlsym 找不到改名后的符号（UnsatisfiedLinkError）；LIEF 的
# fix_modified_binary.py 正是用来重建这些表的，但 LoongArch 上没有
# lief==0.16.2 可用分发包。
# 因此在编译期完成改名：修改 NativeDB.c / NativeDB.h 后重新链接，
# 由链接器生成正确的 .gnu.hash。
# ---------------------------------------------------------------------------
NATIVE_DB_C="$SRC_DIR/src/main/java/org/sqlite/core/NativeDB.c"
NATIVE_DB_H="$SRC_DIR/target/common-lib/NativeDB.h"
RELOCATED_SO="$NATIVE_DIR/libsqlitejdbc-dh-relocated.so"

if [ -f "$NATIVE_DB_H" ]; then
    dh_info "构建 DH 重定位版本 so（编译期重命名 JNI 符号）"
    cp -f "$NATIVE_DB_C" "$NATIVE_DIR/NativeDB.c.orig"
    cp -f "$NATIVE_DB_H" "$NATIVE_DIR/NativeDB.h.orig"

    sed -i 's/Java_org_sqlite_/Java_dh_1sqlite_/g' "$NATIVE_DB_C" "$NATIVE_DB_H"
    # C 代码里用字符串做 FindClass，需要同步改名
    sed -i 's#org/sqlite#dh_sqlite#g' "$NATIVE_DB_C"

    make -C "$SRC_DIR" "${MAKE_ARGS[@]}"
    cp -f "$SO_FILE" "$RELOCATED_SO"

    # 还原源码，保持可重复构建
    cp -f "$NATIVE_DIR/NativeDB.c.orig" "$NATIVE_DB_C"
    cp -f "$NATIVE_DIR/NativeDB.h.orig" "$NATIVE_DB_H"
    touch "$NATIVE_DB_C" "$NATIVE_DB_H"

    if command -v nm >/dev/null 2>&1; then
        NEW_COUNT="$(nm -D --defined-only "$RELOCATED_SO" 2>/dev/null | grep -c 'Java_dh_1sqlite' || true)"
        OLD_COUNT="$(nm -D --defined-only "$RELOCATED_SO" 2>/dev/null | grep -c 'Java_org_sqlite' || true)"
        [ "${NEW_COUNT:-0}" -gt 0 ] || dh_die "重定位版本 so 没有 Java_dh_1sqlite_* 符号"
        [ "${OLD_COUNT:-0}" -eq 0 ] || dh_die "重定位版本 so 仍残留 Java_org_sqlite_* 符号"
        dh_ok "重定位 so 符号校验通过（Java_dh_1sqlite: $NEW_COUNT, Java_org_sqlite: 0）"
    fi
else
    dh_warn "未找到 NativeDB.h，跳过 DH 重定位版本 so（将回退到运行时字符串替换，可能因 ELF hash 未更新而失败）"
    RELOCATED_SO=""
fi

# ---------------------------------------------------------------------------
# 5. 校验 so
# ---------------------------------------------------------------------------
FILE_OUT="$(file -b "$NATIVE_DIR/libsqlitejdbc.so" 2>/dev/null || true)"
case "$FILE_OUT" in
    *[Ll][Oo][Oo][Nn][Gg][Aa][Rr][Cc][Hh]*) ;;
    *) dh_die "产物不是 LoongArch 目标文件: $FILE_OUT" ;;
esac
dh_ok "so 架构校验通过: $FILE_OUT"

READELF="${CROSS_PREFIX}readelf"
command -v "$READELF" >/dev/null 2>&1 || READELF="readelf"
if command -v "$READELF" >/dev/null 2>&1; then
    MACHINE="$("$READELF" -h "$NATIVE_DIR/libsqlitejdbc.so" 2>/dev/null | awk -F: '/Machine/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | head -n 1 || true)"
    [ -n "$MACHINE" ] && dh_info "readelf Machine: $MACHINE"
fi

# ---------------------------------------------------------------------------
# 6. 生成带 so（和补丁后的 OSInfo.class）的 sqlite-jdbc jar
# ---------------------------------------------------------------------------
ORIG_JAR="$BUILD_DIR/downloads/sqlite-jdbc-$SQLITE_JDBC_VERSION.jar"
if [ ! -s "$ORIG_JAR" ] || ! unzip -t "$ORIG_JAR" >/dev/null 2>&1; then
    dh_info "下载官方 sqlite-jdbc-$SQLITE_JDBC_VERSION.jar"
    URL="$SQLITE_JDBC_MAVEN/org/xerial/sqlite-jdbc/$SQLITE_JDBC_VERSION/sqlite-jdbc-$SQLITE_JDBC_VERSION.jar"
    curl -fsSL -C - -o "$ORIG_JAR" "$URL" || dh_die "下载失败: $URL"
    unzip -t "$ORIG_JAR" >/dev/null 2>&1 || dh_die "下载的 jar 不完整: $ORIG_JAR"
fi

STAGE="$BUILD_DIR/jar-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/org/sqlite/native/$OS_NAME/$OS_ARCH"
# 注意：第 4 步会重新生成并覆盖源码树里的 so，这里必须用第 3 步保存的原始符号版本
CANONICAL_SO="$NATIVE_DIR/libsqlitejdbc.so"
cp "$CANONICAL_SO" "$STAGE/org/sqlite/native/$OS_NAME/$OS_ARCH/libsqlitejdbc.so"

if command -v nm >/dev/null 2>&1; then
    CANON_NEW="$(nm -D --defined-only "$CANONICAL_SO" 2>/dev/null | grep -c 'Java_dh_1sqlite' || true)"
    CANON_OLD="$(nm -D --defined-only "$CANONICAL_SO" 2>/dev/null | grep -c 'Java_org_sqlite' || true)"
    [ "${CANON_OLD:-0}" -gt 0 ] || dh_die "jar 使用的 so 缺少 Java_org_sqlite_* 符号"
    [ "${CANON_NEW:-0}" -eq 0 ] || dh_die "jar 误用了重定位版本的 so（含 Java_dh_1sqlite_*）"
fi

if [ "$PATCHED" = "yes" ]; then
    dh_info "重新编译补丁后的 OSInfo.class（--release 8）"
    mkdir -p "$STAGE/org/sqlite/util"
    if ! "$JAVA_HOME/bin/javac" -encoding UTF-8 --release 8 -cp "$ORIG_JAR" \
            -d "$STAGE" "$SRC_DIR/src/main/java/org/sqlite/util/OSInfo.java" 2>/dev/null; then
        dh_warn "--release 8 编译失败，尝试 -source/-target 8"
        "$JAVA_HOME/bin/javac" -encoding UTF-8 -source 8 -target 8 -cp "$ORIG_JAR" \
            -d "$STAGE" "$SRC_DIR/src/main/java/org/sqlite/util/OSInfo.java"
    fi
    [ -f "$STAGE/org/sqlite/util/OSInfo.class" ] || dh_die "OSInfo.class 编译产物缺失"
fi

OUT_JAR="$BUILD_DIR/sqlite-jdbc-$SQLITE_JDBC_VERSION-loongarch.jar"
cp "$ORIG_JAR" "$OUT_JAR"
( cd "$STAGE" && "$JAVA_HOME/bin/jar" --update --file "$OUT_JAR" org )

dh_jar_has_entry "$OUT_JAR" "org/sqlite/native/$OS_NAME/$OS_ARCH/libsqlitejdbc.so" \
    || dh_die "jar 中缺少 loongarch64 so: $OUT_JAR"
if [ "$PATCHED" = "yes" ]; then
    dh_jar_has_entry "$OUT_JAR" "org/sqlite/util/OSInfo.class" \
        || dh_die "jar 中缺少 OSInfo.class: $OUT_JAR"
fi

ENV_FILE="$BUILD_DIR/sqlite-jdbc-loongarch.env"
{
    printf 'SQLITE_JDBC_VERSION=%s\n' "$SQLITE_JDBC_VERSION"
    printf 'SQLITE_JDBC_LOONGARCH_JAR=%s\n' "$OUT_JAR"
    printf 'SQLITE_JDBC_LOONGARCH_SO=%s\n' "$NATIVE_DIR/libsqlitejdbc.so"
    printf 'SQLITE_JDBC_LOONGARCH_RELOCATED_SO=%s\n' "$RELOCATED_SO"
    printf 'SQLITE_JDBC_PATCHED=%s\n' "$PATCHED"
} > "$ENV_FILE"

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
dh_ok "构建完成"
printf '\n'
printf '  version : %s\n' "$SQLITE_JDBC_VERSION"
printf '  so      : %s\n' "$NATIVE_DIR/libsqlitejdbc.so"
printf '  so (DH) : %s\n' "${RELOCATED_SO:-<未生成>}"
printf '  jar     : %s\n' "$OUT_JAR"
printf '  env     : %s\n' "$ENV_FILE"
printf '  patched : %s\n' "$PATCHED"
