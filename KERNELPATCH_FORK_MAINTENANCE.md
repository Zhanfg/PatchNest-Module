# KernelPatch-Public 维护说明

本文档记录 `Zhanfg/KernelPatch-Public` 与上游 `bmax121/KernelPatch` 的关系
及同步流程。

## Fork 状态(2026-06-05 快照)

| 字段 | 值 |
|---|---|
| 上游 | `bmax121/KernelPatch` @ `0ceeeb9`(2026-05-19) |
| 上游 0.13.1 | `ece212d2`(分叉点) |
| 本仓库 HEAD | `d52fc4e`(2026-05-31) |
| 共同祖先 | `ece212d2`(0.13.1) |
| 上游→本仓库 ahead | 0(全部 14 个上游 commit 已包含) |
| 本仓库→上游 ahead | 21(原创功能) |
| 状态 | `ahead` — 纯超集,无 merge conflict |

## 上游活跃分支

| 分支 | 距离 main | 状态 | 结论 |
|---|---|---|---|
| `main` | 0 | 0.13.3 稳定 | 14 commits 已同步 |
| `dev` | ahead 10 | 活跃开发 | **值得跟踪** — 多个 hook 改进(2025-02 最新) |
| `selinux` | behind 260 | 长期落后 | **不跟** — 内含 2018 年的旧代码 |
| `bmax/multi_fix` | ahead 4 | 实验性 | 可选 — kallsym 工具修复 |
| `bmax/fix_hook_func_startwith_pac` | ahead 2 | 实验性 | 可选 — PAC/BTI 支持 |

`dev` 是唯一值得定期跟的分支。

## 本仓库的原创功能(21 commits)

按重要性分组:

### 内核功能(14 commits)
- `feat: port KernelSU features to kernel/patch` — App Profile 体系
- `feat: KPM event system + .o/.ko format support + compact resolver`
- `feat: KPM crash protection system` + 嵌入式 KPM 保护
- `feat: SELinux status hiding` + 上下文隐藏
- `feat: root/module detection hiding system` + 进程重命名
- `feat: umount system`(execve 后自动卸载)

### CI / 构建(2 commits)
- `ci: replace upstream CI with simplified build workflow`
- `ci: add KPM static validation tests`
- `ci: workflow-dispatch only, major version releases`

### 修复(5 commits)
- 多个 include 修复 + memdup_user + vmalloc
- `.ko format full compatibility`
- `compact symbol table — fill non-constant addresses at init`

## 同步流程

### 1. 跟踪上游 main(每 2 周一次)

```bash
cd KernelPatch-Public
git remote add upstream https://github.com/bmax121/KernelPatch.git
git fetch upstream main

# 检查是否有新 commits 需要合并
git log --oneline upstream/main ^HEAD

# 如果有,且不会与 21 个原创 commit 冲突,rebase 上去
# (在公开 fork 中尚未发生过这种场景)
```

### 2. 检查上游 dev(每月一次)

```bash
git fetch upstream dev
git log --oneline upstream/dev ^HEAD
gh api 'repos/bmax121/KernelPatch/compare/main...dev' --jq '.commits[].message'
```

重点关注:
- `inlinehook` 重构 — 会影响 hook.c
- `pt_regs` 偏移维护 — 会影响所有 hook 实现
- `sucompat: skip compat-syscall` — 影响 32 位兼容

### 3. 同步检查清单

每次 fetch 后:
- [ ] `git diff upstream/main..HEAD --stat` 看到的就是 21 个原创 commit
- [ ] `git log upstream/main..HEAD --oneline` 与本表对照
- [ ] 如果上游 main 出现新 commit,评估:
  - 是 bug fix? → 同步
  - 是新功能? → 评估与本仓库原创功能是否重复
  - 是重构? → 评估冲突成本,通常跳过
- [ ] 如果要打新 tag(如 0.13.4),先在 `version` 文件更新

## 与 PatchNest-Module 的关系

`Zhanfg/PatchNest-Module` 通过以下方式使用本仓库的产物:

| 用途 | 文件 | 引用方式 |
|---|---|---|
| `kpimg` | 内核侧 patcher | `Zhanfg/KernelPatch-Public` release,模式 `kpimg-linux` |
| `kptools` | 用户态管理工具 | 同上,模式 `kptools-android` |
| 版本号 | `kernelpatch=0.13.3` | `version.properties` |

打新 tag 后,`PatchNest-Module` 这边要:
1. 更新 `version.properties` 的 `kernelpatch=`
2. 触发 CI(`workflow_dispatch`)
3. 验证 `validate_module.js` 通过
