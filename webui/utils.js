/**
 * Shared utility functions for WebUI
 */

/**
 * Escape HTML special characters to prevent XSS
 * @param {string} str - Raw string to escape
 * @returns {string} - HTML-safe string
 */
export function escapeHTML(str) {
    if (str === null || str === undefined) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Sanitize a filename for safe use in shell commands.
 * Removes characters that could break out of quotes or cause injection.
 * @param {string} name - Raw filename
 * @returns {string} - Shell-safe filename
 */
export function sanitizeFilename(name) {
    if (!name) return 'unnamed';
    return String(name)
        .replace(/[^a-zA-Z0-9._\-]/g, '_')
        .replace(/_{2,}/g, '_')
        .replace(/^_|_$/g, '')
        || 'unnamed';
}

/**
 * Sanitize a URL for safe use in shell commands.
 * Only allows http/https URLs.
 * @param {string} url - Raw URL
 * @returns {string|null} - Safe URL or null if invalid
 */
export function sanitizeUrl(url) {
    if (!url) return null;
    try {
        const parsed = new URL(url);
        if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
        return parsed.href;
    } catch {
        return null;
    }
}

/**
 * Format bytes into a human-readable size string.
 * Centralised here to remove the 3 duplicate copies that previously
 * lived in backup.js, kpm_repo.js, and patch.js.
 * @param {number} bytes - Byte count
 * @returns {string} - e.g. "1.4 MB" / "2.50 GB" / "512 B"
 */
export function formatSize(bytes) {
    if (bytes == null || isNaN(bytes)) return '? B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}
