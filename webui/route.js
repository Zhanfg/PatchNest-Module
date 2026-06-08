import * as patchModule from './page/patch.js';
import * as logModule from './page/log.js';
import * as backupModule from './page/backup.js';
import * as repoModule from './page/kpm_repo.js';
import * as stealthModule from './page/stealth.js';
import { getString } from './language.js';

const backBtn = document.getElementById('back-btn');

function setupExitBtn() {
    if (!backBtn) return;
    const ksuExit = typeof window.ksu?.exit === 'function';
    const webuiExit = typeof window.webui?.exit === 'function';

    if (ksuExit || webuiExit) {
        backBtn.style.display = 'inline-flex';
        backBtn.onclick = (e) => {
            e.stopPropagation();
            setTimeout(() => ksuExit ? window.ksu.exit() : window.webui.exit(), 0);
        };
    } else {
        backBtn.style.display = 'none';
        backBtn.onclick = null;
    }
}

// Page switcher
function switchPage(pageId, title, navId = null) {
    document.getElementById('close-kpm-search-btn')?.click();
    document.getElementById('close-app-search-btn')?.click();
    document.querySelectorAll('.page').forEach(p => p.classList.toggle('active', p.id === pageId));
    const titleEl = document.querySelector('.title');
    if (titleEl) titleEl.textContent = title;

    // Icon
    // P1 fix: optional chaining can't be on the left-hand side of an
    // assignment. Capture the element first, then guard with a regular
    // if-check before mutating its style. Same pattern repeated for
    // each top-bar icon and the trailing-btn below.
    const homeIcon = document.getElementById('home-icon');
    if (homeIcon) homeIcon.style.display = (pageId === 'home-page' ? 'flex' : 'none');
    const kpmIcon = document.getElementById('kpm-icon');
    if (kpmIcon) kpmIcon.style.display = (pageId === 'kpm-page' ? 'flex' : 'none');
    const excludeIcon = document.getElementById('exclude-icon');
    if (excludeIcon) excludeIcon.style.display = (pageId === 'exclude-page' ? 'flex' : 'none');

    // Bottom Bar
    const isPrimary = navId !== null;
    document.querySelector('.bottom-bar')?.classList.toggle('hide', !isPrimary);
    document.querySelector('.content')?.classList.toggle('no-bottom-bar', !isPrimary);

    if (isPrimary) {
        updateBottomBar(navId);
        setupExitBtn();
        setTimeout(() => {
            document.querySelectorAll('.animated').forEach(el => el.classList.add('animate-hidden'));
        }, 200);
    } else {
        backBtn.style.display = 'inline-flex';
        backBtn.onclick = (e) => {
            e.stopPropagation();
            navigateToHome();
        };
    }
}

// Patch/UnPatch
function preparePatchUI(title, isUnpatch) {
    switchPage('patch-page', title);
    const trailingBtn = document.querySelector('.trailing-btn');
    if (trailingBtn) trailingBtn.style.display = 'flex';
    document.getElementById('patch-terminal').innerHTML = '';
    document.getElementById('reboot-fab').classList.add('hide');

    document.querySelectorAll('.patch-only').forEach(p => p.classList.toggle('hidden', isUnpatch));
    document.querySelectorAll('.unpatch-only').forEach(p => p.classList.toggle('hidden', !isUnpatch));
}

function navigateToHome() {
    switchPage('home-page', 'PatchNest', 'home');
}

function navigateToKPM() {
    switchPage('kpm-page', getString('title_kpmodule'), 'KPM');
}

function navigateToExclude() {
    switchPage('exclude-page', getString('title_exclude'), 'exclude');
}

function navigateToSettings() {
    switchPage('settings-page', getString('title_settings'), 'settings');
}

function navigateToLogs() {
    switchPage('log-page', getString('title_logs'));
    logModule.refreshLog();
}

function navigateToBackups() {
    switchPage('backup-page', getString('title_backups'));
    backupModule.refreshBackupList();
}

function navigateToRepository() {
    switchPage('repo-page', getString('title_repository'));
    repoModule.fetchRepo();
}

function navigateToStealth() {
    switchPage('stealth-page', getString('title_stealth'), 'stealth');
    stealthModule.refreshStealthList();
}

function navigateToPatch() {
    preparePatchUI(getString('title_patch'), false);
    patchModule.getKpimgInfo();
    patchModule.extractAndParseBootimg();
}

function navigateToUnPatch() {
    preparePatchUI(getString('title_unpatch'), true);
    patchModule.extractAndParseBootimg();
}

function updateBottomBar(activeId) {
    document.querySelectorAll('.bottom-bar-item').forEach(item => {
        item.toggleAttribute('selected', item.id === activeId);
    });
}

export function setupRoute() {
    document.getElementById('patch-btn')?.addEventListener('click', navigateToPatch);
    document.getElementById('uninstall')?.addEventListener('click', navigateToUnPatch);
    document.getElementById('not-installed')?.addEventListener('click', navigateToPatch);
    document.getElementById('logs')?.addEventListener('click', navigateToLogs);
    document.getElementById('backups')?.addEventListener('click', navigateToBackups);
    document.getElementById('repository')?.addEventListener('click', navigateToRepository);

    document.querySelectorAll('.bottom-bar-item').forEach(item => {
        item.addEventListener('click', () => {
            const routes = {
                home: navigateToHome,
                KPM: navigateToKPM,
                exclude: navigateToExclude,
                settings: navigateToSettings,
                stealth: navigateToStealth,
            };
            routes[item.id]?.();
        });
    });

    navigateToHome();
}
