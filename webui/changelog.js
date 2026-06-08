// Changelog modal: pops the first time a user lands on a new version.
// The version and entries are bundled into the WebUI; the full changelog
// remains at the GitHub URL (set in update.json).

import { escapeHTML } from './utils.js';
import { linkRedirect } from './constants.js';

const LAST_SEEN_KEY = 'patchnest_changelog_last_seen';
const CHANGELOG_URL = 'https://raw.githubusercontent.com/Zhanfg/PatchNest-Module/main/CHANGELOG.md';

// Keep these in sync with CHANGELOG.md / module.prop / update.json.
// Each entry is shown in the modal as a bullet; sub-bullets use a leading
// two-space indent. Only this version's highlights are shown — the link
// below opens the full changelog.
const ENTRIES = [
    {
        version: 'v0.2.4',
        title: 'Security, correctness, and robustness hardening',
        highlights: [
            '🔒 Shell injection closed in load/cmd/cp/CSV/URL/rehook paths',
            '🔒 Backup path traversal — names now stripped to basename only',
            '🔒 KPM repo downloads capped at 50 MiB',
            '🐛 Flash guard no longer attempts to flash missing new-boot.img',
            '🐛 First -M <file> no longer silently skipped by KPM validator',
            '🐛 Compiler exit code now actually captured (was masked by [ $ARCH ])',
            '🐛 magiskboot repack exit code now actually checked',
            '⚡ Rehook switch UI rolls back on backend failure',
            '⚡ Pull-to-refresh handles multi-finger / touchcancel cleanly',
            '⚡ Upload pipes have 60s/chunk + 120s/combine timeouts',
            '⚡ kpm-next pinned to 0.13.5-2 (reproducible builds)',
            '✨ WebUI: "What\'s New" changelog modal on first launch of a new version',
            '✨ WebUI: theme toggle — light / dark / follow system',
            '✨ WebUI: safe mode indicator (queries new kp-safemode helper)',
        ],
    },
];

/**
 * Show the changelog modal if the user has not seen the current version yet.
 * Records `LAST_SEEN_KEY` on close so it only fires once per version.
 */
export function maybeShowChangelog() {
    const dialog = document.getElementById('changelog-dialog');
    if (!dialog) return;

    const newest = ENTRIES[0];
    if (!newest) return;

    const lastSeen = localStorage.getItem(LAST_SEEN_KEY);
    if (lastSeen === newest.version) return;

    // Populate the modal content. Use textContent for user-supplied data
    // (none here, but defensive) and innerHTML for the static list.
    const list = dialog.querySelector('#changelog-list');
    const version = dialog.querySelector('#changelog-version');
    const viewAll = dialog.querySelector('#changelog-view-all');

    if (version) version.textContent = newest.title;
    if (list) {
        list.innerHTML = newest.highlights
            .map(line => {
                // Sub-bullets start with two spaces + "-"
                if (line.startsWith('  -')) {
                    return `<li class="changelog-sub">${escapeHTML(line.replace(/^\s*-\s*/, ''))}</li>`;
                }
                return `<li>${escapeHTML(line)}</li>`;
            })
            .join('');
    }
    if (viewAll) {
        viewAll.onclick = () => {
            dialog.close();
            linkRedirect(CHANGELOG_URL);
        };
    }

    const close = () => {
        try { localStorage.setItem(LAST_SEEN_KEY, newest.version); } catch (_) {}
        dialog.close();
    };
    dialog.querySelector('.changelog-close')?.addEventListener('click', close, { once: true });
    dialog.addEventListener('close', () => {
        try { localStorage.setItem(LAST_SEEN_KEY, newest.version); } catch (_) {}
    }, { once: true });

    // Defer the open so it doesn't fight the splash animation.
    setTimeout(() => dialog.show(), 600);
}

/**
 * For tests: returns the current bundled version list without side effects.
 */
export function _getEntries() {
    return ENTRIES;
}
