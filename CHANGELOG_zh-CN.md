# PatchNest Module

[English](CHANGELOG.md) | **中文**

## 更新日志

### v0.4.1-rc2

#### 🔀 品牌重塑: KPatch-Next → PatchNest
- **项目重命名**: 从 "KPatch-Next" 更名为 "PatchNest"，涉及 68 个文件：
  shell 脚本、CI 工作流、WebUI（JS/HTML/CSS）、15 个 locale XML、
  文档、测试、module.prop、update.json、version.properties。
- **数据目录** 从 `/data/adb/kp-next/` 更改为 `/data/adb/patchnest/`。
- **二进制来源** 从 `KernelSU-Next/KPatch-Next` 更改为 `Zhanfg/PatchNest`。
- **模块 ID** 从 `KPatch-Next` 更改为 `PatchNest`。
- **变量名** 更新: `KPNDIR` → `PNDIR`，`VERSION_KPATCH_NEXT` → `VERSION_PATCHNEST`。

#### 🔒 安全（重命名后审计）
- **service.sh 排除列表 grep** 修复: `grep -F "^$pkgq "` 在 `-F`（字面匹配）模式下
  无法使用 `^` 锚定，已替换为 `grep "^$pkgq "`。
- **boot_unpatch.sh** `patched=` 逻辑反转问题已修正。
- **compile_kpm.sh** `compile_rc` 变量未初始化问题已修复。

#### ⚡ 健壮性
- **WebView 兼容性**: Vite 构建目标从 `es2022` 更改为 `['chrome80', 'es2020']`，
  支持 Android WebView 80+（2020 年后的设备）。
- **顶层 await** 已从 `index.js` 移除；改用动态 `import().then()`。
- **4 个缺失的 i18n 键** 已同步到全部 15 个 locale。
- **CRLF → LF** 所有 `module/*.sh` 脚本的行尾符已修复。

#### 📦 构建
- v0.4.1-rc2 zip 打包完成（1.95 MB，66/66 验证 + 117/117 测试通过）。
- Docker 测试套件: 41/43 通过（2 个预期警告）。

### v0.3.0-rc7

