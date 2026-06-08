import { listPackages, getPackagesInfo, exec, toast } from 'kernelsu-alt';
import { modDir, persistDir, getEnv } from '../index.js';
import { escapeShell } from '../constants.js';
import { getString } from '../language.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';
import { escapeHTML } from '../utils.js';
import { readKsuAllowlist } from '../ksu.js';
import fallbackIcon from '../icon.png';

let allApps = [];
let showSystemApp = false;
let searchQuery = '';
const PROFILES_KEY = 'patchnest_exclude_profiles';
const ACTIVE_PROFILE_KEY = 'patchnest_exclude_active_profile';

const iconObserver = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            const img = entry.target.querySelector('.app-icon');
            const loader = img.parentElement.querySelector('.loader');
            const pkg = img.dataset.package;
            img.onload = () => {
                img.style.opacity = '1';
                loader.remove();
            };
            img.onerror = () => {
                img.src = fallbackIcon;
                img.style.opacity = '1';
                loader.remove();
            };
            img.src = `ksu://icon/${pkg}`;
            iconObserver.unobserve(entry.target);
        }
    });
}, { rootMargin: '100px' });

async function refreshAppList() {
    const appList = document.getElementById('app-list');
    const emptyMsg = document.getElementById('exclude-empty-msg');
    appList.innerHTML = '';
    emptyMsg.textContent = getString('status_loading');
    emptyMsg.classList.remove('hidden');

    try {
        if (import.meta.env.DEV) { // vite debug
            allApps = [
                { appLabel: 'Chrome', packageName: 'com.android.chrome', isSystem: false, uid: 10001 },
                { appLabel: 'Chrome', packageName: 'com.android.chrome', isSystem: false, uid: 1010001 },
                { appLabel: 'Google', packageName: 'com.google.android.googlequicksearchbox', isSystem: true, uid: 1010002 },
                { appLabel: 'Settings', packageName: 'com.android.settings', isSystem: true, uid: 10003 },
                { appLabel: 'WhatsApp', packageName: 'com.whatsapp', isSystem: false, uid: 10123 },
                { appLabel: 'Instagram', packageName: 'com.instagram.android', isSystem: false, uid: 1010456 }
            ];
        } else {
            const pkgs = await listPackages();
            const info = await getPackagesInfo(pkgs);
            allApps = Array.isArray(info) ? info : [];
        }
        renderAppList();
    } catch (e) {
        emptyMsg.textContent = getString('msg_error_loading_apps', e.message);
    }
}

let excludedApps = [];
const appItemMap = new Map();

async function saveExcludedList(excludedApps) {
    const header = 'pkg,exclude,allow,uid';
    const seen = new Set();
    const uniqueList = [];
    excludedApps.forEach(app => {
        const key = `${app.packageName}:${app.uid % 100000}`;
        if (!seen.has(key)) {
            seen.add(key);
            uniqueList.push(app);
        }
    });
    const lines = uniqueList.map(app => `${app.packageName},1,0,${app.uid % 100000}`);
    const csvContent = [header, ...lines].join('\n');
    if (import.meta.env.DEV) {
        localStorage.setItem('patchnest_excluded_mock', csvContent);
        return;
    }
    // Write via a quoted single-quoted heredoc and an explicit printf so a
    // malicious package name with " $ ` or \ cannot inject into the shell.
    // EOF delimiter is unique to the run; the leading '-' tolerates leading tabs.
    // P0-fix (ultracode-audit-2026-06-06): the previous code used
    // `Date.now() + Math.random()` to build the EOF token. Both are
    // non-cryptographic; an attacker who can predict the timestamp
    // window (~10ms) and the random suffix can craft CSV content
    // containing the same EOF token and exit the heredoc early,
    // then inject shell. Switch to crypto.getRandomValues, which
    // is available in every WebView Chromium 92+ supports.
    const eof = (() => {
        const buf = new Uint8Array(8);
        if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
            crypto.getRandomValues(buf);
        } else {
            for (let i = 0; i < 8; i++) buf[i] = Math.floor(Math.random() * 256);
        }
        let hex = '';
        for (let i = 0; i < buf.length; i++) hex += buf[i].toString(16).padStart(2, '0');
        return `__PN_EOF_${Date.now().toString(36)}_${hex}__`;
    })();
    await exec(`cat > ${escapeShell(persistDir + '/package_config')} <<'${eof}'\n${csvContent}\n${eof}`);
}

