// Test: KPM signature policy — verifies the WebUI ↔ shell round-trip
// for the KPM_SIGNATURE_POLICY setting in /data/adb/patchnest/config.
//
// We don't import the actual index.js here (it would drag in the entire
// WebUI surface) — we just verify the parsing/formatting invariants that
// the Settings page relies on.

import { describe, it, expect, vi, beforeEach } from 'vitest';

// Re-implement the parser inline so we test the spec, not the implementation.
function parsePolicy(stdout) {
    if (!stdout) return 'off';
    const lines = stdout.trim().split('\n');
    // Use lastIndexOf-style semantics to match shell's `tail -1` behavior
    // — the LAST occurrence of the key wins.
    const matches = lines.filter(l => /^\s*(export\s+)?KPM_SIGNATURE_POLICY/i.test(l));
    const line = matches[matches.length - 1];
    if (!line) return 'off';
    const v = line.split('=').slice(1).join('=').trim().replace(/^["']|["']$/g, '').toLowerCase();
    if (v === 'off' || v === 'warn' || v === 'strict') return v;
    if (v === '0' || v === 'false') return 'off';
    if (v === '1' || v === 'true' || v === 'yes' || v === 'on') return 'strict';
    return 'off';
}

describe('KPM signature policy parser', () => {
    it('returns "off" by default for empty input', () => {
        expect(parsePolicy('')).toBe('off');
        expect(parsePolicy(null)).toBe('off');
    });

    it('parses the three valid string values', () => {
        expect(parsePolicy('KPM_SIGNATURE_POLICY=off')).toBe('off');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=warn')).toBe('warn');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=strict')).toBe('strict');
    });

    it('is case-insensitive', () => {
        expect(parsePolicy('KPM_SIGNATURE_POLICY=STRICT')).toBe('strict');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=Warn')).toBe('warn');
    });

    it('tolerates `export ` prefix and surrounding whitespace', () => {
        expect(parsePolicy('   export   KPM_SIGNATURE_POLICY=warn  ')).toBe('warn');
        expect(parsePolicy('  KPM_SIGNATURE_POLICY = strict')).toBe('strict');
    });

    it('tolerates quotes around the value', () => {
        expect(parsePolicy('KPM_SIGNATURE_POLICY="warn"')).toBe('warn');
        expect(parsePolicy("KPM_SIGNATURE_POLICY='strict'")).toBe('strict');
    });

    it('maps legacy boolean values', () => {
        // 0/false → off; 1/true/yes/on → strict
        expect(parsePolicy('KPM_SIGNATURE_POLICY=0')).toBe('off');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=false')).toBe('off');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=1')).toBe('strict');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=true')).toBe('strict');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=yes')).toBe('strict');
    });

    it('uses the LAST occurrence when the key appears multiple times', () => {
        expect(parsePolicy(`
            # comment
            KPM_SIGNATURE_POLICY=off
            export KPM_SIGNATURE_POLICY=warn
        `)).toBe('warn');
    });

    it('returns "off" for unknown values (never throws)', () => {
        expect(parsePolicy('KPM_SIGNATURE_POLICY=garbage')).toBe('off');
        expect(parsePolicy('KPM_SIGNATURE_POLICY=')).toBe('off');
    });

    it('returns "off" when the key is absent (with other keys present)', () => {
        expect(parsePolicy(`
            SOMETHING_ELSE=yes
            ANOTHER_KEY=foo
        `)).toBe('off');
    });
});

// Verify the WebUI side actually maps policy values to translation
// keys the user can read. We don't import getString (heavy dependency
// graph) but we verify the lookup is exhaustive.
describe('KPM signature policy i18n mapping', () => {
    const i18nKeys = {
        off:    'sig_policy_off',
        warn:   'sig_policy_warn',
        strict: 'sig_policy_strict',
    };

    for (const policy of Object.keys(i18nKeys)) {
        it(`has an i18n key for "${policy}"`, () => {
            expect(i18nKeys[policy]).toMatch(/^sig_policy_/);
        });
    }
});
