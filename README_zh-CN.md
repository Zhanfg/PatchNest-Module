# PatchNest Module

[English](README.md) | **中文**

适用于 Magisk / KernelSU / APatch 的 KPM 独立实现

---

## KPM 模块仓库

KPM（KernelPatch 模块）通过独立的 **Kpm-Repo** 项目分发。添加或移除 KPM 无需重新构建 PatchNest。

**默认仓库**: [Zhanfg/Kpm-Repo](https://github.com/Zhanfg/Kpm-Repo)

### 使用默认仓库

打开 PatchNest WebUI → **KPM 仓库** → 首次运行时自动拉取默认清单。

### 添加自定义/Fork 仓库

1. Fork [Zhanfg/Kpm-Repo](https://github.com/Zhanfg/Kpm-Repo)
2. 在 `modules/<id>/` 中添加你的 KPM 源码（参见
   [Kpm-Repo README](https://github.com/Zhanfg/Kpm-Repo#add-your-own-kpm)）
3. Push 到 `main` — GitHub Actions 会自动编译、签名并发布 `.kpm` ZIP
4. 在 PatchNest WebUI → **KPM 仓库** → **添加仓库**
5. 粘贴你的 Fork 清单 URL：
   ```
   https://raw.githubusercontent.com/<your-username>/Kpm-Repo/main/kpm_repo.json
   ```

完整 Fork 指南: [Kpm-Repo README](https://github.com/Zhanfg/Kpm-Repo)

### 在 PatchNest Fork 中打包自定义默认仓库

如果你维护了一个 PatchNest Fork，并想打包一个非默认的 KPM 仓库（例如指向你自己的 Kpm-Repo Fork）：

1. 同时 Fork [PatchNest-Module](https://github.com/Zhanfg/PatchNest-Module)
   和 [Kpm-Repo](https://github.com/Zhanfg/Kpm-Repo)
2. 在你的 PatchNest Fork 中，在模块根目录创建 `repos.json` 文件：
   ```json
   [{ "url": "https://raw.githubusercontent.com/<you>/Kpm-Repo/main/kpm_repo.json",
      "name": "Acme KPMs" }]
   ```
3. 重新构建 PatchNest 模块。`customize.sh` 安装器会将 `repos.json` 复制到
   设备上的 `/data/adb/patchnest/repos.json`；WebUI 会优先读取此文件。

---

## 功能特性

- **KPM 模块系统**: 内核模块加载、事件回调、源码编译
- **多 Root 管理器**: Magisk / KernelSU / KernelSU-Next / APatch 自动适配
- **崩溃防护**: 启动计数器、ELF 预验证、故障 KPM 黑名单
- **隐藏系统**: 文件系统 umount、SEL enforce/上下文隐藏、进程重命名
- **WebUI**: 15 种语言、日志查看器、备份管理、KPM 仓库浏览器
- **内核兼容性**: Linux 3.18 - 6.12+ (arm64)

## 仓库架构

| 仓库 | 可见性 | 用途 |
|------|--------|------|
| `Zhanfg/KernelPatch` | 私有 | 开发，commit 级版本 |
| `Zhanfg/KernelPatch-Public` | 公开 | 稳定大版本发布 (0.13.x) |
| `Zhanfg/PatchNest-Module` | 公开 | 模块发布，CI 自动构建 |
| `Zhanfg/PatchNest` | 公开 | kpatch 用户态工具二进制 |
| `Zhanfg/Kpm-Repo` | 公开 | KPM 模块目录仓库 |

## 鸣谢

- 补丁脚本来自 [APatch](https://github.com/bmax121/APatch)
- PatchNest 二进制来自 [Zhanfg/PatchNest](https://github.com/Zhanfg/PatchNest)
- magiskboot 二进制来自 [Magisk](https://github.com/topjohnwu/Magisk)

## 许可证

- PatchNest-Module 采用 GNU 通用公共许可证 v3 [GPL-3.0](/LICENSE)
- PatchNest 二进制采用 GNU 通用公共许可证 v2 [GPL-2.0](https://www.gnu.org/licenses/gpl-2.0.html)
- magiskboot 二进制来自 Magisk，采用 [GPL-3.0](https://github.com/topjohnwu/Magisk/blob/master/LICENSE)
- WebUI 采用 MIT 许可证 [MIT](/webui/LICENSE)
