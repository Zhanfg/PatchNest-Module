import { exec, spawn, toast } from 'kernelsu-alt';
import { modDir, persistDir, MAX_CHUNK_SIZE, escapeShell, linkRedirect } from '../constants.js';
import { initInfo } from '../index.js';
import { getString } from '../language.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';
import { escapeHTML, sanitizeFilename, formatSize } from '../utils.js';
import {
    getKpmRuntimeStats,
    getKpmHeroStatus,
    invalidateKpmStatsCache,
} from './kpm_stats.js';

let allKpms = [];
let searchQuery = '';
let activeFilter = 'all'; // 'all' | 'loaded' | 'event'
let clickCount = 0;
let lastClickTime = 0;
let redirectShown = false;
let dashboardTimer = null;

async function getKpmInfo(path) {
    const result = await exec(`kptools -l -M "${path}"`, { env: { PATH: `${modDir}/bin` } });
    if (import.meta.env.DEV) { // vite debug
        result.stdout = 'name=Test Module\nversion=1.0.0\ndescription=This is a test module\nauthor=KOWX712\nlicense=MIT\nargs=test';
    }
    const infoLines = result.stdout.trim().split('\n');

    const moduleInfo = {};
    infoLines.forEach(line => {
        const [key, ...valueParts] = line.split('=');
        moduleInfo[key] = valueParts.join('=');
    });

    return moduleInfo;
}

async function getKpmList() {
    if (import.meta.env.DEV) { // vite debug
        return [
            {
                name: 'Test Module',
                version: '1.0.0',
                description: 'This is a test module',
                author: 'KOWX712',
                license: 'MIT',
                args: 'test'
            },
            {
                name: 'Test Module 2',
                version: '1.0.0',
                description: 'This is a test module',
                author: 'KOWX712',
                license: 'MIT',
                args: 'test'
            }
        ];
    }

    const listResult = await exec(`kpatch kpm list && sh "${modDir}/status.sh"`, { env: { PATH: `${modDir}/bin:$PATH` } });
    const modules = listResult.stdout.trim().split('\n').filter(line => line.trim());

    const modulePromises = modules.map(async (moduleName) => {
        const infoResult = await exec(`kpatch kpm info "${moduleName}"`, { env: { PATH: `${modDir}/bin` } });
        const infoLines = infoResult.stdout.trim().split('\n');

        const moduleInfo = {};
        infoLines.forEach(line => {
            const [key, ...valueParts] = line.split('=');
            moduleInfo[key] = valueParts.join('=');
        });

        return moduleInfo;
    });

    const results = await Promise.all(modulePromises);
    return results.sort((a, b) => (a.name || '').toLowerCase().localeCompare((b.name || '').toLowerCase()));
}

async function controlModule(moduleName, action) {
    const result = await exec(`kpatch kpm ctl0 "${moduleName}" ${escapeShell(action)}`, { env: { PATH: `${modDir}/bin` } });
    toast(result.errno === 0 ? result.stdout : result.stderr);
}

function forgetModule(moduleName) {
    exec(`rm -f "${persistDir}/kpm/${moduleName}.kpm"`);
}

async function unloadModule(moduleName) {
    forgetModule(moduleName);
    const result = await exec(`kpatch kpm unload "${moduleName}"`, { env: { PATH: `${modDir}/bin` } });
    return result.errno === 0;
}

async function loadModule(modulePath) {
    const result = await exec(`kpatch kpm load "${modulePath}"`, { env: { PATH: `${modDir}/bin` } });
    return result.errno === 0;
}

async function refreshKpmList() {
    const emptyMsg = document.getElementById('kpm-empty-msg');
    emptyMsg.textContent = getString('status_loading');
    emptyMsg.classList.remove('hidden');
    invalidateKpmStatsCache();
    allKpms = await getKpmList();
    renderKpmList();
    refreshKpmDashboard();
}

const kpmItemMap = new Map();

// ---------------------------------------------------------------------------
// KPM dashboard — per-card stats + page hero
// ---------------------------------------------------------------------------

/**
 * Render the per-card mini-dashboard inside an existing module card.
 * Pulls fresh runtime stats from kpm_stats.js and writes the values
 * into the slot left empty in the card template.
 */