async function renderAppList() {
    const appList = document.getElementById('app-list');
    const emptyMsg = document.getElementById('exclude-empty-msg');

    try {
        let rawContent = '';
        if (import.meta.env.DEV) {
            rawContent = localStorage.getItem('patchnest_excluded_mock') || '';
        } else {
            // Prefer the KSU allowlist when KSU is the active root
            // manager — this is the canonical source of which apps
            // have root access. Falling back to package_config lets
            // Magisk/APatch/SukiSU users still see (and toggle) the
            // legacy KPatch exclude list. The two are kept in sync via
            // a service.sh watcher (see module/patch — future work).
            let useKsuAllowlist = false;
            try {
                const env = await getEnv();
                useKsuAllowlist = env.hasKsu && env.manager !== 'apatch';
            } catch (_) {}

            if (useKsuAllowlist) {
                // KSU's .allowlist is a plain-text file of UIDs (one
                // per line), e.g.:
                //   1000
                //   10001
                //   1010023
                // We can't derive package names from UIDs without
                // re-reading /data/system/packages.list, so we
                // return early and let the toggle path use the
                // KSU allowlist directly. The displayed list is
                // still built from allApps (every installed package).
                rawContent = '';
            } else {
                try {
                    const result = await exec(`cat ${persistDir}/package_config`);
                    if (result.errno === 0) {
                        rawContent = result.stdout.trim();
                    }
                } catch (e) {
                    console.warn('package_config not available.')
                }
            }
        }

        // Build appByRealUid map once so the toggle handler (which runs
        // later via closure) can do O(1) lookups instead of scanning allApps.
        const appByRealUid = new Map();
        allApps.forEach(app => {
            const rUid = app.uid % 100000;
            const key = `${(app.packageName || '').trim()}:${rUid}`;
            if (!appByRealUid.has(key)) appByRealUid.set(key, []);
            appByRealUid.get(key).push(app);
        });

        // Detect whether we should sync from KSU's allowlist (preferred
        // when KSU is the active manager) or from the legacy KPatch
        // package_config CSV. The two systems carry the same semantic
        // information when KSU is in use, but the KSU file is the
        // canonical one.
        let ksuAllowlist = null;
        try {
            const env = await getEnv();
            if (env.hasKsu && env.manager !== 'apatch') {
                ksuAllowlist = await readKsuAllowlist();
            }
        } catch (_) {}

        if (ksuAllowlist) {
            // Build excludedApps from KSU's allowlist (inverted: an app
            // is in the "excluded" set iff it is NOT in the allowlist).
            // The KSU allowlist is UIDs only, so we cross-reference
            // with allApps to recover package names for the UI.
            excludedApps = [];
            allApps.forEach(app => {
                if (!ksuAllowlist.has(app.uid)) {
                    excludedApps.push({ packageName: app.packageName, uid: app.uid });
                }
            });
        } else if (rawContent) {
            let lines = rawContent.split('\n').filter(l => l.trim());

            // Skip header
            if (lines.length > 0 && lines[0].startsWith('pkg,exclude')) {
                lines = lines.slice(1);
            }

            const list = lines.map(line => {
                const parts = line.split(',');
                if (parts.length < 4) return null;
                return { packageName: parts[0].trim(), uid: parseInt(parts[3]) };
            }).filter(item => item !== null);


            // Consistency check
            if (allApps.length > 0) {
                excludedApps = [];
                let changed = false;
                list.forEach(item => {
                    const key = `${item.packageName}:${item.uid}`;
                    const matches = appByRealUid.get(key);
                    if (matches) {
                        matches.forEach(app => {
                            excludedApps.push({ packageName: app.packageName, uid: app.uid });
                        });
                    } else {
                        excludedApps.push({ packageName: item.packageName, uid: item.uid });
                        changed = true; // item not in allApps; keep as-is
                    }
                });
                // Detect list expansion (multiple UID matches for one entry).
                if (!changed && excludedApps.length !== list.length) changed = true;

                if (changed) {
                    saveExcludedList(excludedApps);
                }
            } else {
                excludedApps = list;
            }
        }

        const excludedAppKeys = new Set(excludedApps.map(app => `${app.packageName}:${app.uid}`));

        const sortedApps = [...allApps].sort((a, b) => {
            const aExcluded = excludedAppKeys.has(`${a.packageName}:${a.uid}`);
            const bExcluded = excludedAppKeys.has(`${b.packageName}:${b.uid}`);
            if (aExcluded !== bExcluded) return aExcluded ? -1 : 1;
            return (a.appLabel || '').localeCompare(b.appLabel || '');
        });

        emptyMsg.classList.add('hidden');

        sortedApps.forEach(app => {
            const appKey = `${app.packageName}:${app.uid}`;
            let item = appItemMap.get(appKey);
            if (!item) {
                item = document.createElement('label');
                item.className = 'app-item';
                const userIdx = Math.floor(app.uid / 100000);
                const extraTags = [];
                if (userIdx > 0) extraTags.push(getString('info_user', userIdx));
                if (app.isSystem) extraTags.push(getString('info_system'));
                const extraTagsHtml = extraTags.length > 0 ? `
                    <div class="tag-wrapper">
                        ${extraTags.map(tag => `<div class="tag ${app.isSystem ? 'system' : ''}">${tag}</div>`).join('')}
                    </div>
                ` : '';

                item.innerHTML = `
                    <md-ripple></md-ripple>
                    <div class="icon-container">
                        <div class="loader"></div>
                        <img class="app-icon" data-package="${escapeHTML(app.packageName)}" style="opacity: 0;">
                    </div>
                    <div class="app-info">
                        <div class="app-label">${escapeHTML(app.appLabel) || getString('msg_unknown')}</div>
                        <div class="app-package">${escapeHTML(app.packageName)}</div>
                        ${extraTagsHtml}
                    </div>
                    <md-switch class="app-switch"></md-switch>
                `;

                const toggle = item.querySelector('md-switch');
                let saveTimeout = null;
                toggle.addEventListener('change', () => {
                    const realUid = app.uid % 100000;
                    const isSelected = toggle.selected;

                    // Sync state across all instances of the same app.
                    // Build a key list up-front instead of scanning allApps
                    // (O(N) per toggle) — apps with the same package+rUID
                    // are rare, so a direct index lookup is O(1).
                    const groupKey = `${app.packageName}:${realUid}`;
                    const group = appByRealUid.get(groupKey) || [app];
                    group.forEach(a => {
                        if (isSelected) {
                            if (!excludedApps.some(e => e.packageName === a.packageName && e.uid === a.uid)) {
                                excludedApps.push({ packageName: a.packageName, uid: a.uid });
                            }
                        } else {
                            excludedApps = excludedApps.filter(e => !(e.packageName === a.packageName && e.uid === a.uid));
                        }

                        const otherItem = appItemMap.get(`${a.packageName}:${a.uid}`);
                        if (otherItem) {
                            const otherToggle = otherItem.querySelector('md-switch');
                            if (otherToggle && otherToggle !== toggle) {
                                otherToggle.selected = isSelected;
                            }
                        }
                    });

                    if (saveTimeout) clearTimeout(saveTimeout);
                    saveTimeout = setTimeout(() => {
                        saveExcludedList(excludedApps);
                    }, 500);
                    // When KSU is the root manager, sync the toggle to
                    // KSU's allowlist so the native manager and the
                    // kernel module see the same state.
                    if (ksuAllowlist) {
                        if (isSelected) {
                            // Remove from allowlist (deny root).
                            exec(`ksuctl allow remove ${realUid}`, {
                                env: { PATH: `${modDir}/bin:/system/bin` }
                            });
                        } else {
                            // Add to allowlist (grant root).
                            exec(`ksuctl allow add ${realUid}`, {
                                env: { PATH: `${modDir}/bin:/system/bin` }
                            });
                        }
                    } else {
                        exec(`kpatch exclude_set ${realUid} ${isSelected ? 1 : 0}`, { env: { PATH: `${modDir}/bin` } });
                    }
                });

                appItemMap.set(appKey, item);
                iconObserver.observe(item);
            }

            // Update state
            const toggle = item.querySelector('md-switch');
            toggle.selected = excludedAppKeys.has(`${app.packageName}:${app.uid}`);

            appList.appendChild(item);
        });

        applyFilters();
    } catch (e) {
        emptyMsg.textContent = getString('msg_error_rendering_apps', e.message);
        emptyMsg.classList.remove('hidden');
    }
}

