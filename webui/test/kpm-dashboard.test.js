// kpm-dashboard.test.js — Unit tests for the KPM dashboard data layer.
//
// We don't pull in the full DOM. We test:
//   - the pure parsers (parseModulesLine, parseServiceLogLines)
//   - the formatters (formatUptime, formatKpmSize)
//   - the state derivation (deriveState)
//   - the manifest regex
//   - the state badge / i18n key helpers

import { describe, it, expect, vi } from 'vitest';

// Stub out the kernelsu-alt and index.js imports so we can import
// kpm_stats.js without pulling in real fs / DOM.
vi.doMock('kernelsu-alt', () => ({
    exec: vi.fn(async () => ({ errno: 1, stdout: '', stderr: '' })),
}));
vi.doMock('../index.js', () => ({
    modDir: '/data/adb/modules/KPatch-Next',
    persistDir: '/data/adb/kp-next',
    escapeShell: (s) => `'${s.replace(/'/g, "'\\''")}'`,
}));

const stats = await import('../page/kpm_stats.js');

describe('KPM dashboard — uptime formatter', () => {
    it('returns "<1m" for sub-minute', () => {
        expect(stats.formatUptime(0)).toBe('<1m');
        expect(stats.formatUptime(30)).toBe('<1m');
        expect(stats.formatUptime(59)).toBe('<1m');
    });

    it('returns minutes for < 1h', () => {
        expect(stats.formatUptime(60)).toBe('1m');
        expect(stats.formatUptime(60 * 23)).toBe('23m');
    });

    it('returns "Hh Mm" for < 1d', () => {
        expect(stats.formatUptime(60 * 60)).toBe('1h');
        expect(stats.formatUptime(60 * 60 + 60 * 23)).toBe('1h 23m');
        expect(stats.formatUptime(60 * 60 * 5 + 60 * 7)).toBe('5h 7m');
    });

    it('returns "Dd Hh" for >= 1d', () => {
        const oneDay = 60 * 60 * 24;
        expect(stats.formatUptime(oneDay)).toBe('1d');
        expect(stats.formatUptime(oneDay * 2 + 60 * 60 * 5)).toBe('2d 5h');
    });

    it('returns "-" for null/negative', () => {
        expect(stats.formatUptime(null)).toBe('-');
        expect(stats.formatUptime(-5)).toBe('-');
    });
});

describe('KPM dashboard — size formatter', () => {
    it('returns "N B" for < 1 KB', () => {
        expect(stats.formatKpmSize(0)).toBe('-');
        expect(stats.formatKpmSize(512)).toBe('512 B');
    });

    it('returns "N.NN KB" for < 1 MB', () => {
        expect(stats.formatKpmSize(1024)).toBe('1.0 KB');
        expect(stats.formatKpmSize(12345)).toBe('12.1 KB');
    });

    it('returns "N.NN MB" for >= 1 MB', () => {
        expect(stats.formatKpmSize(1024 * 1024)).toBe('1.0 MB');
        expect(stats.formatKpmSize(8 * 1024 * 1024)).toBe('8.0 MB');
    });
});

describe('KPM dashboard — state derivation', () => {
    it('returns "loaded" when size > 0 and last log line is "Loaded:"', () => {
        const log = { lastEvent: '[ts] Loaded: stealth-proc-maps args=[]' };
        expect(stats.deriveState(log, 12345)).toBe('loaded');
    });

    it('returns "failed" when last log line is REJECTED or Failed', () => {
        expect(stats.deriveState({ lastEvent: '[ts] REJECTED: foo' }, 0)).toBe('failed');
        expect(stats.deriveState({ lastEvent: '[ts] Failed to load: foo' }, 0)).toBe('failed');
    });

    it('returns "pending" when size > 0 but log does not say "Loaded"', () => {
        expect(stats.deriveState({ lastEvent: null }, 12345)).toBe('pending');
    });

    it('returns "unknown" when no log line and no size', () => {
        expect(stats.deriveState({ lastEvent: null }, 0)).toBe('unknown');
    });
});

