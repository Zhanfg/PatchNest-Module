/**
 * WebUI confirmation flow for removing PatchNest from the selected current
 * boot image.
 *
 * boot_unpatch.sh does not flash a stored backup. It unpacks the selected
 * current boot image, removes the PatchNest kernel patch, repacks the image,
 * validates it, and writes that newly generated image. The confirmation UI
 * must describe that exact operation and must never imply that a backup will
 * be selected or restored.
 */
import { exec, toast } from 'kernelsu-alt';
import { modDir, persistDir, escapeShell } from '../constants.js';
import { getString } from '../language.js';
import { buildCurrentUnpatchModel } from './boot-unpatch-model.js';

const UNPATCH_SH = `${modDir}/patch/boot_unpatch.sh`;
const APPROVAL_FILE = `${persistDir}/unpatch_approval`;

function appendBullet(parent, text) {
    const row = document.createElement('div');
    row.className = 'auto-unpatch-bullet';
    row.textContent = `• ${text}`;
    parent.appendChild(row);
}

function renderOperationPlan(model) {
    const lose = document.getElementById('auto-unpatch-lose');
    const keep = document.getElementById('auto-unpatch-keep');
    if (!lose || !keep) return false;

    lose.textContent = '';
    keep.textContent = '';

    const loseHeader = document.createElement('div');
    loseHeader.className = 'auto-unpatch-section-title';
    loseHeader.textContent = model.copy.loseTitle;
    lose.appendChild(loseHeader);
    model.copy.lose.forEach((item) => appendBullet(lose, item));

    const keepHeader = document.createElement('div');
    keepHeader.className = 'auto-unpatch-section-title';
    keepHeader.textContent = model.copy.keepTitle;
    keep.appendChild(keepHeader);
    model.copy.keep.forEach((item) => appendBullet(keep, item));
    return true;
}

async function clearUnpatchApproval() {
    try {
        await exec(`rm -f ${escapeShell(APPROVAL_FILE)}`, {
            env: { PATH: '/system/bin' },
        });
    } catch (_) {
        // A missing stale marker is harmless. Creation below remains fail-closed.
    }
}

async function createUnpatchApproval() {
    const command = [
        'set -eu',
        'umask 077',
        `approval_file=${escapeShell(APPROVAL_FILE)}`,
        'approval_tmp="${approval_file}.tmp.$$"',
        "trap 'rm -f \"$approval_tmp\"' EXIT INT TERM HUP",
        `mkdir -p ${escapeShell(persistDir)}`,
        'rm -f "$approval_tmp"',
        '{ printf \'%s\\n\' \'operation=current-image-unpatch\'; printf \'approved_at=\'; date +%s; } > "$approval_tmp"',
        'chmod 0600 "$approval_tmp"',
        'mv "$approval_tmp" "$approval_file"',
        'trap - EXIT INT TERM HUP',
    ].join('; ');

    try {
        const result = await exec(command, { env: { PATH: '/system/bin' } });
        return result.errno === 0;
    } catch (_) {
        return false;
    }
}

/**
 * Ask the user to confirm the current-image unpatch operation.
 *
 * This function is deliberately fail-closed. If the dialog or any required
 * element is missing, it returns false instead of silently allowing a boot
 * write without an explicit confirmation. A successful confirmation creates
 * a one-time, short-lived approval consumed by boot_unpatch.sh.
 */
export async function confirmAutoUnpatch() {
    await clearUnpatchApproval();

    const dialog = document.getElementById('auto-unpatch-dialog');
    const summary = document.getElementById('auto-unpatch-summary');
    const warning = document.getElementById('auto-unpatch-warning');
    if (!dialog || !summary || !warning) {
        toast(getString('msg_error', 'Unpatch confirmation UI is unavailable'));
        return false;
    }

    const model = buildCurrentUnpatchModel(
        typeof navigator !== 'undefined' ? navigator.language : 'en'
    );
    if (!renderOperationPlan(model)) {
        toast(getString('msg_error', 'Unpatch operation details are unavailable'));
        return false;
    }

    const headline = dialog.querySelector('[slot="headline"]');
    const cancelBtn = dialog.querySelector('.cancel');
    const confirmBtn = dialog.querySelector('.confirm');
    if (!cancelBtn || !confirmBtn) {
        toast(getString('msg_error', 'Unpatch confirmation controls are unavailable'));
        return false;
    }

    if (headline) headline.textContent = model.copy.title;
    summary.textContent = model.copy.summary;
    warning.textContent = model.copy.warning;

    const newConfirm = confirmBtn.cloneNode(true);
    confirmBtn.parentNode.replaceChild(newConfirm, confirmBtn);
    const newCancel = cancelBtn.cloneNode(true);
    cancelBtn.parentNode.replaceChild(newCancel, cancelBtn);
    newConfirm.textContent = model.copy.confirm;
    newCancel.textContent = model.copy.cancel;

    return new Promise((resolve) => {
        let settled = false;
        const finish = (value) => {
            if (settled) return;
            settled = true;
            resolve(value);
        };

        newConfirm.onclick = async () => {
            newConfirm.disabled = true;
            const approved = await createUnpatchApproval();
            if (!approved) {
                newConfirm.disabled = false;
                toast(getString('msg_error', 'Could not create the one-time unpatch approval'));
                finish(false);
                dialog.close();
                return;
            }
            finish(true);
            dialog.close();
        };
        newCancel.onclick = async () => {
            await clearUnpatchApproval();
            finish(false);
            dialog.close();
        };
        dialog.addEventListener('close', () => finish(false), { once: true });
        dialog.show();
    });
}

/**
 * Execute boot_unpatch.sh only after the explicit current-image confirmation.
 * Kept as a reusable entry point for pages that do not stream the child process
 * output themselves.
 */
export async function runUnpatchWithConfirmation(bootDev) {
    if (!bootDev) {
        toast(getString('msg_error_no_boot_image'));
        return false;
    }
    if (!(await confirmAutoUnpatch())) {
        toast(getString('msg_cancelled'));
        return false;
    }

    const result = await exec(
        `sh ${escapeShell(UNPATCH_SH)} ${escapeShell(bootDev)}`,
        { env: { PATH: `${modDir}/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH` } }
    );
    if (result.errno === 0) {
        toast(getString('msg_unpatch_done'));
        return true;
    }
    toast(getString('msg_unpatch_failed', result.stderr || result.stdout || ''));
    return false;
}
