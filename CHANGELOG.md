# KPatch Next Module

## Changelog

### v0.3.0-rc6

#### 🔒 Security (ultracode-audit 2026-06-06)
- **KPM signing key replaced**: `module/kpm_verify.sh` now bundles a real Ed25519
  public key (replacing the well-known RFC 8032 Test 1 key, whose private half
  is public and would have let any attacker forge .kpm.sig files). The
  matching private key is held out-of-band and is NOT in the repo. Probe
  vector updated to match.
- **`update-check.js` zipUrl injection fixed**: previously the download URL
  from `update.json` was interpolated into an `exec()` shell command
  unescaped, opening a root-RCE chain via a malicious update.json. Now
  sanitized through `sanitizeUrl` + `escapeShell`; non-http(s) URLs are
  rejected.
- **`constants.js` `linkRedirect()` also hardened**: same unescaped-link
  shell-exec sink.
- **`service.sh` `kpatch kpm load` quoted**: added `--` so $args cannot be
  parsed as additional kpatch options. Args are already sanitized.
- **`install_kpm.sh` `MOD_ARGS` sanitized** with the same `tr -cd
  'A-Za-z0-9_=,.+:/@% -'` filter service.sh uses; `kpatch kpm load` is now
  called with `--` and quoted args.
- **`exclude.js` EOF markers** now use `crypto.getRandomValues` (8 bytes
  of CSPRNG entropy) instead of `Date.now() + Math.random()` (predictable).
  The previous PR3 commit claimed this fix; this is the real one.
- **`patch.js` `rm -f ${tmpPath}`** is now `escapeShell`'d.

#### ⚡ Robustness
- **`version`/`versionCode`** in `module.prop` and `update.json` bumped to
  `v0.3.0-rc6` / `20` (was stuck at `v0.2.4` / `19` despite the rc tag).
- **`update.json` zipUrl** pinned to `v0.3.0-rc6` (was `latest`, which
  means every release would have downloaded whatever the most-recent
  published zip was, defeating the version compare).
- **Update-check zipSha256 field** removed until CI stamps the real value
  (was all-zeros placeholder that v0.2.5 release would have shipped).

### v0.2.4

30+ correctness, security, and robustness fixes accumulated since v0.2.2. Highlights below; full list at https://github.com/Zhanfg/KPatch-Next-Module/pull/1

#### 🔒 Security
- **Shell injection** in user-controlled shell commands: `loadModule`, `cp`, `kpm_repo.js` URL, `exclude.js` CSV writer, `backup.js` save path, `index.js` rehook command. All paths now sanitize input and use `escapeShell` / `sanitizeUrl` / single-quoted heredocs.
- **Backup path traversal** in save-to-storage: filename is now stripped to basename only; `..` rejected.
- **Repo download size cap**: `--max-filesize 50 MiB` on curl to defend against malicious or compromised repos.

#### 🐛 Critical fixes
- **Flash guard precedence bug** in `boot_patch.sh`: the old `if [ -b ] || [ -c ] && [ -f ]` would silently attempt to flash block-device boot images even when `new-boot.img` was missing. Now requires both the device to be a block/char device AND `new-boot.img` to exist.
- **KPM validator silently dropped the first `-M <file>`** argument because `prev_flag` was empty on iteration 0. Sentinel initialization fixes it; also dropped the bogus b700 big-endian aarch64 check.
- **Compiler exit code masked** in `compile_kpm.sh`: `$?` read the subsequent `[ "$ARCH" = "arm64-v8a" ]` test, not the compiler. Explicit `compile_rc=$?` capture.
- **`magiskboot repack` exit code misread** in `boot_patch.sh`: `$?` was reading the next `echo`, not magiskboot. Replaced with `if ! magiskboot ...`.
- **Subshell-piped `while` loop** in `service.sh` lost state on exit; replaced with here-doc reader. Also added 5-minute `boot_completed` timeout to prevent infinite loop on broken ROMs.
- **5-second infinite loop** in `status.sh` for `boot_completed` — same fix.
- **`find -o` precedence bug** in `install_kpm.sh` matched `.kpm` directories and `.bak` files. Added explicit `-type f \( -o -o \)`.

