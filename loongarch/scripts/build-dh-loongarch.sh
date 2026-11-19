#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-dh-loongarch.sh —— 一键入口（本地全流程）
#
# 流程：
#   1. build-sqlitejdbc-loongarch.sh   源码 -> loongarch64 so -> 注入 jar
#   2. inject-so-into-dh-build.sh      注册本地 Maven artifact + Gradle init script
#   3. ./gradlew assemble mergeJars    用替换后的 sqlite-jdbc 构建 DH
#   4. 收集 Fabric / Forge / NeoForge 可分发 jar 到 loongarch/dist/
#
# 版本号全部从 DH 的 gradle.properties 动态读取（mod_version / sqlite_jdbc_version /
# mcVer），不硬编码。
#
# 代理（仅本地需要；CI 中请不要设置）：
#   export PROXY_URL="http://127.0.0.1:20171"   # 默认值，会用于 git/curl/Gradle
#   export PROXY_URL=""                          # 关闭
#   export DH_SKIP_GRADLE_PROXY=1                # 不改写 ~/.gradle/gradle.properties
#
# 用法：
#   ./loongarch/scripts/build-dh-loongarch.sh
#   ./loongarch/scripts/build-dh-loongarch.sh --mc 1.20.1
#   ./loongarch/scripts/build-dh-loongarch.sh --all-loaders   # 26.3.0 + 1.20.1
#   MC_VERSIONS="26.3.0 1.20.1" ./loongarch/scripts/build-dh-loongarch.sh
#   CROSS_PREFIX=loongarch64-linux-gnu- ./loongarch/scripts/build-dh-loongarch.sh  # CI
#   ./loongarch/scripts/build-dh-loongarch.sh --use-lief   # 用 LIEF（需可用的 lief 版本）
#
# 说明：DH 每个 Minecraft 版本只声明两个加载器（1.20.1 = fabric+forge，
# 26.x/1.21.x = fabric+neoforge），因此“三个加载器”需要两个 MC 目标，
# --all-loaders 会分别构建并把 MC 版本写进产物文件名。
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DH_ROOT="$(dh_detect_repo_root)"
LOONGARCH_DIR="$DH_ROOT/loongarch"
BUILD_DIR="${DH_LOONGARCH_BUILD_DIR:-$LOONGARCH_DIR/.build}"
DIST_DIR="${DH_LOONGARCH_DIST_DIR:-$LOONGARCH_DIR/dist}"
INIT_SCRIPT="$LOONGARCH_DIR/scripts/dh-loongarch-init.gradle"

CROSS_PREFIX="${CROSS_PREFIX:-}"
EXTRA_SQLITE_ARGS=()
INJECT_ARGS=()
SKIP_SQLITE=0
GRADLE_EXTRA=()
MC_LIST=()

while [ $# -gt 0 ]; do
    case "$1" in
        --mc)           MC_LIST+=("${2:?--mc 需要参数}"); shift 2 ;;
        --all-loaders)  MC_LIST+=("${DH_DEFAULT_MC_ALL:-26.3.0}" "1.20.1"); shift ;;
        --cross-prefix) CROSS_PREFIX="${2:?--cross-prefix 需要参数}"; shift 2 ;;
        --no-patch)     EXTRA_SQLITE_ARGS+=(--no-patch); shift ;;
        --skip-sqlite)  SKIP_SQLITE=1; shift ;;
        --use-lief)     INJECT_ARGS+=(--use-lief); shift ;;
        --clean)        GRADLE_EXTRA+=(clean); shift ;;
        -h|--help)      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              dh_die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

# ---------------------------------------------------------------------------
# 版本号（全部动态读取）
# ---------------------------------------------------------------------------
MOD_VERSION="$(dh_read_gradle_prop "$DH_ROOT/gradle.properties" mod_version)" \
    || dh_die "无法读取 mod_version"
SQLITE_VERSION="$(dh_sqlite_jdbc_version "$DH_ROOT")" \
    || dh_die "无法读取 sqlite_jdbc_version"
