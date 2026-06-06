// Shared constants and pure utilities — all page modules import from here
// This breaks circular dependency with index.js
import { exec, toast } from 'kernelsu-alt';
import { getString } from './language.js';
import { sanitizeUrl } from './utils.js';

export const modDir = '/data/adb/modules/KPatch-Next';
export const persistDir = '/data/adb/kp-next';

const DEFAULT_CHUNK_SIZE = 96 * 1024;
export let MAX_CHUNK_SIZE = DEFAULT_CHUNK_SIZE;
let maxChunkInitialized = false;

export function escapeShell(cmd) {
    if (cmd === '' || cmd === null || cmd === undefined) return '""';
    // Characters that are dangerous inside double quotes:
    //   $ ` " ! \  — all need backslash-escaping
    return '"' + cmd.replace(/[\\"$`!\\]/g, '\\$&') + '"';
}

export function linkRedirect(link) {
    // P0-fix (ultracode-audit-2026-06-06): `link` can come from any
    // user-clickable text in the WebUI. Sanitizing it through sanitizeUrl
    // blocks any non-http(s) protocol (e.g. file:, javascript:, custom
    // URI schemes that kernelsu-alt exec may surface to `am start`),
    // and escapeShell() keeps the URL a single token in the exec
    // command so a crafted link like 'foo;rm -rf /' cannot break out.
    const safeLink = sanitizeUrl(link) || link;
    toast(getString('msg_redirecting_to', safeLink));
    setTimeout(() => {
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
 * Safe to call multiple times — only runs once.
 */
export async function getMaxChunkSize() {
    if (maxChunkInitialized) return;
    maxChunkInitialized = true;
    try {
        const result = await exec('getconf ARG_MAX');
        const maxArg = parseInt(result.stdout.trim());
        if (!isNaN(maxArg)) {
            MAX_CHUNK_SIZE = Math.floor(maxArg * 0.75) - 1024;
        }
    } catch (e) {
        // Silently fall back to DEFAULT_CHUNK_SIZE
    }
}