#### ⚡ Robustness
- **Rehook switch UI** now rolls back on backend failure instead of leaving the toggle out of sync.
- **`initInfo` shows em-dash** instead of literal `"undefined"` when `uname` returns empty.
- **`tail -200` → `tail -n 200`** in `log.js` (toybox interprets the former as byte offset).
- **`status.sh` race** between `cat tmp > file` and concurrent readers; replaced with `mv`. Sed delimiter changed to `|` so values with `/` don't break it.
- **`status.sh` self-cleanup** uses `readlink -f` fallback for `realpath` (not on all toybox builds).
- **Empty KPM directory** no longer makes the for-loop run once against a literal `*.kpm` string.
- **`MAX_CHUNK_SIZE`** is now initialized via awaited async before uploads can start; no more race.
- **Upload pipes** now have 60s/chunk + 120s/combine timeouts and respect AbortSignal so an aborted upload kills orphan base64 pipes.
- **Pull-to-refresh** requires single-finger gestures; multi-finger and touchcancel abort cleanly.
- **Load failure preserves the uploaded file** in `modDir/tmp` for inspection and retry.
- **`kpmItemMap` prunes stale entries** on each render so a renamed module doesn't leave a stale listener bound to the old name.
- **3-click KSUWebUIStandalone redirect** fires at most once per session.
- **DEV short-circuit** in `parseBootimg` no longer skips `renderKpmList()` — dev UI now matches prod.

#### 📦 Build / dependencies
- `kpatch-next` pinned to `0.13.5-2` (was `latest` — non-reproducible builds).
- `pnpm build || pnpm install && pnpm build` precedence fix.
- `$ARGS_OPT` and `$SRC_FILES` quoting fixes in `install_kpm.sh` / `compile_kpm.sh`.

#### 📋 Misc
- New `KERNELPATCH_FORK_MAINTENANCE.md` documenting the relationship with the upstream `bmax121/KernelPatch` and how to sync.
- WebUI: "What's New" changelog modal on first launch of a new version.
- WebUI: theme toggle — light / dark / follow system (persists in localStorage).
- WebUI: safe mode indicator — shows current KernelPatch safe-mode state (uses new
  kp-safemode helper binary, cross-compiled with Android NDK in CI).
- `module.bin` arm64 test workflow unchanged.

#### Credits
- APatch boot scripts (vendored, with our patches).
- bmax121/KernelPatch upstream.
- KernelSU-Next/KPatch-Next.

### v0.2.2

基于 KernelPatch 的 Magisk/KernelSU/ReSukiSU/APatch 内核补丁模块，提供 KPM 内核模块系统、Root 管理和反检测功能。

#### 🌐 多 Root 管理器兼容
- 自动检测 Magisk / KernelSU / KernelSU-Next / ReSukiSU / SukiSU-Ultra / APatch
- WebUI 启动适配各管理器（KSUWebUIStandalone / KernelSU / APatch 原生 WebUI）
- Magisk 用户可通过 KSUWebUIStandalone 使用完整功能
- 安装说明根据管理器自动调整

#### 📦 KPM 用户体验（类 APM）
- **ZIP 一键安装**: `module.prop + .kpm/.ko/.o/.c` 打包为 zip，WebUI 直接上传安装
- **事件自动注册**: `module.prop` 中 `event=BOOT_COMPLETED,POST_FS_DATA`，开机自动触发
- **参数传递**: `args=--option` 自动传递给 KPM init
- **源码编译**: `compile_kpm.sh` 支持设备端 C 源码编译（TCC/clang/gcc）
- **KPM 在线仓库**: WebUI 内置仓库浏览器，支持自定义仓库 URL
- **自动加载**: `autoLoad=true` 开机自动加载