#### 🔀 重构
- **KPM 目录拆分为独立 Kpm-Repo**: 从 v0.3.0-rc7 起，反检测 KPM 套件不再
  内置于 PatchNest 模块中。源文件（`module/kpms/*.c`）已迁移至
  [Zhanfg/Kpm-Repo](https://github.com/Zhanfg/Kpm-Repo) 的 `modules/<id>/source.c`，
  并配对 `module.prop` 文件。Kpm-Repo 项目有独立的构建脚本、GitHub Actions
  发布工作流、签名基础设施和 README。
- **`DEFAULT_REPO_URL` 更新** 指向新的 Kpm-Repo:
  `https://raw.githubusercontent.com/Zhanfg/Kpm-Repo/main/kpm_repo.json`
- **`/data/adb/patchnest/repos.json` 系统覆盖**: PatchNest 现在优先读取此文件
  （如果存在）作为规范仓库列表。这允许 PatchNest Fork 打包非默认仓库。
- **WebUI "添加仓库" 流程** 不变 — 用户仍可添加多个 Fork 作为订阅。

### v0.3.0-rc6

#### 🔒 安全（ultracode 审计 2026-06-06）
- **KPM 签名密钥替换**: `module/kpm_verify.sh` 现在捆绑真实的 Ed25519 公钥
  （替换已知的 RFC 8032 测试密钥 1，其私钥公开，攻击者可伪造 .kpm.sig 文件）。
- **`update-check.js` zipUrl 注入修复**: 之前 `update.json` 的下载 URL 被未转义地
  插入 `exec()` shell 命令，通过恶意 update.json 打开 root-RCE 链。现已通过
  `sanitizeUrl` + `escapeShell` 消毒；非 http(s) URL 被拒绝。
- **`constants.js` `linkRedirect()` 同样加固**: 相同的未转义链接 shell-exec 漏洞。
- **`service.sh` `kpatch kpm load` 引号修复**: 添加 `--` 防止 $args 被解析为额外选项。
- **`install_kpm.sh` `MOD_ARGS` 消毒**: 使用与 service.sh 相同的 `tr -cd` 过滤器。
- **`exclude.js` EOF 标记** 现在使用 `crypto.getRandomValues`（8 字节 CSPRNG 熵）
  替代 `Date.now() + Math.random()`（可预测）。
- **`patch.js` `rm -f ${tmpPath}`** 已通过 `escapeShell` 处理。

#### ⚡ 健壮性
- **`version`/`versionCode`** 在 module.prop 和 update.json 中已更新为
  `v0.3.0-rc6` / `20`（之前停留在 `v0.2.4` / `19`）。
- **`update.json` zipUrl** 固定为 `v0.3.0-rc6`（之前为 `latest`，导致每次发布
  都会下载最新版本，破坏版本比较）。
- **更新检查 zipSha256 字段** 在 CI 写入真实值前已移除（之前是全零占位符）。

### v0.2.4

自 v0.2.2 以来累积的 30+ 个正确性、安全性和健壮性修复。完整列表：
https://github.com/Zhanfg/PatchNest-Module/pull/1

#### 🔒 安全
- **Shell 注入**: 用户控制的 shell 命令中的注入漏洞，涉及 `loadModule`、`cp`、
  `kpm_repo.js` URL、`exclude.js` CSV 写入器、`backup.js` 保存路径、`index.js` rehook 命令。
  所有路径现已消毒并使用 `escapeShell` / `sanitizeUrl` / 单引号 heredoc。
- **备份路径穿越**: 保存到存储时文件名已限制为 basename；`..` 被拒绝。
- **仓库下载大小限制**: curl 添加 `--max-filesize 50 MiB` 防御恶意仓库。

#### 🐛 关键修复
- **Flash 优先级 Bug** (`boot_patch.sh`): 旧的 `if [ -b ] || [ -c ] && [ -f ]` 会在
  `new-boot.img` 缺失时静默尝试刷写块设备。现在同时要求设备为块/字符设备且 `new-boot.img` 存在。
- **KPM 验证器丢弃首个 `-M <file>`** 参数: 因为迭代 0 时 `prev_flag` 为空。哨兵初始化修复。
- **编译器退出码被遮蔽** (`compile_kpm.sh`): `$?` 读取的是后续的 `[ "$ARCH" = "arm64-v8a" ]` 测试，
  而非编译器。使用显式 `compile_rc=$?` 捕获。
- **`magiskboot repack` 退出码误读** (`boot_patch.sh`): `$?` 读取的是下一个 `echo`。
  替换为 `if ! magiskboot ...`。
- **子 shell 管道 `while` 循环** (`service.sh`): 退出时丢失状态；替换为 here-doc 读取器。
  添加 5 分钟 `boot_completed` 超时防止损坏 ROM 上的无限循环。
- **5 秒无限循环** (`status.sh`): `boot_completed` 同样修复。
- **`find -o` 优先级 Bug** (`install_kpm.sh`): 匹配了 `.kpm` 目录和 `.bak` 文件。
  添加显式 `-type f \( -o -o \)`。

#### ⚡ 健壮性
- **Rehook 开关 UI** 现在在后端失败时回滚，而非让开关与状态不同步。
- **`initInfo` 显示 em-dash** 而非字面 `"undefined"`（当 `uname` 返回空时）。
- **`tail -200` → `tail -n 200`** (`log.js`): toybox 将前者解释为字节偏移。
- **`status.sh` 竞态**: `cat tmp > file` 与并发读取器之间；替换为 `mv`。
- **`status.sh` 自清理**: 使用 `readlink -f` 作为 `realpath` 的回退。
- **空 KPM 目录** 不再导致 for 循环对字面 `*.kpm` 字符串运行一次。
- **`MAX_CHUNK_SIZE`** 现在在上传开始前通过 await async 初始化；不再有竞态。
- **上传管道** 现在有 60 秒/块 + 120 秒/合并超时，尊重 AbortSignal。
- **下拉刷新** 要求单指手势；多指和 touchcancel 干净中止。
- **加载失败保留上传文件** 在 `modDir/tmp` 中供检查和重试。

#### 📦 构建 / 依赖
- `kpatch-next` 固定为 `0.13.5-2`（之前为 `latest` — 不可复现构建）。
- `pnpm build \|\| pnpm install && pnpm build` 优先级修复。
- `$ARGS_OPT` 和 `$SRC_FILES` 引号修复。

#### 📋 其他
- 新增 `KERNELPATCH_FORK_MAINTENANCE.md` 记录与上游 `bmax121/KernelPatch` 的关系。
- WebUI: 新版本首次启动时显示 "更新日志" 弹窗。
- WebUI: 主题切换 — 亮色 / 暗色 / 跟随系统。
- WebUI: 安全模式指示器 — 显示当前 KernelPatch 安全模式状态。

### v0.2.2

基于 KernelPatch 的 Magisk/KernelSU/ReSukiSU/APatch 内核补丁模块，
提供 KPM 内核模块系统、Root 管理和反检测功能。

#### 🌐 多 Root 管理器兼容
- 自动检测 Magisk / KernelSU / KernelSU-Next / ReSukiSU / SukiSU-Ultra / APatch
- WebUI 启动适配各管理器
- 安装说明根据管理器自动调整

#### 📦 KPM 用户体验（类 APM）
- **ZIP 一键安装**: `module.prop + .kpm/.ko/.o/.c` 打包为 zip，WebUI 直接上传安装
- **事件自动注册**: `module.prop` 中 `event=BOOT_COMPLETED,POST_FS_DATA`，开机自动触发
- **源码编译**: `compile_kpm.sh` 支持设备端 C 源码编译（TCC/clang/gcc）
- **KPM 在线仓库**: WebUI 内置仓库浏览器，支持自定义仓库 URL

#### 🔒 崩溃防护
- 连续 3 次启动失败自动进入安全模式
- ELF 预加载验证 + 故障 KPM 黑名单 + 嵌入式 KPM 保护

#### 🕶️ 完整隐藏系统
- 文件系统 umount、SELinux enforce/上下文隐藏、进程重命名

#### 🛡️ 内核侧功能
- App Profile 体系、SELinux 策略操作、KPM 事件系统、.o/.ko 格式支持
- 安全模式、内核兼容性: Linux 3.18 - 6.12+ (arm64)

#### 🖥️ WebUI
- 日志查看器、备份管理、KPM 仓库浏览器
- 15 种语言完整翻译（en, zh-CN, zh-TW, zh-HK, ja, ru, uk, de, fr, it, ar, bn, id, pt-BR, tr）
