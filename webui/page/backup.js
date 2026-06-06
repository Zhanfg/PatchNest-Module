import { exec, toast } from 'kernelsu-alt';
import { persistDir, modDir, escapeShell } from '../index.js';
import { getString } from '../language.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';
import { escapeHTML } from '../utils.js';

const BACKUP_DIR = `${persistDir}/backup`;

async function getBackupList() {
    const result = await exec(`ls -l "${BACKUP_DIR}" 2>/dev/null | grep '\\.img$'`, { env: { PATH: `${modDir}/bin` } });
    if (result.errno !== 0 || !result.stdout.trim()) return [];

    const items = result.stdout.trim().split('\n').map(line => {
        const parts = line.trim().split(/\s+/);
        if (parts.length < 8) return null;
        const size = parseInt(parts[4]);
        const name = parts.slice(7).join(' ');
        if (!name.endsWith('.img')) return null;
        const dateMatch = name.match(/boot_backup_(\d{10})\.img/);
        let dateStr = '';
        if (dateMatch) {
            const d = dateMatch[1];
            dateStr = `20${d.slice(0,2)}-${d.slice(2,4)}-${d.slice(4,6)} ${d.slice(6,8)}:${d.slice(8,10)}`;
        }
        return { name, size, dateStr };
    }).filter(Boolean).reverse();

    // Compute SHA256 in a single batch call. Two reasons to do this as a
    // batch rather than per-card: (1) one shell spawn instead of N, (2) the
    // sha256sum command is parallelizable by the kernel. If the command
    // fails, each card shows "—" instead of a hash.
    const hashes = await computeHashes(items.map(i => i.name));
    items.forEach((it, idx) => { it.sha256 = hashes[idx] || ''; });
    return items;
}

/**
 * Run a single sha256sum over all .img files and parse "<hash>  <name>"
 * output lines. Returns an array indexed by the input order. Failed or
 * missing entries get "" so the caller can render a placeholder.
 */
async function computeHashes(names) {
    if (names.length === 0) return [];
    // Quote each name via escapeShell; join with spaces. The leading "+"
    // tells sha256sum to read filenames from stdin — but we'll just
    // expand the names directly since we control them.
    const quoted = names.map(n => escapeShell(`${BACKUP_DIR}/${n}`)).join(' ');
    const result = await exec(`sha256sum ${quoted} 2>/dev/null`, {
        env: { PATH: `${modDir}/bin` },
    });
    if (result.errno !== 0) return names.map(() => '');

    // Build a name -> hash map from the output.
    const map = new Map();
    result.stdout.split('\n').forEach(line => {
        const m = line.match(/^([0-9a-f]{64})\s+\*?(.+)$/);
        if (m) map.set(m[2], m[1]);
    });
    return names.map(n => map.get(`${BACKUP_DIR}/${n}`) || '');
}

function formatSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