async function renderCardDashboard(card, name) {
    const slot = card.querySelector('.kpm-dashboard-mini');
    if (!slot) return;
    const stats = await getKpmRuntimeStats(name);
    if (!stats) {
        slot.textContent = '';
        return;
    }

    const stateKey = `kpm_state_${stats.state}`;
    const stateText = getString(stateKey);
    const lastEvtText = stats.lastEvent
        ? (stats.lastEvent.ageSec < 60
            ? getString('kpm_stat_just_now')
            : formatUptime(stats.lastEvent.ageSec))
        : '—';

    // Use textContent to assign state class to avoid innerHTML-driven
    // XSS, then assemble each row with createElement. The only static
    // HTML we inject is i18n keys (no user input).
    slot.textContent = '';
    const row = document.createElement('div');
    row.className = 'kpm-dashboard-mini-row';

    const cells = [
        { label: getString('kpm_stat_state'),
          value: stateText,
          cls: 'kpm-state-' + stats.state,
          dot: true },
        { label: getString('kpm_stat_uptime'),
          value: stats.uptimeText,
          cls: 'kpm-state-loaded' },
        { label: getString('kpm_stat_size'),
          value: formatSize(stats.size),
          cls: '' },
        { label: getString('kpm_stat_last_event'),
          value: lastEvtText,
          cls: '' },
    ];
    cells.forEach((c) => {
        const cell = document.createElement('div');
        cell.className = 'kpm-stat';
        const lbl = document.createElement('div');
        lbl.className = 'kpm-stat-label';
        lbl.textContent = c.label;
        const val = document.createElement('div');
        val.className = 'kpm-stat-value ' + c.cls;
        if (c.dot) {
            const dot = document.createElement('span');
            dot.className = 'kpm-state-dot ' + c.cls;
            dot.setAttribute('aria-hidden', 'true');
            val.appendChild(dot);
            const txt = document.createElement('span');
            txt.className = 'kpm-state-text';
            txt.textContent = c.value;
            val.appendChild(txt);
        } else {
            val.textContent = c.value;
        }
        cell.appendChild(lbl);
        cell.appendChild(val);
        row.appendChild(cell);
    });
    slot.appendChild(row);

    if (stats.unsigned) {
        const warn = document.createElement('div');
        warn.className = 'kpm-dashboard-warn';
        warn.setAttribute('role', 'status');
        warn.textContent = getString('kpm_stat_unsigned_warn');
        slot.appendChild(warn);
    }
}

/**
 * Render the page-level hero (C-style) above the KPM list.
 * One status dot + one line of text.
 */
async function renderKpmHero() {
    const host = document.getElementById('kpm-hero');
    if (!host) return;
    const hero = await getKpmHeroStatus();
    if (!hero) {
        host.textContent = '';
        host.classList.add('hidden');
        return;
    }
    const dotClass = hero.failed > 0
        ? 'kpm-hero-down'
        : (hero.loaded > 0 ? 'kpm-hero-ok' : 'kpm-hero-idle');
    const statusText = hero.failed > 0
        ? getString('kpm_hero_down', hero.loaded, hero.failed)
        : (hero.loaded > 0
            ? getString('kpm_hero_ok', hero.loaded, hero.failed)
            : getString('kpm_hero_empty'));
    host.classList.remove('hidden');
    host.textContent = '';
    const dot = document.createElement('span');
    dot.className = 'kpm-hero-dot ' + dotClass;
    dot.setAttribute('aria-hidden', 'true');
    const txt = document.createElement('span');
    txt.className = 'kpm-hero-text';
    txt.textContent = statusText;
    host.appendChild(dot);
    host.appendChild(txt);
}

/**
 * Open the full-page dialog with the expanded dashboard for a KPM.
 * Content is built with textContent (not innerHTML) to be XSS-safe.
 */
