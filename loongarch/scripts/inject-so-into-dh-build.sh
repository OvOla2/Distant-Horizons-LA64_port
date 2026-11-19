#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# inject-so-into-dh-build.sh
#
# 把已注入 LoongArch so 的 sqlite-jdbc jar 注册为本地 Maven artifact，
# 并准备好让 DH 构建用它替换官方依赖的 Gradle init script。
#
# 本脚本不修改 DH 仓库里的任何构建文件，只写入：
#   loongarch/.build/m2/...                 本地 Maven 仓库
#   loongarch/.build/gradle-inject.env      供 build-dh-loongarch.sh / CI 使用
#   relocate_natives/cache/dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so
#                                           预置 relocator 缓存（构建产物，不要提交）
#
# 重定位模式（默认 LIEF）：
#   - 默认：创建 relocate_natives/.venv 并安装 LIEF，让 DH 用上游的
#     NativeTransformer + fix_modified_binary.py 完成重定位。
#     版本选择：loongarch64 -> lief 0.17.6（龙芯镜像），
#               x86_64 等    -> lief 0.16.2（DH 固定版本，PyPI wheel）
#   - 回退：--no-lief 使用“编译期改号 + 预置 relocator 缓存”，
#     完全不依赖 Python/LIEF（本地无网络时可用）。
#
# 龙芯 PyPI 镜像（提供 loongarch64 lief wheel）：
#   https://mirrors.loong64.com/pypi/simple  （需要直连，脚本自动绕过代理）
#
# 代理（仅本地需要）：
#   export PROXY_URL="http://127.0.0.1:20171"   # 默认值
#
# 用法：
#   ./loongarch/scripts/inject-so-into-dh-build.sh
#   ./loongarch/scripts/inject-so-into-dh-build.sh --jar /path/to/sqlite-jdbc-3.53.2.1-loongarch.jar
#   ./loongarch/scripts/inject-so-into-dh-build.sh --verify
#   ./loongarch/scripts/inject-so-into-dh-build.sh --no-lief          # 回退：不用 LIEF
#   ./loongarch/scripts/inject-so-into-dh-build.sh --lief-version 0.17.6
#   LIEF_INDEX_URL=https://mirrors.loong64.com/pypi/simple \
#     ./loongarch/scripts/inject-so-into-dh-build.sh
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DH_ROOT="$(dh_detect_repo_root)"
LOONGARCH_DIR="$DH_ROOT/loongarch"
BUILD_DIR="${DH_LOONGARCH_BUILD_DIR:-$LOONGARCH_DIR/.build}"
INIT_SCRIPT="$LOONGARCH_DIR/scripts/dh-loongarch-init.gradle"
M2_DIR="$BUILD_DIR/m2"
ENV_FILE="$BUILD_DIR/gradle-inject.env"
VERIFY=0
JAR_PATH=""
SEED_NATIVE=1
SO_PATH=""
USE_LIEF=1
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [ "$HOST_ARCH" = "loongarch64" ]; then
    # 龙芯镜像提供 loongarch64 的 lief wheel（0.17.4+），但版本只能用 0.17.x
    LIEF_VERSION="${LIEF_VERSION:-0.17.6}"
    LIEF_INDEX_URL="${LIEF_INDEX_URL:-https://mirrors.loong64.com/pypi/simple}"
else
    # x86_64/aarch64 等平台直接用 DH 固定的 0.16.2（PyPI 有 wheel），
    # CI（x86_64）就走这条路径
    LIEF_VERSION="${LIEF_VERSION:-0.16.2}"
    LIEF_INDEX_URL="${LIEF_INDEX_URL:-}"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --jar)     JAR_PATH="${2:?--jar 需要参数}"; shift 2 ;;
        --m2)      M2_DIR="${2:?--m2 需要参数}"; shift 2 ;;
        --verify)  VERIFY=1; shift ;;
        --so)      SO_PATH="${2:?--so 需要参数}"; shift 2 ;;
        --no-native-seed) SEED_NATIVE=0; shift ;;
        --use-lief)       USE_LIEF=1; SEED_NATIVE=0; shift ;;
        --no-lief)        USE_LIEF=0; SEED_NATIVE=1; shift ;;
        --lief-version)   LIEF_VERSION="${2:?--lief-version 需要参数}"; shift 2 ;;
        --lief-index-url) LIEF_INDEX_URL="${2:?--lief-index-url 需要参数}"; shift 2 ;;
        -h|--help) sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         dh_die "未知参数: $1" ;;
    esac
