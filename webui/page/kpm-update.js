// KPM update checker — the "APM-style" remote link / repo install path
// for installed KernelPatch modules.
//
// Sources of truth for "is there a new KPM version available?":
//   1. The Kpm-Repo JSON catalog (https://.../kpm_repo.json) — the same
//      data already fetched by page/kpm_repo.js. We re-use the *same*
//      list here so users see one consistent "what's available" view
//      regardless of whether they browse the repo or look at installed.
//   2. A per-KPM manual URL install entry — the "paste a .kpm zip URL"
//      flow lives in kpm_repo.js's repo-manager dialog. The actual
//      install is delegated to installFromRepo() in that file because
//      it already has the sanitization, size cap, and tmpdir cleanup.
//
// This module is responsible for:
//   * Computing the diff between installed KPMs and the repo catalog
//   * Rendering "有新版本" badges on installed KPM cards (kpm.js)
//   * Rendering a global "X updates available" banner on the Kpm-Repo
//     page (kpm_repo.js)
//   * Auto-checking on app start (silent — toast only if updates found)
//
// The fetch of the repo catalog is the same one kpm_repo.js does. To
// avoid a duplicate network call, kpm_repo.js exposes its in-memory
// `allModules` via a getInstalledUpdates() call here; we just re-parse.

import { exec, toast } from 'kernelsu-alt';
import { modDir } from '../index.js';
import { getString } from '../language.js';
import { compareVersions } from '../utils.js';

const PNDIR = '/data/adb/patchnest';

/**
 * Build a map of id -> installed-version for all KPMs currently on the
 * device. Reads each module.prop under $PNDIR/kpm/<id>/ — the
 * directory layout installed by install_kpm.sh.
 *
 * The KPM module list shown in the WebUI comes from `kpatch kpm list`
 * but that returns a live (loaded) view, not the on-disk catalog. We
 * need the on-disk catalog so we can also detect installed-but-unloaded
 * updates.
 */
async function readInstalledKpmVersions() {
    // One shell call: ls the kpm dir, then cat each module.prop.
    // We don't have a parallel read helper in kernelsu-alt so we use
    // a single command with awk to produce "id=version" lines.
    //
    // NOTE: keep the `*` glob inside the shell string well clear of
    // any `*\/` sequence — the JSDoc block above this function ends
    // at the first `*\/` it sees, and a literal glob like
    // `"$PNDIR\/kpm"\/*\/` would close the comment prematurely.
    // We use a single-quoted glob with no leading `*\/` instead.
    const result = await exec(
        `if [ -d "${PNDIR}/kpm" ]; then
            for d in ${PNDIR}/kpm/[!.]*/; do
                [ -f "$d/module.prop" ] || continue
                mid=$(grep '^id=' "$d/module.prop" | head -1 | cut -d= -f2-)
                mver=$(grep '^version=' "$d/module.prop" | head -1 | cut -d= -f2-)
                [ -n "$mid" ] && printf '%s\\t%s\\n' "$mid" "$mver"
            done
         fi`,
        { env: { PATH: `${modDir}/bin:/system/bin:$PATH` } }
    );
    if (result.errno !== 0 || !result.stdout.trim()) return new Map();
    const out = new Map();
    for (const line of result.stdout.trim().split('\n')) {
        const [id, version] = line.split('\t');
        if (id) out.set(id, (version || '').trim());
    }
    return out;
}

/**
 * Compute the diff between installed KPMs and a list of repo entries.
 *
 * @param {Map<string,string>} installed  - id -> installed version
 * @param {Array<{id:string, version:string, ...}>} repoModules
 * @returns {{
 *   updates: Array<{id, name, installed, latest, repo, repoUrl, downloadUrl}>,
 *   latest: Map<string, object>,        // id -> best repo entry
 * }}
 *
 * `updates` is the subset of installed KPMs that have a strictly newer
 * version available in the repo. `latest` is every repo entry, indexed
 * by id, for callers that want the full catalog (e.g. the repo page
 * showing "what would I get if I install?").
 */
