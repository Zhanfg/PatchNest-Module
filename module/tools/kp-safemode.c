// SPDX-License-Identifier: GPL-2.0
// kp-safemode: minimal helper to query Android safe-mode state via the
// KernelPatch supercall. Prints "0" or "1" on stdout. Exits 0 on success.
//
// Why a separate binary: kpatch (from Zhanfg/PatchNest) does not
// expose a "safemode" subcommand. SUPERCALL_SU_GET_SAFEMODE (0x1112) is
// implemented in the kernel side of Zhanfg/KernelPatch-Public (and
// upstream bmax121/KernelPatch). This helper makes that one supercall
// reachable from a shell.
//
// Build: see build.sh (cross-compile with Android NDK clang).
// Run: must be root (same as kpatch).

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

// Mirrored from kernel/patch/include/uapi/scdefs.h. Keep in sync if upstream
// renumbers. (Last verified: bmax121/KernelPatch main @ 0ceeeb9.)
#define KP_NR_SUPERCALL 45
#define SUPERCALL_KERNELPATCH_VER 0x1008
#define SUPERCALL_SU_GET_SAFEMODE 0x1112

// The version-token magic (0x1158) is the same constant kpatch uses; see
// ver_and_cmd() in upstream user/supercall.h.
#define KP_VERSION_TOKEN 0x1158

// Build the (version_code << 32) | (token << 16) | cmd word.
static long make_cmd(uint32_t version_code, int cmd)
{
    return ((long)version_code << 32) | ((long)KP_VERSION_TOKEN << 16) | (cmd & 0xFFFF);
}

// Probe the installed kernelpatch version. The kernel returns 0 on a
// non-patched device, otherwise the version code (e.g. 0x0d02 = 0.13.2).
// We pass a placeholder version_code=0; the kernel only uses it for newer
// versions and otherwise falls back to raw cmd.
static long probe_kp_version(void)
{
    return syscall(KP_NR_SUPERCALL, "su", make_cmd(0, SUPERCALL_KERNELPATCH_VER));
}

int main(void)
{
    long kpver = probe_kp_version();
    if (kpver < 0) {
        int saved_errno = errno;
        // Not installed, or no permission. kpatch's hello() returns the same
        // negative values; the WebUI will display "Not installed" when this
        // helper exits non-zero.
        fprintf(stderr, "supercall failed: errno=%d (%s)\n", saved_errno, strerror(saved_errno));
        return 1;
    }

    // SUPERCALL_SU_GET_SAFEMODE returns int (0/1) from android_is_safe_mode.
    // For older kernelpatch (< 0xa05) the kernel may not understand the
    // versioned cmd; in that case kpver would itself be a sensible response.
    long result = syscall(KP_NR_SUPERCALL, "su",
                          make_cmd((uint32_t)kpver, SUPERCALL_SU_GET_SAFEMODE));
    if (result < 0) {
        int saved_errno = errno;
        fprintf(stderr, "safemode supercall returned %ld (errno=%d %s)\n",
                result, saved_errno, strerror(saved_errno));
        return 1;
    }

    printf("%ld\n", result);
    return 0;
}
