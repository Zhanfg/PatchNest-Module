#!/system/bin/sh
# PatchNest KPM source compilation policy.
#
# On-device compilation of an imported ZIP is intentionally disabled. The
# compiler would run as root against attacker-controlled C/preprocessor input;
# that is not a security boundary and can expose local files or compiler bugs.
# Build KPMs off-device against a pinned KernelPatch SDK/toolchain, record the
# source commit and artifact SHA-256, then install the verified `.kpm` binary.

set -u
umask 077

PNDIR=/data/adb/patchnest
LOG="$PNDIR/service.log"
SRC_DIR=${1:-}
OUTPUT=${2:-}

mkdir -p "$PNDIR" 2>/dev/null || true
printf '[%s] compile_kpm: rejected on-device source build; source=%s output=%s\n' \
    "$(date)" "$(basename "${SRC_DIR:-unset}")" "$(basename "${OUTPUT:-unset}")" \
    >>"$LOG" 2>/dev/null || true

cat >&2 <<'EOF'
! On-device KPM source compilation is disabled.
  Build the module off-device using a pinned KernelPatch SDK and toolchain.
  Verify the resulting ARM64 relocatable .kpm with kptools, record its SHA-256,
  and install the binary package instead.
EOF

exit 1