async function openKpmFullDashboard(name) {
    const dialog = document.getElementById('kpm-dashboard-dialog');
    if (!dialog) return;
    const stats = await getKpmRuntimeStats(name);
    if (!stats) return;

    const headline = dialog.querySelector('[slot=headline]');
    headline.textContent = getString('kpm_dashboard_full_title') + ' — ' + name;

    const content = dialog.querySelector('[slot=content]');
    content.textContent = '';
    const wrap = document.createElement('div');
    wrap.className = 'kpm-dashboard-full';

    const rows = [
        ['kpm_stat_state', getString(`kpm_state_${stats.state}`)],
        ['kpm_stat_size', formatSize(stats.size)],
        ['kpm_stat_uptime', stats.uptimeText],
        ['kpm_stat_last_event', stats.lastEvent
            ? formatUptime(stats.lastEvent.ageSec) + ' (' + stats.lastEvent.type + ')'
            : '—'],
        ['kpm_stat_filters', String(stats.filterCount)],
        ['kpm_stat_errors', String(stats.errorCount)],
        ['kpm_stat_build', stats.buildId || '—'],
    ];
    rows.forEach(([k, v]) => {
        const r = document.createElement('div');
        r.className = 'kpm-dashboard-full-row';
        const labelEl = document.createElement('span');
        labelEl.className = 'kpm-dashboard-full-label';
        labelEl.textContent = getString(k);
        const valueEl = document.createElement('span');
        valueEl.className = 'kpm-dashboard-full-value';
        valueEl.textContent = v;
        r.appendChild(labelEl);
        r.appendChild(valueEl);
        wrap.appendChild(r);
    });
    if (stats.buildTime) {
        const t = document.createElement('div');
        t.className = 'kpm-dashboard-full-sub';
        t.textContent = getString('info_time', stats.buildTime);
        wrap.appendChild(t);
    }
    content.appendChild(wrap);

    dialog.querySelector('.cancel').onclick = () => dialog.close();
    dialog.show();
}

/**
 * Wire the body-tap-to-expand behaviour on a card. The click on a
 * button inside .module-card-actions is NOT considered a body tap
 * (so the existing control / dashboard / unload buttons still work).
 */
function wireCardExpand(item, moduleName) {
    item.addEventListener('click', (ev) => {
        const tgt = ev.target;
        if (tgt && tgt.closest('.module-card-actions')) return;
        openKpmFullDashboard(moduleName);
    });
}

/**
 * Refresh every card's mini-dashboard + the page hero. The 4s cache
 * inside kpm_stats.js means this stays cheap; we still rate-limit
 * the auto-refresh to 5s.
 */
async function refreshKpmDashboard() {
    for (const module of allKpms) {
        const card = kpmItemMap.get(module.name);
        if (!card) continue;
        if (card.classList.contains('search-hidden')) continue;
        await renderCardDashboard(card, module.name);
    }
    await renderKpmHero();
}

function startDashboardAutoRefresh() {
    if (dashboardTimer) return;
    dashboardTimer = setInterval(refreshKpmDashboard, 5000);
}

function stopDashboardAutoRefresh() {
    if (dashboardTimer) {
        clearInterval(dashboardTimer);
        dashboardTimer = null;
    }
}

