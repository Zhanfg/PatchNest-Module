// Test: Stealth page — verifies the JS-only logic (filter, render)
// of the WebUI Stealth Center without pulling in the full DOM
// environment.
//
// The actual toggle writes to /data/adb/patchnest/kpm_config/ which we
// mock via a virtual FS stub.

import { describe, it, expect, vi, beforeEach } from 'vitest';

// Minimal mock kernelsu-alt with a programmable exec() queue.
function makeExecMock(queue) {
    let i = 0;
    return {
        exec: vi.fn(async (cmd) => {
            if (i >= queue.length) return { errno: 0, stdout: '', stderr: '' };
            const r = queue[i++];
            return r;
        }),
        spawn: vi.fn(),
        toast: vi.fn(),
    };
}

beforeEach(() => {
    // Reset module cache so each test gets a fresh import.
    vi.resetModules();
});

describe('Stealth page — config file read/write semantics', () => {
    it('reads enabled=1 from config when present', async () => {
        const { readKpmEnabled } = await loadModuleWithExec({
            queue: [
                { errno: 0, stdout: 'enabled=1', stderr: '' },
            ],
        });
        const v = await readKpmEnabled('stealth-proc-maps');
        expect(v).toBe(true);
    });

    it('reads enabled=0 from config when present', async () => {
        const { readKpmEnabled } = await loadModuleWithExec({
            queue: [
                { errno: 0, stdout: 'enabled=0', stderr: '' },
            ],
        });
        const v = await readKpmEnabled('stealth-proc-maps');
        expect(v).toBe(false);
    });

    it('defaults to enabled when config is missing', async () => {
        // The shell fallback echo is the default branch we test here.
        // When the file doesn't exist, grep returns 1 (no match) and
        // our shell helper falls back to "enabled=1".
        const { readKpmEnabled } = await loadModuleWithExec({
            queue: [
                { errno: 0, stdout: 'enabled=1', stderr: '' },
            ],
        });
        const v = await readKpmEnabled('nonexistent-kpm');
        expect(v).toBe(true);
    });

    it('handles export prefix and whitespace', async () => {
        const { readKpmEnabled } = await loadModuleWithExec({
            queue: [
                { errno: 0, stdout: '   export  enabled = 0   ', stderr: '' },
            ],
        });
        const v = await readKpmEnabled('stealth-mount-hide');
        expect(v).toBe(false);
    });
});

describe('Stealth page — known stealth id set', () => {
    it('recognizes all six anti-detect KPMs', async () => {
        const { STEALTH_IDS } = await loadModuleWithExec({ queue: [] });
        expect(STEALTH_IDS.has('stealth-proc-maps')).toBe(true);
        expect(STEALTH_IDS.has('stealth-mount-hide')).toBe(true);
        expect(STEALTH_IDS.has('stealth-selinux-faker')).toBe(true);
        expect(STEALTH_IDS.has('stealth-boot-spoofer')).toBe(true);
        expect(STEALTH_IDS.has('stealth-module-hider')).toBe(true);
        expect(STEALTH_IDS.has('stealth-linker-redact')).toBe(true);
    });

    it('does NOT recognize a regular KPM (e.g. selinux_hook)', async () => {
        const { STEALTH_IDS } = await loadModuleWithExec({ queue: [] });
        expect(STEALTH_IDS.has('selinux_hook')).toBe(false);
        expect(STEALTH_IDS.has('devsafe')).toBe(false);
    });
});

// Helper that loads page/stealth.js with the kernelsu-alt mock
// injected. We don't actually exercise the DOM, just the helper
// functions exported alongside.
async function loadModuleWithExec({ queue }) {
    vi.doMock('kernelsu-alt', () => makeExecMock(queue));
    // Stub the other imports the page pulls in.
    vi.doMock('../index.js', () => ({
        modDir: '/data/adb/modules/PatchNest',
        persistDir: '/data/adb/patchnest',
        escapeShell: (s) => `'${s.replace(/'/g, "'\\''")}'`,
    }));
    vi.doMock('../language.js', () => ({
        getString: (key, ...args) => {
            // minimal stub: return key with %1$s/%1$d placeholders intact
            return key;
        },
    }));
    vi.doMock('../utils.js', () => ({
        escapeHTML: (s) => String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c])),
    }));
    vi.doMock('../pull-to-refresh.js', () => ({
        setupPullToRefresh: () => {},
    }));

    const mod = await import('../page/stealth.js');
    return mod;
}
