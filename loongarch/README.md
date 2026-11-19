# Distant Horizons × LoongArch64（loongarch64）移植构建

[![LoongArch64 Build](https://github.com/OvOla2/Distant-Horizons-LA64_port/actions/workflows/loongarch-build.yml/badge.svg?branch=loongarch-patch)](https://github.com/OvOla2/Distant-Horizons-LA64_port/actions/workflows/loongarch-build.yml)
[![GitHub repo](https://img.shields.io/badge/repo-OvOla2%2FDistant--Horizons--LA64__port-181717?logo=github)](https://github.com/OvOla2/Distant-Horizons-LA64_port)
[![Release](https://img.shields.io/github/v/release/OvOla2/Distant-Horizons-LA64_port?label=release)](https://github.com/OvOla2/Distant-Horizons-LA64_port/releases/tag/loongarch-v3.3.4)

本目录是 **Distant Horizons（DH）LoongArch64 移植**的全部构建资产：
交叉/本机构建 sqlite-jdbc 的 LoongArch 原生库、使用 Gradle 依赖替换把
带 `loongarch64` 原生库的 sqlite-jdbc 注入 DH 构建、产出 Fabric / Forge /
NeoForge 可分发 jar，以及对应的 GitHub Actions 工作流。

> 上游基线：DH 最新正式版 tag **3.3.4**（`loongarch-patch` 分支基于该 tag）。
> sqlite-jdbc 版本不硬编码，运行时从 DH 的 `gradle.properties`
> （`sqlite_jdbc_version`）读取。

---

## 1. 目录结构

```
loongarch/
├── scripts/
│   ├── common.sh                        # 公共函数（版本读取、代理、JDK 探测）
│   ├── build-sqlitejdbc-loongarch.sh     # 源码 -> loongarch64 so -> 注入 jar
│   ├── patch-osinfo.sh                   # 生成/校验 OSInfo.java 补丁（开发期）
│   ├── inject-so-into-dh-build.sh        # 注册本地 Maven artifact + Gradle init script
│   ├── dh-loongarch-init.gradle          # Gradle init script（依赖版本替换）
│   └── build-dh-loongarch.sh             # 一键入口：全流程
├── patches/
│   ├── sqlitejdbc-loongarch64.patch      # 只改 OSInfo.java（2 行）
│   └── README.md                         # 补丁说明与更新流程
├── .gitignore                            # 忽略 .build/ 与 dist/
└── README.md                             # 本文件
.github/workflows/loongarch-build.yml     # CI：交叉编译 + 构建 + artifact/Release
```

**DH 构建脚本零改动**：注入通过 Gradle init script 完成，不改 `build.gradle` /
`settings.gradle`，因此 `loongarch-patch` 分支相对 3.3.4 tag 只新增
`loongarch/` 与 `.github/workflows/`，外加 **1 个文件 2 行**的上游编译 bug
修复（`MinecraftGLWrapper.java`，见 4.2 节，产出 Forge jar 所必需），
rebase 上游时不会与 DH 构建脚本冲突。

---

## 2. 前置依赖（本地）

| 依赖 | 用途 | AOSC 安装 |
| --- | --- | --- |
| JDK 25（含 `javac`/`jar`） | Gradle 9.6.1 / DH 默认 MC 26.3 工具链 | `sudo oma install openjdk-25` |
| `gcc` / `make` | 本机编译 sqlite3 与 JNI | `sudo oma install gcc make` |
| `perl` | sqlite-jdbc Makefile 注入扩展函数 | `sudo oma install perl` |
| `unzip` / `zip` / `curl` / `git` | 下载源码、打包 jar | `sudo oma install unzip zip curl git` |
| `python3` + `venv` | 脚本辅助（缓存预置、版本解析） | `sudo oma install python3 python3-pip` |

构建 MC 1.20.1（Forge）需要 **JDK 17**：本机已安装的 JDK（如
`/usr/lib/java-17`）会被脚本自动加入 Gradle 的 toolchain 候选路径。
原因：DH 的 foojay 工具链解析器在 loongarch64 上不可用
（`Service 'SystemInfo' is not available ... enabled=false`），无法自动下载。

---

## 3. 本地一键构建

```bash
# 0. 切到补丁分支并同步 core 子模块
git checkout loongarch-patch
git submodule update --init --recursive

# 1. 代理（本地必需；脚本默认值也是这个，可省略）
export PROXY_URL="http://127.0.0.1:20171"

# 2. 一键构建（默认使用 gradle.properties 的 mcVer）
./loongarch/scripts/build-dh-loongarch.sh

# 需要 Forge（DH 只在 ≤1.20.1 提供 Forge）时，同时构建两个 MC 目标：
./loongarch/scripts/build-dh-loongarch.sh --all-loaders
# 等价于： MC_VERSIONS="26.3.0 1.20.1" ./loongarch/scripts/build-dh-loongarch.sh

# 默认使用 LIEF 做 native 重定位（见 4.1）；
# 没有 LIEF/无法访问镜像时回退到编译期改号方案：
./loongarch/scripts/build-dh-loongarch.sh --no-lief
```

产物在 `loongarch/dist/`：

| 文件 | 说明 |
| --- | --- |
| `DistantHorizons-fabric-<modVer>.jar` | Fabric 单加载器 jar |
| `DistantHorizons-neoforge-<modVer>.jar` | NeoForge 单加载器 jar |
| `DistantHorizons-forge-<modVer>.jar` | Forge 单加载器 jar（仅 MC ≤1.20.1） |
| `DistantHorizons-merged-<modVer>.jar` | Forgix 合并产物（一次适配该 MC 版本的全部加载器，推荐直接安装） |

同时构建多个 MC 版本时（`--all-loaders` 或 `MC_VERSIONS="..."`），文件名追加
`-mc<版本>`，例如 `DistantHorizons-fabric-3.3.4-mc1.20.1.jar`，避免覆盖。
CI 中通过 `DH_DIST_NAME_WITH_MC=1` 强制加后缀（矩阵按 MC 版本并行）。

> 为什么需要两个 MC 版本：DH 的 `versionProperties/*.properties` 中
> `builds_for` 每个版本只列两个加载器（1.20.1 = `fabric,forge`，
> 26.x/1.21.x = `fabric,neoforge`），不存在同时支持三者的单一版本。
> `--all-loaders` 用两个目标覆盖三个加载器。

### 分步执行

```bash
# 只构建 so + 注入后的 sqlite-jdbc jar（产物：loongarch/.build/）
./loongarch/scripts/build-sqlitejdbc-loongarch.sh
#   --version 3.53.2.1   覆盖版本
#   --cross-prefix ...   交叉编译
#   --no-patch           不应用 OSInfo 补丁
#   --clean              重新 clone 源码

# 注册到本地 Maven 仓库并生成注入配置
./loongarch/scripts/inject-so-into-dh-build.sh [--verify]
# 默认即 LIEF（见 4.1）；回退到无 LIEF 方案：
./loongarch/scripts/inject-so-into-dh-build.sh --no-lief

# 手动构建（与脚本等价）
./gradlew --init-script loongarch/scripts/dh-loongarch-init.gradle \
  -Ddh.loongarch.m2="$PWD/loongarch/.build/m2" \
  -Ddh.loongarch.sqlite.version="$(sed -n 's/^sqlite_jdbc_version=//p' gradle.properties)-loongarch" \
  -PmcVer=26.3.0 assemble mergeJars
```

---

## 4. 注入原理（为什么不是“改 DH 源码”）

1. `build-sqlitejdbc-loongarch.sh` 用 `make native` 产出
   `libsqlitejdbc.so`，连同（可选）重新编译的 `OSInfo.class` 写进官方
   `sqlite-jdbc-<ver>.jar` 的 `org/sqlite/native/Linux/loongarch64/`。
2. `inject-so-into-dh-build.sh` 把该 jar 安装为本地 Maven 构件
   `org.xerial:sqlite-jdbc:<ver>-loongarch`。
3. `dh-loongarch-init.gradle` 通过
   `resolutionStrategy.eachDependency` 把版本替换成 `<ver>-loongarch`；
   该版本只存在于本地仓库，因此 Gradle 必定解析到它，不受仓库顺序影响。
4. DH 的 `shadowJar` + `NativeTransformer` 会把
   `org/sqlite` 重定位为 `dh_sqlite`，并对所有 `org/sqlite/native/**`
   二进制做符号重写，最终 jar 内出现
   `dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so`。

### 4.1 native 重定位：默认走 LIEF，保留无 LIEF 回退

DH 的 `NativeTransformer` 对 `org/sqlite/native/**` 的处理是：先在二进制里
做字符串替换（`org/sqlite`→`dh_sqlite`、`org_sqlite`→`dh_1sqlite`），再用
LIEF 的 `fix_modified_binary.py` 重写 ELF。**裸替换后必须重写 `.gnu.hash`**，
否则 `dlsym("Java_dh_1sqlite_...")` 找不到符号，运行时报
`UnsatisfiedLinkError: dh_sqlite.core.NativeDB._open_utf8`。

#### 默认模式：LIEF（`--use-lief` 已无需显式指定）

`inject-so-into-dh-build.sh` 会自动准备 `relocate_natives/.venv`：

| 构建机架构 | lief 版本 | 来源 |
| --- | --- | --- |
| loongarch64（本机） | `0.17.6` | 龙芯 PyPI 镜像 `https://mirrors.loong64.com/pypi/simple`（0.16.2 没有 loongarch wheel，镜像只提供 0.17.4+） |
| x86_64 / aarch64（CI） | `0.16.2` | PyPI（DH 的固定版本，有 manylinux wheel） |

DH 的 `prepare()` 检测到 `.venv/bin/python` 能 `import lief` 后就不再执行
`pip install`，直接使用该 venv 完成重定位。镜像需要直连，脚本对
`mirrors.loong64.com` 会自动去掉 `*_proxy`。

**LIEF 是跨架构的二进制解析器**：在 x86_64 CI 上解析并重写 LoongArch ELF 完全
可行（不需要 QEMU，也不执行该二进制）。DH 仓库里已提交的
`relocate_natives/cache/linux/loongarch64/libzstd-jni_dh-1.5.7-12.so` 就是上游
在 x86 构建机上生成的 LoongArch 重定位产物。

#### 回退模式：`--no-lief`（编译期改号 + 预置缓存）

如果构建机没有可用的 LIEF / 无法访问镜像，可以用 `--no-lief`：

1. `build-sqlitejdbc-loongarch.sh` 额外编译一个**编译期改号**的 so：
   把 `NativeDB.c` / `NativeDB.h` 里的 `Java_org_sqlite_` 改成
   `Java_dh_1sqlite_`，把 `FindClass` 用的 `"org/sqlite/..."` 改成
   `"dh_sqlite/..."`，重新链接，让链接器生成正确的 `.gnu.hash`；
2. `inject-so-into-dh-build.sh` 把它复制到
   `relocate_natives/cache/dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so`；
3. DH 构建命中缓存，跳过 `prepare()`/LIEF，完全不依赖 Python。

两种模式都实机验证通过；差异只在“谁来重建 ELF 符号表”。

**Fallback（未采用）**：解压 DH shadow jar → 替换 `OSInfo.class` + 新增 so →
重新打包。该方式同样要自行完成上述 ELF 符号重写，否则 `System.load` 会因
JNI 符号名不匹配失败；而 Gradle 依赖替换能让 DH 自带流程完成路径重定位，
因此作为唯一实现。

### 4.2 DH 3.3.4 上游编译 bug（Forge 目标必需的最小修复）

`loongarch-patch` 分支还包含一个**与 LoongArch 无关**的上游修复：

```diff
-        if (!trustGlStateManager())
+        if (runDirectGlCall())
```

位置：`common/src/main/java/com/seibel/distanthorizons/common/wrappers/minecraft/MinecraftGLWrapper.java`
（`enableBlend()` / `disableBlend()` 的 `MC_VER <= MC_26_1_2` 分支，2 处）。

原因：3.3.4 tag 里这两处调用了**不存在的方法** `trustGlStateManager()`，
导致所有 `MC_VER <= 26.1.2` 的目标（1.20.1、1.21.x 等）在
`:common:compileJava` 直接编译失败；26.3.0 走 `#else` 分支所以不受影响。
上游 `main` 已把这两处改为 `runDirectGlCall()`，此处按上游写法同步。

影响：这是产出 **Forge** jar 的前提（Forge 只存在于 ≤1.20.1 的版本属性中）。
它不改变 LoongArch 相关逻辑；后续 rebase 到上游已修复的 tag 时，该 commit
会变成空提交，可以安全丢弃（`git rebase` 时会提示）。

---

## 5. CI（GitHub Actions）

> **状态：已启用**。首次 push 触发的运行已通过（2026-11-19，
> run [#1](https://github.com/OvOla2/Distant-Horizons-LA64_port/actions/runs/44503225890)：
> `build-26.3.0` 与 `build-1.20.1` 均 success，产物各约 75–77MB；
> Release job 因无 tag 按预期跳过）。
> 发版：tag `loongarch-v3.3.4` 的流水线通过，Release
> [loongarch-v3.3.4](https://github.com/OvOla2/Distant-Horizons-LA64_port/releases/tag/loongarch-v3.3.4)
> 已附上 6 个 jar（Fabric/Forge/NeoForge × MC 26.3.0/1.20.1）。

工作流：`.github/workflows/loongarch-build.yml`

**触发**

| 事件 | 行为 |
| --- | --- |
| `workflow_dispatch` | 手动触发，可填 `ref`（默认 `loongarch-patch`）与 `mc_versions`（默认 `26.3.0 1.20.1`） |
| push 到 `loongarch-patch` | 自动构建，上传 artifact |
| push tag `loongarch-v*` | 构建 + 发布 GitHub Release |

**Job 1 `build-native-and-mod`**（`ubuntu-24.04`，按 MC 版本矩阵并行）

1. `actions/checkout@v4`，`submodules: recursive`；
2. `actions/setup-java@v4` 安装 Temurin 25；
3. `maikebing/loongarch64-cross-compile@main` 安装
   `loongarch64-linux-gnu-gcc`（GCC 15.1 / glibc 2.42，带缓存）；
4. 从 `gradle.properties` 读取 `sqlite_jdbc_version`，并校验补丁只改
   `OSInfo.java`；
5. 调用 `build-dh-loongarch.sh --cross-prefix loongarch64-linux-gnu- --mc <ver>`：
   交叉编译 so → 注入 → `./gradlew assemble mergeJars`（与本地同一套脚本，避免分叉）。
   native 重定位默认走 LIEF：x86_64 runner 上用 PyPI 的 `lief==0.16.2`
   解析并重写交叉编译出的 LoongArch ELF（LIEF 与宿主架构无关，不需要 QEMU）；
   需要 `python3-venv`；
6. 上传 `loongarch/dist/*.jar`（artifact 名为
   `distanthorizons-loongarch-jars-<mc>`；设置 `DH_DIST_NAME_WITH_MC=1`，
   文件名带 `-mc<版本>`，中间产物 `-dev`/`-sources`/`-all` 等不上传）。

**Job 2 `release`**（仅 `loongarch-v*` tag）

下载全部 artifact，用 `softprops/action-gh-release` 附加到同名 tag 的 Release。

CI 中**不配置代理**（workflow 里 `PROXY_URL: ''`），也不使用 QEMU / 自托管 runner。

**发布示例**

```bash
git tag loongarch-v3.3.4 && git push origin loongarch-v3.3.4
```

### 5.1 发布到 GitHub（一次性落地步骤）

上游仍在 GitLab；GitHub 只作为 fork / 发布页。当前仓库：
`https://github.com/OvOla2/Distant-Horizons-LA64_port`。

```bash
# 1. 网页新建 Public 空仓库（不要勾选 README / .gitignore / license）

# 2. 本地：GitLab 上游改名 upstream（main 会自动继续跟踪 upstream/main）
git remote rename origin upstream
git remote add origin https://github.com/OvOla2/Distant-Horizons-LA64_port.git

# 3. 推送分支（loongarch-patch 设为 GitHub 默认分支）
git push -u origin loongarch-patch
git push origin main          # 不带 -u：main 仍跟踪 upstream/main

# 4. 网页 Settings → General → Default branch → loongarch-patch
```

**首次 CI 验证**

push `loongarch-patch` 会自动触发一次构建（只有 tag 才会发 Release，
所以这次只是验证）。也可以在 Actions → *LoongArch64 Build* →
*Run workflow* 手动选择分支与 MC 版本。

如果希望**首次只手工触发**：先 Settings → Actions → General →
Disable actions，push 后再启用，然后 Run workflow。

首次运行较慢（下载交叉工具链、Minecraft、JDK 17、lief），重点检查：

- `Relocating to dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so...`
- artifact 断言步骤（每个 jar 必须含该 so）
- 1.20.1 任务里 JDK 17 的自动下载是否成功（x86_64 上 foojay 可用）

**发布 Release**

首次 CI 通过后：

```bash
git tag loongarch-v3.3.4
git push origin loongarch-v3.3.4
```

`release` job 会下载全部 matrix artifact，并把 6 个 jar 附加到同名 tag 的
GitHub Release。

> 注意：`main` 只是上游镜像，后续 rebase 用 `git fetch upstream`；
> `loongarch-patch` 才是移植工作分支。

## 6. 用户手动测试（构建脚本不会启动 Minecraft）

1. 从 Actions artifact 或 Release 下载 jar；
2. 放入对应加载器的 `mods/`（或直接使用 `DistantHorizons-merged-*.jar`）；
3. 启动 Minecraft，进游戏创建/加载世界，让 DH 触发 LOD 数据库读写；
4. 反馈 `logs/latest.log`（必要时 `logs/debug.log`、`crash-reports/`）。

**先确认 jar 里确实有 loongarch64 原生库**：

```bash
unzip -l DistantHorizons-*.jar | grep -E "dh_sqlite/native/(Linux|.*)/loongarch64"
# 期望：
#   dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so
```

**测试时需要搜索的日志关键词**

| 关键词 | 期望结果 |
| --- | --- |
| `loongarch64` | 出现 `dh_sqlite/native/Linux/loongarch64/...` 相关路径 |
| `sqlite` / `dh_sqlite`（不区分大小写） | 只有正常初始化/数据库日志，无异常堆栈 |
| `No native library found for os.name=Linux, os.arch=loongarch64` | **不应出现**；出现即表示 jar 没带上 so 或目录名不匹配 |
| `NativeLibraryNotFoundException` | **不应出现** |
| `UnsatisfiedLinkError` | **不应出现**；出现通常是符号未重写或 ABI 不匹配 |
| `Failed to load native library` | **不应出现** |
| `GLIBC_2.4x not found` / `version 'GLIBC_xxx' not found` | **不应出现**；CI 产物用 glibc 2.42 交叉工具链，比 AOSC 旧系统可能不满足，此时用本地构建 |
| `jdbc:dh_sqlite` / `jdbc:sqlite` | 正常连接串输出 |
| `DistantHorizons` + `SQLite` 相关异常（`SQLException`, `IOException`, `Error opening connection`） | 不应出现 |

建议的命令：

```bash
grep -iE "loongarch|sqlite|jdbc|UnsatisfiedLinkError|NativeLibraryNotFound" logs/latest.log
```

---

## 7. 已知限制

- **GLIBC**：CI 交叉工具链基于 glibc 2.42；目标机 glibc 更旧时会出现
  `GLIBC_2.42 not found`，此时请在本机运行
  `./loongarch/scripts/build-dh-loongarch.sh`（用本机 glibc）。
- **Forge**：DH 3.3.4 只在 MC ≤1.20.1 声明 Forge（`versionProperties/1.20.1.properties`），
  26.x 上游注释为 “forge is broken due to gradle/build script issues”，
  因此三个加载器需要两个 MC 目标（见 3 节与 4.2 节的上游编译修复）。
- **首次构建很慢**：unimined 需要下载 Minecraft、mappings 与大量依赖；
  之后有 Gradle 缓存会快很多。
- LoongArch 上没有 `lief==0.16.2`，默认的 LIEF 模式在 loongarch64 上使用
  龙芯镜像的 0.17.6（已验证与 DH 脚本兼容）；无镜像/无网络时用 `--no-lief`
  回退（编译期改号 + 预置缓存，见 4.1）。
  若上游改用 LIEF 的其它能力（例如重算签名/校验和），需要重新评估回退方案。
- 构建产生的新缓存文件 `relocate_natives/cache/dh_sqlite/native/Linux/loongarch64/`
  属于构建产物，**不要提交**到 `loongarch-patch` 分支。

---

## 8. 版本更新 / rebase 流程

```bash
git fetch origin                    # 或 git fetch upstream
git checkout main && git pull       # main 跟踪上游
git checkout loongarch-patch
git rebase <新的上游正式版 tag>       # 例：git rebase 3.3.4
# 冲突可能出现在 loongarch/、.github/ 与 4.2 节的 2 行上游修复
# （若新 tag 已包含上游修复，该 commit 会被 rebase 自动丢弃）
git push --force-with-lease origin loongarch-patch

# 若 sqlite-jdbc 版本变化：
rm -rf loongarch/.build/sqlite-jdbc-src
./loongarch/scripts/patch-osinfo.sh
./loongarch/scripts/build-dh-loongarch.sh
```

详见 [`patches/README.md`](patches/README.md)。

---

## 9. 本机验证记录

验证环境：AOSC OS for LoongArch（loongarch64）、OpenJDK 25.0.2、
GCC 16.2.0、DH 3.3.4、sqlite-jdbc 3.53.2.1。

| 验证项 | 结果 |
| --- | --- |
| `OSInfo.getNativeLibFolderPathForCurrentOS()`（未打补丁） | `Linux/loongarch64` |
| 用本机 gcc 构建 `libsqlitejdbc.so` | ELF 64-bit LSB shared object, LoongArch；`readelf` Machine = LoongArch |
| sqlite-jdbc jar（含 so + 补丁 OSInfo）独立 JDBC 测试 | `ROW 1 loongarch sqlite=3.53.2` / `JDBC_OK` |
| DH `assemble` + `mergeJars`（MC 26.3.0） | BUILD SUCCESSFUL；fabric/neoforge/merged jar |
| DH `assemble` + `mergeJars`（MC 1.20.1） | BUILD SUCCESSFUL；fabric/forge/merged jar（依赖 4.2 的上游修复） |
| DH 产物内原生库 | 6 个 jar 全部包含 `dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so`，各 61 个 `Java_dh_1sqlite_*` 符号 |
| **DH 重定位后的 JDBC 端到端测试**（直接加载产物 jar 中的 `dh_sqlite`） | 26.3 merged、1.20.1 forge 均输出 `ROW 1 overworld sqlite=3.53.2` / `DH_RELOCATED_JDBC_OK` |
| `--use-lief`（龙芯镜像 lief 0.17.6）流程 | BUILD SUCCESSFUL；日志出现 `Relocating to dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so...`，产物 JDBC 测试同样通过 |
| **用户实机测试**（默认方案，MC 26.3 Fabric，Loongson 3A6000 + AMD RADV） | DH 3.3.4 正常加载；overworld / the_end / the_nether 三个 `DistantHorizons.sqlite` 共执行 72 次建表脚本；`Closing all [3] databases...`，退出码 0；无 native 错误 |
| **用户实机测试（LIEF 方案产物）** | DH 正常加载，3 个数据库正常打开/关闭，`Closing all [3] databases...`，退出码 0，无 `UnsatisfiedLinkError` / `NativeLibraryNotFound` |
| **GitHub Actions 首次运行**（x86_64 交叉编译 + lief 0.16.2） | `build-26.3.0`、`build-1.20.1` 均 success；artifact 断言（每个 jar 含 loongarch64 so）通过 |
| **tag 发版运行**（`loongarch-v3.3.4`） | build 两个矩阵 + release job 全部通过；Release 附 6 个 jar（约 22.5–27.7MB） |
| **用户实机测试 CI 产物** | CI artifact 下载后正常加载使用 |
| LIEF 方案全量构建（`--all-loaders`） | 两个 MC 目标均 BUILD SUCCESSFUL；日志出现 `Relocating to dh_sqlite/native/...`；6 个产物的原生库均为 LIEF 重写结果（与编译期改号版本字节不同） |

最终产物（`--all-loaders`，本机实测）：

```
DistantHorizons-fabric-3.3.4-mc26.3.0.jar
DistantHorizons-neoforge-3.3.4-mc26.3.0.jar
DistantHorizons-merged-3.3.4-mc26.3.0.jar
DistantHorizons-fabric-3.3.4-mc1.20.1.jar
DistantHorizons-forge-3.3.4-mc1.20.1.jar
DistantHorizons-merged-3.3.4-mc1.20.1.jar
```

端到端测试方法（不需要启动 Minecraft，可在目标机复现）：

```bash
unzip -o DistantHorizons-fabric-3.3.4.jar \
  dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so -d /tmp/dh-native
python3 - <<'PY'
import ctypes
lib = ctypes.CDLL("/tmp/dh-native/dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so")
assert hasattr(lib, "Java_dh_1sqlite_core_NativeDB__1open_1utf8")
print("relocated JNI symbol OK")
PY
```

该测试同时验证了：shadow 重定位后的类名、编译期改名的 JNI 符号、
ELF `.gnu.hash`、以及 LoongArch 上的实际 SQL 执行。