async function renderKpmList() {
    const container = document.getElementById('kpm-list');
    container.innerHTML = '';

    allKpms.forEach(module => {
        let item = kpmItemMap.get(module.name);
        if (!item) {
            item = document.createElement('div');
            item.className = 'card module-card';
            item.innerHTML = `
                <div class="module-card-header">
                    <div class="module-card-title">${escapeHTML(module.name)}</div>
                    <div class="module-card-subtitle">${escapeHTML(module.version)}, ${getString('info_author', escapeHTML(module.author))}</div>
                    <div class="module-card-subtitle">${getString('info_args', escapeHTML(module.args) || '(null)')}</div>
                </div>
                <div class="module-card-content">
                    <div class="module-card-text">${escapeHTML(module.description)}</div>
                </div>
                <div class="kpm-dashboard-mini"></div>
                <md-divider></md-divider>
                <div class="module-card-actions">
                    <md-filled-tonal-icon-button class="control" title="${escapeHTML(getString('button_ok'))}">
                        <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="m370-80-16-128q-13-5-24.5-12T307-235l-119 50L78-375l103-78q-1-7-1-13.5v-27q0-6.5 1-13.5L78-585l110-190 119 50q11-8 23-15t24-12l16-128h220l16 128q13 5 24.5 12t22.5 15l119-50 110 190-103 78q1 7 1 13.5v27q0 6.5-2 13.5l103 78-110 190-118-50q-11 8-23 15t-24 12L590-80H370Zm70-80h79l14-106q31-8 57.5-23.5T639-327l99 41 39-68-86-65q5-14 7-29.5t2-31.5q0-16-2-31.5t-7-29.5l86-65-39-68-99 42q-22-23-48.5-38.5T533-694l-13-106h-79l-14 106q-31 8-57.5 23.5T321-633l-99-41-39 68 86 64q-5 15-7 30t-2 32q0 16 2 31t7 30l-86 65 39 68 99-42q22 23 48.5 38.5T427-266l13 106Zm42-180q58 0 99-41t41-99q0-58-41-99t-99-41q-59 0-99.5 41T342-480q0 58 40.5 99t99.5 41Zm-2-140Z" /></svg></md-icon>
                    </md-filled-tonal-icon-button>
                    <md-filled-tonal-icon-button class="dashboard" title="${escapeHTML(getString('kpm_dashboard_expand'))}">
                        <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M200-120q-33 0-56.5-23.5T120-200v-200h80v200h200v80H200Zm0-640v-80h200v80H200v200h-80v-200q0-33 23.5-56.5T200-840Zm560 640v-80h200v200q0 33-23.5 56.5T880-120H680v-80h80v-120Zm0-640h-80v-80h200q33 0 56.5 23.5T960-760v200h-80v-200H760ZM480-280q-83 0-141.5-58.5T280-480q0-83 58.5-141.5T480-680q83 0 141.5 58.5T680-480q0 83-58.5 141.5T480-280Zm0-80q50 0 85-35t35-85q0-50-35-85t-85-35q-50 0-85 35t-35 85q0 50 35 85t85 35Z"/></svg></md-icon>
                    </md-filled-tonal-icon-button>
                    <md-filled-tonal-icon-button class="unload" title="${escapeHTML(getString('button_unload'))}">
                        <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
                    </md-filled-tonal-icon-button>
                </div>
            `;

            const moduleName = module.name;
            item.querySelector('.control').onclick = () => {
                const dialog = document.getElementById('control-dialog');
                const textField = dialog.querySelector('md-outlined-text-field');
                dialog.querySelector('.cancel').onclick = () => dialog.close();
                dialog.querySelector('.confirm').onclick = async () => {
                    await controlModule(moduleName, textField.value);
                    refreshKpmList();
                    initInfo();
                    textField.value = '';
                    dialog.close();
                };
                dialog.show();
            };
            const dashBtn = item.querySelector('.dashboard');
            if (dashBtn) {
                dashBtn.onclick = (ev) => {
                    ev.stopPropagation();
                    openKpmFullDashboard(moduleName);
                };
            }
            wireCardExpand(item, moduleName);
            item.querySelector('.unload').onclick = async () => {
                const dialog = document.getElementById('unload-dialog');
                // P0-7 security fix: previously this used innerHTML with an
                // unescaped ${moduleName}. moduleName originates from
                // `kpatch kpm list` (or install_kpm.sh which writes the id
                // verbatim from a KPM's module.prop) — a malicious KPM
                // could inject <script> or other HTML. Use textContent
                // for the value and build the DOM safely.
                const slot = dialog.querySelector('[slot=content]');
                slot.textContent = '';
                const div = document.createElement('div');
                div.textContent = getString('msg_unload_module', moduleName);
                slot.appendChild(div);
                dialog.querySelector('.cancel').onclick = () => dialog.close();
                dialog.querySelector('.confirm').onclick = async () => {
                    await unloadModule(moduleName);
                    refreshKpmList();
                    initInfo();
                    dialog.close();
                };
                dialog.show();
            }

            kpmItemMap.set(moduleName, item);
        }
        container.appendChild(item);
    });

    // Prune any cached items that no longer exist (renamed or removed modules).
    // Otherwise a stale DOM element would persist with a listener bound to the
    // old name.
    const liveNames = new Set(allKpms.map(m => m.name));
    for (const cachedName of Array.from(kpmItemMap.keys())) {
        if (!liveNames.has(cachedName)) {
            kpmItemMap.delete(cachedName);
        }
    }

    applyFilters();
}

function applyFilters() {
    const query = searchQuery.toLowerCase();
    let visibleCount = 0;

    allKpms.forEach(module => {
        const item = kpmItemMap.get(module.name);
        if (!item) return;

        const matchesSearch = (module.name || '').toLowerCase().includes(query) ||
            (module.description || '').toLowerCase().includes(query) ||
            (module.args || '').toLowerCase().includes(query);

        // Filter chip logic. Each predicate is independent of the search
        // text — the search and the chip combine with AND.
        let matchesFilter = true;
        if (activeFilter === 'loaded') {
            // A module is considered "loaded" if the kpm list call returned
            // it (which it always does in this context, so this is a
            // placeholder for future loaded-state distinction).
            matchesFilter = true;
        } else if (activeFilter === 'event') {
            matchesFilter = !!(module.event && module.event.trim());
        }

        const isVisible = matchesSearch && matchesFilter;
        item.classList.toggle('search-hidden', !isVisible);
        if (isVisible) visibleCount++;
    });

    const emptyMsg = document.getElementById('kpm-empty-msg');
    if (visibleCount === 0) {
        emptyMsg.textContent = getString('msg_no_module_found');
        emptyMsg.classList.remove('hidden');
    } else {
        emptyMsg.classList.add('hidden');
    }
}

