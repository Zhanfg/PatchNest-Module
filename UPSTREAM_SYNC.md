# KernelPatch 上游同步状态

## 最后检查: 2026-06-06

### 结论

上游 dev 有 **2 个值得同步的变更**，其余为实验性代码：

| 文件 | diff | 优先级 | 动作 |
|---|---|---|---|
| `kernel/patch/common/secpass.c` | **无差异**(与 main 一致) | — | 已同步 |
| `kernel/patch/common/accctl.c` | **无差异**(与 main 一致) | — | 已同步 |
| `kernel/patch/common/sucompat.c` | **-8 行**: 移除了 `is_trusted_manager_uid` 判断,简化为 `is_su_allow_uid` | P1 | **值得同步** — 减少 manager-specific 逻辑,更通用 |
| `kernel/base/hook.c` | **+68/-55 行**: inlinehook 重构,改为在内核态计算 hook entry address,不再依赖函数序言扫描 | P2 | **值得同步** — 让 non-GKI 4.14+ 内核的 hook 更稳;但变化大,需测试 |
| `kernel/patch/include/uapi/scdefs.h` | 上游 dev 与 main 一致;我们的 fork 多出 27 个自定义 define(0x1120-0x1182) | — | 正常 |
| 其余 10+ 文件 | 无差异 | — | 已同步 |

### 推荐动作

1. **现在同步 `sucompat.c`** — 只删 3 行,改动极小,无风险。
2. **验证后同步 `hook.c`** — inlinehook 重构;需要在 3 种内核版本(4.14/5.10/6.1+)上测试 hook 是否正常。
3. **不跟 `dev` 分支其他实验性提交** — 这些是 dev-only 的开发中的功能(如 kcmd 重构、新的 ci 逻辑等),不适合生产。

### kptools -s 侧信道缓解 — **不适用**

上游 dev commit `ec82432` 是 `bmax121/KernelPatch` 的 kptools 改动(从 `-S <superkey>` 改为 `-s <superkey>`)。

但 **我们的 kptools 来自 `Zhanfg/PatchNest`**(不是 `bmax121/KernelPatch`)。PatchNest 的 kptools CLI 用法:

```c
optstr = "hvpurdfli:k:o:a:M:E:T:N:V:A:"
//      h v p u r d f l  i:k:o:a:M:E:T:N:V:A:
//      ^                  ^                          ^
//      help verbose     input  output  args         args
//      patch unpack     kernel  kpimg
//      repack delete
//      force
//      list
```

**superkey 是 `argv[1]` 位置参数,没有 `-S` 标志**。所以:
- 上游侧信道检测针对 `-S` argv 扫描 — 不适用
- 我们无需同步
- 这是不同 fork 架构的差异,不是 bug

**结论: 任务 E3 (kptools -s 移植) 关闭 — 不适用。**

---

## `hook.c` inlinehook 重构 — patch 准备就绪,等真机测试

上游 dev `bmax121/KernelPatch` 的 `kernel/base/hook.c` 有 `inlinehook` 重构(+68/-55, 794→816 行)。改动是渐进的,可以 cherry-pick,**但需要 3 个内核版本(4.14/5.10/6.1+)真机测试才能合并到生产 fork**。本仓库无交叉编译器,所以没有直接 port 到我们的 fork。

### 改动清单

**`kernel/include/hook.h`** — 宏重命名:

```diff
-#define TRAMPOLINE_MAX_NUM 6
-#define RELOCATE_INST_NUM (4 * 8 + 8 - 4)
+#define TRAMPOLINE_NUM 4
+#define RELOCATE_INST_NUM (TRAMPOLINE_NUM * 8 + 8)
 
 ...
 
-#define ARM64_PACIASP 0xd503233f
-#define ARM64_PACIBSP 0xd503237f
 ...
-    uint32_t origin_insts[TRAMPOLINE_MAX_NUM] __attribute__((aligned(8)));
-    uint32_t tramp_insts[TRAMPOLINE_MAX_NUM] __attribute__((aligned(8)));
+    uint32_t origin_insts[TRAMPOLINE_NUM] __attribute__((aligned(8)));
+    uint32_t tramp_insts[TRAMPOLINE_NUM] __attribute__((aligned(8)));
```

**`kernel/base/hook.c`** — 5 处改动:

1. **Include 顺序** — `io.h` / `symbol.h` 改成前移到 `cache.h` 之后:
   ```diff
   -#include <io.h>
   -#include <symbol.h>
   +#include <cache.h>
    ...
   -#include <hotpatch.h>
   +#include <io.h>
   +#include <symbol.h>
   ```

