// kpm_stats.js — Per-KPM runtime statistics for the dashboard.
//
// Data sources:
//   - /proc/modules                       (size, state)
//   - /data/adb/patchnest/service.log       (lastEvent, filterCount, errorCount)
//   - /data/adb/patchnest/kpm_config/*.conf (enabled flag)
//   - tail of /data/adb/patchnest/kpm/*.kpm (build manifest JSON at EOF)
//
// Public API:
//   getKpmRuntimeStats(name) -> stats object
//   getKpmHeroStatus()       -> { loaded, failed, total, hasUnsigned }
//   invalidateKpmStatsCache()
//   formatUptime(sec)        -> "3d 2h" / "4h 23m" / "<1m"
//   formatKpmSize(bytes)     -> "12.4 KB" / "3.2 MB"
//   stateBadgeClass(state)   -> CSS class name
//   stateI18nKey(state)      -> i18n key
//
// Results are cached for 4 seconds.

import { exec } from 'kernelsu-alt';
import { modDir, persistDir, escapeShell } from '../index.js';

const CACHE_TTL_MS = 4000;
const _cache = new Map();
let _heroCache = { data: null, ts: 0 };

function ok(r) { return r && r.errno === 0; }
function invalidateCache() { _cache.clear(); _heroCache = { data: null, ts: 0 }; }

function parseModulesLine(line, kpmName) {
    if (!line || !(line.startsWith(kpmName + ' ') || line === kpmName)) return null;
    const parts = line.trim().split(/\s+/);
    if (parts.length < 2) return null;
    return { size: parseInt(parts[1], 10) || 0 };
}

function lineAgeSec(line) {
    if (!line) return null;
    const m = line.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]/);
    if (!m) return null;
    try {
        const ts = new Date(m[1]).getTime() / 1000;
        const age = (Date.now() / 1000) - ts;
        return age > 0 ? Math.floor(age) : 0;
    } catch { return null; }
}

function lastEventType(line) {
    if (!line) return null;
    if (/Loaded:/i.test(line)) return 'loaded';
    if (/(REJECTED|Failed)/i.test(line)) return 'failed';
    if (/WARN/i.test(line)) return 'warn';
    if (/Unsigned/i.test(line)) return 'unsigned';
    return 'other';
}

function parseServiceLogLines(kpmName, lines) {
    let lastEvent = null;
    let lastEventAgeSec = null;
    let lastEventTypeVal = null;
    let filterCount = 0;
    let errorCount = 0;
    for (const line of lines) {
        if (!line.includes(kpmName)) continue;
        if (/^\[/.test(line)) {
            lastEvent = line.trim();
            lastEventAgeSec = lineAgeSec(line);
            lastEventTypeVal = lastEventType(line);
        }
        if (/(?:Filtered|hid|skip)/i.test(line)) filterCount++;
        if (/(?:REJECTED|Failed|error|exception)/i.test(line)) errorCount++;
    }
    return { lastEvent, lastEventAgeSec, lastEventType: lastEventTypeVal, filterCount, errorCount };
}

const MANIFEST_RE = /\{"id":"([^"]+)","build":"([^"]+)","time":"([^"]+)","size":(\d+)\}/;

async function fetchManifest(kpmName) {
    const kpmPath = `${persistDir}/kpm/${kpmName}.kpm`;
    const r = await exec(
        `tail -c 256 ${escapeShell(kpmPath)} 2>/dev/null`,
        { env: { PATH: `${modDir}/bin:$PATH` } }
    );
    if (!ok(r) || !r.stdout) return { buildId: null, buildTime: null };
    const m = r.stdout.match(MANIFEST_RE);
    if (!m) return { buildId: null, buildTime: null };
    return { buildId: m[2], buildTime: m[3] };
}

async function fetchConfigEnabled(kpmName) {
    const cfgPath = `${persistDir}/kpm_config/${kpmName}.conf`;
    const r = await exec(
        `cat ${escapeShell(cfgPath)} 2>/dev/null | grep -E '^[[:space:]]*enabled' | tail -1 || echo 'enabled=1'`,
        { env: { PATH: `${modDir}/bin:$PATH` } }
    );
    if (!ok(r)) return { enabled: true };
    const val = (r.stdout.trim().split('=').slice(1).join('=') || '1').trim().toLowerCase();
    return { enabled: !(val === '0' || val === 'false') };
}

function deriveState(logData, procSize) {
    if (procSize > 0 && logData.lastEvent && /Loaded:/i.test(logData.lastEvent)) return 'loaded';
    if (logData.lastEvent && /(REJECTED|Failed)/i.test(logData.lastEvent)) return 'failed';
    if (procSize > 0) return 'pending';
    return 'unknown';
}

function deriveUptimeFromLog(logTimestamp) {
    if (!logTimestamp) return 0;
    try {
        const m = logTimestamp.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]/);
        if (!m) return 0;
        const ts = new Date(m[1]).getTime() / 1000;
        const up = (Date.now() / 1000) - ts;
        return up > 0 ? Math.floor(up) : 0;
    } catch { return 0; }
}

