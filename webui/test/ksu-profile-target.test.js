import { describe, expect, it } from 'vitest';
import { normalizeKsuProfileTarget } from '../ksu.js';

describe('normalizeKsuProfileTarget', () => {
    it('accepts and canonicalizes decimal UIDs', () => {
        expect(normalizeKsuProfileTarget(0)).toBe('0');
        expect(normalizeKsuProfileTarget('0010234')).toBe('10234');
        expect(normalizeKsuProfileTarget('2147483647')).toBe('2147483647');
    });

    it('rejects UID overflow and malformed numeric values', () => {
        expect(normalizeKsuProfileTarget('2147483648')).toBeNull();
        expect(normalizeKsuProfileTarget('-1')).toBeNull();
        expect(normalizeKsuProfileTarget('12.5')).toBeNull();
        expect(normalizeKsuProfileTarget('123abc')).toBeNull();
    });

    it('accepts Android-style package identifiers', () => {
        expect(normalizeKsuProfileTarget('com.example.app')).toBe('com.example.app');
        expect(normalizeKsuProfileTarget('io.github.kernel_su.manager2')).toBe('io.github.kernel_su.manager2');
        expect(normalizeKsuProfileTarget('  com.example.app  ')).toBe('com.example.app');
    });

    it('rejects option, path, shell and single-segment inputs', () => {
        for (const value of [
            '--help',
            '-1',
            '/data/adb/ksu',
            '../profile',
            'com.example;id',
            'com.example app',
            'com.example/app',
            'single',
            '.com.example',
            'com..example',
            'com.example.',
        ]) {
            expect(normalizeKsuProfileTarget(value)).toBeNull();
        }
    });

    it('rejects nullish, empty and oversized values', () => {
        expect(normalizeKsuProfileTarget(null)).toBeNull();
        expect(normalizeKsuProfileTarget(undefined)).toBeNull();
        expect(normalizeKsuProfileTarget('')).toBeNull();
        expect(normalizeKsuProfileTarget('   ')).toBeNull();
        expect(normalizeKsuProfileTarget(`com.${'a'.repeat(252)}`)).toBeNull();
    });
});
