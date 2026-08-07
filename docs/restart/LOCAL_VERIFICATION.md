# PatchNest local verification without GitHub Actions

The branch `restart/offline-audit-suite` is designed to be reviewed and tested
without consuming GitHub Actions minutes.

## Host requirements

Recommended host: Linux x86-64 with:

- Bash;
- Python 3.11+;
- OpenSSL with Ed25519 `pkeyutl -rawin`;
- Node.js;
- pnpm for the optional full WebUI suite;
- standard GNU coreutils.

The source-only checks require no network, Android root, boot image, attached
device, package download, or GitHub Actions runner.

## One-command source checks

From a complete checkout:

```sh
bash scripts/run_offline_checks.sh
```

This performs:

1. Python syntax compilation;
2. offline scanner unit tests;
3. boot patch/unpatch/restore contracts;
4. install/uninstall/KPM lifecycle contracts;
5. the off-device-only KPM source-build policy;
6. Ed25519 valid/tampered/malformed vectors;
7. kptools argv compatibility vectors;
8. release metadata consistency tests;
9. generation of JSON and Markdown audit reports;
10. Bash syntax parsing of shell entry points;
11. `node --check` parsing of every committed WebUI JavaScript module and test.

Reports are written to `audit-output/`, which is ignored by Git.

## Strict no-network WebUI suite

The repository provides a second entry point that never installs or downloads
packages:

```sh
bash scripts/run_webui_offline_checks.sh
```

It requires an already prepared `webui/node_modules` matching the committed
lockfile. When the dependency tree is absent, the script exits with an explicit
error instead of calling `pnpm install`.

To prepare the exact dependency tree once in a network-enabled environment:

```sh
cd webui
pnpm install --frozen-lockfile
cd ..
```

Then disconnect the network and run:

```sh
bash scripts/run_webui_offline_checks.sh
```

The script performs:

1. JavaScript syntax parsing;
2. the complete Vitest suite;
3. a Vite production build from the existing dependency tree.

Relevant added tests include:

- `boot-unpatch-model.test.js`;
- `ksu-profile-target.test.js`;
- `module-config-validation.test.js`.

The WebUI tests use pure models and mocked root bridges. They do not flash,
unpatch, restore, or contact a real KernelSU manager.

## Boot operation boundaries

Three operations are intentionally separate:

- `boot_patch.sh`: patch the selected current boot image;
- `boot_unpatch.sh`: remove PatchNest from the selected current boot image;
- `boot_restore_verified.sh`: validate or explicitly restore one exact,
  target-bound verified backup.

`boot_unpatch.sh` never selects a backup. `boot_restore_verified.sh` defaults to
validation-only mode and never selects the newest backup automatically.

## KPM quarantine inspection

On an installed module:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh list
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh inspect <entry-id>
```

Activation requires a complete transaction checksum set, a parseable KPM, and
a valid Ed25519 signature:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh activate <entry-id>
```

There is no force-overwrite or delete command. Activation stages and validates
the files again, refuses to replace a live module, and requires reboot so the
normal boot admission path remains authoritative.

## Reproducible package build

A package build downloads immutable release assets and therefore needs network,
but it does not require Actions:

```sh
bash build.sh
```

Expected outputs:

```text
out/PatchNest-Module.zip
out/PatchNest-Module.zip.sha256
out/build-provenance.json
```

Run twice from the same commit and `SOURCE_DATE_EPOCH`; the archive hashes must
match. Do not update `update.json` until the candidate ZIP has completed the
physical-device matrix.

## Optional local release-asset check

```sh
python3 scripts/verify_release_metadata.py \
  --release-asset out/PatchNest-Module.zip
```

This intentionally fails when `update.json` still describes an older published
asset. That failure is correct until a reviewed release candidate is frozen.

## Android read-only evidence

Copy `scripts/collect_device_evidence.sh` to the device and run as root:

```sh
sh collect_device_evidence.sh
```

The default does not read the complete boot partition. To calculate a read-only
active boot SHA-256:

```sh
sh collect_device_evidence.sh --hash-boot
```

Review the sharing notice and logs before uploading the resulting archive.
Device identifiers can appear in properties and kernel logs.

## What has actually been executed during this review

The isolated analysis environment could not resolve GitHub DNS, so the complete
branch could not be cloned there. The following focused checks were executed
independently:

- the repository Ed25519 public probe vector verified successfully with RFC
  8410 DER wrapping and `openssl pkeyutl -verify -pubin -keyform DER -rawin`;
- the kptools argv normalization logic preserved ordinary argument order,
  decoded WebUI `-A` quoting, and rejected missing, mismatched, control-bearing,
  and oversized values;
- the WebUI one-time unpatch approval command was assembled and executed in an
  isolated shell, producing the expected two-line marker with mode `0600` and a
  process-unique temporary filename.

The complete checkout commands remain mandatory. Static review and focused
vectors are not substitutes for the full suite or the physical-device matrix.