async function uploadFile(file, targetPath, onProgress, signal) {
    const CHUNK_SIZE = file.size > MAX_CHUNK_SIZE * 4 ? MAX_CHUNK_SIZE : Math.max(1, Math.ceil(file.size / 4));
    const totalChunks = Math.ceil(file.size / CHUNK_SIZE);
    const CONCURRENCY = 8;
    // Per-chunk write should not exceed this — 16 MB at 96KB chunks is ~3 minutes
    // of pipe time, well above any realistic transport delay.
    const CHUNK_TIMEOUT_MS = 60_000;
    // Final cat-merge should not exceed this.
    const COMBINE_TIMEOUT_MS = 120_000;

    // Wrap a child process in a promise that resolves on exit OR rejects on
    // timeout / abort. The child is killed in either failure case so we don't
    // leak orphan base64 pipes.
    const spawnWithTimeout = (cmd, timeoutMs) => new Promise((resolve, reject) => {
        const child = spawn(cmd);
        let settled = false;
        const onAbort = () => {
            if (settled) return;
            settled = true;
            try { child.kill('SIGKILL'); } catch (_) {}
            reject(new DOMException(signal?.aborted ? 'Aborted' : 'Timed out', signal?.aborted ? 'AbortError' : 'TimeoutError'));
        };
        const timer = setTimeout(onAbort, timeoutMs);
        child.on('exit', (code) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            resolve({ errno: code });
        });
        child.on('error', (err) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            reject(err);
        });
        if (signal) {
            if (signal.aborted) { onAbort(); return; }
            signal.addEventListener('abort', onAbort, { once: true });
        }
    });

    await exec(`mkdir -p "$(dirname "${targetPath}")"`);

    let uploadedBytes = 0;
    let nextChunkIdx = 0;

    const processChunk = async (index) => {
        if (signal?.aborted) return;

        const start = index * CHUNK_SIZE;
        const end = Math.min(start + CHUNK_SIZE, file.size);
        const chunk = file.slice(start, end);

        const base64 = await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result.split(',')[1]);
            reader.onerror = reject;
            reader.readAsDataURL(chunk);
        });

        const partPath = `${targetPath}.part${index.toString().padStart(8, '0')}`;
        const result = await spawnWithTimeout(
            `echo '${base64}' | base64 -d > "${partPath}"`,
            CHUNK_TIMEOUT_MS
        );

        if (result.errno !== 0) {
            throw new Error(`Write error at chunk ${index}`);
        }

        uploadedBytes += (end - start);
        if (onProgress) {
            onProgress(uploadedBytes / file.size);
        }
    };

    try {
        const workers = [];
        for (let i = 0; i < Math.min(CONCURRENCY, totalChunks); i++) {
            workers.push((async () => {
                while (nextChunkIdx < totalChunks && !signal?.aborted) {
                    const index = nextChunkIdx++;
                    await processChunk(index);
                }
            })());
        }

        await Promise.all(workers);

        if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');

        if (totalChunks === 0) {
            await exec(`: > "${targetPath}"`);
            return;
        }

        const combineResult = await spawnWithTimeout(
            `cat "${targetPath}.part"* > "${targetPath}" && rm -f "${targetPath}.part"*`,
            COMBINE_TIMEOUT_MS
        );
        if (combineResult.errno !== 0) {
            throw new Error('Merge error');
        }
    } catch (err) {
        await exec(`rm -f "${targetPath}.part"*`);
        throw err;
    }
}

function checkFileUploadApi() {
    // If the user reaches here 3 times in 2 seconds, the upload API is
    // likely missing on this WebUI host. We only want to suggest the
    // standalone once per session to avoid an annoying redirect on rapid clicks.
    if (redirectShown) return;
    const currentTime = Date.now();
    clickCount = (currentTime - lastClickTime > 2000) ? 1 : clickCount + 1;
    lastClickTime = currentTime;

    if (clickCount === 3) {
        clickCount = 0;
        redirectShown = true;
        linkRedirect('https://github.com/KOWX712/KsuWebUIStandalone/releases/latest');
    }
}