async function refreshBackupList() {
    const container = document.getElementById('backup-list');
    const emptyMsg = document.getElementById('backup-empty-msg');
    container.innerHTML = '';
    emptyMsg.textContent = getString('status_loading');
    emptyMsg.classList.remove('hidden');

    const backups = await getBackupList();

    if (backups.length === 0) {
        emptyMsg.textContent = getString('msg_no_backups');
        return;
    }

    emptyMsg.classList.add('hidden');

    backups.forEach(backup => {
        const card = document.createElement('div');
        card.className = 'card module-card';
        card.innerHTML = `
            <div class="module-card-header">
                <div class="module-card-title">${escapeHTML(backup.name)}</div>
                <div class="module-card-subtitle">${escapeHTML(backup.dateStr)} &middot; ${formatSize(backup.size)}</div>
            </div>
            <div class="module-card-content">
                <div class="module-card-subtitle backup-hash">${backup.sha256
                    ? `<span class="hash-label">SHA256</span> <code>${escapeHTML(backup.sha256)}</code>`
                    : `<span class="hash-label">SHA256</span> <span class="hash-unknown">—</span>`}</div>
            </div>
            <md-divider></md-divider>
            <div class="module-card-actions">
                <md-filled-tonal-icon-button class="copy-hash-btn" title="${getString('button_copy_hash')}"${backup.sha256 ? '' : ' disabled'}>
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M360-240q-33 0-56.5-23.5T280-320v-480q0-33 23.5-56.5T360-880h360q33 0 56.5 23.5T800-800v480q0 33-23.5 56.5T720-240H360Zm0-80h360v-480H360v480ZM200-80q-33 0-56.5-23.5T120-160v-560h80v560h440v80H200Zm160-240v-480 480Z"/></svg></md-icon>
                </md-filled-tonal-icon-button>
                <md-filled-tonal-icon-button class="save-btn" title="${getString('button_save_to_storage')}">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M480-320 280-520l56-58 104 104v-326h80v326l104-104 56 58-200 200ZM240-160q-33 0-56.5-23.5T160-240v-120h80v120h480v-120h80v120q0 33-23.5 56.5T720-160H240Z"/></svg></md-icon>
                </md-filled-tonal-icon-button>
                <md-filled-tonal-icon-button class="delete-btn" title="${getString('button_delete')}">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
                </md-filled-tonal-icon-button>
            </div>
        `;

        const copyBtn = card.querySelector('.copy-hash-btn');
        if (backup.sha256) {
            copyBtn.onclick = () => {
                // Try the modern Clipboard API first; fall back to a
                // hidden textarea + execCommand for older WebView builds
                // (Kernelsu's runtime is sometimes an old WebView).
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(backup.sha256)
                        .then(() => toast(getString('msg_hash_copied')))
                        .catch(() => fallbackCopy(backup.sha256));
                } else {
                    fallbackCopy(backup.sha256);
                }
            };
        }

        const fallbackCopy = (text) => {
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            try { document.execCommand('copy'); toast(getString('msg_hash_copied')); }
            catch (_) { toast(getString('msg_hash_copy_failed')); }
            document.body.removeChild(ta);
        };

        card.querySelector('.save-btn').onclick = async () => {
            // Strip any directory components — backup.name must be a basename only,
            // otherwise a malicious or malformed ls entry could write outside Download/.
            const baseName = String(backup.name).split('/').pop().split('\\').pop();
            if (!baseName || baseName.includes('..')) {
                toast(getString('msg_error', 'Invalid backup name'));
                return;
            }
            const result = await exec(
                `cp ${escapeShell(BACKUP_DIR + '/' + baseName)} ` +
                `${escapeShell('/storage/emulated/0/Download/' + baseName)}`
            );
            toast(result.errno === 0 ? getString('msg_backup_saved') : getString('msg_error', result.stderr));
        };

        card.querySelector('.delete-btn').onclick = async () => {
            const baseName = String(backup.name).split('/').pop().split('\\').pop();
            await exec(`rm -f ${escapeShell(BACKUP_DIR + '/' + baseName)}`);
            toast(getString('msg_backup_deleted'));
            refreshBackupList();
        };

        container.appendChild(card);
    });
}

export function initBackupPage() {
    document.getElementById('backup-refresh').onclick = refreshBackupList;

    const purgeBtn = document.getElementById('purge-backups');
    if (purgeBtn) purgeBtn.onclick = openPurgeDialog;

    setupPullToRefresh(document.querySelector('#backup-page .page-content'), refreshBackupList);
}

/**
 * Open the purge dialog. On confirm, the N newest backups are kept
 * and all older ones are deleted. The dialog shows a preview of what
 * will be deleted before the user confirms.
 */
async function openPurgeDialog() {
    const dialog = document.getElementById('purge-dialog');
    if (!dialog) return;
    const keepInput = document.getElementById('purge-keep-count');
    const preview = document.getElementById('purge-preview');
    const confirmBtn = dialog.querySelector('.confirm');
    const cancelBtn = dialog.querySelector('.cancel');

    const updatePreview = async () => {
        const count = parseInt(keepInput.value) || 3;
        const backups = await getBackupList();
        const toDelete = backups.slice(count); // older = after the N newest
        if (toDelete.length === 0) {
            preview.textContent = getString('purge_none_to_delete');
            if (confirmBtn) confirmBtn.disabled = true;
        } else {
            preview.textContent = getString('purge_will_delete', toDelete.length);
            if (confirmBtn) confirmBtn.disabled = false;
        }
    };
    keepInput.addEventListener('input', updatePreview);
    updatePreview();

    cancelBtn.onclick = () => dialog.close();
    confirmBtn.onclick = async () => {
        const count = parseInt(keepInput.value) || 3;
        // Refresh the list to get the current order.
        const backups = await getBackupList();
        const toDelete = backups.slice(count);
        if (toDelete.length === 0) {
            dialog.close();
            return;
        }
        // Delete each backup.
        for (const b of toDelete) {
            const baseName = String(b.name).split('/').pop().split('\\').pop();
            if (!baseName || baseName.includes('..')) continue;
            await exec(`rm -f ${escapeShell(BACKUP_DIR + '/' + baseName)}`);
        }
        toast(getString('msg_purged', toDelete.length));
        dialog.close();
        refreshBackupList();
    };
    dialog.show();
}

export { refreshBackupList };
