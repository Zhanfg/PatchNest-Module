# KPM source build policy

PatchNest does not compile imported KPM source code on the Android device.

## Reason

The module and WebUI run with root privileges. Passing untrusted C source to a
local `tcc`, `clang`, or `gcc` process is not a sandbox:

- the preprocessor and assembler can read absolute local paths;
- source can encode local file contents into the produced object;
- compiler/parser vulnerabilities execute in a root process;
- locally discovered compilers and headers are mutable build inputs;
- the resulting artifact is not reproducible or attributable to a source
  commit and fixed SDK/toolchain;
- a successful compile does not prove that the object is a valid or safe KPM.

Therefore `module/compile_kpm.sh` is a fail-closed policy stub. It records the
rejected request and exits non-zero without invoking a compiler.

## Required build flow

A KPM intended for PatchNest must be built outside the target device:

1. select an immutable KernelPatch SDK commit;
2. select and hash an immutable AArch64 toolchain;
3. build in a clean directory;
4. inspect the ELF header, sections, relocations, and KPM metadata;
5. verify the artifact with the matching `kptools`;
6. record source repository, source commit, SDK commit, toolchain identity,
   artifact size, and SHA-256;
7. sign the exact artifact with the release signing process;
8. package exactly one `.kpm`, its signature, and bounded metadata;
9. test load, control, unload, failure isolation, and reboot behavior on a
   physical device before adding it to an installable catalog.

## Device behavior

A ZIP containing source but no binary will be rejected. A ZIP containing both
source and a binary is also rejected because the review target would be
ambiguous. PatchNest only admits the already-built `.kpm` artifact after format
and signature checks.

## Re-enabling source builds

On-device source compilation may be reconsidered only if there is a separately
audited, non-root sandbox with:

- no access to Android data, block devices, properties, credentials, or module
  state;
- immutable compiler and SDK images;
- strict CPU, memory, file-size, time, and syscall limits;
- deterministic output and complete provenance;
- no package-provided build scripts;
- independent output validation.

A normal Android root shell, namespace, chroot, proot, or temporary directory
does not satisfy this requirement.