done

if [ "$USE_LIEF" = "1" ]; then
    SEED_NATIVE=0
fi

dh_require_cmds unzip jar

# ---------------------------------------------------------------------------
# 1. 定位带 loongarch so 的 sqlite-jdbc jar
# ---------------------------------------------------------------------------
if [ -z "$JAR_PATH" ]; then
    if [ -f "$BUILD_DIR/sqlite-jdbc-loongarch.env" ]; then
        # shellcheck disable=SC1090
        source "$BUILD_DIR/sqlite-jdbc-loongarch.env"
        JAR_PATH="${SQLITE_JDBC_LOONGARCH_JAR:-}"
    fi
fi
if [ -z "$JAR_PATH" ]; then
    # shellcheck disable=SC2012
    JAR_PATH="$(ls -t "$BUILD_DIR"/sqlite-jdbc-*-loongarch.jar 2>/dev/null | head -n 1 || true)"
fi
[ -n "$JAR_PATH" ] && [ -f "$JAR_PATH" ] \
    || dh_die "找不到已注入 so 的 sqlite-jdbc jar，请先运行 build-sqlitejdbc-loongarch.sh"

JAR_PATH="$(dh_abs_path "$JAR_PATH")"
dh_jar_has_entry "$JAR_PATH" "org/sqlite/native/Linux/loongarch64/libsqlitejdbc.so" \
    || dh_die "jar 中没有 Linux/loongarch64 原生库，请检查 build-sqlitejdbc-loongarch.sh 产物: $JAR_PATH"

# 版本号：文件名形如 sqlite-jdbc-3.53.2.1-loongarch.jar
JAR_BASENAME="$(basename "$JAR_PATH")"
BASE_VERSION="$(printf '%s' "$JAR_BASENAME" | sed -E 's/^sqlite-jdbc-(.*)-loongarch\.jar$/\1/')"
[ "$BASE_VERSION" != "$JAR_BASENAME" ] \
    || dh_die "无法从文件名解析 sqlite-jdbc 版本: $JAR_BASENAME"
PATCHED_VERSION="${BASE_VERSION}-loongarch"

dh_info "sqlite-jdbc jar : $JAR_PATH"
dh_info "本地版本号      : $PATCHED_VERSION"

# ---------------------------------------------------------------------------
# 2. 写入本地 Maven 仓库
# ---------------------------------------------------------------------------
DEST_DIR="$M2_DIR/org/xerial/sqlite-jdbc/$PATCHED_VERSION"
mkdir -p "$DEST_DIR"
cp -f "$JAR_PATH" "$DEST_DIR/sqlite-jdbc-$PATCHED_VERSION.jar"

# 极简 POM：保留 upstream 的 slf4j-api（optional），避免影响 DH 的编译类路径
cat > "$DEST_DIR/sqlite-jdbc-$PATCHED_VERSION.pom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/maven-v4_0_0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>org.xerial</groupId>
  <artifactId>sqlite-jdbc</artifactId>
  <version>$PATCHED_VERSION</version>
  <name>SQLite JDBC (LoongArch64 local build)</name>
  <description>sqlite-jdbc $BASE_VERSION rebuilt with org/sqlite/native/Linux/loongarch64/libsqlitejdbc.so</description>
  <licenses>
    <license>
      <name>The Apache Software License, Version 2.0</name>
      <url>https://www.apache.org/licenses/LICENSE-2.0.txt</url>
    </license>
  </licenses>
  <dependencies>
    <dependency>
      <groupId>org.slf4j</groupId>
      <artifactId>slf4j-api</artifactId>
      <version>1.7.36</version>
      <optional>true</optional>
    </dependency>
  </dependencies>
</project>
EOF

