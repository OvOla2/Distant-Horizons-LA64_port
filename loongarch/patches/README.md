# sqlite-jdbc LoongArch64 补丁说明

## 补丁文件

- `sqlitejdbc-loongarch64.patch`
- 只修改一个文件：`src/main/java/org/sqlite/util/OSInfo.java`
- 补丁基线：**sqlite-jdbc 3.53.2.1**（当前 DH `3.3.4` 的 `gradle.properties` 中
  `sqlite_jdbc_version=3.53.2.1`；版本以构建脚本运行时从 `gradle.properties`
  读取的值 为准，升级 DH 后需重新生成补丁）

## 修改内容

```diff
     public static final String RISCV64 = "riscv64";
+    public static final String LOONGARCH64 = "loongarch64";

     static {
         ...
         archMapping.put(RISCV64, RISCV64);
+        archMapping.put(LOONGARCH64, LOONGARCH64);
     }
```

作用链：

```
System.getProperty("os.arch") = "loongarch64"
  -> OSInfo.getArchName()                      // 命中 archMapping -> "loongarch64"
  -> OSInfo.getNativeLibFolderPathForCurrentOS() = "Linux/loongarch64"
  -> LibraryLoaderUtil.getNativeLibResourcePath()
       = "/org/sqlite/native/Linux/loongarch64"
  -> 加载 jar 内 org/sqlite/native/Linux/loongarch64/libsqlitejdbc.so
```

在 DH 的 shadow 重定位之后，`org/sqlite` 会被改名为 `dh_sqlite`，上述路径随之
变为 `/dh_sqlite/native/Linux/loongarch64/libsqlitejdbc.so`，由 DH 的
`NativeTransformer` 自动生成（见 `buildSrc/src/main/groovy/dh-loader.gradle`）。

## 关于“补丁是否必需”的实测结论

在本仓库验证环境（AOSC OS LoongArch，OpenJDK 25.0.2，`os.arch=loongarch64`）中：

- **未打补丁**的 sqlite-jdbc 3.53.2.1，`OSInfo.getNativeLibFolderPathForCurrentOS()`
  同样返回 `Linux/loongarch64`（`getArchName()` 对未知架构会走
  `translateArchNameToFolderName()`，只删除非单词字符，`loongarch64` 原样保留）。
  仅注入 `libsqlitejdbc.so` 后即可成功建表/查询（见 `loongarch/README.md` 的验证记录）。
- 补丁的价值在于**显式登记**该架构：`archMapping` 的查找键是小写化的，
  因此 `os.arch` 为 `LoongArch64`、`LOONGARCH64` 等大小写变体时也能稳定映射到
  `loongarch64`；未登记时 `translateArchNameToFolderName()` 会保留原始大小写，
  得到 `Linux/LoongArch64`，从而找不到 native 目录。

也就是说：**使 LoongArch 可用的关键是把 `libsqlitejdbc.so` 放进 jar**，
补丁是保证目录名稳定的最小加固，不是唯一使能条件。脚本默认仍然应用补丁，
因为这是本移植方案的可追溯基线；如需完全零改动可加 `--no-patch`。

## 生成 / 重新生成

```bash
# 生成（幂等；已应用则跳过）
./loongarch/scripts/patch-osinfo.sh

# 强制丢弃本地改动后重新生成
./loongarch/scripts/patch-osinfo.sh --force

# 校验补丁能否干净应用（CI 也会做）
./loongarch/scripts/patch-osinfo.sh --check
```

脚本会：

1. 按 `gradle.properties` 的 `sqlite_jdbc_version` 取源码（没有则 clone）；
2. 修改 `OSInfo.java`（只增 2 行）；
3. `git diff` 生成标准 patch；
4. 断言只改动了 `OSInfo.java`，且补丁可反向应用。

## 更新流程（DH 升级 sqlite-jdbc 版本后）

1. 在 `loongarch-patch` 分支上更新 DH 后，确认 `gradle.properties` 的新
   `sqlite_jdbc_version`。
2. 重新生成补丁：

   ```bash
   rm -rf loongarch/.build/sqlite-jdbc-src
   ./loongarch/scripts/patch-osinfo.sh
   ```

3. 若上游 `OSInfo.java` 结构变化（例如 `RISCV64` 常量或 `archMapping` 调用被
   改写），脚本会直接报错并打印缺失的锚点，此时按新的源码结构更新
   `patch-osinfo.sh` 中的两处 anchor 即可。
4. 运行 `./loongarch/scripts/build-dh-loongarch.sh` 验证，再提交补丁文件。

## 上游状态

sqlite-jdbc 上游（`xerial/sqlite-jdbc`）截至 3.54.1.0 **没有** LoongArch64 的
release 原生库，也没有相关提交；本补丁与 so 构建流程属于下游移植，未尝试上游化。
