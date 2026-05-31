#!/usr/bin/env node
/**
 * Module Package Validation Test
 *
 * Validates the module directory structure and required files.
 * Run before packaging the zip to catch missing components.
 */

const fs = require('fs');
const path = require('path');

const MODULE_DIR = path.join(__dirname, '..', 'module');

let passed = 0;
let failed = 0;

function ok(msg) { passed++; console.log(`  ✓ ${msg}`); }
function fail(msg) { failed++; console.error(`  ✗ ${msg}`); }

// Required binaries
const REQUIRED_BINARIES = [
    { name: 'kpatch', desc: 'User-space supercall tool', minSize: 1024 },
    { name: 'kptools', desc: 'Kernel patching tool', minSize: 1024 },
    { name: 'kpimg', desc: 'KernelPatch kernel image', minSize: 1024 },
    { name: 'magiskboot', desc: 'Magisk boot image tool', minSize: 1024 },
];

// Required scripts
const REQUIRED_SCRIPTS = [
    'customize.sh',
    'service.sh',
    'post-fs-data.sh',
    'action.sh',
    'status.sh',
    'uninstall.sh',
    'patch/boot_patch.sh',
    'patch/boot_extract.sh',
    'patch/boot_unpatch.sh',
    'patch/util_functions.sh',
];

// Required other files
const REQUIRED_FILES = [
    'module.prop',
];

// Required WebUI files
const REQUIRED_WEBUI = [
    'webroot/index.html',
];

function testBinaries() {
    console.log('\n═══ Binaries ═══');
    const binDir = path.join(MODULE_DIR, 'bin');

    if (!fs.existsSync(binDir)) {
        fail('bin/ directory missing');
        return;
    }

    for (const bin of REQUIRED_BINARIES) {
        const filePath = path.join(binDir, bin.name);
        if (!fs.existsSync(filePath)) {
            fail(`MISSING: ${bin.name} — ${bin.desc}`);
            continue;
        }
        const stats = fs.statSync(filePath);
        if (stats.size < bin.minSize) {
            fail(`TOO SMALL: ${bin.name} (${stats.size} bytes, min ${bin.minSize})`);
            continue;
        }
        ok(`${bin.name} (${(stats.size / 1024).toFixed(1)} KB)`);
    }

    // Check for stale/old binaries
    const files = fs.readdirSync(binDir);
    const expected = new Set(REQUIRED_BINARIES.map(b => b.name));
    for (const f of files) {
        const fp = path.join(binDir, f);
        if (fs.statSync(fp).isDirectory()) continue; // skip subdirs
        if (!expected.has(f)) {
            console.log(`  ⚠ Extra file in bin/: ${f}`);
        }
    }
}

function testScripts() {
    console.log('\n═══ Scripts ═══');
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
        // Check shebang
        const content = fs.readFileSync(filePath, 'utf8');
        if (!content.startsWith('#!/')) {
            console.log(`  ⚠ No shebang: ${script}`);
        }
        ok(`${script} (${stats.size} bytes)`);
    }
}

function testModuleProp() {
    console.log('\n═══ module.prop ═══');
    const propPath = path.join(MODULE_DIR, 'module.prop');
    if (!fs.existsSync(propPath)) {
        fail('module.prop missing');
        return;
    }

    const content = fs.readFileSync(propPath, 'utf8');
    const required = ['id=', 'name=', 'version=', 'versionCode=', 'author=', 'description='];
    for (const key of required) {
        if (!content.includes(key)) {
            fail(`Missing key: ${key.replace('=', '')}`);
        } else {
            const value = content.split('\n').find(l => l.startsWith(key))?.split('=')[1]?.trim();
            ok(`${key.replace('=', '')}: ${value || '(empty)'}`);
        }
    }
}

function testWebUI() {
    console.log('\n═══ WebUI ═══');
    for (const file of REQUIRED_WEBUI) {
        const filePath = path.join(MODULE_DIR, file);
        if (!fs.existsSync(filePath)) {
            fail(`MISSING: ${file}`);
            continue;
        }
        const stats = fs.statSync(filePath);
        if (stats.size < 100) {
            fail(`TOO SMALL: ${file} (${stats.size} bytes)`);
            continue;
        }
        ok(`${file} (${(stats.size / 1024).toFixed(1)} KB)`);
    }

    // Check webroot assets
    const assetsDir = path.join(MODULE_DIR, 'webroot', 'assets');
    if (!fs.existsSync(assetsDir)) {
        fail('webroot/assets/ missing');
    } else {
        const assets = fs.readdirSync(assetsDir);
        const hasJS = assets.some(f => f.endsWith('.js'));
        const hasCSS = assets.some(f => f.endsWith('.css'));
        if (!hasJS) fail('No JS file in webroot/assets/');
        else ok(`JS bundle present`);
        if (!hasCSS) fail('No CSS file in webroot/assets/');
        else ok(`CSS bundle present`);
    }

    // Check locales
    const localesDir = path.join(MODULE_DIR, 'webroot', 'locales', 'strings');
    if (fs.existsSync(localesDir)) {
        const locales = fs.readdirSync(localesDir).filter(f => f.endsWith('.xml'));
        ok(`${locales.length} locale files`);
    }
}

// Main
console.log('Module Package Validation');
console.log('=========================');

testBinaries();
testScripts();
testModuleProp();
testWebUI();

console.log('\n═══ Summary ═══');
console.log(`Passed: ${passed}, Failed: ${failed}`);

if (failed > 0) {
    console.error('\n! Module package has missing or broken components.');
    console.error('! The module WILL NOT work correctly on device.');
}

process.exit(failed > 0 ? 1 : 0);