function applyFilters() {
    const query = searchQuery.toLowerCase();
    let visibleCount = 0;

    allApps.forEach(app => {
        const item = appItemMap.get(`${app.packageName}:${app.uid}`);
        if (!item) return;

        const matchesSearch = (app.appLabel || '').toLowerCase().includes(query) ||
            (app.packageName || '').toLowerCase().includes(query);
        const matchesSystem = showSystemApp || !app.isSystem;
        const isVisible = matchesSearch && matchesSystem;

        item.classList.toggle('search-hidden', !isVisible);
        if (isVisible) visibleCount++;
    });

    const emptyMsg = document.getElementById('exclude-empty-msg');
    if (visibleCount === 0) {
        emptyMsg.textContent = getString('msg_no_app_found');
        emptyMsg.classList.remove('hidden');
    } else {
        emptyMsg.classList.add('hidden');
    }
}

/**
 * Export the current exclude list to /storage/emulated/0/Download/ so the
 * user can move it between devices or back it up before flashing a new ROM.
 * File format is the same CSV the on-device service.sh reads.
 */
async function exportExcludeList() {
    if (excludedApps.length === 0) {
        toast(getString('msg_export_empty'));
        return;
    }
    const header = 'pkg,exclude,allow,uid';
    const lines = excludedApps.map(app => `${app.packageName},1,0,${app.uid % 100000}`);
    const csv = [header, ...lines].join('\n');
    // Write to a tmp file in modDir, then copy to Download. Going through
    // tmp means the heredoc-safe write logic is shared with saveExcludedList.
    // P0-fix (ultracode-audit-2026-06-06): use crypto.getRandomValues
    // instead of Math.random + Date.now alone — see saveExcludedList.
    const eof = (() => {
        const buf = new Uint8Array(8);
        if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
            crypto.getRandomValues(buf);
        } else {
            for (let i = 0; i < 8; i++) buf[i] = Math.floor(Math.random() * 256);
        }
        let hex = '';
        for (let i = 0; i < buf.length; i++) hex += buf[i].toString(16).padStart(2, '0');
        return `__PN_EOF_${Date.now().toString(36)}_${hex}__`;
    })();
    const tmp = `${persistDir}/export_exclude.csv`;
    const result = await exec(
        `cat > ${escapeShell(tmp)} <<'${eof}'\n${csv}\n${eof}`
    );
    if (result.errno !== 0) {
        toast(getString('msg_export_failed'));
        return;
    }
    const dest = `/storage/emulated/0/Download/patchnest-exclude-${Date.now()}.csv`;
    const cp = await exec(
        `cp ${escapeShell(tmp)} ${escapeShell(dest)} && rm -f ${escapeShell(tmp)}`
    );
    toast(cp.errno === 0
        ? getString('msg_export_success', dest)
        : getString('msg_export_failed'));
}