dh_ok "已写入本地 Maven 仓库: $DEST_DIR"

# ---------------------------------------------------------------------------
# 2.5 可选：准备 LIEF venv（走上游重定位流程）
#
# DH 的 NativeRelocator.prepare() 会先检查 relocate_natives/.venv：
# 只要 .venv/bin/python 能 import lief，就跳过 pip install。
# 因此这里直接建好 venv，DH 构建就会用它自己的 fix_modified_binary.py。
# ---------------------------------------------------------------------------
prepare_lief_venv() {
    local venv="$DH_ROOT/relocate_natives/.venv"
    command -v python3 >/dev/null 2>&1 || dh_die "需要 python3 来创建 LIEF venv"
    if [ -x "$venv/bin/python" ] && "$venv/bin/python" -c 'import lief' >/dev/null 2>&1; then
        dh_info "复用已有 LIEF venv: $venv"
        return 0
    fi
    dh_info "创建 LIEF venv（lief==$LIEF_VERSION，index: ${LIEF_INDEX_URL:-PyPI}）"
    python3 -m venv "$venv" \
        || dh_die "python3 -m venv 失败（缺少 python3-venv？）；可用 --no-lief 回退"
    # 注意：--index-url 是 install 子命令的选项，必须放在 install 之后
    local pip_cmd=("$venv/bin/pip" -q --disable-pip-version-check install)
    local index_args=()
    if [ -n "$LIEF_INDEX_URL" ]; then
        index_args=(--index-url "$LIEF_INDEX_URL")
    fi
    # 龙芯镜像通常需要直连（走代理会连不上），pip 时单独去掉代理变量
    case "$LIEF_INDEX_URL" in
    *mirrors.loong64.com*)
        env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
            "${pip_cmd[@]}" "${index_args[@]}" "lief==$LIEF_VERSION" "requests>=2.32" \
            || dh_die "安装 lief==$LIEF_VERSION 失败（镜像上可能没有该版本）；可用 --no-lief 回退"
        ;;
    *)
        "${pip_cmd[@]}" "${index_args[@]}" "lief==$LIEF_VERSION" "requests>=2.32" \
            || dh_die "安装 lief==$LIEF_VERSION 失败（镜像上可能没有该版本）；可用 --no-lief 回退"
        ;;
    esac
    "$venv/bin/python" -c 'import lief' \
        || dh_die "LIEF venv 创建后仍无法 import lief；可用 --no-lief 回退"
    dh_ok "LIEF venv 就绪: $venv ($("$venv/bin/python" -c 'import lief;print(lief.__version__)'))"
}

if [ "$USE_LIEF" = "1" ]; then
    prepare_lief_venv
    # 删掉之前预置的缓存，强制 DH 走 processBinary() -> LIEF
    rm -f "$DH_ROOT/relocate_natives/cache/dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so"
    dh_info "已清空预置缓存，DH 构建将使用 LIEF 重定位"
fi

# ---------------------------------------------------------------------------
# 3. 预置 DH 的 native 重定位缓存（绕过 LIEF）
#
# DH 的 NativeTransformer 会先查 relocate_natives/cache/<mapped path>：
# 命中则直接复用，不再调用 prepare()/LIEF。LoongArch 上没有 lief==0.16.2
# 的可用分发包（PyPI 只有 x86_64/aarch64 的 wheel，源码构建也会失败），
# 因此这里按 NativeRelocator.replaceInNullTerminatedStrings 的同一算法
# 预先完成字符串替换并写入缓存。
#
# 替换规则与 buildSrc/src/main/groovy/dh-loader.gradle 中 sqlite 的配置一致：
#   org/sqlite -> dh_sqlite      （路径/字符串）
#   org_sqlite -> dh_1sqlite     （JNI 符号）
# ---------------------------------------------------------------------------
seed_relocated_native() {
    local so="$1"
    [ -f "$so" ] || dh_die "找不到 loongarch64 so: $so"
    local cache_dir="$DH_ROOT/relocate_natives/cache/dh_sqlite/native/Linux/loongarch64"
    local cache_file="$cache_dir/libsqlitejdbc.so"
    mkdir -p "$cache_dir"

    # 该 so 由 build-sqlitejdbc-loongarch.sh 在编译期完成改号
    # （JNI 符号 + FindClass 字符串），链接器已生成匹配的 .gnu.hash，
    # 直接复制即可；不要在这里做运行期字符串替换。
    cp -f "$so" "$cache_file"

    if command -v nm >/dev/null 2>&1; then
        local count
        count="$(nm -D --defined-only "$cache_file" 2>/dev/null | grep -c 'Java_dh_1sqlite' || true)"
        [ "${count:-0}" -gt 0 ] \
            || dh_die "预置缓存的 so 中没有 Java_dh_1sqlite_* 符号，替换失败: $cache_file"
        dh_ok "已预置 relocator 缓存（JNI 符号 $count 个）: $cache_file"
    else
        dh_ok "已预置 relocator 缓存: $cache_file"
    fi

    dh_warn "该文件是构建产物，请勿提交到 loongarch-patch 分支（CI 会重新生成）"
}

