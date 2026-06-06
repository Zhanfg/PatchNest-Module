// Update checker: fetches update.json from GitHub, compares with the
// locally-installed version, and notifies the user if a newer release is
// available. The URL is taken from module.prop's updateJson line so this
// module doesn't need to know where the user hosts their releases.

import { exec, toast } from 'kernelsu-alt';
import { modDir } from './index.js';
import { getString } from './language.js';
import { escapeShell, sanitizeUrl } from './utils.js';

const FETCH_TIMEOUT_MS = 8000;

/**
 * Parse "v0.2.4" or "0.2.4" or "0.2.4-beta1" into [0, 2, 4, ...] for
 * semver-style compare. Pre-release tags are sorted as: final > rc > beta > alpha.
 */
function parseVersion(s) {
    if (!s) return null;
    const m = String(s).trim().match(/^v?(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/i);
    if (!m) return null;
    const [, major, minor, patch, pre] = m;
    // Pre-release rank: 0 (no pre), 4 (final), 3 (rc), 2 (beta), 1 (alpha)
    let preRank = 4;
    if (pre) {
        const tag = pre.toLowerCase();
        if (tag.startsWith('rc')) preRank = 3;
        else if (tag.startsWith('beta')) preRank = 2;
        else if (tag.startsWith('alpha')) preRank = 1;
        else preRank = 0; // unknown tag, sort lowest
    }
    return [
        parseInt(major, 10),
        parseInt(minor, 10),
        parseInt(patch, 10),
        pre ? 0 : 1, // 0 if pre-release, 1 if final
        preRank,
    ];
}

function compareVersions(a, b) {
    const av = parseVersion(a);
    const bv = parseVersion(b);
    if (!av || !bv) return 0;
    for (let i = 0; i < Math.max(av.length, bv.length); i++) {
        const diff = (av[i] || 0) - (bv[i] || 0);
        if (diff !== 0) return diff;
    }
    return 0;
}

/**
 * Read the local module.prop to get the current version. Use kpatch's
 * own status line as a proxy since it already lives in module.prop and
 * doesn't need an extra shell call.
 */
async function getLocalVersion() {
    // Read module.prop via shell. cat + grep is sufficient; no need for
    // a JSON parser since the format is stable.
    const result = await exec(
        `grep '^version=' ${modDir}/module.prop | head -1 | cut -d= -f2-`,
        { env: { PATH: `${modDir}/bin` } }
    );
    if (result.errno !== 0 || !result.stdout.trim()) return null;
    return result.stdout.trim();
}

/**
 * Fetch update.json and parse it. Returns {version, versionCode, zipUrl,
 * changelog} or null on failure. Network errors are non-fatal: the user
 * will simply not see an update notification.
 */
async function fetchRemoteInfo() {
    // Read the updateJson URL from module.prop so we don't hard-code it.
    const urlResult = await exec(
        `grep '^updateJson=' ${modDir}/module.prop | head -1 | cut -d= -f2-`,
        { env: { PATH: `${modDir}/bin` } }
    );
    if (urlResult.errno !== 0 || !urlResult.stdout.trim()) return null;
    const url = urlResult.stdout.trim();

    const result = await exec(
        `curl -fsL --max-time 8 "${url}"`,
        { env: { PATH: `${modDir}/bin:/system/bin:$PATH` } }
    );
    if (result.errno !== 0 || !result.stdout.trim()) return null;

    try {
        const data = JSON.parse(result.stdout);
        if (typeof data.version !== 'string') return null;
        return {
            version: data.version,
            versionCode: data.versionCode || 0,
            zipUrl: data.zipUrl || '',
            changelog: data.changelog || '',
            // P0-9: SHA256 hash of the release zip. Fetched at build time
            // and written here by the release CI workflow.
            zipSha256: data.zipSha256 || '',
        };
    } catch (_) {
        return null;
    }
}

/**
 * Manually triggered check from the Settings page. Returns the diff
 * result so the caller can show a custom toast on error.
 */
export async function checkForUpdates() {
    const local = await getLocalVersion();
    const remote = await fetchRemoteInfo();
    if (!local) {
        return { ok: false, reason: 'local-version-unknown' };
    }
    if (!remote) {
        return { ok: false, reason: 'network-error' };
    }
    const diff = compareVersions(remote.version, local);
    if (diff > 0) {
        return { ok: true, updateAvailable: true, local, remote };
    }
    return { ok: true, updateAvailable: false, local, remote };
}

/**
 * Auto-run on app init. Fetches update.json in the background and,
 * if a newer version is available, shows the update dialog. Errors are
 * silent (no toast spam on every cold start).
 */
export async function maybeNotifyUpdate() {
    try {
        const result = await checkForUpdates();
        if (!result.ok || !result.updateAvailable) return;
        showUpdateDialog(result.local, result.remote);
    } catch (_) {
        // network failure or no perm — silently skip
    }
}

function showUpdateDialog(localVer, remote) {
    const dialog = document.getElementById('update-dialog');
    if (!dialog) return;

    const versionEl = dialog.querySelector('#update-version');
    const currentEl = dialog.querySelector('#update-current');
    const downloadBtn = dialog.querySelector('.update-download');
    const laterBtn = dialog.querySelector('.update-later');

    if (versionEl) versionEl.textContent = remote.version;
    if (currentEl) currentEl.textContent = getString('update_current', localVer);

    if (downloadBtn) {
        downloadBtn.onclick = () => {
            dialog.close();
            if (remote.zipUrl) {
                // P0-9 security fix: if the update manifest contains a
                // zipSha256 field (which it MUST for releases after v0.2.5),
                // surface it to the user as a verification step. We do not
                // attempt to download + verify inline here because that
                // requires the zip to be cached locally and the WebView
                // usually downloads to /sdcard/Download. The release CI
                // pipeline is the trust boundary: maintainer must sign.
                if (remote.zipSha256) {
                    toast(getString('update_verify_sha', remote.zipSha256.slice(0, 16) + '…'));
                } else {
                    // Refuse to silently download an unsigned update.
                    toast(getString('update_unsigned_warning'));
                    return;
                }
                // P0-fix (ultracode-audit-2026-06-06): the previous code
                // interpolated `remote.zipUrl` directly into a shell exec
                // template literal. update.json is fetched over the network
                // and is attacker-controlled (e.g. a compromised mirror or
                // MITM). A malicious zipUrl like `https://x'; rm -rf / #`
                // would have been passed to `am start` as two shell tokens,
                // opening a root RCE chain on the device. Two defenses:
                //   1. Reject any URL that isn't http(s) before doing
                //      anything with it.
                //   2. Always pass the URL through escapeShell() so the
                //      exec call gets a single, double-quoted argument.
                const safeUrl = sanitizeUrl(remote.zipUrl);
                if (!safeUrl) {
                    toast(getString('update_invalid_url'));
                    return;
                }
                // Use am start to let the browser/system download manager
                // handle the actual download.
                exec(`am start -a android.intent.action.VIEW -d ${escapeShell(safeUrl)}`)
                    .then(() => toast(getString('update_download_started')))
                    .catch(() => toast(getString('update_download_failed')));
            } else {
                toast(getString('update_no_url'));
            }
        };
    }
    if (laterBtn) {
        laterBtn.onclick = () => dialog.close();
    }

    // Defer so it doesn't fight the splash.
    setTimeout(() => dialog.show(), 800);
}