export function diffInstalledVsRepo(installed, repoModules) {
    const latest = new Map();
    for (const m of repoModules || []) {
        if (!m || !m.id) continue;
        const existing = latest.get(m.id);
        if (!existing || compareVersions(m.version, existing.version) > 0) {
            latest.set(m.id, m);
        }
    }

    const updates = [];
    for (const [id, installedVer] of installed) {
        const candidate = latest.get(id);
        if (!candidate) continue;
        if (compareVersions(candidate.version, installedVer) > 0) {
            updates.push({
                id,
                name: candidate.name || id,
                installed: installedVer,
                latest: candidate.version,
                repo: candidate._repo || '',
                repoUrl: candidate._repoUrl || '',
                downloadUrl: candidate.downloadUrl || '',
                signatureRequired: !!candidate.signatureRequired,
            });
        }
    }
    return { updates, latest };
}

/**
 * One-shot: read installed versions, then take an already-fetched repo
 * list (from kpm_repo.js's allModules) and produce the update diff.
 * Exposed for callers that already have the repo data in memory.
 */
export async function checkKpmUpdates(repoModules) {
    const installed = await readInstalledKpmVersions();
    return diffInstalledVsRepo(installed, repoModules);
}

/**
 * Render a "有新版本" badge onto an installed KPM card, and wire its
 * "update" action to install the matching repo entry. The card DOM is
 * built by page/kpm.js — this function just injects a badge and a
 * button. Returns true if the badge was added, false if no update.
 *
 * @param {HTMLElement} card - The .module-card element from kpm-list
 * @param {object} update   - One entry from the diff's `updates` array
 * @param {Function} onUpdate - Callback invoked when the user clicks
 *                              "update" — typically kpm_repo's
 *                              installFromRepo bound to the entry
 */
export function renderUpdateBadge(card, update, onUpdate) {
    if (!card || !update) return false;
    // Idempotent: skip if already added for this id.
    if (card.querySelector(`.kpm-update-badge[data-kpm-id="${CSS.escape(update.id)}"]`)) {
        return true;
    }
    const header = card.querySelector('.module-card-header');
    if (!header) return false;

    const badge = document.createElement('div');
    badge.className = 'tag tag-update kpm-update-badge';
    badge.dataset.kpmId = update.id;
    badge.title = getString('kpm_update_available_tooltip', update.installed, update.latest);
    badge.textContent = getString('kpm_update_badge', update.latest);

    const btn = document.createElement('md-filled-tonal-icon-button');
    btn.className = 'kpm-update-btn';
    btn.title = getString('kpm_update_button_title');
    btn.innerHTML = '<md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M200-120v-80h520v-40H320l40 40-56 56-160-160 160-160 56 56-40 40h400v240H200Zm560-560H240v40h400l-40-40 56-56 160 160-160 160-56-56 40-40H160v-240h600v80Z"/></svg></md-icon>';
    btn.onclick = (ev) => {
        ev.stopPropagation();
        if (typeof onUpdate === 'function') onUpdate(update);
    };

    const actions = card.querySelector('.module-card-actions');
    if (actions) {
        // Insert at the start so update is the most prominent action.
        actions.insertBefore(btn, actions.firstChild);
    }

    const titleRow = header.querySelector('.flex-header') || header;
    titleRow.appendChild(badge);
    return true;
}

/**
 * Show a transient toast with the count of available KPM updates.
 * Used by the auto-check on app start (silent on zero, toast on >0).
 */
export function notifyUpdateCount(updates) {
    if (!updates || updates.length === 0) return;
    toast(getString('kpm_updates_available_toast', updates.length));
}

/**
 * Auto-check entry point. Call from app init after the repo catalog has
 * been fetched. Errors are non-fatal: missing repo, no permission, etc.
 *
 * @param {Array} repoModules  - The fetched catalog (or null)
 */
export async function autoCheckKpmUpdates(repoModules) {
    try {
        const { updates } = await checkKpmUpdates(repoModules || []);
        notifyUpdateCount(updates);
        return updates;
    } catch (_) {
        return [];
    }
}
