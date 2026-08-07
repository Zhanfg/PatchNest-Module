# PatchNest device validation matrix

This matrix is a release gate, not a suggestion. Each row must record the exact
commit, device, ROM build, kernel, root manager, boot-slot state, commands,
result, and attached evidence archive.

## Evidence requirements

For every test session record:

- repository commit SHA;
- packaged module SHA-256;
- device model and SoC;
- Android/ROM build fingerprint;
- kernel release and architecture;
- root manager and version;
- A/B status and active slot;
- boot partition logical name, resolved block node, size, and read-only state;
- `runtime_compat_check.sh --strict` report with `summary=pass` before any
  direct-write scenario;
- pre-operation boot image SHA-256;
- generated image SHA-256;
- post-flash readback SHA-256;
- reboot result;
- rollback method and result;
- `scripts/collect_device_evidence.sh` archive, including
  `runtime-compat-console.txt` and `runtime-compat-status.txt`.

Do not attach complete boot image bytes to public issues or PRs unless the image
is known to be redistributable and contains no device-specific material.

## Matrix A — source and file-only validation

| ID | Scenario | Expected result | Status |
|---|---|---|---|
| A01 | Run `python3 tests/test_offline_audit.py` | All fixture tests pass | Pending |
| A02 | Run `python3 tests/validate_boot_hardening.py` | Contracts pass | Pending |
| A03 | Run `python3 scripts/offline_audit.py --no-syntax` | Report produced without crash | Pending |
| A04 | Run `python3 scripts/offline_audit.py --enforce` | Fails only on documented unresolved blockers | Pending |
| A05 | `bash -n`/BusyBox `sh -n` on patch scripts | No syntax error | Pending |
| A06 | Patch a copied stock boot image with flash disabled | Valid non-empty output saved | Pending |
| A07 | Re-open generated patched image | Kernel exists and reports `patched=true` | Pending |
| A08 | Unpatch copied patched image | Re-opened kernel no longer reports `patched=true` | Pending |
| A09 | Interrupt patch before repack, then rerun | No stale work artifact is reused | Pending |
| A10 | Invalid/unparseable `-M` KPM | Patch stops before repack | Pending |
| A11 | Run `runtime_compat_check.sh --strict` on device | Required checks pass and report is persisted | Pending |
| A12 | Force compatibility probe failure during evidence fixture | Collector records failure and continues collecting all files | Pending |
| A13 | Run `tests/test_flash_compat_gate.sh` | Failed/missing probe blocks the gate | Pending |

## Matrix B — target discovery

| ID | Device layout | Expected result | Status |
|---|---|---|---|
| B01 | `/dev/block/by-name/boot_a` symlink | Resolves logical name `boot_a` | Pending |
| B02 | Raw node plus sysfs `PARTNAME=boot_b` | Accepted as `boot_b` | Pending |
| B03 | Raw node reverse-mapped through by-name | Accepted only when link is boot-like | Pending |
| B04 | `vendor_boot[_a/_b]` | Rejected before WebUI patch phase | Pending |
| B05 | `init_boot[_a/_b]` | Rejected before WebUI patch phase | Pending |
| B06 | Unknown raw block with no PARTNAME/by-name link | Rejected | Pending |
| B07 | MediaTek `kern-a`/`kern_a` | Accepted and unpack contains kernel | Pending |
| B08 | Non-A/B `boot` | Accepted | Pending |

## Matrix C — A/B physical devices

Run on at least two distinct SoC families. Every direct-write row first requires
a passing strict runtime compatibility report from the same boot session.

| ID | Scenario | Expected result | Status |
|---|---|---|---|
| C01 | Patch active slot A | Gate passes; readback matches generated image; device boots | Pending |
| C02 | Normal unpatch active slot A | Gate passes; readback matches unpatched image; device boots | Pending |
| C03 | Patch active slot B | Correct slot is selected; device boots | Pending |
| C04 | Normal unpatch active slot B | Correct slot is selected; device boots | Pending |
| C05 | Patch inactive slot for OTA test | Only explicitly selected inactive slot changes | Pending |
| C06 | OTA slot switch | Backup target binding prevents cross-slot restore | Pending |
| C07 | Repeated patch within one minute | Backup filenames remain unique | Pending |
| C08 | Repeated patch within one second | PID suffix prevents collision | Pending |
| C09 | Force `KP_REBACKUP=1` after external root-tool flash | Fresh verified backup created | Pending |
| C10 | Existing valid backup, already patched kernel | Previous verified backup is preserved | Pending |

