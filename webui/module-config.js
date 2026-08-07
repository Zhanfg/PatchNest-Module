// KSU module config UI with constrained ksuctl arguments.

import { exec, toast } from 'kernelsu-alt';
import { modDir, getEnv } from './index.js';
import { getString } from './language.js';
import { supportsProfiles } from './ksu.js';
import { escapeHTML } from './utils.js';

const MODULE_ID = 'PatchNest';
const MAX_CONFIG_VALUE_LENGTH = 4096;

/** Return a canonical config key or null. */
export function normalizeConfigKey(value) {
    if (value === null || value === undefined) return null;
    const key = String(value).trim();
    if (!/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(key)) return null;
    return key;
}

/** Return a bounded config value or null. */
export function normalizeConfigValue(value) {
    const text = value === null || value === undefined ? '' : String(value);
    if (text.length > MAX_CONFIG_VALUE_LENGTH) return null;
    // Prevent multiline/control-bearing command arguments and ambiguous binary
    // config values. Ordinary printable Unicode remains allowed.
    if (/[\u0000-\u001F\u007F]/u.test(text)) return null;
    return text;
}

function shellQuote(value) {
    return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

export async function readConfig(key) {
    const safeKey = normalizeConfigKey(key);
    if (safeKey === null) return null;
    const env = await getEnv();
    if (!supportsProfiles(env)) return null;
    try {
        const result = await exec(
            `ksuctl module config get ${MODULE_ID} ${shellQuote(safeKey)}`,
            { env: { PATH: `${modDir}/bin:/system/bin` } }
        );
        if (result.errno !== 0) return null;
        const output = result.stdout.replace(/\n$/, '');
        return normalizeConfigValue(output);
    } catch (_) {
        return null;
    }
}

export async function writeConfig(key, value) {
    const safeKey = normalizeConfigKey(key);
    const safeValue = normalizeConfigValue(value);
    if (safeKey === null || safeValue === null) return false;
    const env = await getEnv();
    if (!supportsProfiles(env)) return false;
    try {
        const result = await exec(
            `ksuctl module config set ${MODULE_ID} ${shellQuote(safeKey)} ${shellQuote(safeValue)}`,
            { env: { PATH: `${modDir}/bin:/system/bin` } }
        );
        return result.errno === 0;
    } catch (_) {
        return false;
    }
}

export async function deleteConfig(key) {
    const safeKey = normalizeConfigKey(key);
    if (safeKey === null) return false;
    const env = await getEnv();
    if (!supportsProfiles(env)) return false;
    try {
        const result = await exec(
            `ksuctl module config delete ${MODULE_ID} ${shellQuote(safeKey)}`,
            { env: { PATH: `${modDir}/bin:/system/bin` } }
        );
        return result.errno === 0;
    } catch (_) {
        return false;
    }
}

export async function openModuleConfigDialog() {
    const env = await getEnv();
    if (!supportsProfiles(env)) {
        toast(getString('msg_module_disabled'));
        return;
    }

    const dialog = document.getElementById('control-dialog') || document.getElementById('module-config-dialog');
    if (!dialog) {
        toast(getString('msg_no_config'));
        return;
    }

    const headline = dialog.querySelector('[slot=headline]');
    const contentDiv = dialog.querySelector('[slot=content] > div');
    const field = dialog.querySelector('md-outlined-text-field');
    const confirmBtn = dialog.querySelector('.confirm');
    const cancelBtn = dialog.querySelector('.cancel');
    const origHeadline = headline?.textContent;
    const origLabel = contentDiv?.textContent;

    if (headline) headline.textContent = getString('title_module_config');
    if (contentDiv) contentDiv.textContent = getString('label_config_value');
    if (field) {
        field.value = '';
        field.disabled = false;
    }

    const list = document.createElement('div');
    list.className = 'config-list';

    const refresh = async () => {
        list.replaceChildren();
        try {
            const result = await exec(
                `ksuctl module config list ${MODULE_ID}`,
                { env: { PATH: `${modDir}/bin:/system/bin` } }
            );
            if (result.errno === 0 && result.stdout.trim()) {
                const keys = [...new Set(
                    result.stdout
                        .split('\n')
                        .map(normalizeConfigKey)
                        .filter(key => key !== null)
                )];
                for (const key of keys) {
                    const value = await readConfig(key);
                    const row = document.createElement('div');
                    row.className = 'config-row';
                    row.innerHTML = `
                        <div class="config-key">${escapeHTML(key)}</div>
                        <div class="config-value">${escapeHTML(value ?? '—')}</div>
                        <md-icon-button class="config-delete-btn" title="${escapeHTML(getString('button_delete'))}">
                            <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
                        </md-icon-button>
                    `;
                    row.querySelector('.config-delete-btn').onclick = async () => {
                        if (await deleteConfig(key)) await refresh();
                    };
                    list.appendChild(row);
                }
            }
        } catch (_) {}

        if (list.children.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'config-empty';
            empty.textContent = getString('msg_no_config');
            list.appendChild(empty);
        }
    };

    const replacementConfirm = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(replacementConfirm, confirmBtn);
    replacementConfirm.textContent = getString('button_save_config');
    replacementConfirm.disabled = false;
    replacementConfirm.onclick = async () => {
        const raw = String(field?.value ?? '').trim();
        if (!raw) return;
        const separator = raw.indexOf('=');
        const key = normalizeConfigKey(separator < 0 ? raw : raw.slice(0, separator));
        const value = normalizeConfigValue(separator < 0 ? '' : raw.slice(separator + 1).trim());
        if (key === null || value === null) {
            toast(getString('msg_invalid_input') || 'Invalid config key or value');
            return;
        }
        if (await writeConfig(key, value)) {
            field.value = '';
            await refresh();
        }
    };
    cancelBtn.onclick = () => dialog.close();

    const content = dialog.querySelector('[slot=content]');
    content?.querySelector('.config-list')?.remove();
    if (field) field.placeholder = 'key=value';
    if (contentDiv) contentDiv.after(list);
    else content?.appendChild(list);

    await refresh();
    dialog.show();
    dialog.addEventListener('close', () => {
        if (headline) headline.textContent = origHeadline;
        if (contentDiv) contentDiv.textContent = origLabel;
        if (field) field.placeholder = '';
        list.remove();
    }, { once: true });
}
