#!/system/bin/sh
#
# KPM Source Compiler
# Usage: compile_kpm.sh <source_dir> <output.kpm> [moddir]
#
# Compiles .c source files into a .kpm/.o module using TCC or system compiler.
# Requires: tcc-android (bundled) or clang/gcc on device.
#

SRC_DIR="$1"
OUTPUT="$2"
MODDIR="${3:-$(dirname "$0")}"
KPNDIR="/data/adb/kp-next"
LOG="$KPNDIR/service.log"
PATH="$MODDIR/bin:$PATH"

log() {
    echo "[$(date)] compile_kpm: $1" >> "$LOG"
    echo "- $1"
}

if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
    echo "! Source directory not found: $SRC_DIR"
    exit 1
fi

# Find .c source files
SRC_FILES=$(find "$SRC_DIR" -name "*.c" -type f 2>/dev/null)
if [ -z "$SRC_FILES" ]; then
    echo "! No .c source files found"
    exit 1
fi

# Determine compiler: prefer TCC, fallback to clang/gcc
COMPILER=""
if command -v tcc >/dev/null 2>&1; then
    COMPILER="tcc"
elif [ -x "$MODDIR/bin/tcc" ]; then
    COMPILER="$MODDIR/bin/tcc"
elif command -v clang >/dev/null 2>&1; then
    COMPILER="clang"
elif command -v gcc >/dev/null 2>&1; then
    COMPILER="gcc"
fi

if [ -z "$COMPILER" ]; then
    log "No compiler found (need tcc, clang, or gcc)"
    echo "! No C compiler available on device"
    echo "  Install TCC: push tcc to $MODDIR/bin/tcc"
    exit 1
fi

log "Using compiler: $COMPILER"

# KPM header directory
KPM_INCLUDE="$KPNDIR/include"
mkdir -p "$KPM_INCLUDE"

# If kpmodule.h not present, create a minimal version
if [ ! -f "$KPM_INCLUDE/kpmodule.h" ]; then
    log "Creating minimal kpmodule.h"
    cat > "$KPM_INCLUDE/kpmodule.h" << 'HEADER'
#ifndef _KP_KPMODULE_H_
#define _KP_KPMODULE_H_

#define KPM_INFO(name, info, limit)                                 \
    _Static_assert(sizeof(info) <= limit, "Info string too long");  \
    static const char __kpm_info_##name[] __attribute__((__used__)) \
    __attribute__((section(".kpm.info"), unused, aligned(1))) = #name "=" info

#define KPM_NAME_LEN 32
#define KPM_VERSION_LEN 32
#define KPM_LICENSE_LEN 32
#define KPM_AUTHOR_LEN 32
#define KPM_DESCRIPTION_LEN 512
#define KPM_ARGS_LEN 1024

#define KPM_NAME(x) KPM_INFO(name, x, KPM_NAME_LEN)
#define KPM_VERSION(x) KPM_INFO(version, x, KPM_VERSION_LEN)
#define KPM_LICENSE(x) KPM_INFO(license, x, KPM_LICENSE_LEN)
#define KPM_AUTHOR(x) KPM_INFO(author, x, KPM_AUTHOR_LEN)
#define KPM_DESCRIPTION(x) KPM_INFO(description, x, KPM_DESCRIPTION_LEN)

typedef long (*mod_initcall_t)(const char *args, const char *event, void *reserved);
typedef long (*mod_ctl0call_t)(const char *ctl_args, char *out_msg, int outlen);
typedef long (*mod_ctl1call_t)(void *a1, void *a2, void *a3);
typedef long (*mod_exitcall_t)(void *reserved);

#define KPM_INIT(fn) \
    static mod_initcall_t __kpm_initcall_##fn __attribute__((__used__)) __attribute__((__section__(".kpm.init"))) = fn
#define KPM_CTL0(fn) \
    static mod_ctl0call_t __kpm_ctlmodule_##fn __attribute__((__used__)) __attribute__((__section__(".kpm.ctl0"))) = fn
#define KPM_CTL1(fn) \
    static mod_ctl1call_t __kpm_ctlmodule_##fn __attribute__((__used__)) __attribute__((__section__(".kpm.ctl1"))) = fn
#define KPM_EXIT(fn) \
    static mod_exitcall_t __kpm_exitcall_##fn __attribute__((__used__)) __attribute__((__section__(".kpm.exit"))) = fn

#endif
HEADER
fi

# Compile
# For TCC: compile to ELF relocatable .o
# For clang/gcc: cross-compile for aarch64

TMPDIR=$(mktemp -d /tmp/kpm_build.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

OBJ_FILE="$TMPDIR/module.o"
# P1-Cluster B fix: add -fPIC so clang/aarch64 doesn't fail on .kpm
# relocations. Also keep -O2 so -O0 doesn't make verification slow.
CFLAGS="-nostdinc -nostdlib -fno-builtin -fno-stack-protector -fPIC -O2 -I$KPM_INCLUDE -I$SRC_DIR"

if [ "$COMPILER" = "tcc" ]; then
    # TCC: simple compile to .o
    # shellcheck disable=SC2086  # SRC_FILES is intentionally word-split (one flag per file)
    $COMPILER -c $CFLAGS -o "$OBJ_FILE" $SRC_FILES
    compile_rc=$?
else
    # clang/gcc: need aarch64 target
    ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
    if [ "$ARCH" = "arm64-v8a" ]; then
        # Native compilation on arm64 device
        # shellcheck disable=SC2086
        $COMPILER -c $CFLAGS -o "$OBJ_FILE" $SRC_FILES
        compile_rc=$?
    else
        echo "! Cross-compilation not supported on $ARCH architecture"
        exit 1
    fi
fi

if [ "$compile_rc" -ne 0 ] || [ ! -f "$OBJ_FILE" ]; then
    log "Compilation failed (rc=$compile_rc)"
    echo "! Compilation failed"
    exit 1
fi

# Copy output
cp "$OBJ_FILE" "$OUTPUT"
log "Compiled successfully: $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
echo "- Compiled: $(basename "$OUTPUT")"