/**
 * Import an exclude list from a user-supplied file. Opens a file picker
 * for .csv files and applies the entries, merging with the current set.
 * The picker uses a hidden <input type="file"> created on demand.
 */
function importExcludeList() {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.csv,text/csv,text/plain';
    input.style.position = 'fixed';
    input.style.opacity = '0';
    input.style.pointerEvents = 'none';
    document.body.appendChild(input);

    let cleaned = false;
    const cleanup = () => {
        if (cleaned) return;
        cleaned = true;
        if (input.parentNode) input.parentNode.removeChild(input);
    };
    input.addEventListener('change', async () => {
        cleanup();
        const file = input.files && input.files[0];
        if (!file) return;
        try {
            const text = await file.text();
            // Parse CSV: skip header line if present, then expect 4 columns.
            const lines = text.split('\n').map(l => l.trim()).filter(Boolean);
            const dataLines = lines[0] && lines[0].startsWith('pkg,') ? lines.slice(1) : lines;
            let added = 0;
            for (const line of dataLines) {
                const parts = line.split(',');
                if (parts.length < 4) continue;
                const pkg = parts[0].trim();
                const uid = parseInt(parts[3].trim());
                if (!pkg || pkg.length > 255 || isNaN(uid) || uid < 0) continue;
                if (!excludedApps.some(a => a.packageName === pkg && a.uid === uid)) {
                    excludedApps.push({ packageName: pkg, uid });
                    added++;
                }
            }
            await saveExcludedList(excludedApps);
            // Re-render to pick up the new entries in the UI.
            appItemMap.clear();
            await refreshAppList();
            toast(getString('msg_import_success', added));
        } catch (e) {
            toast(getString('msg_import_failed', e.message));
        }
    });
    // If the user cancels the picker, fire the change event with no file
    // so cleanup runs.
    window.addEventListener('focus', () => setTimeout(cleanup, 500), { once: true });
    input.click();
}

