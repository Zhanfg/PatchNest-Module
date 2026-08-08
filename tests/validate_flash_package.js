#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const MOD = path.join(ROOT, 'module');
let failed = 0;

function fail(msg) {
  failed += 1;
  console.error(`FAIL: ${msg}`);
}
function pass(msg) {
  console.log(`PASS: ${msg}`);
}
function read(rel) {
  return fs.readFileSync(path.join(MOD, rel), 'utf8');
}
function requireFile(rel, minSize = 1) {
  const p = path.join(MOD, rel);
  if (!fs.existsSync(p)) {
    fail(`missing required package entry: ${rel}`);
    return false;
  }
  const st = fs.statSync(p);
  if (!st.isFile() || st.size < minSize) {
    fail(`invalid/empty required package entry: ${rel}`);
    return false;
  }
  pass(`${rel} present (${st.size} bytes)`);
  return true;
}
function hasExecutableShellCommand(text, command) {
  const re = new RegExp(`^\\s*${command}(?:\\s|$)`);
  return text.split(/\r?\n/).some(line => {
    const trimmed = line.trimStart();
    if (!trimmed || trimmed.startsWith('#')) return false;
    return re.test(line);
  });
}

console.log('PatchNest release-safety package validation');

for (const [rel, minSize] of [
  ['bin/kpatch', 1024],
  ['bin/kptools', 1024],
  ['bin/kpimg', 1024],
  ['bin/magiskboot', 1024],
  ['customize.sh', 1],
  ['service.sh', 1],
  ['post-fs-data.sh', 1],
  ['uninstall.sh', 1],
  ['install_kpm.sh', 1],
  ['compile_kpm.sh', 1],
  ['kpm_verify.sh', 1],
  ['validate_kpm_file.sh', 1],
  ['kpatch_runtime_wrapper.sh', 1],
  ['device_validation.sh', 1],
  ['arm_auto_recovery.sh', 1],
  ['verify_auto_recovery.sh', 1],
  ['export_recovery_boot.sh', 1],
  ['patch/boot_patch.sh', 1],
  ['patch/boot_extract.sh', 1],
  ['patch/boot_unpatch.sh', 1],
  ['patch/util_functions.sh', 1],
  ['patch/flash_safety.sh', 1],
  ['patch/transaction_safety.sh', 1],
  ['patch/transactional_flash.sh', 1],
  ['patch/fr014_gate.sh', 1],
  ['patch/superkey_safety.sh', 1],
]) requireFile(rel, minSize);

const blocker = path.join(MOD, 'FLASH_REVIEW_BLOCKED');
const candidate = path.join(MOD, 'FR014_DEVICE_CANDIDATE');
if (!fs.existsSync(blocker) && !fs.existsSync(candidate)) {
  fail('package has neither FLASH_REVIEW_BLOCKED nor FR014_DEVICE_CANDIDATE');
} else if (fs.existsSync(blocker) && fs.existsSync(candidate)) {
  fail('package contains both review blocker and physical-candidate marker');
} else {
  pass(fs.existsSync(blocker) ? 'review blocker present' : 'FR-014 candidate marker present');
}

