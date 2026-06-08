import { exec, toast } from 'kernelsu-alt';
import { modDir, persistDir } from '../index.js';
import { getString } from '../language.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';
import { escapeShell } from '../constants.js';
import { escapeHTML, sanitizeUrl, formatSize } from '../utils.js';

// Default KPM repository URL — points to the standalone PatchNest-Kpms
// repo on the main branch. The PatchNest-Kpms repo is the
// independently-versioned KPM catalog for the PatchNest module.
// Forks of PatchNest-Kpms are encouraged — users can add them
// as additional subscriptions via the WebUI's "Add Repository"
// button.
const DEFAULT_REPO_URL = 'https://raw.githubusercontent.com/Zhanfg/PatchNest-Kpms/main/kpm_repo.json';
const REPOS_KEY = 'patchnest_repos';
const SYSTEM_REPOS_PATH = '/data/adb/patchnest/repos.json';

/**
 * Repo list shape in localStorage:
 *   [{ url: string, name: string }, ...]
 * The first entry is treated as the "primary" repo for display purposes.
 * Legacy patchnest_repo_url (a single string) is migrated on first read.
 */
let allModules = [];
let searchQuery = '';

function getRepos() {
    // System override: if /data/adb/patchnest/repos.json exists, it
    // defines the canonical repo list. This is set by the module
    // maintainer's customize.sh (or a root shell) and is meant for:
    //   * Custom PatchNest builds that ship a non-default default
    //     repo (e.g. a maintainer who wants to point users at their
    //     own Kpm-Repo fork).
    //   * Sysadmins who pre-configure a fleet of devices with a fixed
    //     repo catalog.
    // The file format is the same as the localStorage value:
    //   [{ "url": "https://...", "name": "..." }, ...]
    // If the file is unreadable or malformed we silently fall through
    // to the localStorage/default path.
    try {
        if (typeof window !== 'undefined' && window.__systemRepos) {
            const sys = window.__systemRepos;
            if (Array.isArray(sys) && sys.length > 0) return sys;
        }
    } catch (_) {}

    // Migrate the legacy single-URL key if present.
    const legacy = localStorage.getItem('patchnest_repo_url');
    if (legacy && !localStorage.getItem(REPOS_KEY)) {
        const migrated = [{ url: legacy, name: 'Main' }];
        localStorage.setItem(REPOS_KEY, JSON.stringify(migrated));
        localStorage.removeItem('patchnest_repo_url');
    }
    try {
        const parsed = JSON.parse(localStorage.getItem(REPOS_KEY) || 'null');
        if (Array.isArray(parsed) && parsed.length > 0) return parsed;
    } catch (_) {}
    // First-run default.
    return [{ url: DEFAULT_REPO_URL, name: getString('repo_official') }];
}

/**
 * Try to read /data/adb/patchnest/repos.json from the device. The file
 * can be created by the maintainer's customize.sh or by an admin via
 * `sh -c 'echo ... > /data/adb/patchnest/repos.json'`. We try the read
 * once at module load (synchronously-blocking is fine — this is a
 * single 100-byte file) and cache the result in window.__systemRepos.
 *
 * If the file is missing, unreadable, or doesn't parse as JSON, we
 * leave window.__systemRepos undefined and getRepos() falls through
 * to the localStorage path.
 */
async function loadSystemRepos() {
    try {
        const r = await exec(
            `cat ${SYSTEM_REPOS_PATH} 2>/dev/null`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );
        if (!r || r.errno !== 0 || !r.stdout) return;
        const trimmed = r.stdout.trim();
        if (!trimmed) return;
        const parsed = JSON.parse(trimmed);
        if (Array.isArray(parsed) && parsed.length > 0) {
            window.__systemRepos = parsed;
        }
    } catch (_) {
        // Malformed JSON, missing file, no permission — all non-fatal.
    }
}

function setRepos(repos) {
    if (!Array.isArray(repos) || repos.length === 0) {
        localStorage.removeItem(REPOS_KEY);
        return;
    }
    localStorage.setItem(REPOS_KEY, JSON.stringify(repos));
}

/**
 * Snapshot accessor for the in-memory repo catalog. Returns a shallow
 * copy so callers (notably kpm-update.js) can iterate without risk
 * of being mutated by a concurrent fetchRepo(). Returns [] before the
 * first fetchRepo() resolves.
 */
function getAllRepoModules() {
    return allModules.slice();
}

/**
 * Backwards-compat shim. The old single-URL API is still imported by
 * index.js for the Settings detail line; redirect to the primary repo.
 *
 * P2-fix: both functions had no callers in any *.js/*.html across the
 * project (verified by grep). They were only re-exported at the bottom
 * of this file. Safe to delete; keep a stub comment for one release to
 * avoid surprising downstream forks.
 */