if [ "$SEED_NATIVE" = "1" ]; then
    if [ -z "$SO_PATH" ] && [ -f "$BUILD_DIR/sqlite-jdbc-loongarch.env" ]; then
        # shellcheck disable=SC1090
        source "$BUILD_DIR/sqlite-jdbc-loongarch.env"
        # 必须使用编译期已改名 JNI 符号的版本：
        # 在成品 so 上直接替换字符串会破坏 ELF .gnu.hash，dlsym 会找不到新符号。
        SO_PATH="${SQLITE_JDBC_LOONGARCH_RELOCATED_SO:-}"
    fi
    if [ -n "$SO_PATH" ] && [ -f "$SO_PATH" ]; then
        seed_relocated_native "$SO_PATH"
    else
        dh_die "找不到 DH 重定位版本的 so（SQLITE_JDBC_LOONGARCH_RELOCATED_SO），请先运行 build-sqlitejdbc-loongarch.sh 重新构建；如确认构建机有可用 LIEF，可加 --no-native-seed"
    fi
fi

# ---------------------------------------------------------------------------
# 4. 生成环境文件
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
{
    printf 'DH_LOONGARCH_M2=%s\n' "$M2_DIR"
    printf 'DH_LOONGARCH_SQLITE_VERSION=%s\n' "$PATCHED_VERSION"
    printf 'DH_LOONGARCH_SQLITE_JAR=%s\n' "$DEST_DIR/sqlite-jdbc-$PATCHED_VERSION.jar"
    printf 'DH_LOONGARCH_INIT_SCRIPT=%s\n' "$INIT_SCRIPT"
} > "$ENV_FILE"

# ---------------------------------------------------------------------------
# 5. 可选：验证依赖确实被替换
# ---------------------------------------------------------------------------
if [ "$VERIFY" = "1" ]; then
    dh_require_cmds git
    dh_configure_gradle_proxy
    dh_ensure_java_home
    dh_info "验证依赖替换（:core:dependencies）..."
    ( cd "$DH_ROOT" && ./gradlew --console=plain \
        --init-script "$INIT_SCRIPT" \
        -Ddh.loongarch.m2="$M2_DIR" \
        -Ddh.loongarch.sqlite.version="$PATCHED_VERSION" \
        :core:dependencies --configuration runtimeClasspath ) 2>&1 \
        | grep -E "sqlite-jdbc" | head -n 5 || true
fi

printf '\n'
dh_ok "注入配置就绪"
printf '\n'
printf '  init script : %s\n' "$INIT_SCRIPT"
printf '  m2 repo     : %s\n' "$M2_DIR"
printf '  version     : %s\n' "$PATCHED_VERSION"
printf '  env file    : %s\n' "$ENV_FILE"
printf '\n'
printf '手动构建时可这样调用 Gradle：\n'
printf '  ./gradlew --init-script %s \\\n' "$INIT_SCRIPT"
printf '    -Ddh.loongarch.m2=%s \\\n' "$M2_DIR"
printf '    -Ddh.loongarch.sqlite.version=%s \\\n' "$PATCHED_VERSION"
printf '    assemble mergeJars\n'