describe('KPM dashboard — /proc/modules line parser', () => {
    it('extracts size from a matching line', () => {
        expect(stats.parseModulesLine('stealth-proc-maps 8192 0 - Live 0xffff...', 'stealth-proc-maps'))
            .toEqual({ size: 8192 });
    });

    it('returns null for non-matching lines', () => {
        expect(stats.parseModulesLine('snd_timer 28672 2 - Live 0x...', 'stealth-proc-maps'))
            .toBeNull();
    });

    it('returns null for malformed lines', () => {
        expect(stats.parseModulesLine('stealth-proc-maps', 'stealth-proc-maps'))
            .toBeNull();
    });
});

describe('KPM dashboard — service.log parser', () => {
    it('extracts the last event for the named KPM', () => {
        const lines = [
            '[2026-06-06 08:00:00] kpatch hello OK',
            '[2026-06-06 08:00:05] Loaded: stealth-proc-maps args=[]',
            '[2026-06-06 08:00:06] Loaded: stealth-mount-hide args=[]',
            '[2026-06-06 08:00:07] REJECTED (sig invalid): stealth-mount-hide',
        ];
        const result = stats.parseServiceLogLines('stealth-proc-maps', lines);
        expect(result.lastEvent).toContain('stealth-proc-maps');
        expect(result.lastEventType).toBe('loaded');
        expect(result.filterCount).toBe(0);
        expect(result.errorCount).toBe(0);
    });

    it('counts filter and error events for the named KPM', () => {
        const lines = [
            '[ts] Filtered line: stealth-proc-maps (deleted)',
            '[ts] Filtered line: stealth-proc-maps (deleted)',
            '[ts] REJECTED (sig invalid): stealth-proc-maps',
            '[ts] Other: not relevant',
        ];
        const result = stats.parseServiceLogLines('stealth-proc-maps', lines);
        expect(result.filterCount).toBe(2);
        expect(result.errorCount).toBe(1);
        expect(result.lastEvent).toContain('REJECTED');
    });

    it('ignores log lines for other KPMs', () => {
        const lines = [
            '[ts] Loaded: stealth-mount-hide',
            '[ts] Loaded: stealth-proc-maps',
        ];
        const r1 = stats.parseServiceLogLines('stealth-proc-maps', lines);
        const r2 = stats.parseServiceLogLines('stealth-mount-hide', lines);
        expect(r1.lastEvent).toContain('stealth-proc-maps');
        expect(r2.lastEvent).toContain('stealth-mount-hide');
    });
});

describe('KPM dashboard — manifest regex', () => {
    it('matches a valid manifest JSON', () => {
        const manifest = 'KPMM\x01\x00\x00\x00foo   {"id":"foo","build":"abc1234","time":"2026-06-06T08:00:00Z","size":8192}';
        const m = manifest.match(stats.MANIFEST_RE);
        expect(m).not.toBeNull();
        expect(m[2]).toBe('abc1234');
        expect(m[3]).toBe('2026-06-06T08:00:00Z');
        expect(m[4]).toBe('8192');
    });

    it('returns null on a non-manifest tail', () => {
        const garbage = 'some random ELF data with no manifest';
        expect(garbage.match(stats.MANIFEST_RE)).toBeNull();
    });
});

describe('KPM dashboard — state badge class', () => {
    it('returns a class for each state', () => {
        expect(stats.stateBadgeClass('loaded')).toBe('kpm-state-loaded');
        expect(stats.stateBadgeClass('failed')).toBe('kpm-state-failed');
        expect(stats.stateBadgeClass('pending')).toBe('kpm-state-pending');
        expect(stats.stateBadgeClass('unknown')).toBe('kpm-state-unknown');
        expect(stats.stateBadgeClass('garbage')).toBe('kpm-state-unknown');
    });
});

describe('KPM dashboard — state i18n key', () => {
    it('returns a key for each state', () => {
        expect(stats.stateI18nKey('loaded')).toBe('kpm_state_loaded');
        expect(stats.stateI18nKey('failed')).toBe('kpm_state_failed');
        expect(stats.stateI18nKey('pending')).toBe('kpm_state_pending');
        expect(stats.stateI18nKey('unknown')).toBe('kpm_state_unknown');
    });
});
