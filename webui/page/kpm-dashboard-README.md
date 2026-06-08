# KPM Dashboard

The KPM page now ships a **per-card runtime dashboard** plus a
**full-page expand dialog** for every installed KPM. It surfaces signals
that `kpatch kpm info` does not — uptime, last event, lifetime
loads/failures, build id, config size, and an unsigned warning — by
reading on-disk artifacts the supervisor already writes.

## 1. What you see

### Per-card mini dashboard

Every KPM card gets a small status block below the description:

```
● loaded   3h 12m   142 loads   0 fails
Filters 142 · Errors 0 · Build 7f3a91c · 7 cfg keys
```

A coloured **state dot + label** (`loaded`, `pending`, `failed`), a
compact **uptime**, **lifetime loads/fails**, and a footer with
**Filters** (loads), **Errors** (fails), **Build id**, and the **number
of config keys**. An **unsigned** icon appears when the KPM was loaded
under the warn-policy without a valid signature.

### Expanded dialog

Tap the card body (outside the action buttons) or the **dashboard** icon
to open a full-page dialog with every field, the *last event* timestamp,
and the *age* of the most recent load/failure.

### Page hero

A one-line status above the card list summarises the whole set:

```
● System OK · 8 loaded · 0 failed
```

## 2. Data fields and their sources

| Field           | Meaning                                       | Source                                                |
|-----------------|-----------------------------------------------|-------------------------------------------------------|
| `state`         | `loaded` / `pending` / `failed`               | `kpatch kpm list` + last service.log event + `kpm/failed/` marker |
| `uptime`        | Seconds since the most recent successful load | `service.log` `Loaded: <name>` last timestamp         |
| `uptimeText`    | Human-readable (`3h 12m`)                     | Derived from `uptime`                                 |
| `filterCount`   | Lifetime successful loads                     | `service.log` regex on `Loaded: <name>`               |
| `errorCount`    | Lifetime failed loads                         | `service.log` regex on `Failed to load` / `REJECTED`  |
| `lastEvent`     | Most recent load/failure and its age          | Last matching line in `service.log`                   |
| `buildId`       | Embedded build hash (built-in KPMs only)      | Last 256 bytes of `module/kpms/built/<name>.kpm`      |
| `configKeys`    | Lines in the runtime config file              | `wc -l kpm_config/<name>.conf`                        |
| `unsigned`      | Loaded under warn-policy, no signature        | `unsigned_modules.log` grep for `<name>`              |
| `failed`        | Failure blob present on disk                  | `ls kpm/failed/<name>.kpm`                            |

Pure parsers live in `kpm_stats.js` and are exported for unit tests —
they never call `exec()`. Shell-backed wrappers (`readKpmList`,
`readServiceLog`, etc.) are the only functions that touch the device.

## 3. Auto-refresh

- A 5 s timer (`startDashboardAutoRefresh` in `kpm.js`) re-fetches
  per-card stats and re-renders the mini dashboard.
- Stats are cached in-process for **4 s** (`CACHE_TTL_MS`), so each
  5 s tick collapses into one shell-out pass per source, not seven.
- After any load / unload / ctl action, `invalidateKpmStatsCache()`
  runs so the next render sees the new state immediately, without
  waiting out the 4 s window.

To **kill the dashboard** without removing code, comment out
`startDashboardAutoRefresh()` at the bottom of `renderKpmPage()`.

## 4. State colour mapping

All colours are existing Material 3 tokens — no new variables.

| State     | Token                                   | Notes                              |
|-----------|-----------------------------------------|------------------------------------|
| `loaded`  | `--md-sys-color-primary`                | Healthy, in the live module list   |
| `pending` | `--md-sys-color-on-surface-variant`     | Known (config / log / unsigned) but not live |
| `failed`  | `--md-sys-color-error`                  | Last event is a failure, or `kpm/failed/<name>.kpm` exists |

