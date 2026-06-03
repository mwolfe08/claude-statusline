# claude-statusline

A rich PowerShell status bar for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays model info, git state, token usage, multi-window cost, subscription quotas, weather, and optionally Bible verses.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)

![screenshot](screenshot.png)

## What it shows

**Row 1 — Identity:** model label, working directory, current weather + forecast alerts

**Row 2 — Progress:** git branch/status, context window bar, token count, cost (single or four-window), cache hit %, prompt count, style

**Row 3 — Quota:** account tag, 5-hour utilization %, 7-day utilization %, LLM call count, API duration

**Verses (optional):** Verse of the Day from YouVersion and Bible Gateway (ESV), with word-level color theming

## Features

- **Context pressure bar** — 5-cell block bar colored green → yellow → orange → red as you approach the context limit. Thresholds differ for 200K vs 1M context models.
- **Git integration** — current branch with dirty (`*`), ahead (`+N`), and behind (`-N`) markers.
- **Token accounting** — parses the transcript file to count input + cache_read + cache_creation tokens and compute cache hit %.
- **Prompt counter** — counts real user turns (excluding tool results, meta injections, and slash commands) plus interrupts.
- **Cost tracking** — a single session figure, or a four-window view of spend across **session / 5h / 7d / 30d**, each colored by spend level. See [How cost tracking works](#how-cost-tracking-works).
- **Subscription quota** — fetches 5-hour and 7-day utilization from the Anthropic OAuth endpoint (5-min cache, file-locked refresh).
- **Weather** — current conditions + upcoming rain/wind alerts via [Open-Meteo](https://open-meteo.com) (free, no API key). 30-min cache with stale fallback.
- **Bible verses** — dual-source Verse of the Day with word-level coloring in a brown palette (God/Jesus/LORD/Lord highlighted in red). 12-hour cache.

## Install

1. **Copy `statusline.ps1`** somewhere permanent (e.g. `~/.claude/statusline.ps1`).

2. **Edit the `CONFIG` block** at the top of the script (all optional — see [Configuration](#configuration)):
   ```powershell
   $WEATHER_LAT  = '40.7128'   # your latitude  (empty = no weather)
   $WEATHER_LON  = '-74.0060'  # your longitude

   $ACCOUNT_TAGS = @{
       'yourcompany.com' = 'work'
       'gmail.com'       = 'me'
   }

   $COST_WINDOWS       = $true # $false for a single session "$X.XX" figure
   $BILLING_ANCHOR_DAY = 1     # day of month your plan renews (30d window reset)
   ```

3. **Point Claude Code at it.** In `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell -NoProfile -File C:/Users/you/.claude/statusline.ps1"
     }
   }
   ```
   On PowerShell 7+ use `pwsh` instead of `powershell`.

4. **Restart Claude Code.** The status bar appears below your prompt and refreshes on every render.

## Configuration

All configuration is the `CONFIG` block at the top of the script — no other edits required to get running.

| Variable | Purpose | Default |
|----------|---------|---------|
| `$WEATHER_LAT` / `$WEATHER_LON` | Coordinates for weather. Leave empty to disable. | `''` (disabled) |
| `$ACCOUNT_TAGS` | Map email-domain suffixes → short labels. Unmatched accounts show the email's username. | `@{}` |
| `$COST_WINDOWS` | `$true` = session/5h/7d/30d windows; `$false` = single session figure. | `$true` |
| `$BILLING_ANCHOR_DAY` | Day of month your plan renews; the 30d window resets at 00:00 local on it (clamped to month length). | `1` |

## Customize

Everything below the `CONFIG` block is plain PowerShell — tweak freely:

- **Disable Bible verses** — delete or comment out everything from the `# Verse of the Day` comment to the end of the file.
- **Cost color thresholds** — edit the `$cS/$cH/$c7/$c30` lines in the cost block (e.g. `if ($fiveHourTotal -ge 20) { $red } ...`). The single-figure mode uses `$costColor`.
- **Context-bar thresholds / width** — `$barLen` sets the cell count; the `$barColor` block sets the green/yellow/orange/red breakpoints (separate ladders for 200K vs 1M models).
- **Weather alert sensitivity** — the `rain $prob -ge 50` and `wind $maxMph -ge 20` checks in the weather block.
- **Row layout** — segments are appended to `$row1`, `$row2`, `$row3`, and `$partsBottom`; reorder or drop `+=` lines to taste.

## How cost tracking works

Claude Code reports `cost.total_cost_usd` to the statusline. Two things about that number are easy to get wrong, and the four-window view (`$COST_WINDOWS = $true`) handles both:

**1. It's per *process*, not per session.** `total_cost_usd` accumulates for the life of the running `claude` process and **survives `/clear`, `/compact`, and resume** — each of those mints a new `session_id` but keeps the same process and its running total. So the **`s` (session) figure does not reset to $0 after a `/clear`** — it reflects everything that terminal has spent since launch. That's expected, not a bug.

**2. The wider windows must be keyed by process, not session.** For the 5h / 7d / 30d sums, each render writes the current cost to a small file under `~/.claude/cost-tracker/`, and one pass sums the files whose last-write time falls inside each window (files pool across accounts; pruned past 40 days). The trap: if you key those files by `session_id`, every `/clear` leaves a **stale file holding the carried-over cumulative cost**, and the next session writes essentially the same total again — so the windows **double-count** the same spend (once per `/clear`).

The fix is to key each file by the **owning `claude` process PID** instead of `session_id`. One file per terminal, overwritten across `/clear` — so the carried-over cost is counted once. Resolving that PID takes some care: the statusline's *immediate* parent is whatever shell Claude Code spawned it through (bash, pwsh, cmd — and often a **fresh shell each render**), so the script walks **up** the process tree — via a `Win32_Process` CIM lookup that works in both Windows PowerShell 5.1 and 7 — until it reaches the `claude`/`node` process, and keys on that. If no such ancestor is found it falls back to `session_id` (the old per-session behavior).

**Window boundaries:** the 5h and 7d windows snap to the real `resets_at` reported by the OAuth usage cache (`usage-exact.json`), advanced forward by whole blocks to the most recent boundary at/before now (so a stale anchor still yields the *current* window). The 30d window resets at 00:00 local on `$BILLING_ANCHOR_DAY`.

**Caveat:** a long-lived terminal still counts its full cumulative cost in whichever window its last render landed, so the older windows can skew slightly high. Removing that entirely would need per-render delta tracking; PID-keying removes the much larger `/clear` double-count.

> Migrating from an older copy that keyed by `session_id`? Old files linger until they age out (5h self-corrects within ~5h, 7d within a week). To reset immediately, delete the non-numeric (GUID-named) files and keep the numeric (PID) ones:
> ```powershell
> Get-ChildItem "$env:USERPROFILE\.claude\cost-tracker\*.cost" |
>   Where-Object { $_.BaseName -notmatch '^\d+$' } | Remove-Item
> ```

## Multi-account support

If you run more than one Claude account (e.g. separate Pro/Max subscriptions) and switch between them with per-account [`CLAUDE_CONFIG_DIR`](https://docs.anthropic.com/en/docs/claude-code/settings) profiles, the status bar follows the **active** account automatically — the account tag and the 5h/7d quota reflect whichever account the current session is running, not whichever login happens to be in the default `~/.claude`.

It works because Claude Code spawns the statusline with the session's environment, so the `-NoProfile` script still inherits `CLAUDE_CONFIG_DIR` and reads that profile's credentials + usage cache. With no `CLAUDE_CONFIG_DIR` set (a normal single-account setup) it falls back to `~/.claude` and behaves exactly as before — nothing to configure.

A minimal profile switcher to pair with it (PowerShell):

```powershell
# Each profile keeps its own persisted login; sign in once per profile, then switch freely.
function claude-work { $env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude-profiles\work"; claude }
function claude-me   { $env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude-profiles\me";   claude }
```

Add each account's email domain to `$ACCOUNT_TAGS` so its tag shows in the bar. Cost-tracker files pool across all accounts, so the cost windows show your **total** spend regardless of which account each session used.

## How it works

Claude Code pipes a JSON blob to the statusline command's stdin on every render. The JSON includes model info, workspace path, transcript path, cost data, and permission mode. This script reads that JSON, enriches it with git status, token parsing, cost windows, weather, and quota data, then outputs ANSI-colored lines to stdout.

Caches and state are stored under `~/.claude/`:
- `cost-tracker/<pid>.cost` — one tiny file per `claude` process; summed for the 5h/7d/30d windows (see [How cost tracking works](#how-cost-tracking-works))
- `weather-cache.json` — 30-min TTL
- `usage-exact.json` — 5-min TTL, file-locked (stored under the active `CLAUDE_CONFIG_DIR` profile when set, so quota is per-account — see [Multi-account support](#multi-account-support))
- `verse-cache.json` / `verse-cache-yv.json` — 12-hour TTL

## Requirements

- Windows with PowerShell 5.1+ (ships with Windows 10/11); PowerShell 7+ works too
- Claude Code CLI or desktop app
- Git (for branch/status display)
- Internet access (for weather and verse fetching; gracefully falls back to cache)

## License

MIT