const util = read('patch/util_functions.sh');
if (hasExecutableShellCommand(util, 'eval')) fail('runtime util_functions.sh still executes eval');
else pass('runtime util_functions.sh executes no eval command');
if (/rm\s+-rf\s+["']?\$MODPATH/.test(util)) fail('runtime util_functions.sh can recursively delete MODPATH');
else pass('runtime util_functions.sh cannot recursively delete MODPATH');

const safety = read('patch/flash_safety.sh');
if (!/abort\(\)[\s\S]*?exit\s+1/.test(safety)) fail('flash_safety abort override does not terminate safely');
else pass('flash_safety abort terminates without upstream cleanup');
if (/vendor_boot|init_boot/.test(safety.match(/find_boot_image\(\)[\s\S]*?\n\}/)?.[0] || '')) {
  fail('reviewed find_boot_image contains vendor_boot/init_boot fallback');
} else pass('reviewed boot resolver has no vendor_boot/init_boot fallback');

const patcher = read('patch/boot_patch.sh');
if (!patcher.includes('patchnest_transactional_flash')) fail('boot patcher does not use transactional writer');
else pass('boot patcher uses transactional writer');
if (/flash_image\s+"\$WORKDIR\/new-boot\.img"/.test(patcher)) fail('boot patcher directly calls low-level writer for patched boot');
else pass('boot patcher does not bypass transactional writer');

const tx = read('patch/transactional_flash.sh');
if (!tx.includes('patchnest_consume_fr014_preflight_if_required')) fail('transaction writer lacks FR-014 receipt gate');
else pass('transaction writer contains FR-014 receipt gate');
if (!tx.includes('PATCHNEST_FR014_GATE_MISSING')) fail('transaction writer does not fail closed on missing candidate gate helper');
else pass('candidate gate-helper absence fails closed');

const gate = read('patch/fr014_gate.sh');
for (const required of [
  'boot_target_sha256',
  'device_binding_sha256',
  'candidate_marker_sha256',
  'PATCHNEST_RECOVERY_EXPORT_FILE',
  'patchnest_fr014_recovery_export_matches',
  'patchnest_clear_fr014_preflight_receipt',
]) {
  if (!gate.includes(required)) fail(`FR-014 gate missing binding/control: ${required}`);
}
if (failed === 0) pass('FR-014 receipt binds target/device/candidate/recovery export and is one-time');

const transaction = read('patch/transaction_safety.sh');
if (!transaction.includes('patchnest_json_string rollback_backup "$PATCHNEST_PENDING_TRANSACTION_FILE"')) {
  fail('rollback commit does not verify exact pending backup filename');
} else pass('rollback commit binds exact pending backup filename');

const uninstall = read('uninstall.sh');
if (/rm\s+-rf\s+\/data\/adb\/patchnest/.test(uninstall)) {
  fail('uninstall destroys boot-critical PatchNest recovery state');
} else pass('uninstall preserves boot-critical recovery state');

const installer = read('install_kpm.sh');
if (/unzip\s+[^\n]*-d\s+/.test(installer)) {
  fail('KPM installer lets unzip directly materialize archive paths');
} else pass('KPM installer materializes validated entries itself');
if (!installer.includes('unzip -p')) fail('KPM installer lacks regular-file-only archive extraction');
else pass('KPM installer extracts entry bytes with unzip -p');
if (!installer.includes('7f454c460201') || !installer.includes('b700')) {
  fail('KPM installer lacks ELF64 little-endian AArch64 admission check');
} else pass('KPM installer enforces AArch64 ELF admission');
if (!installer.includes('FR014_DEVICE_CANDIDATE')) fail('FR-014 candidate does not block persistent KPM installation');
else pass('FR-014 candidate blocks persistent KPM installation');

const directValidator = read('validate_kpm_file.sh');
if (!directValidator.includes('7f454c460201') || !directValidator.includes('b700')) {
  fail('direct KPM validator lacks AArch64 ELF admission');
} else pass('direct KPM validator enforces AArch64 ELF admission');
if (!directValidator.includes('KPM_CYCLE') || !directValidator.includes('FR014_DEVICE_CANDIDATE')) {
  fail('direct KPM validator lacks explicit FR-014 diagnostic exception boundary');
} else pass('direct KPM validator isolates FR-014 diagnostic KPM cycle');

const wrapper = read('kpatch_runtime_wrapper.sh');
if (!wrapper.includes('kpatch.real')) fail('runtime kpatch wrapper does not delegate to kpatch.real');
else pass('runtime kpatch wrapper delegates to kpatch.real');
if (!wrapper.includes('"${1:-}" = "kpm"') || !wrapper.includes('"${2:-}" = "load"')) {
  fail('runtime wrapper does not intercept kpm load');
} else pass('runtime wrapper intercepts kpm load');
if (!wrapper.includes('validate_kpm_file.sh')) fail('runtime wrapper does not invoke direct KPM admission helper');
else pass('runtime wrapper invokes direct KPM admission helper');

const customize = read('customize.sh');
for (const required of ['kpatch.real', 'kpatch_runtime_wrapper.sh', 'validate_kpm_file.sh', 'binarySha256']) {
  if (!customize.includes(required)) fail(`installer missing runtime-wrapper invariant: ${required}`);
}
if (customize.includes('mv "$MODPATH/bin/kpatch" "$MODPATH/bin/kpatch.real"') &&
    customize.includes('cp "$MODPATH/kpatch_runtime_wrapper.sh" "$MODPATH/bin/kpatch"')) {
  pass('installer preserves validated CLI and replaces entry point with runtime guard');
}

const service = read('service.sh');
if (!service.includes('.autoload')) fail('service does not require explicit KPM autoload markers');
else pass('service requires explicit KPM autoload markers');
if (!service.includes('validate_runtime_kpm')) fail('service lacks second-stage KPM binary validation');
else pass('service revalidates KPM binaries before kernel load');
if (!service.includes('FR-014 candidate pre-patch idle')) fail('service lacks FR-014 prepatch idle state');
else pass('service distinguishes candidate prepatch idle from patched failure');

const verifier = read('kpm_verify.sh');
if (!verifier.includes('openssl pkeyutl -verify') || !verifier.includes('302a300506032b6570032100')) {
  fail('KPM signature verifier does not use Ed25519 SPKI/pkeyutl flow');
} else pass('KPM signature verifier uses Ed25519 SPKI/pkeyutl flow');

if (failed) {
  console.error(`release-safety package validation failed: ${failed} issue(s)`);
  process.exit(1);
}
console.log('release-safety package validation: PASS');
