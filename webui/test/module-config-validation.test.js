import { describe, expect, it } from 'vitest';
import { normalizeConfigKey, normalizeConfigValue } from '../module-config.js';

describe('normalizeConfigKey', () => {
    it('accepts bounded identifier-like keys', () => {
        expect(normalizeConfigKey('policy')).toBe('policy');
        expect(normalizeConfigKey('  kpm.signature-policy  ')).toBe('kpm.signature-policy');
        expect(normalizeConfigKey('A_1.value')).toBe('A_1.value');
        expect(normalizeConfigKey(`a${'b'.repeat(63)}`)).toHaveLength(64);
    });

    it('rejects options, paths, shell syntax and oversized keys', () => {
        for (const value of [
            '--help',
            '-policy',
            '/data/adb/config',
            '../config',
            'key value',
            'key=value',
            'key;id',
            '.hidden',
            '',
            '1startsWithDigit',
            `a${'b'.repeat(64)}`,
        ]) {
            expect(normalizeConfigKey(value)).toBeNull();
        }
    });
});

describe('normalizeConfigValue', () => {
    it('accepts printable values including Unicode and empty values', () => {
        expect(normalizeConfigValue('')).toBe('');
        expect(normalizeConfigValue('strict')).toBe('strict');
        expect(normalizeConfigValue('中文值 ✓')).toBe('中文值 ✓');
        expect(normalizeConfigValue(' '.repeat(32))).toBe(' '.repeat(32));
        expect(normalizeConfigValue('a'.repeat(4096))).toHaveLength(4096);
    });

    it('rejects controls and oversized values', () => {
        for (const value of [
            'line1\nline2',
            'tab\tvalue',
            'carriage\rreturn',
            `nul\u0000byte`,
            `del\u007fbyte`,
            'a'.repeat(4097),
        ]) {
            expect(normalizeConfigValue(value)).toBeNull();
        }
    });
});
