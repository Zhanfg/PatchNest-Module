// Pure operation model for the WebUI unpatch confirmation flow.
//
// The current implementation invokes boot_unpatch.sh, which unpacks the
// selected current boot image, removes PatchNest from its kernel payload,
// repacks it, validates it, and then writes that newly generated image. It
// does not select or flash a stored backup. Keeping this model separate makes
// the UI semantics testable without a root bridge or DOM.

const COPY = Object.freeze({
    en: Object.freeze({
        title: 'Remove PatchNest from the current boot image',
        summary: 'PatchNest will be removed by unpacking, unpatching, validating, and repacking the currently selected boot image.',
        warning: 'This operation does not restore or flash any stored backup. Existing verified backups remain unchanged. Backup restoration requires a separate verified restore flow.',
        loseTitle: 'This operation removes:',
        lose: Object.freeze([
            'The PatchNest kernel patch in the selected current boot image',
            'KPM modules embedded inside that PatchNest kernel patch',
        ]),
        keepTitle: 'This operation preserves:',
        keep: Object.freeze([
            'Non-PatchNest contents already present in the selected boot image',
            'Stored boot backup images and their verification manifests',
            'Persistent PatchNest configuration and KPM files under /data/adb/patchnest',
        ]),
        confirm: 'Remove PatchNest',
        cancel: 'Cancel',
    }),
    zh: Object.freeze({
        title: '从当前 boot 镜像移除 PatchNest',
        summary: '系统将解包当前选中的 boot 镜像，移除其中的 PatchNest 内核补丁，重新打包并完成校验。',
        warning: '此操作不会选择、恢复或刷入任何已保存备份。现有已验证备份保持不变；备份恢复必须通过独立的已验证恢复流程执行。',
        loseTitle: '此操作会移除：',
        lose: Object.freeze([
            '当前选中 boot 镜像中的 PatchNest 内核补丁',
            '嵌入该 PatchNest 内核补丁中的 KPM 模块',
        ]),
        keepTitle: '此操作会保留：',
        keep: Object.freeze([
            '当前 boot 镜像中并非由 PatchNest 添加的其他内容',
            '已保存的 boot 备份镜像及其校验清单',
            '/data/adb/patchnest 下的持久配置与 KPM 文件',
        ]),
        confirm: '移除 PatchNest',
        cancel: '取消',
    }),
});

export function normalizeUnpatchLocale(locale) {
    const normalized = String(locale || 'en').trim().toLowerCase();
    return normalized === 'zh' || normalized.startsWith('zh-') ? 'zh' : 'en';
}

export function getCurrentUnpatchCopy(locale) {
    return COPY[normalizeUnpatchLocale(locale)];
}

export function buildCurrentUnpatchModel(locale) {
    const copy = getCurrentUnpatchCopy(locale);
    return Object.freeze({
        operation: 'current-image-unpatch',
        usesStoredBackup: false,
        flashesStoredBackup: false,
        preservesStoredBackups: true,
        requiresExplicitConfirmation: true,
        copy,
    });
}
