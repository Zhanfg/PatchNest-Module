// Stealth Center — per-KPM toggle controls for the anti-detection suite.
//
// Each installed stealth KPM gets a card with a switch. The switch
// state is persisted to /data/adb/patchnest/kpm_config/<id>.conf so the
// next-boot KPM can read its own config. The WebUI does NOT need to
// re-launch service.sh — the KPMs re-read their config every load.

import { exec, toast } from 'kernelsu-alt';
import { modDir, persistDir, escapeShell } from '../constants.js';
import { getString } from '../language.js';
import { escapeHTML } from '../utils.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';

// In-memory state — reloaded on each refresh from the KPM dir listing.
// The "installed" set is the set of .kpm files that match a known
// stealth id, so we don't have to hardcode the list here.
let installedKpms = [];      // [{ id, name, fileName, enabled }]

const STEALTH_IDS = new Set([
    'stealth-proc-maps',
    'stealth-mount-hide',
    'stealth-selinux-faker',
    'stealth-boot-spoofer',
    'stealth-module-hider',
    'stealth-linker-redact',
]);

// Configuration on disk is read+written here. Each KPM looks at its
// own <id>.conf which contains at minimum:
//   enabled = 1   # or 0
//   hide_paths = ...
//   ...
const KPM_CONFIG_DIR = '/data/adb/patchnest/kpm_config';

async function getInstalledKpms() {
    // List all .kpm files installed and cross-reference with known
    // stealth ids. We don't decode the kpm binary itself — we use the
    // file basename to match against kpm_repo.json.
    const r = await exec(
        `ls -1 ${persistDir}/kpm/*.kpm 2>/dev/null`,
        { env: { PATH: `${modDir}/bin:$PATH` } }
    );
    if (!r || r.errno !== 0 || !r.stdout.trim()) return [];
    const files = r.stdout.trim().split('\n').filter(Boolean);
    const matches = files.map(f => f.split('/').pop().replace(/\.kpm$/, '')).filter(id => STEALTH_IDS.has(id));
    if (!matches.length) return [];
    const enabledStates = await Promise.all(matches.map(id => readKpmEnabled(id)));
    return matches.map((id, i) => ({
        id,
        name: id.replace(/^stealth-/, 'Stealth: ').replace(/-/g, ' '),
        fileName: id + '.kpm',
        enabled: enabledStates[i],
    }));
}

async function readKpmEnabled(id) {
    // enabled = 1 (default) means the KPM runs with default behavior.
    // enabled = 0 means the KPM should not apply its hide rules.
    try {
        const r = await exec(
            `cfg=${escapeShell(KPM_CONFIG_DIR + '/' + id + '.conf')}; ` +
            `[ -f "$cfg" ] && grep -E '^[[:space:]]*enabled' "$cfg" | tail -1 || echo 'enabled=1'`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );
        if (!r || r.errno !== 0 || !r.stdout.trim()) return true;
        const v = r.stdout.trim().split('=').slice(1).join('=').trim().toLowerCase();
        return !(v === '0' || v === 'false' || v === 'off');
    } catch (_) {
        return true;
    }
}

async function writeKpmEnabled(id, enabled) {
    // Idempotent: read the file, replace the enabled line, or append
    // if missing. Touch the file so it exists.
    // NOTE: v is constrained to '0'|'1' — do NOT accept user input here.
    const v = enabled ? '1' : '0';
    const cmd =
        `cfg=${escapeShell(KPM_CONFIG_DIR + '/' + id + '.conf')}; ` +
        `mkdir -p ${escapeShell(KPM_CONFIG_DIR)}; touch "$cfg"; ` +
        `if grep -qE '^[[:space:]]*enabled' "$cfg"; then ` +
        `  sed -i 's|^[[:space:]]*enabled=.*|enabled=${v}|' "$cfg"; ` +
        `else ` +
        `  printf '%s\\n' 'enabled=${v}' >> "$cfg"; ` +
        `fi`;
    const r = await exec(cmd, { env: { PATH: `${modDir}/bin:$PATH` } });
    return r && r.errno === 0;
}

function renderCard(kpm) {
    const card = document.createElement('div');
    card.className = 'card module-card stealth-card';
    card.dataset.id = kpm.id;
    card.innerHTML = `
        <div class="module-card-header">
            <div class="flex-header">
                <div class="module-card-title">${escapeHTML(kpm.name)}</div>
                <div class="tag ${kpm.enabled ? 'tag-stealth-on' : 'tag-stealth-off'}">${kpm.enabled ? 'ON' : 'OFF'}</div>
            </div>
            <div class="module-card-subtitle">${escapeHTML(kpm.id)}.kpm</div>
        </div>
        <md-divider></md-divider>
        <div class="module-card-actions">
            <span class="stealth-hint" data-i18n="stealth_hint_reboot">Takes effect on next boot</span>
            <md-switch class="stealth-toggle" ${kpm.enabled ? 'selected' : ''}></md-switch>
        </div>
    `;
    const toggle = card.querySelector('.stealth-toggle');
    toggle.addEventListener('change', async () => {
        const newEnabled = toggle.selected;
        const ok = await writeKpmEnabled(kpm.id, newEnabled);
        if (ok) {
            kpm.enabled = newEnabled;
            const tag = card.querySelector('.tag');
            tag.className = `tag ${newEnabled ? 'tag-stealth-on' : 'tag-stealth-off'}`;
            tag.textContent = newEnabled ? 'ON' : 'OFF';
            toast(getString(newEnabled ? 'toast_stealth_enabled' : 'toast_stealth_disabled', kpm.name));
        } else {
            // Roll back on failure
            toggle.selected = !newEnabled;
            toast(getString('msg_error', 'config write failed'));
        }
    });
    return card;
}

export async function refreshStealthList() {
    const container = document.getElementById('stealth-list');
    const emptyMsg = document.getElementById('stealth-empty-msg');
    if (!container) return;
    container.innerHTML = '';

    installedKpms = await getInstalledKpms();
    if (installedKpms.length === 0) {
        emptyMsg?.classList.remove('hidden');
        return;
    }
    emptyMsg?.classList.add('hidden');

    installedKpms.forEach(kpm => {
        container.appendChild(renderCard(kpm));
    });
}

export function initStealthPage() {
    setupPullToRefresh('stealth-page', refreshStealthList);
}

// Internal helpers exported for unit testing. Not part of the public
// surface; their signatures may change between releases.
export {
    STEALTH_IDS,
    readKpmEnabled,
    writeKpmEnabled,
    getInstalledKpms,
};
