import '@material/web/all.js';

let exec, toast;
try {
    const ks = await import('kernelsu-alt');
    exec = ks.exec;
    toast = ks.toast;
} catch (e) {
    console.error('kernelsu-alt not available:', e);
    exec = async () => ({ errno: -1, stdout: '', stderr: 'kernelsu-alt not available' });
    toast = (msg) => console.warn('toast:', msg);
}

import { setupRoute } from './route.js';
import { getString, loadTranslations } from './language.js';
import { modDir, persistDir, escapeShell, linkRedirect, getMaxChunkSize } from './constants.js';
import * as patchModule from './page/patch.js';
import * as kpmModule from './page/kpm.js';
import * as excludeModule from './page/exclude.js';
import * as logModule from './page/log.js';
import * as backupModule from './page/backup.js';
import * as repoModule from './page/kpm_repo.js';

// Re-export for any code still importing from index.js
export { modDir, persistDir, escapeShell, linkRedirect, getMaxChunkSize };

async function updateStatus() {
    const version = await patchModule.getInstalledVersion();
    const versionText = document.getElementById('version');
    const notInstalled = document.getElementById('not-installed');
    const working = document.getElementById('working');
    const installedOnly = document.querySelectorAll('.installed-only');
    if (version) {
        versionText.textContent = version;
        kpmModule.refreshKpmList();
        initRehook();
        installedOnly.forEach(el => el.removeAttribute('hidden'));
    } else {
        installedOnly.forEach(el => el.setAttribute('hidden', ''));
    }
    notInstalled.classList.toggle('hidden', version);
    working.classList.toggle('hidden', !version);
}

export async function initInfo() {
    const result = await exec('uname -r && getprop ro.build.version.release && getprop ro.build.fingerprint && getenforce');
    if (import.meta.env.DEV) {
        result.stdout = '6.18.2-linux\n16\nLinuxPC\nEnforcing';
    }
    const info = result.stdout.trim().split('\n');
    // If the kernel call failed (no newline-separated output) fall back to a
    // placeholder so the UI doesn't render literal "undefined".
    const fallback = '—';
    document.getElementById('kernel-release').textContent = info[0] || fallback;
    document.getElementById('system').textContent = info[1] || fallback;
    document.getElementById('fingerprint').textContent = info[2] || fallback;
    document.getElementById('selinux').textContent = info[3] || fallback;
}

async function reboot(reason = "") {
    if (reason === "recovery") {
        await exec("/system/bin/input keyevent 26");
    }
    exec(`/system/bin/svc power reboot ${reason} || /system/bin/reboot ${reason}`);
}

async function initRehook() {
    const rehook = document.getElementById('rehook');
    const rehookRipple = rehook.querySelector('md-ripple');
    const rehookSwitch = rehook.querySelector('md-switch');
    const isEnabled = await updateRehookStatus();
    if (isEnabled === null) {
        rehookRipple.disabled = true;
        rehookSwitch.disabled = true;
        return;
    }
    rehookSwitch.addEventListener('change', () => {
        setRehookMode(rehookSwitch.selected);
    });
}

async function updateRehookStatus() {
    const rehook = document.getElementById('rehook');
    if (!rehook) return null;
    const rehookSwitch = rehook.querySelector('md-switch');
    let isEnabled = null;
    const result = await exec(`kpatch rehook_status`, { env: { PATH: `${modDir}/bin` } });
    if (result.errno === 0) {
        const mode = result.stdout.split(':')[1].trim();
        isEnabled = mode === 'enabled' ? true : (mode === 'disabled' ? false : null);
        if (isEnabled !== null && rehookSwitch) rehookSwitch.selected = isEnabled;
    }
    return isEnabled;
}

function setRehookMode(isEnable) {
    const rehook = document.getElementById('rehook');
    const rehookSwitch = rehook?.querySelector('md-switch');
    const mode = isEnable ? "enable" : "disable";
    exec(
        `kpatch rehook ${mode} && echo ${mode} > ${escapeShell(persistDir + '/rehook')} && sh ${escapeShell(modDir + '/status.sh')}`,
        { env: { PATH: `${modDir}/bin:$PATH` } }
    ).then((result) => {
        if (result.errno !== 0) {
            toast(getString('msg_error', result.stderr));
            // Roll the UI switch back to the previous state on failure.
            updateRehookStatus();
            return;
        }
        updateRehookStatus();
    });
}