The page-hero dot uses the same tokens, picked from the aggregate
`loaded` / `failed` counts returned by `getKpmHeroStatus()`. Every
coloured element has a sibling text label and an `aria-label`, so the
UI is readable in monochrome and by screen readers.

## 5. Privacy: what is exposed to user-space

The dashboard reads **only artifacts the supervisor already wrote to
`/data/adb/patchnest/`** — no new kernel handles, no `/proc/<pid>/` reads.
Concretely, the surface area is:

- `kpatch kpm list` — public module list.
- `/data/adb/patchnest/service.log` — supervisor log.
- `/data/adb/patchnest/unsigned_modules.log`.
- `/data/adb/patchnest/kpm_config/<name>.conf` — per-KPM runtime config.
- `/data/adb/patchnest/kpm/failed/<name>.kpm` — failure blobs.
- `<modDir>/kpms/built/<name>.kpm` last 256 bytes — embedded manifest.

**No PII, no per-process info, no network calls.** Build hash and
embedded timestamp are the KPM author's metadata, not the user's. The
*config-keys count* is shown but **the config contents are not** — only
`wc -l` is executed.

## 6. Troubleshooting

| Symptom                              | Likely cause                                       | Fix                                                                                            |
|--------------------------------------|----------------------------------------------------|------------------------------------------------------------------------------------------------|
| State always `pending`               | KPM was loaded once, then unloaded                 | Expected — `kpatch kpm list` is the source of truth for `loaded`.                              |
| `unsigned` icon never goes away      | Module loaded under warn-policy                    | Re-load with a valid signature, or remove the `unsigned_modules.log` entry.                     |
| `Build` field empty                  | KPM installed by dropping a `.kpm` into `kpms/`    | Expected — the embedded manifest only exists for built-in KPMs.                               |
| `0 cfg keys` shown                   | KPM has no `kpm_config/<name>.conf`                | Expected; not all KPMs need a config.                                                          |
| Stale numbers                        | 4 s in-process cache                               | Pull-to-refresh, or trigger any load/unload action — `invalidateKpmStatsCache()` will run.     |
| Dialog never opens                   | `getElementById('kpm-dashboard-dialog')` is null   | Make sure `index.html` still has the dialog host.                                              |

## 7. Adding a new metric (for future maintainers)

The dashboard is intentionally two-layered — keep it that way.

**Pure parsers** (testable, no shell): add a function in `kpm_stats.js`
that takes the raw log/config text and returns the extracted value.
Export it. Add unit tests in `test/kpm-dashboard.test.js` using a
fixture string.

**Shell-backed fetchers**: if the signal lives somewhere new on disk,
add a small `async function readX()` next to `readServiceLog()` etc.,
following the same `try { await exec(...) } catch { return '' }`
pattern. Never let an exception bubble — the dashboard must degrade
gracefully when a source is missing.

**Aggregating into the runtime stats object**: extend
`getKpmRuntimeStats(name)` to call your new fetcher in the
`Promise.all` and add the field to the returned `data` object. Prefer
`Promise.all` over a sequential `await` chain.

**Rendering**:
- Per-card mini view: edit `renderKpmDashboardMini(slot, stats)` in
  `kpm.js` and add a new `.kpm-dashboard-mini-row`.
- Expanded dialog: edit `renderKpmDashboardFull(stats, name)` and add
  a `.kpm-dashboard-full-row`.
- Style with the existing `.kpm-*` classes and Material 3 tokens. Do
  **not** introduce new colour variables — re-use `--md-sys-color-*`.

**State mapping**: if the new metric should influence the page hero or
the per-card state, extend `detectState()` in `kpm_stats.js` and the
`.kpm-state-*` CSS rules. Keep `detectState` pure so tests can call it
directly.

**i18n**: add keys to `public/locales/strings/en.xml` and `zh-CN.xml`,
then look them up via `getString(...)` in `kpm.js`. The existing
`kpm_dashboard_*` namespace is the right place.

**Kill switch**: ship new metrics behind a constant in `kpm_stats.js`
that defaults to `true` so a regression can be turned off in one place
without removing the parser.
