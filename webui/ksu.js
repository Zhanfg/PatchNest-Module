// KSU environment detection and constrained profile access.

import { exec } from 'kernelsu-alt';
import { modDir, escapeShell } from './constants.js';

const KSU_DIR = '/data/adb/ksu';
const KSU_ALLOWLIST = '/data/adb/ksu/.allowlist';

const KSU_PACKAGES = [
    'me.weishu.kernelsu',
    'io.github.kernelsu',
    'com.rifsxd.sukisuultra',
    'com.rifsxd.sukisu',
];

let _env = null;

/**
 * Normalize a ksuctl profile target without allowing option injection.
 *
 * Accepted forms:
 * - decimal Android UID in the signed 32-bit positive range;
 * - an Android-style package identifier, limited to 255 ASCII characters.
 *
 * Returns a canonical string or null. A quoted string beginning with `-` is
 * still an option after shell parsing, so shell escaping alone is insufficient.
 */
export function normalizeKsuProfileTarget(value) {
    if (value === null || value === undefined) return null;
    const input = String(value).trim();
    if (!input || input.length > 255) return null;

    if (/^[0-9]{1,10}$/.test(input)) {
        const uid = Number(input);
        if (Number.isSafeInteger(uid) && uid >= 0 && uid <= 2147483647) {
            return String(uid);
        }
        return null;
    }

    // Android package names are dot-separated Java-like identifiers. This
    // deliberately rejects whitespace, slashes, colons, shell metacharacters,
    // leading dashes and single-segment aliases.
    if (/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$/.test(input)) {
        return input;
    }
    return null;
}

/** Detect and cache the active root-manager environment. */
export async function detectEnvironment() {
    if (_env) return _env;

    const result = {
        manager: 'unknown',
        hasKsu: false,
        ksuVersion: null,
        managerPackage: null,
        moduleEnabled: true,
    };

    try {
        const ver = await exec('ksu --version', { env: { PATH: `${modDir}/bin` } });
        if (ver.errno === 0 && ver.stdout.trim()) {
            result.hasKsu = true;
            result.ksuVersion = ver.stdout.trim();
            result.manager = 'ksu';
        }
    } catch (_) {}

    if (!result.hasKsu) {
        try {
            const ls = await exec(`ls ${escapeShell(KSU_DIR)} 2>/dev/null`, { env: { PATH: '/system/bin' } });
            if (ls.errno === 0 && ls.stdout.trim()) {
                result.hasKsu = true;
                result.manager = 'ksu';
            }
        } catch (_) {}
    }

    if (result.hasKsu) {
        for (const pkg of KSU_PACKAGES) {
            try {
                const pm = await exec(`pm path ${escapeShell(pkg)}`, { env: { PATH: '/system/bin' } });
                if (pm.errno === 0 && pm.stdout.trim()) {
                    result.managerPackage = pkg;
                    if (pkg === 'me.weishu.kernelsu') {
                        result.manager = 'ksu-next';
                    } else if (pkg === 'io.github.kernelsu') {
                        result.manager = 'ksu';
                    } else if (pkg.includes('sukisu')) {
                        result.manager = 'sukisu';
                    }
                    break;
                }
            } catch (_) {}
        }
    }

    if (result.manager === 'unknown') {
        try {
            const ap = await exec('ls /data/adb/ap 2>/dev/null', { env: { PATH: '/system/bin' } });
            if (ap.errno === 0 && ap.stdout.trim()) result.manager = 'apatch';
        } catch (_) {}
    }

    if (result.manager === 'unknown') {
        try {
            const magisk = await exec('magisk --version', { env: { PATH: '/system/bin' } });
            if (magisk.errno === 0 && magisk.stdout.trim()) result.manager = 'magisk';
        } catch (_) {}
    }

    if (result.hasKsu) {
        try {
            const en = await exec(`cat ${escapeShell(modDir)}/disable 2>/dev/null`, { env: { PATH: '/system/bin' } });
            result.moduleEnabled = !(en.errno === 0 && en.stdout.trim());
        } catch (_) {}
    }

    _env = result;
    return result;
}

export function resetEnvironment() {
    _env = null;
}

export async function readKsuAllowlist() {
    try {
        const result = await exec(`cat ${escapeShell(KSU_ALLOWLIST)}`, { env: { PATH: '/system/bin' } });
        if (result.errno !== 0) return new Set();
        return new Set(
            result.stdout.split(/\s+/)
                .map(line => line.trim())
                .filter(Boolean)
                .map(Number)
                .filter(uid => Number.isSafeInteger(uid) && uid >= 0 && uid <= 2147483647)
        );
    } catch (_) {
        return new Set();
    }
}

/** Read one KSU App Profile after strict target validation. */
export async function readKsuProfile(pkgOrUid) {
    const target = normalizeKsuProfileTarget(pkgOrUid);
    if (target === null) return null;

    try {
        const result = await exec(`ksuctl profile get ${escapeShell(target)}`, {
            env: { PATH: `${modDir}/bin:/system/bin` }
        });
        if (result.errno !== 0 || !result.stdout.trim()) return null;
        try {
            const parsed = JSON.parse(result.stdout);
            return parsed && typeof parsed === 'object' ? parsed : null;
        } catch (_) {
            return null;
        }
    } catch (_) {
        return null;
    }
}

export function supportsProfiles(env) {
    if (!env?.hasKsu || !env.ksuVersion) return false;
    const version = String(env.ksuVersion).match(/(\d+)\.(\d+)/);
    if (!version) return false;
    return Number.parseInt(version[1], 10) >= 2;
}
