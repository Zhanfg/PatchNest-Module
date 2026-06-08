/**
 * Tests for detectEnvironment() in webui/ksu.js.
 *
 * detectEnvironment() runs a sequence of `exec()` calls and infers
 * the running root manager (KSU / KernelSU-Next / SukiSU / APatch /
 * Magisk) from the responses. Because every call is async and the
 * function caches its result, the tests:
 *   1. mock `kernelsu-alt` with a programmable exec()
 *   2. mock `./index.js` so modDir is a real-ish path
 *   3. call resetEnvironment() before each test to clear the cache
 *
 * Each spec models one detection path end-to-end. The mock's queue
 * pattern lets us return different stdout for `ksu --version`,
 * `ls /data/adb/ksu`, `pm path <pkg>`, etc.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

// --- Module stubs ----------------------------------------------------

// A small queue: each call to exec() pops the next canned response
// from the queue. If the queue is empty, fall through to "not found".
const execQueue = [];
const enqueue = (r) => execQueue.push(r);
const flush = () => { execQueue.length = 0; };

vi.mock('kernelsu-alt', () => ({
    exec: vi.fn(async () => {
        const next = execQueue.shift();
        if (!next) return { errno: -1, stdout: '', stderr: '' };
        return next;
    }),
}));

// FIX: ksu.js now imports modDir/escapeShell from constants.js, not
// the index.js barrel. Mock the canonical source.
vi.mock('../constants.js', () => ({
    modDir: '/data/adb/modules/PatchNest',
    persistDir: '/data/adb/patchnest',
    escapeShell: (s) => `'${String(s).replace(/'/g, `'\\''`)}'`,
}));

// SUT — imported *after* mocks are registered.
const ksu = await import('../ksu.js');

describe('detectEnvironment', () => {
    beforeEach(() => {
        // The module caches its result in a module-level `_env`.
        // Call resetEnvironment() so each test starts fresh.
        ksu.resetEnvironment();
        flush();
    });

    it('reports manager="ksu" and the version when `ksu --version` succeeds', async () => {
        enqueue({ errno: 0, stdout: '1.0.4\n', stderr: '' });
        // No legacy ls fallback needed (ksu --version already set hasKsu).
        // No manager package found (pm path returns -1 for all four).
        enqueue({ errno: -1, stdout: '', stderr: '' });
        enqueue({ errno: -1, stdout: '', stderr: '' });
        enqueue({ errno: -1, stdout: '', stderr: '' });
        enqueue({ errno: -1, stdout: '', stderr: '' });

        const env = await ksu.detectEnvironment();
        expect(env.hasKsu).toBe(true);
        expect(env.ksuVersion).toBe('1.0.4');
        // No manager package matched → manager stays at the default 'ksu'.
        expect(env.manager).toBe('ksu');
        expect(env.managerPackage).toBeNull();
    });

    it('identifies KernelSU-Next when me.weishu.kernelsu is installed', async () => {
        // 1. ksu --version → hasKsu=true
        enqueue({ errno: 0, stdout: '2.0.1', stderr: '' });
        // 2. pm path me.weishu.kernelsu → success (KernelSU-Next)
        enqueue({ errno: 0, stdout: 'package:/data/app/.../kernelsu-next', stderr: '' });
        // Remaining pm path calls won't be reached (we `break` on the first hit).

        const env = await ksu.detectEnvironment();
        expect(env.manager).toBe('ksu-next');
        expect(env.managerPackage).toBe('me.weishu.kernelsu');
    });

    it('falls back to APatch detection when KSU is absent', async () => {
        // 1. ksu --version → not installed.
        enqueue({ errno: -1, stdout: '', stderr: '' });
        // 2. ls /data/adb/ksu → empty.
        enqueue({ errno: -1, stdout: '', stderr: '' });
        // 3. APatch directory present.
        enqueue({ errno: 0, stdout: 'apd', stderr: '' });

        const env = await ksu.detectEnvironment();
        expect(env.hasKsu).toBe(false);
        expect(env.manager).toBe('apatch');
    });

    it('falls back to Magisk when neither KSU nor APatch is present', async () => {
        // 1. ksu --version → no.
        enqueue({ errno: -1, stdout: '', stderr: '' });
        // 2. ls /data/adb/ksu → no.
        enqueue({ errno: -1, stdout: '', stderr: '' });
        // 3. ls /data/adb/ap → no (no APatch).
        enqueue({ errno: -1, stdout: '', stderr: '' });
        // 4. magisk --version → yes.
        enqueue({ errno: 0, stdout: '27.0', stderr: '' });

        const env = await ksu.detectEnvironment();
        expect(env.hasKsu).toBe(false);
        expect(env.manager).toBe('magisk');
    });

    it('returns manager="unknown" when nothing is detected', async () => {
        // No enqueue'd responses — every exec() returns errno -1.
        const env = await ksu.detectEnvironment();
        expect(env.manager).toBe('unknown');
        expect(env.hasKsu).toBe(false);
        expect(env.ksuVersion).toBeNull();
    });
});
