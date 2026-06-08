// Shared constants and pure utilities — all page modules import from here
// This breaks circular dependency with index.js
import { exec, toast } from 'kernelsu-alt';
import { getString } from './language.js';
import { sanitizeUrl } from './utils.js';

// On-device paths. modDir is the Magisk/KernelSU/APatch mount-point
// for the active installation of the PatchNest module; persistDir
// is where the module's runtime state (KPM allowlist, KP
// signature keys, etc.) lives. /data/adb/paths must match the
// on-device directory names exactly — they're consumed by the
// companion shell scripts in module/*.sh.
export const modDir = '/data/adb/modules/PatchNest';
export const persistDir = '/data/adb/patchnest';

const DEFAULT_CHUNK_SIZE = 96 * 1024;
export let MAX_CHUNK_SIZE = DEFAULT_CHUNK_SIZE;

export function escapeShell(cmd) {
    if (cmd === '' || cmd === null || cmd === undefined) return '""';
    // Characters that are dangerous inside double quotes:
    //   $ ` " ! \ \n \r — all need backslash-escaping
    return '"' + cmd.replace(/[\\"$`!\n\r]/g, '\\$&') + '"';
}

export function linkRedirect(link) {
    // P0-fix (ultracode-audit-2026-06-06): `link` can come from any
    // user-clickable text in the WebUI. Sanitizing it through sanitizeUrl
    // blocks any non-http(s) protocol (e.g. file:, javascript:, custom
    // URI schemes that kernelsu-alt exec may surface to `am start`).
    //
    // P0-11: the previous form was `sanitizeUrl(link) || link` — a
    // null-fallback that defeated the whole sanitization. A user
    // could click on a `javascript:alert(1)` link, sanitizeUrl
    // would return null, the `||` would silently fall through to
    // the original `javascript:` URL, and `am start` would happily
    // dispatch the intent. Now: hard-reject anything that doesn't
    // pass sanitizeUrl, with a toast to the user.
    const safeLink = sanitizeUrl(link);
    if (!safeLink) {
        toast(getString('msg_invalid_link'));
        return;
    }
    toast(getString('msg_redirecting_to', safeLink));
    setTimeout(() => {
        // safeLink is guaranteed http(s) by sanitizeUrl() above, and
        // escapeShell() double-quotes it for the shell. Together that
        // is defense-in-depth against the documented Android WebView
        // bridges — note that `kernelsu-alt.exec` is a JS-Native
        // bridge, not Node's child_process.exec, so the standard
        // execFile() / spawn() recommendations don't apply here.
        exec(`am start -a android.intent.action.VIEW -d ${escapeShell(safeLink)}`)
            .then(({ errno }) => {
                if (errno !== 0) {
                    toast(getString('msg_failed_open_link'));
                    window.open(safeLink, '_blank');
                }
            });
    }, 100);
}

/**
 * Initialize MAX_CHUNK_SIZE from `getconf ARG_MAX`.
 * Returns a promise so callers can await it before first upload.
 * Safe to call multiple times — caches the promise so concurrent
 * callers share the same in-flight async operation.
 */
let _chunkSizePromise = null;
export async function getMaxChunkSize() {
    if (!_chunkSizePromise) {
        _chunkSizePromise = (async () => {
            try {
                const result = await exec('getconf ARG_MAX');
                const maxArg = parseInt(result.stdout.trim());
                if (!isNaN(maxArg)) {
                    const computed = Math.floor(maxArg * 0.75) - 1024;
                    // Clamp to [DEFAULT_CHUNK_SIZE, DEFAULT_CHUNK_SIZE * 10]
                    // to guard against extreme or corrupted ARG_MAX values.
                    MAX_CHUNK_SIZE = Math.min(
                        Math.max(computed, DEFAULT_CHUNK_SIZE),
                        DEFAULT_CHUNK_SIZE * 10
                    );
                }
            } catch (e) {
                console.warn('getMaxChunkSize: getconf ARG_MAX failed, using DEFAULT_CHUNK_SIZE', e);
            }
        })();
    }
    return _chunkSizePromise;
}
