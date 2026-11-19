#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-osinfo.sh
#
# 开发期辅助脚本：在 sqlite-jdbc 源码中修改 org/sqlite/util/OSInfo.java，
# 生成标准 patch 文件 loongarch/patches/sqlitejdbc-loongarch64.patch。
#
# 补丁内容（最小化，只改 OSInfo.java）：
#   1) 新增 LOONGARCH64 = "loongarch64" 常量
#   2) 在 archMapping 中登记 loongarch64
# 作用：让 OSInfo.getArchName() 的返回值稳定为 "loongarch64"，从而
#   getNativeLibFolderPathForCurrentOS() == "Linux/loongarch64"，
#   对应 jar 内路径 org/sqlite/native/Linux/loongarch64/libsqlitejdbc.so。
#
# 说明：在当前 LoongArch JDK 上（os.arch=loongarch64）未打补丁的
#   translateArchNameToFolderName() 也能得到同样的目录名；打补丁是为了
#   显式登记该架构，并兼容 os.arch 大小写/别名不同的 JDK，避免得到
#   "Linux/LoongArch64" 这类找不到 native 的目录名。
#
# 代理（仅本地需要）：
#   export PROXY_URL="http://127.0.0.1:20171"   # 默认值
#
# 用法：
#   ./loongarch/scripts/patch-osinfo.sh                 # 生成/更新补丁
#   ./loongarch/scripts/patch-osinfo.sh --check         # 只校验补丁能否干净应用
#   ./loongarch/scripts/patch-osinfo.sh --force         # 丢弃改动后重新生成
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

DH_ROOT="$(dh_detect_repo_root)"
LOONGARCH_DIR="$DH_ROOT/loongarch"
BUILD_DIR="${DH_LOONGARCH_BUILD_DIR:-$LOONGARCH_DIR/.build}"
PATCH_OUT="${SQLITE_JDBC_PATCH:-$LOONGARCH_DIR/patches/sqlitejdbc-loongarch64.patch}"
SQLITE_JDBC_REPO="${SQLITE_JDBC_REPO:-https://github.com/xerial/sqlite-jdbc.git}"
OSINFO_REL="src/main/java/org/sqlite/util/OSInfo.java"

MODE="generate"
VERSION_OVERRIDE="${SQLITE_JDBC_VERSION:-}"
SRC_OVERRIDE="${SQLITE_JDBC_SRC:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --version)   VERSION_OVERRIDE="${2:?--version 需要参数}"; shift 2 ;;
        --src)       SRC_OVERRIDE="${2:?--src 需要参数}"; shift 2 ;;
        --patch-out) PATCH_OUT="${2:?--patch-out 需要参数}"; shift 2 ;;
        --check)     MODE="check"; shift ;;
        --force)     MODE="force"; shift ;;
        -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           dh_die "未知参数: $1" ;;
    esac
done

if [ -n "$VERSION_OVERRIDE" ]; then
    SQLITE_JDBC_VERSION="$VERSION_OVERRIDE"
else
    SQLITE_JDBC_VERSION="$(dh_sqlite_jdbc_version "$DH_ROOT")" \
        || dh_die "无法从 DH 构建文件读取 sqlite_jdbc_version"
fi
SRC_DIR="${SRC_OVERRIDE:-$BUILD_DIR/sqlite-jdbc-src/sqlite-jdbc-$SQLITE_JDBC_VERSION}"

dh_require_cmds git python3
dh_export_proxy_env

# ---------------------------------------------------------------------------
# 源码（必须是 git 仓库，才能用 git diff 生成标准补丁）
# ---------------------------------------------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
    if [ -d "$SRC_DIR" ] && [ -f "$SRC_DIR/$OSINFO_REL" ]; then
        dh_info "源码目录不是 git 仓库，初始化基线提交以便生成补丁: $SRC_DIR"
        git -C "$SRC_DIR" init -q
        git -C "$SRC_DIR" add -A
        git -C "$SRC_DIR" -c user.name=dh-loongarch -c user.email=dh-loongarch@localhost \
            commit -q -m "baseline sqlite-jdbc $SQLITE_JDBC_VERSION"
    else
        dh_info "clone sqlite-jdbc $SQLITE_JDBC_VERSION"
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --filter=blob:none --depth 1 --branch "$SQLITE_JDBC_VERSION" \
            "$SQLITE_JDBC_REPO" "$SRC_DIR"
    fi
