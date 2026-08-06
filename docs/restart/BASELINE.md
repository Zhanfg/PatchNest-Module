# PatchNest restart baseline

Baseline date: 2026-08-06

## Scope

This branch restores a trustworthy build baseline before feature work resumes. It does not publish a new release and does not change the installed module version.

## Confirmed repository topology

| Repository | Responsibility | Current restart status |
|---|---|---|
| `Zhanfg/PatchNest-Module` | Root-manager module, WebUI, packaging and update entry point | Baseline repair in progress |
| `Zhanfg/KernelPatch-Public` | `kpimg` and `kptools` source/releases | Release assets available; source/release provenance review pending |
| `Zhanfg/PatchNest` | `kpatch-android` release | Binary exists; reproducible source restoration pending |
| `Zhanfg/PatchNest-Kpms` | KPM source and catalog | Catalog and release pipeline repair pending |

## Baseline defects confirmed

1. `module/module.prop` used `0.4.1-rc2` while `update.json` used `v0.4.1-rc2`, causing both configuration checks to fail.
2. The build and release jobs skipped after the configuration failure.
3. Dependency hashes in `version.properties` did not match the currently published release assets.
4. SHA verification was configured with `continue-on-error`, allowing a failed trust check to be ignored.
5. The Magisk APK key used by local and CI builds was inconsistent, so local builds could silently skip APK verification.
6. Release automation treated the internal version as the Git tag instead of deriving `v<version>`.
7. Two overlapping workflows implemented different validation policies.
8. A device log archive was accidentally tracked in the repository root.
9. Documentation still referenced the retired `Kpm-Repo` name in several places.

## Changes in this baseline branch

- Removed the accidentally committed device log archive.
- Added ignore rules for logs and temporary diagnostic archives.
- Normalized the internal version to `0.4.1-rc2`; the release tag remains `v0.4.1-rc2`.
- Refreshed trusted SHA256 values for:
  - `kpimg-linux` `0.13.3`
  - `kptools-android` `0.13.3`
  - `kpatch-android` `0.13.5-2`
  - `Magisk-v30.7.apk`
- Made local dependency verification fail closed.
- Replaced the duplicate CI workflows with one PR/push pipeline.
- Added hard dependency verification, ARM64 checks, package layout checks and release-manifest verification.
- Prevented release creation when the corresponding `v<version>` tag already exists.

## Release rule

The following values have distinct meanings:

```text
Internal version: 0.4.1-rc2
Git tag:          v0.4.1-rc2
Version code:     26
```

A new release may be published only when:

1. the internal version and version code match between `module.prop` and `update.json`;
2. every downloaded dependency matches a pinned SHA256;
3. the complete module validates and packages successfully;
4. the package SHA256 exactly matches `update.json`;
5. the `v<version>` tag does not already exist.

## Not completed in PR-00

The following work belongs to later restart phases:

- Restore the complete, reproducible `PatchNest` CLI source tree.
- Rebuild the `PatchNest-Kpms` catalog and replace invalid asset URLs.
- Re-audit boot image detection, patching, flashing and rollback paths.
- Run the real-device matrix for Magisk, KernelSU, KernelSU-Next and APatch.
- Prepare `0.5.0-beta.1` and stamp its final package digest.
- Back up GitHub metadata and evaluate detaching from the upstream fork network.
