import { describe, expect, it } from 'vitest';
import {
    buildCurrentUnpatchModel,
    getCurrentUnpatchCopy,
    normalizeUnpatchLocale,
} from '../page/boot-unpatch-model.js';

describe('current-image unpatch model', () => {
    it('never represents the operation as a stored-backup restore', () => {
        const model = buildCurrentUnpatchModel('en-US');
        expect(model.operation).toBe('current-image-unpatch');
        expect(model.usesStoredBackup).toBe(false);
        expect(model.flashesStoredBackup).toBe(false);
        expect(model.preservesStoredBackups).toBe(true);
        expect(model.requiresExplicitConfirmation).toBe(true);
    });

    it('states the backup boundary explicitly', () => {
        const copy = getCurrentUnpatchCopy('en');
        expect(copy.warning).toContain('does not restore or flash');
        expect(copy.warning).toContain('Existing verified backups remain unchanged');
        expect(copy.keep.join(' ')).toContain('backup images');
    });

    it('uses Chinese copy for Chinese locales', () => {
        expect(normalizeUnpatchLocale('zh-CN')).toBe('zh');
        expect(normalizeUnpatchLocale('zh-TW')).toBe('zh');
        const copy = getCurrentUnpatchCopy('zh-Hans-CN');
        expect(copy.title).toContain('当前 boot');
        expect(copy.warning).toContain('不会选择、恢复或刷入');
    });

    it('falls back to English for unsupported locales', () => {
        expect(normalizeUnpatchLocale('de-DE')).toBe('en');
        expect(getCurrentUnpatchCopy('de-DE').confirm).toBe('Remove PatchNest');
    });

    it('returns immutable copy arrays', () => {
        const model = buildCurrentUnpatchModel('en');
        expect(Object.isFrozen(model)).toBe(true);
        expect(Object.isFrozen(model.copy)).toBe(true);
        expect(Object.isFrozen(model.copy.lose)).toBe(true);
        expect(Object.isFrozen(model.copy.keep)).toBe(true);
    });
});