async function handleFileUpload(accept, containerId, onSelected) {
    checkFileUploadApi();
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = accept;
    input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;

        // P1-Cluster A fix: previous code did `file.name.endsWith(accept)`
        // which never matches when accept is a comma-separated list
        // (e.g. ".kpm,.zip"). Split on comma, trim, and match any.
        if (accept) {
            const exts = accept.split(',').map(s => s.trim()).filter(Boolean);
            const lowerName = file.name.toLowerCase();
            const ok = exts.some(ext => lowerName.endsWith(ext.toLowerCase()));
            if (!ok) {
                toast(getString('msg_please_select_file', accept));
                return;
            }
        }

        const abortController = new AbortController();
        const loadingCard = document.createElement('div');
        loadingCard.className = 'card module-card';
        // P0-fix (ultracode-audit-2026-06-06): escape file.name. A
        // user-selected KPM zip named e.g. "<img src=x onerror=alert(1)>.kpm"
        // would otherwise be injected as raw HTML and could call out to
        // attacker-controlled code in the WebView.
        loadingCard.innerHTML = `
            <div class="module-card-header flex-header">
                <div class="header-info">
                    <div class="module-card-title">${escapeHTML(file.name)}</div>
                    <div class="module-card-subtitle" id="upload-progress-text">${getString('msg_please_wait')}</div>
                </div>
                <md-outlined-icon-button id="cancel-upload">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="m256-200-56-56 224-224-224-224 56-56 224 224 224-224 56 56-224 224 224 224-56 56-224-224-224 224Z"/></svg></md-icon>
                </md-outlined-icon-button>
            </div>
            <div class="module-card-content">
                <md-linear-progress indeterminate></md-linear-progress>
            </div>
        `;
        const container = document.getElementById(containerId);
        container.prepend(loadingCard);

        const progressBar = loadingCard.querySelector('md-linear-progress');
        const progressText = loadingCard.querySelector('#upload-progress-text');
        const cancelBtn = loadingCard.querySelector('#cancel-upload');

        cancelBtn.onclick = () => {
            abortController.abort();
        };

        const onProgress = (percent) => {
            const p = Math.round(percent * 100);
            progressBar.value = percent;
            progressBar.indeterminate = false;
            progressText.textContent = getString('msg_uploading', p + '%');
        };

        try {
            await onSelected(file, onProgress, abortController.signal);
        } catch (err) {
            if (err.name === 'AbortError') {
                toast(getString('msg_upload_cancelled'));
            } else {
                toast(getString('msg_error', err.message));
            }
        } finally {
            loadingCard.remove();
        }
    };
    input.click();
}

async function uploadAndLoadModule() {
    const loadBtn = document.getElementById('load');
    handleFileUpload('.kpm,.zip', 'kpm-list', async (file, onProgress, signal) => {
        loadBtn.classList.add('hide');

        // Check if this is a ZIP package
        if (file.name.endsWith('.zip')) {
            await installKpmZip(file, onProgress, signal);
        } else {
            await loadKpmFile(file, onProgress, signal);
        }

        loadBtn.classList.remove('hide');
    });
}

async function installKpmZip(file, onProgress, signal) {
    const safeName = sanitizeFilename(file.name);
    const tmpPath = `${modDir}/tmp/${safeName}`;
    try {
        await exec(`mkdir -p ${modDir}/tmp && rm -rf ${modDir}/tmp/*`);
        await uploadFile(file, tmpPath, onProgress, signal);

        toast(getString('msg_installing_kpm'));

        // Run install_kpm.sh
        const result = await exec(
            `sh "${modDir}/install_kpm.sh" "${tmpPath}"`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );

        if (result.errno === 0) {
            toast(result.stdout || getString('msg_kpm_installed'));
            refreshKpmList();
        } else {
            toast(getString('msg_error', result.stderr || result.stdout));
        }
    } catch (e) {
        toast(getString('msg_error', e.message));
    } finally {
        exec(`rm -rf ${modDir}/tmp`);
    }
}

