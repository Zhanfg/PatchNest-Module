// KSU environment detection. Detects the running root manager (KernelSU,
// KernelSU-Next, APatch, Magisk) and exposes helper functions for reading
// KSU-specific paths (profiles, allowlist, module config).

import { exec } from 'kernelsu-alt';
import { modDir, escapeShell } from './constants.js';

// KSU well-known paths.
const KSU_DIR = '/data/adb/ksu';
const KSU_PROFILES_DIR = '/data/adb/ksu/profile';
const KSU_ALLOWLIST = '/data/adb/ksu/.allowlist';
const KSU_MODULE_CONFIG = '/data/adb/ksu/module_config';

// KernelSU manager package names (checked in order).
const KSU_PACKAGES = [
    'me.weishu.kernelsu',        // KernelSU-Next (standard)
    'io.github.kernelsu',        // KernelSU (original)
    'com.rifsxd.sukisuultra',    // SukiSU-Ultra
    'com.rifsxd.sukisu',         // ReSukiSU
];

let _env = null;

/**
 * Detect the running environment once and cache it.
 * Returns {manager, hasKsu, ksuVersion, managerPackage}.
 * manager: 'ksu' | 'ksu-next' | 'sukisu' | 'apatch' | 'magisk' | 'unknown'
 * hasKsu: boolean — true when KSU APIs are actually available
 * ksuVersion: string | null — KSU kernel version (e.g. '1.0.4')
 * managerPackage: string | null — package name of the KSU manager
 */
export async function detectEnvironment() {
    if (_env) return _env;

    const result = {
        manager: 'unknown',
        hasKsu: false,
        ksuVersion: null,
        managerPackage: null,
        moduleEnabled: true,
    };

    // 1. Check KSU root daemon. `ksu --version` returns the KSU version
    //    string if installed and working. This is the most reliable marker.
    try {
        const ver = await exec('ksu --version', { env: { PATH: `${modDir}/bin` } });
        if (ver.errno === 0 && ver.stdout.trim()) {
            result.hasKsu = true;
            result.ksuVersion = ver.stdout.trim();
            result.manager = 'ksu';
        }
    } catch (_) {}

    // 2. If `ksu` isn't available, check the /data/adb/ksu directory
    //    (this is more permissive — works even if the user hasn't
    //    re-rooted yet after flashing KSU).
    if (!result.hasKsu) {
        try {
            const ls = await exec(`ls ${escapeShell(KSU_DIR)} 2>/dev/null`, { env: { PATH: '/system/bin' } });
            if (ls.errno === 0 && ls.stdout.trim()) {
                result.hasKsu = true;
                result.manager = 'ksu';
            }
        } catch (_) {}
    }

    // 3. Detect the KSU manager package (for launching its UI).
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

    // 4. Detect APatch (separate root manager with similar capabilities).
    if (result.manager === 'unknown') {
        try {
            const ap = await exec('ls /data/adb/ap 2>/dev/null', { env: { PATH: '/system/bin' } });
            if (ap.errno === 0 && ap.stdout.trim()) {
                result.manager = 'apatch';
            }
        } catch (_) {}
    }

    // 5. Detect Magisk.
    if (result.manager === 'unknown') {
        try {
            const magisk = await exec('magisk --version', { env: { PATH: '/system/bin' } });
            if (magisk.errno === 0 && magisk.stdout.trim()) {
                result.manager = 'magisk';
            }
        } catch (_) {}
    }

    // 6. Check module enabled state (KSU sets this via its module system).
    if (result.hasKsu) {
        try {
            const en = await exec(`cat ${escapeShell(modDir)}/disable 2>/dev/null`, { env: { PATH: '/system/bin' } });
            result.moduleEnabled = !(en.errno === 0 && en.stdout.trim());
        } catch (_) {}
    }

    _env = result;
    return result;
}

/**
 * Force re-detection (used after a reboot or manager update).
 */
export function resetEnvironment() {
    _env = null;
}

/**
 * Read the list of apps that have been granted root access via KSU's
 * allowlist. Returns a Set of UIDs. For non-KSU environments, returns
 * an empty set.
 */
export async function readKsuAllowlist() {
    try {
        const result = await exec(`cat ${escapeShell(KSU_ALLOWLIST)}`, { env: { PATH: '/system/bin' } });
        if (result.errno !== 0) return new Set();
        return new Set(
            result.stdout.split(/\s+/)
                .map(l => l.trim())
                .filter(Boolean)
                .map(Number)
                .filter(uid => !isNaN(uid))
        );
    } catch (_) {
        return new Set();
    }
}

/**
 * Read a KSU App Profile for a given package. Returns the profile
 * object or null if not found. Only works when KSU is the root manager.
 *
 * KSU profiles are stored as binary blobs in /data/adb/ksu/profile/<uid>.
 * We can also use `ksuctl profile get <uid>` if available.
 */
export async function readKsuProfile(pkgOrUid) {
    try {
        const result = await exec(`ksuctl profile get ${escapeShell(pkgOrUid)}`, {
            env: { PATH: `${modDir}/bin:/system/bin` }
        });
        if (result.errno !== 0 || !result.stdout.trim()) return null;
        try { return JSON.parse(result.stdout); } catch (_) { return null; }
    } catch (_) {
        return null;
    }
}

/**
 * Detect whether this KSU supports the enhanced features (App Profile,
 * module config). Returns true for KSU ≥ v2.0.0 (the version that
 * added profiles).
 */
export function supportsProfiles(env) {
    if (!env.hasKsu) return false;
    if (!env.ksuVersion) return false;
    const v = env.ksuVersion.match(/(\d+)\.(\d+)/);
    if (!v) return false;
    return parseInt(v[1]) >= 2;
}
