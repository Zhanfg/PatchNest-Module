// KSU module config UI: read and write per-module persistent config
// stored at /data/adb/ksu/module_config (the KSUM magic format).
//
// KSU module config is a binary blob: [magic:u32 "KSUM"] [version:u32]
// [count:u32] then `count` entries of [key_len:u32, key:bytes,
// val_len:u32, val:bytes] (each key/value string is 4-byte length-prefixed).
//
// We don't need to parse the binary in detail since ksud itself exposes
// `ksuctl module config get <id> <key>` and `set`. So the simplest
// implementation shells out to ksuctl for both directions.

import { exec, toast } from 'kernelsu-alt';
import { modDir, getEnv } from './index.js';
import { getString } from './language.js';
import { supportsProfiles } from './ksu.js';
import { escapeHTML } from './utils.js';

const MODULE_ID = 'PatchNest';

/**
 * Read a single config value by key. Returns the string value or null
 * if the key is missing or the manager doesn't support config.
 */
export async function readConfig(key) {
    if (!key) return null;
    const env = await getEnv();
    if (!supportsProfiles(env)) return null;
    try {
        const result = await exec(
            `ksuctl module config get ${MODULE_ID} ${shellQuote(key)}`,
            { env: { PATH: `${modDir}/bin:/system/bin` } }
        );
        if (result.errno !== 0) return null;
        return result.stdout.replace(/\n$/, '');
    } catch (_) {
        return null;
    }
}

/**
 * Write a single config value by key.
 */
export async function writeConfig(key, value) {
    if (!key) return false;
    const env = await getEnv();
    if (!supportsProfiles(env)) return false;
    try {
        const result = await exec(
            `ksuctl module config set ${MODULE_ID} ${shellQuote(key)} ${shellQuote(value || '')}`,
            { env: { PATH: `${modDir}/bin:/system/bin` } }
        );
        return result.errno === 0;
    } catch (_) {
        return false;
    }
}

/**
 * Delete a single config value by key.
 */
export async function deleteConfig(key) {
    if (!key) return false;
    const env = await getEnv();
    if (!supportsProfiles(env)) return false;
    try {
        const result = await exec(
            `ksuctl module config delete ${MODULE_ID} ${shellQuote(key)}`,
            { env: { PATH: `${modDir}/bin:/system/bin` } }
        );
        return result.errno === 0;
    } catch (_) {
        return false;
    }
}

/**
 * Quote a string for safe inclusion in a single shell argument.
 * Single-quote-wrapped with embedded single quotes escaped.
 */
function shellQuote(s) {
    return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

/**
 * Open the module config dialog. Shows key/value rows; user can add,
 * edit, and remove entries. Persists via writeConfig().
 */
export async function openModuleConfigDialog() {
    const env = await getEnv();
    if (!supportsProfiles(env)) {
        toast(getString('msg_module_disabled'));
        return;
    }

    // FIX (ultracode-audit 2026-06-07): #module-config-dialog never
    // existed in index.html — the function silently returned. Reuse
    // the existing #control-dialog the same way save/load-profile
    // flows do (it has the same slots).
    const dialog = document.getElementById('control-dialog') || document.getElementById('module-config-dialog');
    if (!dialog) {
        // Fall back to a toast — UI affordance for this rare path.
        toast(getString('msg_no_config'));
        return;
    }

    // Reuse the existing control-dialog pattern. Toggle its visibility
    // by changing headline + content + buttons. This keeps the DOM
    // lean (no new md-dialog) but means we need to be careful with the
    // close handler to restore original content.
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

    // List of saved entries.
    const list = document.createElement('div');
    list.className = 'config-list';
    const refresh = async () => {
        list.innerHTML = '';
        try {
            // List all keys via ksuctl. Output is one key per line.
            const result = await exec(
                `ksuctl module config list ${MODULE_ID}`,
                { env: { PATH: `${modDir}/bin:/system/bin` } }
            );
            if (result.errno === 0 && result.stdout.trim()) {
                const keys = result.stdout.trim().split('\n').filter(Boolean);
                for (const k of keys) {
                    const value = await readConfig(k);
                    const row = document.createElement('div');
                    row.className = 'config-row';
                    row.innerHTML = `
                        <div class="config-key">${escapeHTML(k)}</div>
                        <div class="config-value">${escapeHTML(value || '—')}</div>
                        <md-icon-button class="config-delete-btn" title="${escapeHTML(getString('button_delete'))}">
                            <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
                        </md-icon-button>
                    `;
                    row.querySelector('.config-delete-btn').onclick = async () => {
                        await deleteConfig(k);
                        refresh();
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

    // Add a new entry: read the key/value from the dialog's text
    // field, save it, and clear the field.
    const origConfirm = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(origConfirm, confirmBtn);
    origConfirm.textContent = getString('button_save_config');
    origConfirm.disabled = false;
    origConfirm.onclick = async () => {
        // The text field holds a "key=value" pair for compactness.
        // If no '=' is present, treat the whole string as the key and
        // set value to empty.
        const raw = field.value.trim();
        if (!raw) return;
        const eq = raw.indexOf('=');
        let key, value;
        if (eq < 0) {
            key = raw;
            value = '';
        } else {
            key = raw.slice(0, eq).trim();
            value = raw.slice(eq + 1).trim();
        }
        if (!key) return;
        const ok = await writeConfig(key, value);
        if (ok) {
            field.value = '';
            refresh();
        }
    };
    cancelBtn.onclick = () => dialog.close();
    // Insert the list before the dialog's actions.
    const content = dialog.querySelector('[slot=content]');
    const existingList = content?.querySelector('.config-list');
    if (existingList) existingList.remove();
    if (field) field.placeholder = 'key=value';
    if (contentDiv) {
        contentDiv.after(list);
    } else {
        content?.appendChild(list);
    }
    await refresh();

    dialog.show();
    dialog.addEventListener('close', () => {
        if (headline) headline.textContent = origHeadline;
        if (contentDiv) contentDiv.textContent = origLabel;
        if (field) field.placeholder = '';
        list.remove();
    }, { once: true });
}