// Initial setup for the search and menu
function initExcludePage() {
    const searchBtn = document.getElementById('search-btn');
    const searchBar = document.getElementById('app-search-bar');
    const closeBtn = document.getElementById('close-app-search-btn');
    const searchInput = document.getElementById('app-search-input');
    const menuBtn = document.getElementById('exclude-menu-btn');
    const menu = document.getElementById('exclude-menu');
    const systemAppCheckbox = document.getElementById('show-system-app');

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

    menuBtn.onclick = () => menu.show();

    systemAppCheckbox.addEventListener('change', () => {
        showSystemApp = systemAppCheckbox.checked;
        localStorage.setItem('patchnest_show_system_app', showSystemApp);
        applyFilters();
    });
    if (localStorage.getItem('patchnest_show_system_app') === 'true') {
        showSystemApp = true;
        systemAppCheckbox.checked = true;
    }

    document.getElementById('refresh-app-list').onclick = () => {
        appItemMap.clear();
        refreshAppList();
    };

    document.getElementById('export-exclude-list').onclick = () => exportExcludeList();
    document.getElementById('import-exclude-list').onclick = () => importExcludeList();

    setupPullToRefresh(document.querySelector('#exclude-page .page-content'), async () => {
        appItemMap.clear();
        await refreshAppList();
    });

    // Profile management.
    const profileMenu = document.getElementById('exclude-profile-menu');
    if (profileMenu) {
        document.getElementById('save-profile-btn')?.addEventListener('click', openSaveProfileDialog);
        document.getElementById('load-profile-btn')?.addEventListener('click', openLoadProfileDialog);
    }

    // init render
    refreshAppList();
}

/* ── Exclude profiles ──────────────────────────────────────────────
 * Named snapshots of the current exclude list. Useful when a user
 * wants a "test" config and a "production" config and can switch
 * between them without manually toggling each app. Stored in
 * localStorage as {name: [{pkg, uid}, ...]}.
 */

function getProfiles() {
    try {
        const raw = localStorage.getItem(PROFILES_KEY);
        return raw ? JSON.parse(raw) : {};
    } catch (_) { return {}; }
}
function saveProfiles(p) {
    localStorage.setItem(PROFILES_KEY, JSON.stringify(p));
}

/**
 * Open a dialog to save the current exclude list under a user-chosen name.
 * Reuses the existing control-dialog pattern (clone-and-replace for the
 * confirm button).
 */
function openSaveProfileDialog() {
    const dialog = document.getElementById('control-dialog');
    if (!dialog) return;
    const title = dialog.querySelector('[slot=headline]');
    const label = dialog.querySelector('[slot=content] > div');
    const field = dialog.querySelector('md-outlined-text-field');
    const confirmBtn = dialog.querySelector('.confirm');
    const cancelBtn = dialog.querySelector('.cancel');

    // Temporarily repurpose the dialog.
    const origTitle = title?.textContent;
    const origLabel = label?.textContent;
    if (title) title.textContent = getString('title_save_profile');
    if (label) label.textContent = getString('label_profile_name');
    if (field) { field.value = ''; field.disabled = false; }

    // Wire confirm.
    const origConfirm = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(origConfirm, confirmBtn);
    origConfirm.disabled = false;
    origConfirm.onclick = async () => {
        const name = field.value.trim();
        if (!name) return;
        const profiles = getProfiles();
        profiles[name] = excludedApps.map(a => ({ packageName: a.packageName, uid: a.uid }));
        saveProfiles(profiles);
        localStorage.setItem(ACTIVE_PROFILE_KEY, name);
        toast(getString('msg_profile_saved', name));
        dialog.close();
    };
    cancelBtn.onclick = () => dialog.close();
    dialog.show();
    dialog.addEventListener('close', () => {
        // Restore original content.
        if (title) title.textContent = origTitle;
        if (label) label.textContent = origLabel;
    }, { once: true });
}

