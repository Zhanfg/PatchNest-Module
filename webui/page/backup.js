import { exec, toast } from 'kernelsu-alt';
import { persistDir, modDir, escapeShell } from '../index.js';
import { getString } from '../language.js';
import { setupPullToRefresh } from '../pull-to-refresh.js';
import { escapeHTML } from '../utils.js';

const BACKUP_DIR = `${persistDir}/backup`;

async function getBackupList() {
    const result = await exec(`ls -l "${BACKUP_DIR}" 2>/dev/null | grep '\\.img$'`, { env: { PATH: `${modDir}/bin` } });
    if (result.errno !== 0 || !result.stdout.trim()) return [];

    return result.stdout.trim().split('\n').map(line => {
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
            <md-divider></md-divider>
            <div class="module-card-actions">
                <md-filled-tonal-icon-button class="save-btn" title="${getString('button_save_to_storage')}">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M480-320 280-520l56-58 104 104v-326h80v326l104-104 56 58-200 200ZM240-160q-33 0-56.5-23.5T160-240v-120h80v120h480v-120h80v120q0 33-23.5 56.5T720-160H240Z"/></svg></md-icon>
                </md-filled-tonal-icon-button>
                <md-filled-tonal-icon-button class="delete-btn" title="${getString('button_delete')}">
                    <md-icon><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M280-120q-33 0-56.5-23.5T200-200v-520h-40v-80h200v-40h240v40h200v80h-40v520q0 33-23.5 56.5T680-120H280Zm400-600H280v520h400v-520ZM360-280h80v-360h-80v360Zm160 0h80v-360h-80v360ZM280-720v520-520Z"/></svg></md-icon>
                </md-filled-tonal-icon-button>
            </div>
        `;

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

    setupPullToRefresh(document.querySelector('#backup-page .page-content'), refreshBackupList);
}

export { refreshBackupList };