## Matrix D — non-A/B physical devices

Every direct-write row first requires a passing strict runtime compatibility
report from the same boot session.

| ID | Scenario | Expected result | Status |
|---|---|---|---|
| D01 | Patch single `boot` partition | Gate passes, verified write and successful boot | Pending |
| D02 | Normal unpatch | Gate passes, verified write and successful boot | Pending |
| D03 | Power loss simulation before write | Boot partition unchanged | Pending |
| D04 | Power loss simulation after write | Explicit recovery procedure restores exact verified backup | Pending |
| D05 | Partition smaller than image | Refused before write | Pending |
| D06 | Read-only block target | Refused before write | Pending |
| D07 | Strict compatibility probe fails | `flash_image` returns gate error 8; no `setrw` or `dd` occurs | Pending |

## Matrix E — recovery and failure injection

| ID | Injection | Expected result | Status |
|---|---|---|---|
| E01 | Empty selected backup file | Explicit restore validation rejects it | Pending |
| E02 | Missing manifest | Explicit restore validation rejects it | Pending |
| E03 | `backup_verified=false` | Explicit restore validation rejects it | Pending |
| E04 | Wrong `boot_image` target | Explicit restore validation rejects it | Pending |
| E05 | Malformed `backup_sha256` | Explicit restore validation rejects it | Pending |
| E06 | Image digest differs from manifest | Explicit restore validation rejects it | Pending |
| E07 | Digest matches but unpack fails | Explicit restore validation rejects it | Pending |
| E08 | Newest backup invalid, older backup valid | No auto-selection occurs; explicitly selected older valid backup passes | Pending |
| E09 | No valid explicitly selected backup | Recovery stops without block write | Pending |
| E10 | Readback mismatch after test-device write | Operation reports failure; rollback invoked | Pending |
| E11 | Boot counter reaches threshold | Request markers/state written; no automatic flash claimed | Pending |
| E12 | Healthy boot after request | Counter and compatibility markers cleared | Pending |
| E13 | Restore approval reused or expired | Rejected before compatibility gate and block write | Pending |

## Matrix F — root-manager combinations

| ID | Environment | Expected result | Status |
|---|---|---|---|
| F01 | Magisk stable | Backup metadata records Magisk version | Pending |
| F02 | KernelSU | Backup metadata records KSU version | Pending |
| F03 | KernelSU-Next | WebUI and scripts locate binaries correctly | Pending |
| F04 | APatch | APatch state recorded; current boot preserved | Pending |
| F05 | Recovery/BusyBox ash | Scripts parse; compatibility report identifies unsupported command behavior | Pending |
| F06 | Root manager absent, file-only patch | Flash disabled; output file produced | Pending |

## Matrix G — KPM lifecycle

Use only a non-invasive diagnostic KPM first.

| ID | Scenario | Expected result | Status |
|---|---|---|---|
| G01 | Embed verified diagnostic KPM | Patch succeeds | Pending |
| G02 | Embed malformed ELF | Patch stops | Pending |
| G03 | Embed non-AArch64 ELF | `kptools` rejects it | Pending |
| G04 | Load diagnostic KPM | Load event visible | Pending |
| G05 | Control channel response | Exact expected constant returned | Pending |
| G06 | Unload diagnostic KPM | Unload event visible | Pending |
| G07 | Reboot persistence | Matches documented event configuration | Pending |
| G08 | Failed KPM load | Module quarantined without affecting boot | Pending |

## Sign-off record

A release candidate can leave draft state only after:

- every applicable blocker row is marked Pass;
- failures include a linked issue and are not silently waived;
- every direct-write session has a passing strict runtime compatibility report;
- at least one A/B and one non-A/B rollback is demonstrated;
- the exact tested commit has not changed after testing;
- evidence archives have hashes and are retained outside GitHub Actions.