fi
[ -f "$SRC_DIR/$OSINFO_REL" ] || dh_die "找不到 $SRC_DIR/$OSINFO_REL"

# ---------------------------------------------------------------------------
# --check：只验证现有补丁
# ---------------------------------------------------------------------------
if [ "$MODE" = "check" ]; then
    [ -f "$PATCH_OUT" ] || dh_die "补丁不存在: $PATCH_OUT"
    git -C "$SRC_DIR" apply --reverse --check "$PATCH_OUT" >/dev/null 2>&1 \
        && { dh_ok "补丁已应用在源码中: $PATCH_OUT"; exit 0; }
    git -C "$SRC_DIR" apply --check "$PATCH_OUT" \
        && { dh_ok "补丁可干净应用到 $SQLITE_JDBC_VERSION"; exit 0; }
    dh_die "补丁无法应用（源码版本可能已变化，需要重新生成）: $PATCH_OUT"
fi

# ---------------------------------------------------------------------------
# 修改 OSInfo.java（幂等）
# ---------------------------------------------------------------------------
if [ "$MODE" = "force" ]; then
    git -C "$SRC_DIR" checkout -- "$OSINFO_REL" 2>/dev/null || true
fi

python3 - "$SRC_DIR/$OSINFO_REL" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

if "LOONGARCH64" in src:
    print("OSInfo.java 已包含 loongarch64 修改，跳过")
    sys.exit(0)

anchor_const = '    public static final String RISCV64 = "riscv64";'
if anchor_const not in src:
    sys.exit("未找到 RISCV64 常量声明，sqlite-jdbc 版本结构可能已变化")

src = src.replace(
    anchor_const,
    anchor_const + '\n    public static final String LOONGARCH64 = "loongarch64";',
    1,
)

anchor_map = "        archMapping.put(RISCV64, RISCV64);"
if anchor_map not in src:
    sys.exit("未找到 archMapping.put(RISCV64, RISCV64)，sqlite-jdbc 版本结构可能已变化")

src = src.replace(
    anchor_map,
    anchor_map + "\n        archMapping.put(LOONGARCH64, LOONGARCH64);",
    1,
)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("已修改 OSInfo.java: 新增 LOONGARCH64 常量与 archMapping 映射")
PY

# ---------------------------------------------------------------------------
# 生成并校验补丁
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$PATCH_OUT")"
git -C "$SRC_DIR" diff --no-color -- "$OSINFO_REL" > "$PATCH_OUT"

[ -s "$PATCH_OUT" ] || dh_die "补丁为空（OSInfo.java 没有改动？）"

CHANGED_FILES="$(git -C "$SRC_DIR" diff --name-only)"
[ "$CHANGED_FILES" = "$OSINFO_REL" ] \
    || dh_die "补丁意外修改了其他文件: $CHANGED_FILES"

# 反向校验：补丁必须能干净地 reverse / apply
git -C "$SRC_DIR" apply --reverse --check "$PATCH_OUT" \
    || dh_die "生成的补丁无法反向应用，补丁不完整"

dh_ok "已生成补丁: $PATCH_OUT"
printf '\n'
printf '  sqlite-jdbc : %s\n' "$SQLITE_JDBC_VERSION"
printf '  修改文件    : %s\n' "$CHANGED_FILES"
printf '  补丁行数    : %s\n' "$(wc -l < "$PATCH_OUT")"
printf '\n'
dh_info "如版本已更新，请同步更新 loongarch/patches/README.md 中的版本说明"