if [ ${#MC_LIST[@]} -eq 0 ]; then
    if [ -n "${MC_VERSIONS:-}" ]; then
        # shellcheck disable=SC2206
        MC_LIST=($MC_VERSIONS)
    else
        MC_LIST=("$(dh_read_gradle_prop "$DH_ROOT/gradle.properties" mcVer)")
    fi
fi

dh_info "DH 版本      : $MOD_VERSION"
dh_info "sqlite-jdbc  : $SQLITE_VERSION"
dh_info "MC 目标      : ${MC_LIST[*]}"

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
dh_ensure_java_home
TOOLS=(git make curl unzip file java)
[ -x "$JAVA_HOME/bin/javac" ] || dh_die "JAVA_HOME 下没有 javac: $JAVA_HOME"
[ -x "$JAVA_HOME/bin/jar" ]   || dh_die "JAVA_HOME 下没有 jar: $JAVA_HOME"
command -v zip >/dev/null 2>&1 || dh_warn "未找到 zip（make native 通常不需要，可忽略）"
dh_require_cmds "${TOOLS[@]}"
if [ -n "$CROSS_PREFIX" ]; then
    command -v "${CROSS_PREFIX}gcc" >/dev/null 2>&1 \
        || dh_die "找不到交叉编译器 ${CROSS_PREFIX}gcc"
else
    dh_require_cmds gcc
fi
dh_require_cmds python3
[ -f "$DH_ROOT/coreSubProjects/LICENSE.txt" ] \
    || dh_die "缺少 coreSubProjects 子模块，请先执行: git submodule update --init --recursive"

dh_export_proxy_env
dh_configure_gradle_proxy
dh_info "JAVA_HOME: $JAVA_HOME"

# Gradle 守护进程参数：DH 默认 -Xmx4096M，这里不覆盖
GRADLE_BASE=(--console=plain --stacktrace)

# 显式告诉 Gradle 本机 JDK 位置：
# foojay 在 loongarch64 上不可用，1.20.1（JDK 17）等目标需要本机已安装的 JDK。
JDK_PATHS="$(dh_detect_jdk_paths)"
if [ -n "$JDK_PATHS" ]; then
    GRADLE_BASE+=("-Dorg.gradle.java.installations.paths=$JDK_PATHS")
    dh_info "Gradle toolchain 候选 JDK: $JDK_PATHS"
fi

# ---------------------------------------------------------------------------
# 1 + 2. sqlite-jdbc（so + jar）与注入
# ---------------------------------------------------------------------------
if [ "$SKIP_SQLITE" = "1" ]; then
    dh_info "--skip-sqlite：复用已有 sqlite-jdbc 构建产物"
else
    SQLITE_ARGS=("${EXTRA_SQLITE_ARGS[@]}")
    if [ -n "$CROSS_PREFIX" ]; then
        SQLITE_ARGS+=(--cross-prefix "$CROSS_PREFIX")
    fi
    dh_info "步骤 1/4：构建 sqlite-jdbc LoongArch64 原生库"
    "$SCRIPT_DIR/build-sqlitejdbc-loongarch.sh" "${SQLITE_ARGS[@]}"
fi

dh_info "步骤 2/4：注入到 DH 构建（Gradle 依赖替换）"
"$SCRIPT_DIR/inject-so-into-dh-build.sh" "${INJECT_ARGS[@]}"

# shellcheck disable=SC1090
source "$BUILD_DIR/gradle-inject.env"
dh_info "注入版本: $DH_LOONGARCH_SQLITE_VERSION"

# ---------------------------------------------------------------------------
# 3. DH 构建
# ---------------------------------------------------------------------------
mkdir -p "$DIST_DIR"
MULTI_MC=0
[ ${#MC_LIST[@]} -gt 1 ] && MULTI_MC=1

build_for_mc() {
    local mc="$1"
    mkdir -p "$BUILD_DIR"
    # 标记本次构建开始时间，collect_for_mc 用它排除残留产物
    touch "$BUILD_DIR/.build-start-$mc"
    dh_info "步骤 3/4：./gradlew assemble mergeJars -PmcVer=$mc"
    ( cd "$DH_ROOT" && ./gradlew "${GRADLE_BASE[@]}" \
        --init-script "$INIT_SCRIPT" \
        -Ddh.loongarch.m2="$DH_LOONGARCH_M2" \
        -Ddh.loongarch.sqlite.version="$DH_LOONGARCH_SQLITE_VERSION" \
        "${GRADLE_EXTRA[@]}" \
        -PmcVer="$mc" \
        -PinfoBuildSource="Local LoongArch64 build" \
        assemble mergeJars )
}

collect_for_mc() {
    local mc="$1" name_suffix=""
    # 多个 MC 目标或 CI（矩阵按 MC 版本拆分）时必须带 MC 版本后缀，
    # 否则不同 MC 版本的产物会同名覆盖。
    if [ "$MULTI_MC" = "1" ] || [ "${DH_DIST_NAME_WITH_MC:-0}" = "1" ]; then
        name_suffix="-mc$mc"
    fi

    # 只收集该 MC 版本在 versionProperties 中声明的加载器，
    # 避免把上一个 MC 目标残留的 build/libs 产物混进来。
    local props="$DH_ROOT/versionProperties/$mc.properties"
    [ -f "$props" ] || dh_die "找不到版本属性: $props"
    local loaders
    loaders="$(sed -n 's/^[[:space:]]*builds_for[[:space:]]*=[[:space:]]*//p' "$props" | tail -n 1 | tr ',' ' ')"
    [ -n "$loaders" ] || dh_die "无法从 $props 读取 builds_for"

    # 用时间戳标记区分“本次构建产物”和上一次 MC 目标的残留
    local marker="$BUILD_DIR/.build-start-$mc"
    local loader dir jar dest
    for loader in $loaders; do
        dir="$DH_ROOT/$loader/build/libs"
        [ -d "$dir" ] || { dh_warn "跳过 $loader：目录不存在 $dir"; continue; }
        jar=""
        # 过滤中间产物（sources/javadoc/dev/all/raw/unobf/api），只取本次构建新生成的
        for candidate in "$dir"/*.jar; do
            [ -f "$candidate" ] || continue
            case "$candidate" in
                *-sources.jar|*-javadoc.jar|*-dev.jar|*-all.jar|*-raw.jar|*-unobf.jar|*-api.jar) continue ;;
            esac
            [ "$candidate" -nt "$marker" ] || continue
            if [ -z "$jar" ] || [ "$candidate" -nt "$jar" ]; then
                jar="$candidate"
            fi
        done
        if [ -n "$jar" ]; then
            dest="$DIST_DIR/DistantHorizons-$loader-$MOD_VERSION$name_suffix.jar"
            cp -f "$jar" "$dest"
            dh_ok "loader jar: $(basename "$dest")  <- $(basename "$jar")"
        else
            dh_warn "未找到 $loader 的新构建产物（$dir）"
        fi
    done

    # Forgix 合并产物（一个 jar 同时支持该 MC 版本的所有加载器）
    local forgix_jar=""
    for candidate in "$DH_ROOT"/build/forgix/*.jar; do
        [ -f "$candidate" ] || continue
        [ "$candidate" -nt "$marker" ] || continue
        if [ -z "$forgix_jar" ] || [ "$candidate" -nt "$forgix_jar" ]; then
            forgix_jar="$candidate"
        fi
    done
    if [ -n "$forgix_jar" ]; then
        dest="$DIST_DIR/DistantHorizons-merged-$MOD_VERSION$name_suffix.jar"
        cp -f "$forgix_jar" "$dest"
        dh_ok "merged jar: $(basename "$dest")  <- $(basename "$forgix_jar")"
    else
        dh_warn "未找到 Forgix 合并产物（$DH_ROOT/build/forgix/）"
    fi
}

FAILED_MC=()
for mc in "${MC_LIST[@]}"; do
    if build_for_mc "$mc"; then
        collect_for_mc "$mc"
    else
        dh_warn "MC $mc 构建失败（继续下一个目标）"
        FAILED_MC+=("$mc")
    fi
done

# ---------------------------------------------------------------------------
# 4. 汇总
# ---------------------------------------------------------------------------
dh_info "步骤 4/4：产物汇总"
printf '\n'
if compgen -G "$DIST_DIR/*.jar" >/dev/null; then
    shopt -s nullglob
    for _jar in "$DIST_DIR"/*.jar; do
        printf '  %-9s %s\n' "$(du -h "$_jar" | cut -f1)" "$(basename "$_jar")"
    done
    shopt -u nullglob
else
    dh_warn "$DIST_DIR 下没有 jar 产物"
fi
printf '\n'

if [ ${#FAILED_MC[@]} -gt 0 ]; then
    dh_die "以下 MC 目标构建失败: ${FAILED_MC[*]}"
fi

dh_ok "全部完成，产物目录: $DIST_DIR"
