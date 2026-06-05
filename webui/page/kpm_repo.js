import { exec, toast } from 'kernelsu-alt';
import { modDir, persistDir } from '../index.js';
import { getString } from '../language.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';
import { escapeHTML, sanitizeUrl } from '../utils.js';

const DEFAULT_REPO_URL = 'https://raw.githubusercontent.com/Zhanfg/KPatch-Next-Module/main/kpm_repo.json';
const REPO_URL_KEY = 'kp-next_repo_url';

let allModules = [];
let searchQuery = '';

function getRepoUrl() {
    return localStorage.getItem(REPO_URL_KEY) || DEFAULT_REPO_URL;
}

function setRepoUrl(url) {
    if (url && url.trim()) {
        localStorage.setItem(REPO_URL_KEY, url.trim());
    } else {
        localStorage.removeItem(REPO_URL_KEY);
    }
}

async function fetchRepo() {
    const rawUrl = getRepoUrl();
    const safeUrl = sanitizeUrl(rawUrl);
    if (!safeUrl) {
        const emptyMsg = document.getElementById('repo-empty-msg');
        emptyMsg.textContent = getString('msg_repo_fetch_failed');
        return;
    }
    const emptyMsg = document.getElementById('repo-empty-msg');
    emptyMsg.textContent = getString('status_loading');
    emptyMsg.classList.remove('hidden');

    try {
        // Use kpatch to fetch via the device's network
        const result = await exec(
            `curl -sL "${safeUrl}"`,
            { env: { PATH: `${modDir}/bin:/system/bin:$PATH` } }
        );

        if (result.errno !== 0 || !result.stdout.trim()) {
            emptyMsg.textContent = getString('msg_repo_fetch_failed');
            return;
        }

        const repo = JSON.parse(result.stdout);
        allModules = repo.modules || [];
        renderRepoList();
    } catch (e) {
        emptyMsg.textContent = getString('msg_error', e.message);
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
        card.innerHTML = `
            <div class="module-card-header">
                <div class="module-card-title">${escapeHTML(mod.name || mod.id)}</div>
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

function formatSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
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
        emptyMsg.textContent = getString('msg_no_modules_in_repo');
        emptyMsg.classList.remove('hidden');
    } else if (allModules.length === 0) {
        emptyMsg.textContent = getString('msg_no_modules_in_repo');
        emptyMsg.classList.remove('hidden');
    } else {
        emptyMsg.classList.add('hidden');
    }
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

export { fetchRepo, getRepoUrl, setRepoUrl };