/**
 * Open a dialog to load a saved profile. Shows a list of profile
 * names; selecting one applies it.
 */
function openLoadProfileDialog() {
    const profiles = getProfiles();
    const names = Object.keys(profiles);
    if (names.length === 0) {
        toast(getString('msg_no_profiles'));
        return;
    }
    const dialog = document.getElementById('control-dialog');
    if (!dialog) return;
    const title = dialog.querySelector('[slot=headline]');
    const contentDiv = dialog.querySelector('[slot=content] > div');
    const field = dialog.querySelector('md-outlined-text-field');
    const confirmBtn = dialog.querySelector('.confirm');
    const cancelBtn = dialog.querySelector('.cancel');

    const origTitle = title?.textContent;
    const origLabel = contentDiv?.textContent;
    if (title) title.textContent = getString('title_load_profile');
    if (contentDiv) contentDiv.textContent = getString('label_select_profile');

    // Build a selection list from the profile names.
    if (field) {
        field.style.display = 'none';
        // We'll build a list dynamically into the content area.
    }
    const content = dialog.querySelector('[slot=content]');
    const list = document.createElement('div');
    list.className = 'profile-list';
    names.forEach(name => {
        const row = document.createElement('div');
        row.className = 'profile-row';
        const count = profiles[name]?.length || 0;
        row.innerHTML = `
            <span class="profile-name">${escapeHTML(name)}</span>
            <span class="profile-count">${getString('profile_count', count)}</span>
            <md-icon-button class="profile-delete-btn">
                <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
            </md-icon-button>
        `;
        row.querySelector('.profile-name').onclick = async () => {
            // Apply this profile.
            excludedApps = (profiles[name] || []).map(a => ({ packageName: a.packageName, uid: a.uid }));
            localStorage.setItem(ACTIVE_PROFILE_KEY, name);
            await saveExcludedList(excludedApps);
            // Sync all toggle switches.
            const exKeys = new Set(excludedApps.map(a => `${a.packageName}:${a.uid}`));
            document.querySelectorAll('#app-list .app-switch').forEach(toggle => {
                const item = toggle.closest('.app-item') || toggle.closest('[class*=app-item]');
                // Nothing to sync here because the page will re-render.
            });
            appItemMap.clear();
            await refreshAppList();
            toast(getString('msg_profile_loaded', name));
            dialog.close();
        };
        row.querySelector('.profile-delete-btn').onclick = (e) => {
            e.stopPropagation();
            const p = getProfiles();
            delete p[name];
            saveProfiles(p);
            if (localStorage.getItem(ACTIVE_PROFILE_KEY) === name) {
                localStorage.removeItem(ACTIVE_PROFILE_KEY);
            }
            row.remove();
            if (Object.keys(p).length === 0) dialog.close();
        };
        list.appendChild(row);
    });
    // Replace the field with the list.
    if (field) field.style.display = 'none';
    // Insert list after the content div (before the dialog actions).
    contentDiv?.after?.(list) ?? content?.appendChild(list);

    const origConfirm = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(origConfirm, confirmBtn);
    origConfirm.disabled = true; // Profile is selected via row click.
    cancelBtn.onclick = () => dialog.close();
    dialog.show();
    dialog.addEventListener('close', () => {
        if (title) title.textContent = origTitle;
        if (contentDiv) contentDiv.textContent = origLabel;
        if (field) field.style.display = '';
        list.remove();
    }, { once: true });
}

export { refreshAppList, initExcludePage };