#### 🔒 崩溃防护
- **启动计数器**: 连续 3 次启动失败自动进入安全模式
- **ELF 预加载验证**: 加载前检查 ELF 格式、架构、类型
- **故障 KPM 黑名单**: 崩溃的 KPM 自动跳过
- **嵌入式 KPM 保护**: 补丁时验证 + `/dev/.kp_bootcount` 早期计数器
- **KPM 安全加载**: 加载失败移至 `failed/` 目录而非删除

#### 🕶️ 完整隐藏系统
- **文件系统隐藏**: 可配置 umount 路径列表，execve 后自动卸载
- **SELinux enforce 隐藏**: hook `sel_read_enforce`，返回原始状态
- **SELinux 上下文隐藏**: hook `proc_pid_attr_read`，替换 root context 为应用 context
- **进程名重命名**: `proc_hide_rename_current()` 将 kpatch/kptools 改为 kworker

#### 🛡️ 内核侧功能（私有 KernelPatch fork）
- **App Profile 体系**: per-app root/non-root profiles，支持自定义 uid/gid/groups/capabilities/SELinux domain
- **SELinux 策略操作**: 运行时 allow/deny/type_transition/genfscon
- **KPM 事件系统**: 结构化事件回调，compact 符号解析器
- **.o/.ko 格式支持**: 标准内核模块格式加载，modinfo 元数据解析
- **安全模式**: `SUPERCALL_SET_SAFEMODE` 阻止所有 SU 和 KPM
- **内核兼容性**: Linux 3.18 - 6.12+ (arm64)

#### 🖥️ WebUI
- **日志查看器**: 实时查看 `service.log`
- **备份管理**: 列出/保存/删除 boot 备份
- **KPM 仓库浏览器**: 在线浏览和安装 KPM 模块
- **仓库 URL 配置**: Settings → Repository 可自定义地址
- **15 种语言**: 完整翻译（en, zh-CN, zh-TW, zh-HK, ja, ru, uk, de, fr, it, ar, bn, id, pt-BR, tr）
- **智能语言识别**: 自动匹配系统语言，支持中文变体检测
- **白屏修复**: 5 秒兜底超时 + `kernelsu-alt` 容错

#### 🏗️ 构建与 CI
- **双二进制源**: kpimg/kptools 来自 KernelPatch-Public，kpatch 来自 KPatch-Next
- **CI 测试体系** (7 类 60+ 项检查):
  - ShellCheck + bash 语法检查
  - 配置一致性验证 (module.prop / update.json / version.properties)
  - 15 语言 locale 完整性
  - KPM 测试文件 ELF 静态验证
  - 模块包完整性 (二进制/脚本/WebUI/交叉引用)
  - 自动 GitHub Release 发布

#### 📁 仓库架构
| 仓库 | 可见性 | 用途 |
|------|--------|------|
| `Zhanfg/KernelPatch` | 私有 | 开发，commit 级版本 |
| `Zhanfg/KernelPatch-Public` | 公开 | 稳定大版本发布 (0.13.x) |
| `Zhanfg/KPatch-Next-Module` | 公开 | 模块发布，CI 自动构建 |

#### 🔧 Supercall 接口
| ID | 功能 |
|----|------|
| 0x1120-0x1123 | App Profile GET/SET/LIST/NUM |
| 0x1130 | SELinux 策略操作 |
| 0x1140 | 安全模式开关 |
| 0x1150 | KPM 事件分发 |
| 0x1160-0x1163 | Umount 路径管理 |
| 0x1170 | 进程重命名 |
| 0x1180-0x1182 | 崩溃防护状态/黑名单 |

#### 基于
- [bmax121/KernelPatch](https://github.com/bmax121/KernelPatch) v0.13.1
- 参考: [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU), [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra), [KernelSU](https://github.com/tiann/KernelSU), [APatch](https://github.com/bmax121/APatch)
- magiskboot 来自 [Magisk](https://github.com/topjohnwu/Magisk) v30.7
