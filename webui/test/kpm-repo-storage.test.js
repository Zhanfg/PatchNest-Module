/**
 * Tests for getRepos() / setRepos() in webui/page/kpm_repo.js.
 *
 * Both functions are pure localStorage wrappers, so the strategy is:
 *  1. Seed localStorage with known values before each test.
 *  2. Call the function under test.
 *  3. Assert the returned value (getRepos) or the localStorage
 *     side-effect (setRepos).
 *
 * The source imports several modules that don't exist in the test
 * environment (kernelsu-alt, index.js, language.js, pull-to-refresh).
 * We mock them all so the import graph resolves cleanly.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

// --- Module stubs ----------------------------------------------------

vi.mock('kernelsu-alt', () => ({
    exec: vi.fn(async () => ({ errno: 0, stdout: '', stderr: '' })),
    toast: vi.fn(),
}));

vi.mock('../index.js', () => ({
    modDir: '/data/adb/modules/PatchNest',
    persistDir: '/data/adb/patchnest',
}));

vi.mock('../language.js', () => ({
    getString: vi.fn((id) => id),   // return the key itself
}));

vi.mock('../pull-to-refresh.js', () => ({
    setupPullToRefresh: vi.fn(),
}));

vi.mock('../utils.js', async () => {
    // Import the real utils so the mock doesn't break escapeHTML etc.
    // but we only need getRepos/setRepos, so a minimal stub is fine.
    return {
        escapeHTML: (s) => s,
        sanitizeUrl: (u) => u,
        formatSize: (b) => `${b} B`,
    };
});

// Dynamic import *after* mocks are registered so the module sees our stubs.
const { getRepos, setRepos } = await import('../page/kpm_repo.js');

// The localStorage key used by kpm_repo.js (verified by reading the source).
const REPOS_KEY = 'patchnest_repos';
const DEFAULT_URL = 'https://raw.githubusercontent.com/Zhanfg/PatchNest-Kpms/main/kpm_repo.json';

describe('getRepos / setRepos — localStorage round-trip', () => {
    it('returns the default repo when localStorage is empty (first run)', () => {
        // localStorage is wiped by the global afterEach in setup.js.
        const repos = getRepos();
        // When getString() returns its own key (mock), the name is the i18n key.
        expect(repos).toEqual([{ url: DEFAULT_URL, name: 'repo_official' }]);
    });

    it('round-trips a custom repo list through setRepos -> getRepos', () => {
        const custom = [
            { url: 'https://example.com/a.json', name: 'Alpha' },
            { url: 'https://example.com/b.json', name: 'Beta' },
        ];
        setRepos(custom);
        expect(getRepos()).toEqual(custom);
    });

    it('setRepos with an empty array removes the key (falls back to default)', () => {
        setRepos([]);
        // The key should be gone from localStorage.
        expect(localStorage.getItem(REPOS_KEY)).toBeNull();
        // getRepos should fall through to the default.
        expect(getRepos()[0].url).toBe(DEFAULT_URL);
    });

    it('getRepos handles corrupt JSON without throwing (returns default)', () => {
        // Write valid JSON that is not an array.
        localStorage.setItem(REPOS_KEY, '"just a string"');
        const repos = getRepos();
        // Not an array → fallback.
        expect(repos[0].url).toBe(DEFAULT_URL);
    });

    it('getRepos handles broken JSON (SyntaxError) gracefully', () => {
        localStorage.setItem(REPOS_KEY, '{bad json');
        const repos = getRepos();
        expect(repos[0].url).toBe(DEFAULT_URL);
    });
});
