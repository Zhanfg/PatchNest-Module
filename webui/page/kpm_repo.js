import { exec, toast } from 'kernelsu-alt';
import { modDir, persistDir } from '../index.js';
import { getString } from '../language.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';
import { escapeHTML, sanitizeUrl, formatSize } from '../utils.js';

const DEFAULT_REPO_URL = 'https://raw.githubusercontent.com/Zhanfg/KPatch-Next-Module/main/kpm_repo.json';
const REPOS_KEY = 'kp-next_repos';

/**
 * Repo list shape in localStorage:
 *   [{ url: string, name: string }, ...]
 * The first entry is treated as the "primary" repo for display purposes.
 * Legacy kp-next_repo_url (a single string) is migrated on first read.
 */
let allModules = [];
let searchQuery = '';

function getRepos() {
    // Migrate the legacy single-URL key if present.
    const legacy = localStorage.getItem('kp-next_repo_url');
    if (legacy && !localStorage.getItem(REPOS_KEY)) {
        const migrated = [{ url: legacy, name: 'Main' }];
        localStorage.setItem(REPOS_KEY, JSON.stringify(migrated));
        localStorage.removeItem('kp-next_repo_url');
    }
    try {
        const parsed = JSON.parse(localStorage.getItem(REPOS_KEY) || 'null');
        if (Array.isArray(parsed) && parsed.length > 0) return parsed;
    } catch (_) {}
    // First-run default.
    return [{ url: DEFAULT_REPO_URL, name: getString('repo_official') }];
}

function setRepos(repos) {
    if (!Array.isArray(repos) || repos.length === 0) {
        localStorage.removeItem(REPOS_KEY);
        return;
    }
    localStorage.setItem(REPOS_KEY, JSON.stringify(repos));
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
            `curl -sL --max-time 10 "${safeUrl}"`,
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

    allModules.forEach(mod => {
        const card = document.createElement('div');
        card.className = 'card module-card';
        const sizeStr = mod.size ? formatSize(mod.size) : '';
        // Repo name rendered as a small tag so the user can see where
        // each module came from. Empty when the source is the default
        // "Official" repo, to keep the list uncluttered.
        const repoTag = mod._repo && mod._repo !== getString('repo_official')
            ? `<div class="tag tag-repo">${escapeHTML(mod._repo)}</div>`
            : '';
        card.innerHTML = `
            <div class="module-card-header">
                <div class="flex-header">
                    <div class="module-card-title">${escapeHTML(mod.name || mod.id)}</div>
                    ${repoTag}
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

        await exec(`mkdir -p ${modDir}/tmp && rm -rf ${modDir}/tmp/*`);

        // Download the module. Cap the download at 50 MiB to defend against a
        // malicious or compromised repo that hands us a multi-GB payload.
        const dlResult = await exec(
            `curl -sL --max-filesize 52428800 "${safeUrl}" -o "${tmpPath}"`,
            { env: { PATH: `/system/bin:$PATH` } }
        );

        if (dlResult.errno !== 0) {
            toast(getString('msg_error', 'Download failed (file too large or network error)'));
            return;
        }

        // Install via install_kpm.sh
        const installResult = await exec(
            `sh "${modDir}/install_kpm.sh" "${tmpPath}"`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );

        if (installResult.errno === 0) {
            toast(getString('msg_kpm_installed'));
        } else {
            toast(getString('msg_error', installResult.stderr || installResult.stdout));
        }
    } catch (e) {
        toast(getString('msg_error', e.message));
    } finally {
        exec(`rm -rf ${modDir}/tmp`);
    }
}

function applyFilters() {
    const query = searchQuery.toLowerCase();
    let visibleCount = 0;

    const cards = document.querySelectorAll('#repo-list .module-card');
    cards.forEach((card, idx) => {
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

export function initRepoPage() {
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

    setupPullToRefresh(document.querySelector('#repo-page .page-content'), fetchRepo);
}

export { fetchRepo, getRepos, setRepos, openRepoManager };