// getRepoUrl/setRepoUrl removed in PR3. Use getRepos()/setRepos() instead.

async function fetchRepo() {
    const repos = getRepos();
    const emptyMsg = document.getElementById('repo-empty-msg');
    emptyMsg.textContent = getString('status_loading');
    emptyMsg.classList.remove('hidden');

    // Fan out: fetch each repo in parallel, then merge. The empty-msg
    // state is updated as results come in: any successful repo hides
    // the loading message; only the all-failed case keeps it visible.
    const results = await Promise.all(repos.map(fetchOne));

    // Merge modules, dedup by `id` (first-seen wins). Different repos can
    // legitimately publish the same module under different names; dedup
    // by id is the convention.
    const seen = new Set();
    const merged = [];
    for (const r of results) {
        if (!r) continue;
        for (const m of r.modules) {
            if (!m || !m.id) continue;
            if (seen.has(m.id)) continue;
            seen.add(m.id);
            // Tag each module with which repo it came from, so the card
            // can show the source and installFromRepo can quote it.
            merged.push({ ...m, _repo: r.name, _repoUrl: r.url });
        }
    }
    allModules = merged;

    if (allModules.length === 0) {
        emptyMsg.textContent = getString('msg_no_modules_in_repo');
        emptyMsg.classList.remove('hidden');
    } else {
        emptyMsg.classList.add('hidden');
    }
    renderRepoList();
}

/**
 * Fetch a single repo. Returns { name, url, modules: [] } on success,
 * null on failure. Network errors and JSON parse errors are both
 * tolerated — the caller just won't see modules from this repo.
 */
async function fetchOne(repo) {
    const safeUrl = sanitizeUrl(repo.url);
    if (!safeUrl) return null;
    try {
        const result = await exec(
            `curl -sL --max-time 10 ${escapeShell(safeUrl)}`,
            { env: { PATH: `${modDir}/bin:/system/bin:$PATH` } }
        );
        if (result.errno !== 0 || !result.stdout.trim()) return null;
        const data = JSON.parse(result.stdout);
        const modules = Array.isArray(data.modules) ? data.modules : [];
        return { name: repo.name, url: repo.url, modules };
    } catch (_) {
        return null;
    }
}

function renderRepoList() {
    const container = document.getElementById('repo-list');
    const emptyMsg = document.getElementById('repo-empty-msg');
    container.innerHTML = '';

    if (allModules.length === 0) {
        emptyMsg.textContent = getString('msg_no_modules_in_repo');
        emptyMsg.classList.remove('hidden');
        return;
    }

    emptyMsg.classList.add('hidden');

    allModules.forEach((mod, idx) => {
        const card = document.createElement('div');
        card.className = 'card module-card';
        const sizeStr = mod.size ? formatSize(mod.size) : '';
        // Repo name rendered as a small tag so the user can see where
        // each module came from. Empty when the source is the default
        // "Official" repo, to keep the list uncluttered.
        const repoTag = mod._repo && mod._repo !== getString('repo_official')
            ? `<div class="tag tag-repo">${escapeHTML(mod._repo)}</div>`
            : '';
        // Signature-required badge: shown when the repo entry has
        // signatureRequired === true. This is a UI hint that the module
        // ships with a .kpm.sig and will be verified by the boot-time
        // service.sh before kpatch kpm load. It does NOT by itself
        // block installation — enforcement is controlled by
        // REQUIRE_KPM_SIGNATURES in /data/adb/patchnest/config, which the
        // WebUI cannot read directly.
        const sigTag = mod.signatureRequired
            ? `<div class="tag tag-signed" title="Signed (Ed25519)">${getString('tag_signed')}</div>`
            : '';
        card.innerHTML = `
            <div class="module-card-header">
                <div class="flex-header">
                    <div class="module-card-title">${escapeHTML(mod.name || mod.id)}</div>
                    ${repoTag}
                    ${sigTag}
                </div>
                <div class="module-card-subtitle">${escapeHTML(mod.version || '0.0.0')} ${sizeStr ? '· ' + sizeStr : ''}</div>
                <div class="module-card-subtitle">${getString('info_author', escapeHTML(mod.author) || getString('msg_unknown'))}</div>
            </div>
            <div class="module-card-content">
                <div class="module-card-text">${escapeHTML(mod.description) || getString('info_no_description')}</div>
            </div>
            <md-divider></md-divider>
            <div class="module-card-actions">
                <md-filled-tonal-icon-button class="install-btn">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M440-120v-320H120v-80h320v-320h80v320h320v80H520v320h-80Z"/></svg></md-icon>
                </md-filled-tonal-icon-button>
            </div>
        `;

        card.dataset.idx = idx;
        card.querySelector('.install-btn').onclick = () => installFromRepo(mod);
        container.appendChild(card);
    });

    applyFilters();
}

