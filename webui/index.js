import '@material/web/all.js';
import { applyStoredTheme } from './theme.js';
import { detectEnvironment, resetEnvironment } from './ksu.js';
import { openModuleConfigDialog } from './module-config.js';

// Apply theme as early as possible — before any UI renders — so the user
// doesn't see a flash of the wrong color.
applyStoredTheme();

// Enable edge-to-edge as soon as the KSU module is loaded. This must run
// early (before the splash dismisses) so the WebView resizes its viewport
// in one frame rather than two. Supported since KSU v3.0.0-115 — older
// managers will silently reject the request (returns false), which is fine.
(async () => {
    try {
        const { enableEdgeToEdge } = await import('kernelsu-alt');
        if (typeof enableEdgeToEdge === 'function') {
            await enableEdgeToEdge(true);
        }
    } catch (_) {
        // kernelsu-alt not loaded (e.g. dev preview) — non-fatal.
    }
})();

let exec, toast;

// Initialize kernelsu-alt synchronously (no top-level await) for
// compatibility with older WebViews (Chrome < 89).
import('kernelsu-alt')
    .then(ks => {
        exec = ks.exec;
        toast = ks.toast;
    })
    .catch(e => {
        console.error('kernelsu-alt not available:', e);
        exec = async () => ({ errno: -1, stdout: '', stderr: 'kernelsu-alt not available' });
        toast = (msg) => console.warn('toast:', msg);
    });

import { setupRoute } from './route.js';
import { getString, loadTranslations } from './language.js';
import { modDir, persistDir, escapeShell, linkRedirect, getMaxChunkSize } from './constants.js';
import { sanitizeUrl } from './utils.js';
// NOTE: PR3 deferred this to a future iteration. The 6 page modules
// below are eagerly imported because switching to dynamic import()
// would require changing switchPage() in route.js to handle a promise.
// The audit report flagged it as a P2 bundle-size optimization; the
// recommended fix is:
//   1. Replace `import * as xModule from './page/x.js'` with:
//        const xModule = { init: () => import('./page/x.js').then(m => m.init()) };
//   2. In route.js:switchPage, await the import on first visit and
//      cache the module reference in a Map for subsequent visits.
// For now, the WebUI loads ~200KB of page JS on cold start; the perf
// win from the fix above is meaningful on low-end Android (entry-level
// 4GB devices in 2026 are still common).
import * as patchModule from './page/patch.js';
import * as kpmModule from './page/kpm.js';
import * as excludeModule from './page/exclude.js';
import * as logModule from './page/log.js';
import * as backupModule from './page/backup.js';
import * as repoModule from './page/kpm_repo.js';
import * as stealthModule from './page/stealth.js';
import { maybeShowChangelog } from './changelog.js';
import { initThemeSettings } from './theme.js';
import { maybeNotifyUpdate, checkForUpdates } from './update-check.js';
import { autoCheckKpmUpdates } from './page/kpm-update.js';

// Re-export for any code still importing from index.js
export { modDir, persistDir, escapeShell, linkRedirect, getMaxChunkSize };
// KSU environment — lazily initialized in init(), available to pages.
let _env = null;
export async function getEnv() { if (!_env) _env = await detectEnvironment(); return _env; }

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
        initSignaturePolicy();
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

    // Populate KSU/manager info on the home card. This is non-blocking;
    // if the detection fails the row just stays hidden.
    try {
        const env = await getEnv();
        const ksuEl = document.getElementById('ksu-info');
        if (ksuEl) {
            const parts = [];
            if (env.hasKsu && env.ksuVersion) {
                parts.push(`KSU ${env.ksuVersion}`);
            }
            if (env.managerPackage) {
                parts.push(env.managerPackage);
            }
            if (env.manager !== 'unknown') {
                parts.push(env.manager);
            }
            if (parts.length > 0) {
                ksuEl.textContent = parts.join(' · ');
                ksuEl.closest('.info')?.classList.remove('hidden');
            } else {
                ksuEl.closest('.info')?.classList.add('hidden');
            }
        }
    } catch (_) {}
}

const VALID_REBOOT_REASONS = new Set(['', 'recovery', 'bootloader', 'download', 'edl']);
async function reboot(reason = "") {
    if (!VALID_REBOOT_REASONS.has(reason)) reason = "";
    if (reason === "recovery") {
        await exec("/system/bin/input keyevent 26");
    }
    exec(`/system/bin/svc power reboot ${reason} || /system/bin/reboot ${reason}`);
}

/**
 * KSU integration: enables the "Open in KSU Manager" Settings item
 * (which deep-links to the module's detail page) and wires the
 * module config dialog. Only shown when a supported KSU manager is
 * detected.
 */