function initRepoSettings() {
    const repoItem = document.getElementById('repository');
    const repoUrlDetail = document.getElementById('current-repo-url');
    const repoUrlDialog = document.getElementById('repo-url-dialog');
    const repoUrlInput = document.getElementById('repo-url-input');

    repoUrlDetail.textContent = repoModule.getRepoUrl();

    repoItem.onclick = () => {
        repoUrlInput.value = repoModule.getRepoUrl();
        repoUrlDialog.querySelector('.cancel').onclick = () => repoUrlDialog.close();
        repoUrlDialog.querySelector('.confirm').onclick = () => {
            const newUrl = repoUrlInput.value.trim();
            repoModule.setRepoUrl(newUrl);
            repoUrlDetail.textContent = repoModule.getRepoUrl();
            toast(getString('msg_repo_url_updated'));
            repoUrlDialog.close();
        };
        repoUrlDialog.show();
    };
}

document.addEventListener('DOMContentLoaded', async () => {
    document.querySelectorAll('[unresolved]').forEach(el => el.removeAttribute('unresolved'));
    const splash = document.getElementById('splash');
    if (splash) setTimeout(() => splash.querySelector('.splash-icon').classList.add('show'), 20);

    setupRoute();

    const language = document.getElementById('language');
    const languageDialog = document.getElementById('language-dialog');
    language.onclick = () => languageDialog.show();
    languageDialog.querySelector('.cancel').onclick = () => languageDialog.close();

    document.getElementById('embed').onclick = patchModule.embedKPM;
    document.getElementById('start').onclick = () => {
        document.querySelector('.trailing-btn').style.display = 'none';
        patchModule.patch("patch");
    };
    document.getElementById('unpatch').onclick = () => {
        document.querySelector('.trailing-btn').style.display = 'none';
        patchModule.patch("unpatch");
    };

    const rebootMenu = document.getElementById('reboot-menu');
    document.getElementById('reboot-btn').onclick = () => {
        rebootMenu.open = !rebootMenu.open;
    };
    rebootMenu.querySelectorAll('md-menu-item').forEach(item => {
        item.onclick = () => reboot(item.getAttribute('data-reason'));
    });
    document.getElementById('reboot-fab').onclick = () => reboot();

    await getMaxChunkSize();

    await loadTranslations();
    await Promise.all([updateStatus(), initInfo()]);

    excludeModule.initExcludePage();
    kpmModule.initKPMPage();
    logModule.initLogPage();
    backupModule.initBackupPage();
    repoModule.initRepoPage();
    initRepoSettings();

    if (splash) {
        setTimeout(() => splash.classList.add('exit'), 50);
        setTimeout(() => splash.remove(), 400);
    }
});

// Overwrite default dialog animation
document.querySelectorAll('md-dialog').forEach(dialog => {
    const defaultOpenAnim = dialog.getOpenAnimation;
    const defaultCloseAnim = dialog.getCloseAnimation;

    dialog.getOpenAnimation = () => {
        const d = defaultOpenAnim.call(dialog);
        return {
            ...d,
            dialog: [[[{ opacity: 0, transform: 'translateY(50px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 300, easing: 'ease' }]],
            scrim: [[[{ opacity: 0 }, { opacity: 0.32 }], { duration: 300, easing: 'linear' }]],
            container: [],
        };
    };

    dialog.getCloseAnimation = () => {
        const d = defaultCloseAnim.call(dialog);
        return {
            ...d,
            dialog: [[[{ opacity: 1, transform: 'translateY(0)' }, { opacity: 0, transform: 'translateY(-50px)' }], { duration: 300, easing: 'ease' }]],
            scrim: [[[{ opacity: 0.32 }, { opacity: 0 }], { duration: 300, easing: 'linear' }]],
            container: [],
        };
    };
});