async function installFromRepo(mod) {
    if (!mod.downloadUrl) {
        toast(getString('msg_no_download_url'));
        return;
    }

    const safeUrl = sanitizeUrl(mod.downloadUrl);
    if (!safeUrl) {
        toast(getString('msg_error', 'Invalid download URL'));
        return;
    }

    toast(getString('msg_installing_kpm'));

    try {
        const filename = sanitizeFilename(mod.id || mod.name) + '.zip';
        const tmpPath = `${modDir}/tmp/${filename}`;

        await exec(`mkdir -p ${escapeShell(modDir + '/tmp')} && rm -rf ${escapeShell(modDir + '/tmp')}/*`);

        // Download the module. Cap the download at 50 MiB to defend against a
        // malicious or compromised repo that hands us a multi-GB payload.
        const dlResult = await exec(
            `curl -sL --max-filesize 52428800 ${escapeShell(safeUrl)} -o ${escapeShell(tmpPath)}`,
            { env: { PATH: `/system/bin:$PATH` } }
        );

        if (dlResult.errno !== 0) {
            toast(getString('msg_error', 'Download failed (file too large or network error)'));
            return;
        }

        // Install via install_kpm.sh
        const installResult = await exec(
            `sh ${escapeShell(modDir + '/install_kpm.sh')} ${escapeShell(tmpPath)}`,
            { env: { PATH: `${modDir}/bin:/system/bin` } }
        );

        if (installResult.errno === 0) {
            toast(getString('msg_kpm_installed'));
        } else {
            toast(getString('msg_error', installResult.stderr || installResult.stdout));
        }
    } catch (e) {
        toast(getString('msg_error', e.message));
    } finally {
        try {
            await exec(`rm -rf ${escapeShell(modDir + '/tmp')}`);
        } catch (_) { /* best-effort cleanup */ }
    }
}

function applyFilters() {
    const query = searchQuery.toLowerCase();
    let visibleCount = 0;

    const cards = document.querySelectorAll('#repo-list .module-card');
    cards.forEach((card) => {
        const idx = parseInt(card.dataset.idx, 10);
        const mod = allModules[idx];
        if (!mod) return;
        const matches = (mod.name || '').toLowerCase().includes(query) ||
            (mod.description || '').toLowerCase().includes(query) ||
            (mod.id || '').toLowerCase().includes(query);
        card.classList.toggle('search-hidden', !matches);
        if (matches) visibleCount++;
    });

    const emptyMsg = document.getElementById('repo-empty-msg');
    if (visibleCount === 0 && allModules.length > 0) {
        emptyMsg.textContent = getString('msg_no_module_found');
        emptyMsg.classList.remove('hidden');
    } else if (allModules.length === 0) {
        emptyMsg.textContent = getString('msg_no_modules_in_repo');
        emptyMsg.classList.remove('hidden');
    } else {
        emptyMsg.classList.add('hidden');
    }
}

/**
 * Open a dialog to manage the list of subscribed repos. Each row is
 * [name | url] with a delete button; a footer "Add" button appends a
 * new row. Saving the dialog persists the new repo list.
 */
function openRepoManager() {
    const dialog = document.getElementById('repo-manager-dialog');
    if (!dialog) return;
    const list = dialog.querySelector('#repo-manager-list');
    const addBtn = dialog.querySelector('.repo-add');
    const saveBtn = dialog.querySelector('.repo-save');
    const cancelBtn = dialog.querySelector('.repo-cancel');

    const rebuild = () => {
        const repos = getRepos();
        list.innerHTML = '';
        repos.forEach((r, idx) => {
            const row = document.createElement('div');
            row.className = 'repo-row';
            row.innerHTML = `
                <md-outlined-text-field label="Name" data-field="name" value="${escapeHTML(r.name || '')}"></md-outlined-text-field>
                <md-outlined-text-field label="URL" data-field="url" value="${escapeHTML(r.url || '')}" type="url"></md-outlined-text-field>
                <md-icon-button class="repo-remove" title="${getString('button_delete')}">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
                </md-icon-button>
            `;
            row.querySelector('.repo-remove').onclick = () => {
                row.remove();
            };
            list.appendChild(row);
        });
    };

    addBtn.onclick = () => {
        const row = document.createElement('div');
        row.className = 'repo-row';
        row.innerHTML = `
            <md-outlined-text-field label="Name" data-field="name" placeholder="${escapeHTML(getString('repo_placeholder_name'))}"></md-outlined-text-field>
            <md-outlined-text-field label="URL" data-field="url" type="url" placeholder="https://..."></md-outlined-text-field>
            <md-icon-button class="repo-remove" title="${getString('button_delete')}">
                <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
            </md-icon-button>
        `;
        row.querySelector('.repo-remove').onclick = () => row.remove();
        list.appendChild(row);
    };

    saveBtn.onclick = () => {
        const rows = list.querySelectorAll('.repo-row');
        const newRepos = [];
        for (const r of rows) {
            const name = r.querySelector('[data-field="name"]')?.value?.trim();
            const url = r.querySelector('[data-field="url"]')?.value?.trim();
            if (!url) continue;
            const safe = sanitizeUrl(url);
            if (!safe) continue;
            newRepos.push({ name: name || new URL(safe).hostname, url: safe });
        }
        if (newRepos.length === 0) {
            // Don't allow an empty list — fall back to default.
            newRepos.push({ url: DEFAULT_REPO_URL, name: getString('repo_official') });
        }
        setRepos(newRepos);
        dialog.close();
        // Update the Settings detail line.
        const detail = document.getElementById('current-repo-url');
        if (detail) {
            const primary = newRepos[0];
            detail.textContent = newRepos.length === 1
                ? primary.url
                : `${primary.name} (+${newRepos.length - 1} ${getString('repo_more')})`;
        }
        toast(getString('msg_repo_url_updated'));
        // Auto-refresh the repo page with the new list.
        fetchRepo();
    };
    cancelBtn.onclick = () => dialog.close();

    rebuild();
    dialog.show();
}

