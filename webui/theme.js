// Theme picker: lets the user override the OS preference.
// "auto" follows prefers-color-scheme; "light" and "dark" force one or the
// other. Choice is persisted in localStorage and applied via a data-theme
// attribute on <html>, which the theme.css rules key off.

import { getString } from './language.js';

const THEME_KEY = 'patchnest_theme';
const VALID_THEMES = ['auto', 'light', 'dark'];

/**
 * Apply the saved theme as early as possible. Call this before
 * loadTranslations() to avoid a flash of wrong-colored UI.
 */
export function applyStoredTheme() {
    const theme = getStoredTheme();
    setDocumentTheme(theme);
}

function getStoredTheme() {
    try {
        const v = localStorage.getItem(THEME_KEY);
        if (v && VALID_THEMES.includes(v)) return v;
    } catch (_) {}
    return 'auto';
}

function setDocumentTheme(theme) {
    const html = document.documentElement;
    if (theme === 'auto') {
        html.removeAttribute('data-theme');
    } else {
        html.setAttribute('data-theme', theme);
    }
}

function persistTheme(theme) {
    try {
        if (theme === 'auto') {
            localStorage.removeItem(THEME_KEY);
        } else {
            localStorage.setItem(THEME_KEY, theme);
        }
    } catch (_) {}
}

/**
 * Wire the settings-page list item and dialog. Mirrors the language picker
 * pattern from index.js. Safe to call before translations load — it shows
 * raw English in the detail line until they do, then updates.
 */
export function initThemeSettings() {
    const listItem = document.getElementById('theme-setting');
    const detail = document.getElementById('current-theme');
    const dialog = document.getElementById('theme-dialog');
    const form = document.getElementById('theme-form');
    if (!listItem || !dialog || !form || !detail) return;

    const updateDetail = () => {
        const theme = getStoredTheme();
        const label = getString(`theme_${theme}`);
        if (detail) detail.textContent = label;
    };

    const open = () => {
        // (Re)build the radio group. Each option is a label wrapping an
        // md-radio so it remains accessible and respects Material styling.
        form.innerHTML = '';
        const current = getStoredTheme();
        VALID_THEMES.forEach(theme => {
            const label = document.createElement('label');
            label.className = 'radio-item';
            const radio = document.createElement('md-radio');
            radio.name = 'theme';
            radio.value = theme;
            if (theme === current) radio.checked = true;
            const text = document.createElement('span');
            text.textContent = getString(`theme_${theme}`);
            label.appendChild(radio);
            label.appendChild(text);
            label.onclick = () => {
                radio.checked = true;
                persistTheme(theme);
                setDocumentTheme(theme);
                updateDetail();
                dialog.close();
            };
            form.appendChild(label);
        });
        dialog.show();
    };

    listItem.onclick = open;
    dialog.querySelector('.cancel')?.addEventListener('click', () => dialog.close());
    updateDetail();

    // Keep the detail line in sync with translations that arrive after init.
    // We can't easily hook the language load, so we just update once the
    // document is fully loaded (translations are usually loaded by then).
    if (document.readyState !== 'complete') {
        window.addEventListener('load', updateDetail, { once: true });
    }
}
