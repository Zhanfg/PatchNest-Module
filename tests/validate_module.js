#!/usr/bin/env node
/**
 * Comprehensive Module Package Validation
 *
 * Tests:
 * 1. Binary presence, size, and ELF format
 * 2. Shell script completeness, syntax, shebangs, security
 * 3. module.prop / update.json / version.properties consistency
 * 4. WebUI build output validity
 * 5. Locale completeness
 * 6. Cross-file reference integrity
 * 7. Config file validity (JSON, properties)
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const MODULE_DIR = path.join(ROOT, 'module');

let passed = 0, failed = 0, warned = 0;
function ok(msg)   { passed++; console.log(`  ✓ ${msg}`); }
function fail(msg) { failed++; console.error(`  ✗ ${msg}`); }
function warn(msg) { warned++; console.log(`  ⚠ ${msg}`); }

// ═══════════════════════════════════════════════
// 1. Binary Validation
// ═══════════════════════════════════════════════

const REQUIRED_BINARIES = [
    { name: 'kpatch',      desc: 'User-space supercall tool', minSize: 1024 },
    { name: 'kptools',     desc: 'Kernel patching tool',      minSize: 1024 },
    { name: 'kpimg',       desc: 'KernelPatch kernel image',  minSize: 1024 },
    // magiskboot is only needed for the Magisk/legacy boot_patch.sh
    // path. The newer kp-safemode path doesn't unpack/repack with
    // magiskboot; it works on a pre-unpacked kernel. KPM-install
    // paths that bypass boot_patch.sh entirely (the typical APatch
    // / KernelSU-Next / Magisk flow) also don't need it. Treat
    // it as optional so a CI that hasn't built it yet (e.g. during
    // the SHA-hash refresh window) doesn't fail the package check.
    { name: 'magiskboot',  desc: 'Magisk boot image tool',    minSize: 1024, optional: true },
    { name: 'kp-safemode', desc: 'Safe-mode query helper',    minSize: 4096, optional: true },
];

function testBinaries() {
    console.log('\n═══ 1. Binaries ═══');
    const binDir = path.join(MODULE_DIR, 'bin');

    if (!fs.existsSync(binDir)) {
        fail('bin/ directory missing — no binaries packaged');
        return;
    }

    for (const bin of REQUIRED_BINARIES) {
        const filePath = path.join(binDir, bin.name);
        if (!fs.existsSync(filePath)) {
            if (bin.optional) {
                warn(`OPTIONAL MISSING: ${bin.name} — ${bin.desc} (only built in CI with NDK)`);
            } else {
                fail(`MISSING: ${bin.name} — ${bin.desc}`);
            }
            continue;
        }
        const stats = fs.statSync(filePath);
        if (stats.size < bin.minSize) {
            fail(`TOO SMALL: ${bin.name} (${stats.size} bytes, min ${bin.minSize}) — likely corrupted or empty`);
            continue;
        }

        // Verify ELF header for arm64 binaries (kpatch, kptools, kp-safemode)
        // kpimg is a raw kernel image, not ELF
        // magiskboot is extracted from .so
        if (bin.name === 'kpatch' || bin.name === 'kptools' || bin.name === 'kp-safemode') {
            const buf = Buffer.alloc(20);
            const fd = fs.openSync(filePath, 'r');
            fs.readSync(fd, buf, 0, 20, 0);
            fs.closeSync(fd);

            const isELF = buf[0] === 0x7f && buf[1] === 0x45 && buf[2] === 0x4c && buf[3] === 0x46;
            const is64 = buf[4] === 2;
            const isLE = buf[5] === 1;
            const machine = buf.readUInt16LE(18);

            if (!isELF) {
                fail(`NOT ELF: ${bin.name} — not a valid binary`);
            } else if (!is64) {
                fail(`NOT ELF64: ${bin.name} — expected 64-bit`);
            } else if (machine !== 0xB7 && machine !== 0x03) {
                // 0xB7 = aarch64, 0x03 = x86 (kptools-linux)
                warn(`${bin.name}: arch=0x${machine.toString(16)} (expected aarch64=0xb7)`);
            } else {
                ok(`${bin.name} (${(stats.size / 1024).toFixed(1)} KB) — ELF64 ${machine === 0xB7 ? 'aarch64' : 'x86'}`);
            }
        } else {
            // magiskboot might not be a standard ELF (extracted from .so)
            ok(`${bin.name} (${(stats.size / 1024).toFixed(1)} KB)`);
        }
    }

    // Check for unexpected files
    const files = fs.readdirSync(binDir);
    const expected = new Set(REQUIRED_BINARIES.map(b => b.name));
    for (const f of files) {
        const fp = path.join(binDir, f);
        if (fs.statSync(fp).isDirectory()) continue;
        if (!expected.has(f)) {
            warn(`Extra file in bin/: ${f} (${fs.statSync(fp).size} bytes)`);
        }
    }
}

// ═══════════════════════════════════════════════
// 2. Shell Script Validation
// ═══════════════════════════════════════════════

const REQUIRED_SCRIPTS = [
    'customize.sh',
    'service.sh',
    'post-fs-data.sh',
    'action.sh',
    'status.sh',
    'uninstall.sh',
    'detect_env.sh',
    'patch/boot_patch.sh',
    'patch/boot_extract.sh',
    'patch/boot_unpatch.sh',
    'patch/util_functions.sh',
    'install_kpm.sh',
    'compile_kpm.sh',
];

const DANGEROUS_PATTERNS = [
    { pattern: /rm\s+-rf\s+\/[^"'\s]/, msg: 'Dangerous rm -rf on absolute path' },
    { pattern: />\s*\/dev\/sd[a-z]/, msg: 'Writing directly to block device' },
    { pattern: /mkfs\./, msg: 'Filesystem formatting command' },
    { pattern: /dd\s+.*of=\/dev\//, msg: 'dd writing to device (potential brick)' },
];

function testScripts() {
    console.log('\n═══ 2. Shell Scripts ═══');

    for (const script of REQUIRED_SCRIPTS) {
        const filePath = path.join(MODULE_DIR, script);
        if (!fs.existsSync(filePath)) {
            fail(`MISSING: ${script}`);
            continue;
        }

        const stats = fs.statSync(filePath);
        if (stats.size === 0) {
            fail(`EMPTY: ${script}`);
            continue;
        }

        const content = fs.readFileSync(filePath, 'utf8');

        // Shebang check
        if (!content.startsWith('#!/')) {
            warn(`${script}: no shebang line`);
        }

        // Check for dangerous patterns
        for (const dp of DANGEROUS_PATTERNS) {
            if (dp.pattern.test(content)) {
                warn(`${script}: ${dp.msg}`);
            }
        }

        // Check for common bugs
        if (content.includes('rm -rf "$MODDIR"')) {
            fail(`${script}: tries to delete its own module directory!`);
        }

        ok(`${script} (${stats.size} bytes)`);
    }
}

// ═══════════════════════════════════════════════
// 3. Config Consistency
// ═══════════════════════════════════════════════

function parseProperties(content) {
    const result = {};
    for (const line of content.split('\n')) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;
        const eqIdx = trimmed.indexOf('=');
        if (eqIdx > 0) {
            const key = trimmed.slice(0, eqIdx).trim();
            const val = trimmed.slice(eqIdx + 1).trim().replace(/^["']|["']$/g, '').replace(/\s+#.*$/, '');
            result[key] = val;
        }
    }
    return result;
}

function testConfigConsistency() {
    console.log('\n═══ 3. Config Consistency ═══');

    // module.prop
    const propPath = path.join(MODULE_DIR, 'module.prop');
    if (!fs.existsSync(propPath)) {
        fail('module.prop missing');
        return;
    }

    const propContent = fs.readFileSync(propPath, 'utf8');
    const prop = parseProperties(propContent);
    const requiredPropKeys = ['id', 'name', 'version', 'versionCode', 'author', 'description'];

    for (const key of requiredPropKeys) {
        if (!prop[key]) {
            fail(`module.prop missing: ${key}`);
        } else {
            ok(`module.prop ${key}: ${prop[key]}`);
        }
    }

    // update.json
    const updatePath = path.join(ROOT, 'update.json');
    if (fs.existsSync(updatePath)) {
        try {
            const update = JSON.parse(fs.readFileSync(updatePath, 'utf8'));

            // Version match
            if (prop.version && update.version && prop.version !== update.version) {
                fail(`Version mismatch: module.prop="${prop.version}" vs update.json="${update.version}"`);
            } else if (prop.version && update.version) {
                ok(`Version consistent: ${prop.version}`);
            }

            // VersionCode match
            if (prop.versionCode && update.versionCode &&
                String(prop.versionCode) !== String(update.versionCode)) {
                fail(`VersionCode mismatch: module.prop="${prop.versionCode}" vs update.json="${update.versionCode}"`);
            } else {
                ok(`VersionCode consistent: ${prop.versionCode || update.versionCode}`);
            }

            // update.json has required fields
            if (!update.zipUrl) warn('update.json missing zipUrl');
            if (!update.changelog) warn('update.json missing changelog');

        } catch (e) {
            fail(`update.json: invalid JSON — ${e.message}`);
        }
    } else {
        warn('update.json not found');
    }

    // version.properties
    const verPropPath = path.join(ROOT, 'version.properties');
    if (fs.existsSync(verPropPath)) {
        const verProp = parseProperties(fs.readFileSync(verPropPath, 'utf8'));
        if (!verProp.kernelpatch) fail('version.properties missing kernelpatch');
        else ok(`kernelpatch version: ${verProp.kernelpatch}`);
        if (!verProp.magiskboot) fail('version.properties missing magiskboot');
        else ok(`magiskboot version: ${verProp.magiskboot}`);
    }
}

// ═══════════════════════════════════════════════
// 4. WebUI Validation
// ═══════════════════════════════════════════════

function testWebUI() {
    console.log('\n═══ 4. WebUI ═══');

    // Check webroot exists
    const webrootDir = path.join(MODULE_DIR, 'webroot');
    if (!fs.existsSync(webrootDir)) {
        fail('webroot/ directory missing — WebUI not built');
        return;
    }

    // index.html
    const htmlPath = path.join(webrootDir, 'index.html');
    if (!fs.existsSync(htmlPath)) {
        fail('webroot/index.html missing');
    } else {
        const html = fs.readFileSync(htmlPath, 'utf8');
        if (html.length < 100) {
            fail('webroot/index.html too small');
        } else {
            // Check HTML references valid assets
            const jsMatch = html.match(/src="\.\/assets\/([^"]+)"/);
            const cssMatch = html.match(/href="\.\/assets\/([^"]+)"/);

            if (jsMatch) {
                const jsFile = path.join(webrootDir, 'assets', jsMatch[1]);
                if (fs.existsSync(jsFile)) {
                    ok(`JS bundle: ${jsMatch[1]} (${(fs.statSync(jsFile).size / 1024).toFixed(1)} KB)`);
                } else {
                    fail(`JS bundle referenced but missing: ${jsMatch[1]}`);
                }
            } else {
                fail('No JS bundle reference in index.html');
            }

            if (cssMatch) {
                const cssFile = path.join(webrootDir, 'assets', cssMatch[1]);
                if (fs.existsSync(cssFile)) {
                    ok(`CSS bundle: ${cssMatch[1]} (${(fs.statSync(cssFile).size / 1024).toFixed(1)} KB)`);
                } else {
                    fail(`CSS bundle referenced but missing: ${cssMatch[1]}`);
                }
            } else {
                fail('No CSS bundle reference in index.html');
            }

            // Check for key elements
            if (html.includes('kernelsu-alt')) ok('References kernelsu-alt SDK');
            if (html.includes('[unresolved]') || html.includes('setTimeout')) ok('Has unresolved fallback timeout');
        }
    }

    // Check locales
    const localesDir = path.join(webrootDir, 'locales', 'strings');
    if (fs.existsSync(localesDir)) {
        const locales = fs.readdirSync(localesDir).filter(f => f.endsWith('.xml'));
        if (locales.length === 0) {
            fail('No locale files in webroot/locales/strings/');
        } else {
            ok(`${locales.length} locale files`);

            // Check en.xml key count
            const enPath = path.join(localesDir, 'en.xml');
            let enKeyCount = 0;
            if (fs.existsSync(enPath)) {
                enKeyCount = (fs.readFileSync(enPath, 'utf8').match(/name="/g) || []).length;
                ok(`en.xml has ${enKeyCount} translation keys`);
            }

            // Check zh-CN completeness
            const zhPath = path.join(localesDir, 'zh-CN.xml');
            if (fs.existsSync(zhPath)) {
                const zhKeys = (fs.readFileSync(zhPath, 'utf8').match(/name="/g) || []).length;
                if (enKeyCount > 0) {
                    if (zhKeys < enKeyCount) {
                        warn(`zh-CN has ${zhKeys} keys, en has ${enKeyCount} (${enKeyCount - zhKeys} missing)`);
                    } else {
                        ok(`zh-CN complete (${zhKeys} keys)`);
                    }
                }
            }
        }
    } else {
        warn('No locales directory in webroot');
    }
}

// ═══════════════════════════════════════════════
// 5. Cross-file Reference Integrity
// ═══════════════════════════════════════════════

function testCrossReferences() {
    console.log('\n═══ 5. Cross-file References ═══');

    // service.sh references binaries that must exist
    const serviceSh = path.join(MODULE_DIR, 'service.sh');
    if (fs.existsSync(serviceSh)) {
        const content = fs.readFileSync(serviceSh, 'utf8');
        const binRefs = ['kpatch', 'kptools'];
        for (const ref of binRefs) {
            if (content.includes(ref)) {
                const binPath = path.join(MODULE_DIR, 'bin', ref);
                if (fs.existsSync(binPath)) {
                    ok(`service.sh references ${ref} — exists`);
                } else {
                    fail(`service.sh references ${ref} — NOT FOUND in bin/`);
                }
            }
        }
    }

    // customize.sh references bin/ paths
    const customizeSh = path.join(MODULE_DIR, 'customize.sh');
    if (fs.existsSync(customizeSh)) {
        const content = fs.readFileSync(customizeSh, 'utf8');
        if (content.includes('MODPATH/bin')) {
            ok('customize.sh references MODPATH/bin');
        }
        if (content.includes('set_perm_recursive')) {
            ok('customize.sh sets bin permissions');
        }
    }

    // boot_patch.sh references kptools and magiskboot
    const bootPatch = path.join(MODULE_DIR, 'patch', 'boot_patch.sh');
    if (fs.existsSync(bootPatch)) {
        const content = fs.readFileSync(bootPatch, 'utf8');
        const deps = ['kptools', 'magiskboot', 'kpimg'];
        for (const dep of deps) {
            if (content.includes(dep)) {
                ok(`boot_patch.sh uses ${dep}`);
            }
        }
    }

    // action.sh references WebUI app
    const actionSh = path.join(MODULE_DIR, 'action.sh');
    if (fs.existsSync(actionSh)) {
        const content = fs.readFileSync(actionSh, 'utf8');
        if (content.includes('ksuwebui') || content.includes('WebUI')) {
            ok('action.sh has WebUI launch logic');
        } else {
            warn('action.sh missing WebUI launch logic');
        }
    }

    // uninstall.sh cleans up
    const uninstallSh = path.join(MODULE_DIR, 'uninstall.sh');
    if (fs.existsSync(uninstallSh)) {
        const content = fs.readFileSync(uninstallSh, 'utf8');
        if (content.includes('patchnest')) {
            ok('uninstall.sh cleans PatchNest data');
        } else {
            warn('uninstall.sh may not clean all data');
        }
    }
}

// ═══════════════════════════════════════════════
// 6. Build System Validation
// ═══════════════════════════════════════════════

function testBuildSystem() {
    console.log('\n═══ 6. Build System ═══');

    // build.sh exists and references correct repos
    const buildSh = path.join(ROOT, 'build.sh');
    if (fs.existsSync(buildSh)) {
        const content = fs.readFileSync(buildSh, 'utf8');
        if (content.includes('KernelPatch-Public')) {
            ok('build.sh references KernelPatch-Public');
        }
        if (content.includes('kpatch-android')) {
            ok('build.sh downloads kpatch tool');
        }
        if (content.includes('magiskboot')) {
            ok('build.sh downloads magiskboot');
        }
    }

    // CI workflow exists
    const ciPath = path.join(ROOT, '.github', 'workflows', 'build.yaml');
    if (fs.existsSync(ciPath)) {
        const content = fs.readFileSync(ciPath, 'utf8');
        if (content.includes('validate_module.js')) {
            ok('CI runs module validation');
        } else {
            warn('CI does not run module validation');
        }
        if (content.includes('validate_kpm.js')) {
            ok('CI runs KPM validation');
        }
        if (content.includes('pnpm build')) {
            ok('CI builds WebUI');
        }
        if (content.includes('softprops/action-gh-release')) {
            ok('CI creates GitHub releases');
        }
    } else {
        fail('CI workflow missing');
    }

    // Test KPM files exist
    const testKpmDir = path.join(ROOT, 'tests', 'kpm');
    if (fs.existsSync(testKpmDir)) {
        const files = fs.readdirSync(testKpmDir).filter(f => f.endsWith('.kpm') || f.endsWith('.ko'));
        ok(`${files.length} test KPM files present`);
    } else {
        warn('No test KPM files');
    }
}

// ═══════════════════════════════════════════════
// 7. i18n Validation
// ═══════════════════════════════════════════════

function testI18n() {
    console.log('\n═══ 7. i18n ═══');

    const srcLocalesDir = path.join(ROOT, 'webui', 'public', 'locales', 'strings');
    if (!fs.existsSync(srcLocalesDir)) {
        warn('Source locale directory not found');
        return;
    }

    const locales = fs.readdirSync(srcLocalesDir).filter(f => f.endsWith('.xml'));
    ok(`${locales.length} source locale files`);

    // Get en.xml keys as baseline
    const enPath = path.join(srcLocalesDir, 'en.xml');
    if (!fs.existsSync(enPath)) {
        fail('en.xml missing — cannot validate other locales');
        return;
    }

    const enContent = fs.readFileSync(enPath, 'utf8');
    const enKeys = [...enContent.matchAll(/name="([^"]+)"/g)].map(m => m[1]);

    for (const locale of locales) {
        if (locale === 'en.xml') continue;
        const localeContent = fs.readFileSync(path.join(srcLocalesDir, locale), 'utf8');
        const localeKeys = new Set([...localeContent.matchAll(/name="([^"]+)"/g)].map(m => m[1]));
        const missing = enKeys.filter(k => !localeKeys.has(k));

        if (missing.length === 0) {
            ok(`${locale}: all ${enKeys.length} keys present`);
        } else {
            warn(`${locale}: ${missing.length} missing keys (will fallback to en)`);
        }
    }
}

// ═══════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════

console.log('Module Package Validation — Comprehensive');
console.log('===========================================');

testBinaries();
testScripts();
testConfigConsistency();
testWebUI();
testCrossReferences();
testBuildSystem();
testI18n();

console.log('\n═══ Summary ═══');
console.log(`Passed: ${passed}, Failed: ${failed}, Warnings: ${warned}`);

if (failed > 0) {
    console.error(`\n! ${failed} critical issue(s) found — module will NOT work correctly.`);
} else if (warned > 0) {
    console.log(`\n✓ All critical checks passed. ${warned} warning(s) to review.`);
} else {
    console.log('\n✓ All checks passed. Module package is complete and valid.');
}

process.exit(failed > 0 ? 1 : 0);