function initKsuIntegration() {
    const item = document.getElementById('open-in-ksu');
    const detail = document.getElementById('open-in-ksu-detail');
    const configItem = document.getElementById('module-config');
    const configDetail = document.getElementById('module-config-detail');
    if (!item) return;

    (async () => {
        const env = await getEnv();
        // Only show the item when we actually have a KSU manager
        // (not Magisk, not unknown).
        if (!env.hasKsu || !env.managerPackage) {
            item.classList.add('hidden');
            if (configItem) configItem.classList.add('hidden');
            return;
        }
        item.classList.remove('hidden');
        if (detail) {
            detail.textContent = env.managerPackage;
        }
        item.onclick = () => {
            // Deep link to the module's detail page in the KSU
            // manager. The intent format is: am start -a
            // android.intent.action.VIEW -d
            // kernelsu://module/<module-id>
            // The manager package provides the activity.
            const moduleId = 'PatchNest';
            exec(
                `am start -a android.intent.action.VIEW -d kernelsu://module/${moduleId} -p ${env.managerPackage}`,
                { env: { PATH: '/system/bin' } }
            ).then(({ errno, stderr }) => {
                if (errno !== 0) {
                    toast(getString('msg_repo_fetch_failed'));
                    console.warn('open-in-ksu failed:', stderr);
                }
            });
        };

        // Module config (KSU v2+ only). The button is only meaningful
        // when the manager supports persistent per-module config.
        if (configItem) {
            if (env.ksuVersion) {
                const v = env.ksuVersion.match(/(\d+)\.(\d+)/);
                if (v && parseInt(v[1]) >= 2) {
                    configItem.classList.remove('hidden');
                    if (configDetail) configDetail.textContent = getString('title_module_config');
                    configItem.onclick = () => openModuleConfigDialog();
                }
            }
        }
    })();
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
    // Defensive: coerce any truthy input to one of the two known values
    // before interpolating into a shell command.
    const mode = isEnable === true ? "enable" : "disable";
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

// ─── KPM signature policy (Settings page) ────────────────────────────
//
// The user can choose one of three policies for how service.sh should
// handle unsigned / unverified KPM modules at boot:
//
//   off     — never check, load everything silently (default; preserves
//             pre-v0.3.0 behavior, lets users load / embed their own
//             unsigned KPMs without any friction).
//   warn    — load everything, but log a warning to service.log AND
//             append to /data/adb/patchnest/unsigned_modules.log. The
//             WebUI shows a visible "Unsigned modules loaded" warning
//             row in Settings so the user is aware.
//   strict  — refuse to load any KPM that lacks a valid .kpm.sig.
//
// Policy is persisted to /data/adb/patchnest/config and read by
// service.sh on every boot. The WebUI never relies on a localStorage
// mirror because service.sh is the source of truth.

let _sigPolicyLoaded = false;
async function initSignaturePolicy() {
    const select = document.getElementById('kpm-sig-policy-select');
    const detail = document.getElementById('kpm-sig-policy-detail');
    if (!select || _sigPolicyLoaded) return;
    _sigPolicyLoaded = true;

    // Read the current policy from /data/adb/patchnest/config on disk.
    // The shell helper we call is intentionally permissive: it returns
    // 'off' on any error, never throws.
    let current = 'off';
    try {
        const r = await exec(
            `cat ${escapeShell(persistDir + '/config')} 2>/dev/null | grep -E '^[[:space:]]*(export[[:space:]]+)?KPM_SIGNATURE_POLICY' | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"\\r\\n' | tr 'A-Z' 'a-z'`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );
        if (result_ok(r) && r.stdout.trim()) {
            const v = r.stdout.trim();
            if (v === 'off' || v === 'warn' || v === 'strict') current = v;
            else if (v === '0' || v === 'false') current = 'off';
            else if (v === '1' || v === 'true' || v === 'yes' || v === 'on') current = 'strict';
        }
    } catch (_) { /* fall through with 'off' */ }

    select.value = current;
    if (detail) {
        detail.textContent = getString(
            current === 'strict' ? 'sig_policy_strict'
            : current === 'warn'  ? 'sig_policy_warn'
            :                       'sig_policy_off'
        );
    }

    // On user change, write the new policy to disk and refresh the warning
    // list. The next boot will pick it up; we don't need to re-launch
    // service.sh because the policy is re-read every time it runs.
    select.addEventListener('change', async () => {
        const newPolicy = select.value;
        if (!['off', 'warn', 'strict'].includes(newPolicy)) return;
        const setRes = await exec(
            // idempotent: if file exists, replace the line; otherwise append.
            // Use single-quoted heredoc to make the value shell-safe.
            `cfg=${escapeShell(persistDir + '/config')}; touch "$cfg"; ` +
            `if grep -q '^[[:space:]]*\\(export[[:space:]]*\\)\\?KPM_SIGNATURE_POLICY' "$cfg"; then ` +
            `  sed -i 's|^[[:space:]]*\\(export[[:space:]]*\\)\\?KPM_SIGNATURE_POLICY=.*|KPM_SIGNATURE_POLICY=${newPolicy}|' "$cfg"; ` +
            `else ` +
            `  printf '%s\\n' 'KPM_SIGNATURE_POLICY=${newPolicy}' >> "$cfg"; ` +
            `fi; ` +
            `sh ${escapeShell(modDir + '/status.sh')} >/dev/null 2>&1 || true`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );
        if (result_ok(setRes)) {
            if (detail) {
                detail.textContent = getString(
                    newPolicy === 'strict' ? 'sig_policy_strict'
                    : newPolicy === 'warn'  ? 'sig_policy_warn'
                    :                         'sig_policy_off'
                );
            }
            await refreshUnsignedWarning();
            toast(getString('toast_sig_policy_saved'));
        } else {
            // Roll back the UI on failure.
            select.value = current;
            toast(getString('msg_error', setRes.stderr || ''));
        }
    });

    await refreshUnsignedWarning();
}

// Show the "Unsigned KPM modules loaded" warning row in Settings when
// the service.log indicates that warn-mode flagged modules on the last
// boot. The marker file is written by service.sh when policy=warn and
// a .kpm/.ko/.o was loaded without a .kpm.sig.
async function refreshUnsignedWarning() {
    const row = document.getElementById('unsigned-modules-warning');
    const detail = document.getElementById('unsigned-modules-detail');
    if (!row || !detail) return;
    try {
        const r = await exec(
            `cat ${escapeShell(persistDir + '/unsigned_modules.log')} 2>/dev/null || true`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );
        if (!result_ok(r) || !r.stdout.trim()) {
            row.setAttribute('hidden', '');
            return;
        }
        // Parse "unsigned:<filename>:<epoch>" lines, keep unique filenames.
        const lines = r.stdout.trim().split('\n').filter(Boolean);
        const files = [...new Set(
            lines.map(l => l.split(':')[1]).filter(Boolean)
        )];
        if (files.length === 0) {
            row.setAttribute('hidden', '');
            return;
        }
        detail.textContent = getString('unsigned_modules_count', files.length, files.slice(0, 3).join(', ') + (files.length > 3 ? '…' : ''));
        row.removeAttribute('hidden');
    } catch (_) {
        row.setAttribute('hidden', '');
    }
}

function result_ok(r) { return r && r.errno === 0; }

function initRepoSettings() {
    const repoItem = document.getElementById('repository');
    const repoUrlDetail = document.getElementById('current-repo-url');
    const repoUrlDialog = document.getElementById('repo-url-dialog');
    const safemodeDetail = document.getElementById('current-safemode');
    const safemodeItem = document.getElementById('safemode');

    // Check for updates on click. The checkForUpdates call is async;
    // we debounce so the user doesn't get multiple spinners.
    const checkItem = document.getElementById('check-updates');
    const updateStatus = document.getElementById('update-status');
    if (checkItem) {
        checkItem.onclick = async () => {
            if (updateStatus) updateStatus.textContent = getString('status_checking');
            const result = await checkForUpdates();
            if (!result.ok) {
                if (updateStatus) updateStatus.textContent = result.reason === 'network-error'
                    ? getString('msg_repo_fetch_failed')
                    : getString('msg_error', result.reason);
                return;
            }
            if (result.updateAvailable) {
                // Open the update dialog instead of showing a toast.
                const dialog = document.getElementById('update-dialog');
                const versionEl = dialog?.querySelector('#update-version');
                const currentEl = dialog?.querySelector('#update-current');
                if (versionEl) versionEl.textContent = result.remote.version;
                if (currentEl) currentEl.textContent = getString('update_current', result.local);
                dialog?.querySelector('.update-download')?.addEventListener('click', () => {
                    dialog.close();
                    if (result.remote.zipUrl) {
                        // P0-13: result.remote.zipUrl comes from
                        // network-fetched update.json — controlled by
                        // whoever serves the release. A MITM or
                        // compromised mirror could swap the URL for
                        // something like `; rm -rf /data;` and the
                        // unescaped template literal would execute
                        // it as root via `am start`. Force the URL
                        // through sanitizeUrl (http(s) allowlist) and
                        // escapeShell (shell-quote) before exec.
                        const safeUrl = sanitizeUrl(result.remote.zipUrl);
                        if (!safeUrl) {
                            toast(getString('update_invalid_url'));
                            return;
                        }
                        // safeUrl is http(s)-only by sanitizeUrl() and
                        // double-quoted by escapeShell(). The same
                        // caveat as constants.js#linkRedirect applies
                        // here: kernelsu-alt.exec is a JS-Native
                        // bridge, not Node child_process, so
                        // execFile() / spawn() aren't reachable.
                        exec(`am start -a android.intent.action.VIEW -d ${escapeShell(safeUrl)}`)
                            .then(() => toast(getString('update_download_started')))
                            .catch(() => toast(getString('update_download_failed')));
                    }
                }, { once: true });
                dialog?.querySelector('.update-later')?.addEventListener('click', () => dialog.close(), { once: true });
                dialog?.show();
                if (updateStatus) updateStatus.textContent = getString('update_available', result.remote.version);
            } else {
                toast(getString('update_up_to_date'));
                if (updateStatus) updateStatus.textContent = getString('update_up_to_date');
            }
        };
    }

    // Query the safe-mode state via the kp-safemode helper. The helper
    // exits 0 with stdout "0" or "1" on success. Anything else (binary
    // missing, kernel not patched, no root) leaves the indicator in the
    // "Unknown" state rather than throwing a toast.
    if (safemodeItem) {
        exec(`sh ${escapeShell(modDir + '/bin/kp-safemode')}`, {
            env: { PATH: `${modDir}/bin` },
        }).then((result) => {
            if (safemodeDetail) {
                if (result.errno === 0) {
                    const v = result.stdout.trim();
                    safemodeDetail.textContent = v === '1'
                        ? getString('status_safemode_on')
                        : getString('status_safemode_off');
                    safemodeItem.classList.toggle('warning-card', v === '1');
                } else {
                    safemodeDetail.textContent = getString('status_safemode_unknown');
                }
            }
        });
    }
    const repoUrlInput = document.getElementById('repo-url-input');

    // Show the primary repo URL, with a "+N more" suffix when the user
    // has subscribed to multiple repos.
    const updateDetail = () => {
        const repos = repoModule.getRepos();
        if (repos.length === 1) {
            repoUrlDetail.textContent = repos[0].url;
        } else {
            repoUrlDetail.textContent = `${repos[0].name} (+${repos.length - 1} ${getString('repo_more')})`;
        }
    };
    updateDetail();

    // The Settings page now opens the multi-repo manager instead of a
    // single-URL dialog. The legacy dialog is still in the DOM for any
    // other caller, but no UI surface reaches it.
    repoItem.onclick = () => repoModule.openRepoManager();
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
    // AK3-recovery (Fix 4): show a confirmation dialog explaining what
    // will be preserved vs. lost by the auto_unpatch before we run it.
    // Old behaviour (no dialog) is preserved for users on the old
    // unpatch-only page that hasn't been initialized.
    document.getElementById('unpatch').onclick = async () => {
        document.querySelector('.trailing-btn').style.display = 'none';
        let proceed = true;
        try {
            // Lazy-import to avoid a startup-time cost on the patch
            // page. If the module is missing, fall through to the
            // legacy "just run it" path.
            const unpatchModule = await import('./page/boot_unpatch.js');
            proceed = await unpatchModule.confirmAutoUnpatch();
        } catch (_) {
            proceed = true;
        }
        if (proceed) {
            patchModule.patch("unpatch");
        }
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
    stealthModule.initStealthPage();
    initRepoSettings();
    initThemeSettings();
    // P0-4 / P0-12: `initUpdateCheck()` was never defined in the
    // project. update-check.js only exports `checkForUpdates` and
    // `maybeNotifyUpdate`. Calling the undefined binding would have
    // thrown a ReferenceError at DOMContentLoaded, halting every
    // subsequent line — including maybeNotifyUpdate() further down.
    // The auto-check is already performed unconditionally below, so
    // the redundant call here is simply removed.
    initKsuIntegration();

    if (splash) {
        setTimeout(() => splash.classList.add('exit'), 50);
        setTimeout(() => splash.remove(), 400);
    }

    // Show the changelog modal the first time a user lands on a new version.
    // No-op once they've dismissed it (tracked in localStorage).
    maybeShowChangelog();

    // Background: check update.json and notify if a newer release exists.
    // Errors are silent so this doesn't add toast noise on cold start.
    maybeNotifyUpdate();

    // Background: fetch the Kpm-Repo catalog and diff it against the
    // installed KPMs. Two outcomes:
    //   1. The Kpm-Repo page gets populated (lazy on first visit, but
    //      priming it here means the first visit is instant).
    //   2. The installed KPM cards in the KPM page get "update" badges.
    //   3. If any updates are found, a single toast nudges the user.
    // Errors at any stage are swallowed — a network blip should never
    // break app init.
    try {
        await repoModule.fetchRepo();
        await kpmModule.annotateInstalledKpmWithUpdates();
        // autoCheckKpmUpdates returns [] when nothing is new, so the
        // toast only fires on actual updates. We don't await its
        // settle — it can run in parallel with whatever page renders
        // next.
        autoCheckKpmUpdates().catch(() => {});
    } catch (_) {
        // No permission, no network, or repo file missing — all non-fatal.
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