export async function getKpmRuntimeStats(kpmName) {
    if (!kpmName) return null;
    const cached = _cache.get(kpmName);
    if (cached && Date.now() - cached.ts < CACHE_TTL_MS) return cached.data;

    try {
        const [procModulesRaw, serviceLogRaw, manifest, config] = await Promise.all([
            exec('cat /proc/modules 2>/dev/null', { env: { PATH: `${modDir}/bin:$PATH` } }),
            exec(
                `cat ${escapeShell(persistDir + '/service.log')} 2>/dev/null | tail -n 200`,
                { env: { PATH: `${modDir}/bin:$PATH` } }
            ),
            fetchManifest(kpmName),
            fetchConfigEnabled(kpmName),
        ]);

        let procSize = 0;
        if (ok(procModulesRaw) && procModulesRaw.stdout) {
            for (const line of procModulesRaw.stdout.split('\n')) {
                const parsed = parseModulesLine(line, kpmName);
                if (parsed) { procSize = parsed.size; break; }
            }
        }

        const logLines = ok(serviceLogRaw) && serviceLogRaw.stdout
            ? serviceLogRaw.stdout.split('\n').filter(Boolean)
            : [];
        const logData = parseServiceLogLines(kpmName, logLines);

        const state = deriveState(logData, procSize);
        const uptimeSec = deriveUptimeFromLog(logData.lastEvent);
        const unsigned = logData.lastEventType === 'unsigned';

        const result = {
            state,
            size: procSize,
            uptime: uptimeSec,
            uptimeText: formatUptime(uptimeSec),
            lastEvent: logData.lastEvent,
            lastEventAgeSec: logData.lastEventAgeSec,
            lastEventType: logData.lastEventType,
            unsigned,
            filterCount: logData.filterCount,
            errorCount: logData.errorCount,
            buildId: manifest.buildId,
            buildTime: manifest.buildTime,
            enabled: config.enabled,
        };

        _cache.set(kpmName, { data: result, ts: Date.now() });
        return result;
    } catch (err) {
        return {
            state: 'unknown', size: 0, uptime: 0, uptimeText: '-',
            lastEvent: null, lastEventAgeSec: null, lastEventType: null,
            unsigned: false, filterCount: 0, errorCount: 0,
            buildId: null, buildTime: null, enabled: true,
        };
    }
}

export async function getKpmHeroStatus() {
    if (_heroCache.data && Date.now() - _heroCache.ts < CACHE_TTL_MS) {
        return _heroCache.data;
    }
    try {
        const r = await exec('cat /proc/modules 2>/dev/null',
            { env: { PATH: `${modDir}/bin:$PATH` } });
        if (!ok(r) || !r.stdout) {
            const empty = { loaded: 0, failed: 0, total: 0, hasUnsigned: false };
            _heroCache = { data: empty, ts: Date.now() };
            return empty;
        }
        const moduleNames = r.stdout.split('\n').filter(Boolean)
            .map(l => l.split(/\s+/)[0])
            .filter(Boolean);
        const total = moduleNames.length;
        const logR = await exec(
            `cat ${escapeShell(persistDir + '/service.log')} 2>/dev/null | tail -n 200`,
            { env: { PATH: `${modDir}/bin:$PATH` } }
        );
        let loaded = 0, failed = 0, hasUnsigned = false;
        if (ok(logR) && logR.stdout) {
            const lines = logR.stdout.split('\n');
            for (const name of moduleNames) {
                for (let i = lines.length - 1; i >= 0; i--) {
                    if (lines[i].includes(name) && /^\[/.test(lines[i])) {
                        if (/Loaded:/i.test(lines[i])) loaded++;
                        else if (/(REJECTED|Failed)/i.test(lines[i])) failed++;
                        if (/Unsigned/i.test(lines[i])) hasUnsigned = true;
                        break;
                    }
                }
            }
        } else {
            loaded = total;
        }
        const hero = { loaded, failed, total, hasUnsigned };
        _heroCache = { data: hero, ts: Date.now() };
        return hero;
    } catch {
        const empty = { loaded: 0, failed: 0, total: 0, hasUnsigned: false };
        _heroCache = { data: empty, ts: Date.now() };
        return empty;
    }
}

export function invalidateKpmStatsCache() { invalidateCache(); }

export function formatUptime(sec) {
    if (sec == null || sec < 0) return '-';
    if (sec < 60) return '<1m';
    const m = Math.floor(sec / 60);
    if (m < 60) return m + 'm';
    const h = Math.floor(m / 60);
    const rm = m % 60;
    if (h < 24) return rm ? h + 'h ' + rm + 'm' : h + 'h';
    const d = Math.floor(h / 24);
    const rh = h % 24;
    return rh ? d + 'd ' + rh + 'h' : d + 'd';
}

export function formatKpmSize(bytes) {
    if (!bytes || bytes <= 0) return '-';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

export function stateBadgeClass(state) {
    switch (state) {
        case 'loaded':  return 'kpm-state-loaded';
        case 'failed':  return 'kpm-state-failed';
        case 'pending': return 'kpm-state-pending';
        default:        return 'kpm-state-unknown';
    }
}

export function stateI18nKey(state) {
    switch (state) {
        case 'loaded':  return 'kpm_state_loaded';
        case 'failed':  return 'kpm_state_failed';
        case 'pending': return 'kpm_state_pending';
        default:        return 'kpm_state_unknown';
    }
}

export { CACHE_TTL_MS, parseModulesLine, parseServiceLogLines, lineAgeSec, lastEventType, MANIFEST_RE, deriveState, deriveUptimeFromLog };