/**
 * Manual "paste a .kpm zip URL" install dialog. This is the
 * "KPM 像 APM 一样可以通过指定的链接进行更新" entry point that doesn't
 * require the user to subscribe to a repo first.
 *
 * The actual install reuses installFromRepo() — same sanitizeUrl +
 * 50 MiB cap + install_kpm.sh pipeline, so URL-injection and oversized
 * payloads are blocked the same way as repo entries.
 */
function openUrlInstallDialog() {
    const dialog = document.getElementById('url-install-dialog');
    if (!dialog) return;
    const input = dialog.querySelector('#url-install-input');
    const confirmBtn = dialog.querySelector('.url-install-confirm');
    const cancelBtn = dialog.querySelector('.url-install-cancel');

    const close = () => dialog.close();
    cancelBtn.onclick = close;
    confirmBtn.onclick = async () => {
        const url = input.value && input.value.trim();
        if (!url) {
            toast(getString('msg_error', 'URL is empty'));
            return;
        }
        const safe = sanitizeUrl(url);
        if (!safe) {
            toast(getString('msg_error', 'Invalid URL (http/https only)'));
            return;
        }
        // Derive a placeholder id from the URL path so installFromRepo
        // can write a sensible filename; install_kpm.sh will overwrite
        // it with the real id parsed from module.prop inside the zip.
        let placeholderId = 'manual';
        try {
            const u = new URL(safe);
            const last = u.pathname.split('/').filter(Boolean).pop() || 'manual';
            placeholderId = last.replace(/\.zip$/i, '') || 'manual';
        } catch (_) {}
        confirmBtn.disabled = true;
        try {
            await installFromRepo({
                id: placeholderId,
                name: placeholderId,
                version: '0.0.0',
                downloadUrl: safe,
            });
        } finally {
            confirmBtn.disabled = false;
            input.value = '';
            close();
        }
    };
    dialog.show();
    if (input) input.focus();
}

export function initRepoPage() {
    // Load the system-managed repo override once at init. We don't
    // await — getRepos() handles the missing/empty case gracefully
    // (falls through to localStorage, then to the built-in default).
    // Subsequent getRepos() calls within the same WebView session
    // will pick up window.__systemRepos.
    loadSystemRepos();

    const searchBtn = document.getElementById('repo-search-btn');
    const searchBar = document.getElementById('repo-search-bar');
    const closeBtn = document.getElementById('close-repo-search-btn');
    const searchInput = document.getElementById('repo-search-input');
    const refreshBtn = document.getElementById('repo-refresh');

    if (searchBtn) {
        searchBtn.onclick = () => {
            searchBar.classList.add('show');
            searchInput.focus();
        };
    }

    if (closeBtn) {
        closeBtn.onclick = () => {
            searchBar.classList.remove('show');
            searchQuery = '';
            searchInput.value = '';
            applyFilters();
        };
    }

    if (searchInput) {
        searchInput.addEventListener('input', () => {
            searchQuery = searchInput.value;
            applyFilters();
        });
    }

    if (refreshBtn) {
        refreshBtn.onclick = fetchRepo;
    }

    // "Install from URL" button — lets users paste a direct .kpm zip
    // link without subscribing to a repo. Same safety pipeline as
    // installFromRepo, just a different entry point.
    const urlInstallBtn = document.getElementById('url-install-btn');
    if (urlInstallBtn) {
        urlInstallBtn.onclick = openUrlInstallDialog;
    }

    setupPullToRefresh(document.querySelector('#repo-page .page-content'), fetchRepo);
}

export { fetchRepo, getRepos, setRepos, openRepoManager, installFromRepo, getAllRepoModules, openUrlInstallDialog };