async function loadKpmFile(file, onProgress, signal) {
    const safeName = sanitizeFilename(file.name);
    const tmpPath = `${modDir}/tmp/${safeName}`;
    try {
        await exec(`mkdir -p ${modDir}/tmp && rm -rf ${modDir}/tmp/*`);
        await uploadFile(file, tmpPath, onProgress, signal);
        const info = await getKpmInfo(tmpPath);
        if (info && info.name) {
            const dialog = document.getElementById('load-dialog');
            dialog.querySelector('#load-module-msg').textContent = getString('msg_module_loaded', info.name);
            const checkbox = dialog.querySelector('md-checkbox');
            checkbox.checked = false;

            dialog.querySelector('.cancel').onclick = () => {
                dialog.close();
                exec(`rm -rf ${modDir}/tmp`);
            };

            dialog.querySelector('.confirm').onclick = async () => {
                // Sanitize once: the user's original filename is the trust boundary here.
                // Both sides of the upload flow must use the SAME safe name to avoid
                // a TOCTOU between upload() and loadModule().
                const safeFileName = sanitizeFilename(file.name) + '.kpm';
                const success = await loadModule(`${modDir}/tmp/${safeFileName}`);
                if (success) {
                    toast(getString('msg_successfully_loaded', info.name));
                    refreshKpmList();
                    if (!checkbox.checked) {
                        const safeName = sanitizeFilename(info.name);
                        exec(
                            `mkdir -p ${escapeShell(persistDir + '/kpm')}\n` +
                            `cp -f ${escapeShell(modDir + '/tmp/' + safeFileName)} ` +
                            `${escapeShell(persistDir + '/kpm/' + safeName + '.kpm')}`
                        );
                    }
                    // Success — safe to drop the tmp dir.
                    exec(`rm -rf ${escapeShell(modDir + '/tmp')}`);
                } else {
                    // Keep the uploaded file in tmp/ on failure so the user can
                    // inspect it (e.g. kptools -l -M) and so a retry can use
                    // it without re-uploading. The next upload/load cycle's
                    // `rm -rf ${modDir}/tmp/*` at the start will clear it.
                    toast(getString('msg_failed_load_module', info.name));
                }
                dialog.close();
            };

            dialog.show();
        } else {
            toast(getString('msg_failed_get_module_info'));
            exec(`rm -rf ${modDir}/tmp`);
        }
    } catch (e) {
        exec(`rm -rf ${modDir}/tmp`);
        throw e;
    }
}

export function initKPMPage() {
    const searchBtn = document.getElementById('kpm-search-btn');
    const searchBar = document.getElementById('kpm-search-bar');
    const closeBtn = document.getElementById('close-kpm-search-btn');
    const searchInput = document.getElementById('kpm-search-input');
    const menuBtn = document.getElementById('kpm-menu-btn');
    const menu = document.getElementById('kpm-menu');

    searchBtn.onclick = () => {
        searchBar.classList.add('show');
        document.querySelectorAll('.search-bg').forEach(el => el.classList.add('hide'));
        searchInput.focus();
    };

    closeBtn.onclick = () => {
        searchBar.classList.remove('show');
        document.querySelectorAll('.search-bg').forEach(el => el.classList.remove('hide'));
        searchQuery = '';
        searchInput.blur();
        searchInput.value = '';
        applyFilters();
    };

    searchInput.addEventListener('input', () => {
        searchQuery = searchInput.value;
        applyFilters();
    });

    // Filter chips: clicking a chip deselects others and applies the filter.
    const chips = document.querySelectorAll('#kpm-filter-chips md-filter-chip');
    chips.forEach(chip => {
        chip.addEventListener('click', () => {
            chips.forEach(c => c.selected = (c === chip));
            activeFilter = chip.dataset.filter || 'all';
            applyFilters();
        });
    });

    menuBtn.onclick = () => menu.show();

    document.getElementById('refresh-kpm-list-menu').onclick = () => {
        kpmItemMap.clear();
        refreshKpmList();
    };

    const controlDialog = document.getElementById('control-dialog');
    const controlTextField = controlDialog.querySelector('md-outlined-text-field');
    controlTextField.addEventListener('input', () => {
        controlDialog.querySelector('.confirm').disabled = !controlTextField.value;
    });

    document.getElementById('load').onclick = () => uploadAndLoadModule();

    setupPullToRefresh(document.querySelector('#kpm-page .page-content'), async () => {
        kpmItemMap.clear();
        await refreshKpmList();
    });

    // Start the dashboard auto-refresh loop (5s). The 4s cache inside
    // kpm_stats.js means each tick is cheap.
    startDashboardAutoRefresh();
}

export { loadModule, refreshKpmList, handleFileUpload, uploadFile }