2. **BTI/PAC 检查简化** (line 121):
   ```diff
   -    } else if (inst == ARM64_BTI_C || inst == ARM64_BTI_J ||
   -               (inst == ARM64_BTI_JC && !hook_get_mem_from_origin(addr))) {
   +    } else if (inst == ARM64_BTI_C || inst == ARM64_BTI_J || inst == ARM64_BTI_JC) {
   ```

3. **移除 `current_inline_hook_chain()` 宏** (line 346-351) — 改用 `adr` + NOP 反扫。

4. **4 个 `current_inline_hook_chain()` 调用点替换为**(line 354-355, 383-384, 418-419, 459-460):
   ```diff
   -    hook_chain_t *hook_chain = current_inline_hook_chain();
   -    if (!hook_chain) return 0;
   +    uint64_t this_va;
   +    asm volatile("adr %0, ." : "=r"(this_va));
   +    uint32_t *vptr = (uint32_t *)this_va;
   +    while (*--vptr != ARM64_NOP) {
   +    };
   +    vptr--;
   +    hook_chain_t *hook_chain = local_container_of((uint64_t)vptr, hook_chain_t, transit);
   ```

5. **trampoline 设置简化** (line 560-566):
   ```diff
   -    if (hook->origin_insts[0] == ARM64_PACIASP || hook->origin_insts[0] == ARM64_PACIBSP) {
   -        hook->tramp_insts_num = branch_from_to(&hook->tramp_insts[1], hook->origin_addr, hook->replace_addr);
   -        hook->tramp_insts[0] = ARM64_BTI_JC;
   -        hook->tramp_insts_num++;
   -    } else {
   -        hook->tramp_insts_num = branch_from_to(hook->tramp_insts, hook->origin_addr, hook->replace_addr);
   -    }
   +    hook->tramp_insts_num = branch_from_to(hook->tramp_insts, hook->origin_addr, hook->replace_addr);
   ```

6. **TRAMPOLINE 宏调用替换**:
   ```diff
   -    for (int i = 0; i < TRAMPOLINE_MAX_NUM; i++) {
   +    for (int i = 0; i < TRAMPOLINE_NUM; i++) {
   ...
   -    void *addrs[TRAMPOLINE_MAX_NUM];
   +    void *addrs[TRAMPOLINE_NUM];
   ```

### 应用步骤(等你 sync private fork 时)

```bash
# 在 Zhanfg/KernelPatch-Public 本地克隆里
cd kernel/base
curl -sL https://raw.githubusercontent.com/bmax121/KernelPatch/dev/kernel/base/hook.c > hook.c
# 然后修复宏名(因为 hook.h 是我们 fork 的)
sed -i 's/TRAMPOLINE_NUM/TRAMPOLINE_MAX_NUM/g' hook.c
sed -i 's/ARM64_PACIASP.*//g; s/ARM64_PACIBSP.*//g' hook.c
cd ../include
# 保留我们的 hook.h (因为有额外的原创字段)
# 只同步 TRAMPOLINE_NUM = 4 这个值
sed -i 's/TRAMPOLINE_MAX_NUM 6/TRAMPOLINE_MAX_NUM 4/g' hook.h
# 在 3 个内核版本上测试 boot + module load + unload
```

### 风险

- **`adr` + NOP 反扫**: 现代内核(5.10+)工作良好;**4.14 老内核某些编译器布局可能不稳**,需要真机验证
- **`TRAMPOLINE_MAX_NUM` 6 → 4**: 减少 trampoline 槽位,某些超长函数 prologue 可能放不下
- **PAC/IBTI 简化**: 我们 fork 在某些 6.x 内核上还依赖 PAC 修复路径,简化后会失去这个能力

**结论: patch 准备好,但合并需要真机测试。本仓库不动 fork 代码。**

### 上游 git log (dev, 最近 10 个)

```
8c2d2ae  sucompat: change to inlinehook, skip calculate sizeof pt_regs
decaf80  skip calculate sizeof struct pt_regs
3d9bdeb  su command: fuck compat compat-syscall for 32-bits
6f1781a  fix: hook input_handle_event
cbd6d6d  maintain pt_regs offset
221a3d5  kpatch is deprecated, instead is supercmd; hook improved; add thread local interface
e33d3a6  supercall: Fix super key authentication (#99)
6c59ee8  supercall: Add SUPERCALL_SU_GET_SAFEMODE (#101)
ec82432  kptools with -s instead of -S, to avoid side-channel detection
4455d14  disable hash superkey after reset key
```
