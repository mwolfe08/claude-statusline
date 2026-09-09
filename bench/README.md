# Status line render benchmark

Harness for measuring what one status line render costs, and the baseline numbers to
beat. Measured 2026-09-08 on the main workstation (AMD, 32 threads) against
`statusline.ps1` at 78 KB / 1,337 lines.

## Running it

```powershell
.\make-payload.ps1 -OutFile $env:TEMP\p.json
# warm up first - the first render spawns a detached cache refresh
.\render-bench.cmd ..\statusline.ps1 $env:TEMP\p.json 3
$sw = [Diagnostics.Stopwatch]::StartNew()
.\render-bench.cmd ..\statusline.ps1 $env:TEMP\p.json 20
$sw.Stop(); $sw.ElapsedMilliseconds / 20
```

Compare two implementations for identical output before comparing speed:

```powershell
$a = (cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File ..\statusline.ps1 < $env:TEMP\p.json") -replace '\x1b\[[0-9;]*m',''
$b = (cmd /c "statusline.exe < $env:TEMP\p.json")                                                        -replace '\x1b\[[0-9;]*m',''
Compare-Object $a $b     # empty result = identical
```

## Baseline: the PowerShell implementation

| Stage | ms | Share |
|---|---|---|
| process startup (powershell 5.1) | 99.3 | 26% |
| parsing the 78 KB script | 33.8 | 9% |
| executing the logic | 247.2 | 65% |
| **total per render** | **~385** | |

Render rate is about 5.5 per session per minute, roughly 2.8 processes each (a `bash`
wrapper, `powershell`, sometimes `git`, plus `conhost`).

## Startup floor by host

| Host | ms/run |
|---|---|
| cmd.exe (native baseline) | 7.7 |
| git.exe --version (real native binary) | 16.8 |
| bash.exe -c exit (the wrapper) | 19.9 |
| **bash -c "native binary" (target shape)** | **32.0** |
| powershell 5.1 -Command exit | 91.4 |
| pwsh 7 -Command exit | 137.0 |

**The `bash` wrapper is unavoidable.** Claude Code runs the status line command through
Git Bash whenever Git Bash is installed, and Git is required for this install anyway, so
19.9 ms is a hard floor. Everything above it is winnable: a native binary should land
near 32 ms total, against 385 ms today.

## Outcome: the host was the answer

The four dead ends below are all still true - and all four were attacking the wrong thing.
None of the cost is in any one section; it is in being a large interpreted script
re-parsed from scratch several times a minute in every open session. The only remaining
lever was the host, and a Go port (`../native/`) took it.

Measured 2026-09-08, 20-60 runs per arm, machine at 10.7% of 32 threads, both arms through
the `bash -c` wrapper:

| Shape | cwd IS a git repo | cwd is NOT a repo |
|---|---|---|
| `bash -c "powershell -File statusline.ps1"` | 416.8 ms | 418.0 ms |
| `bash -c "statusline.exe"` | 52.6 ms | **32.7 ms** |
| speedup | 7.9x | **12.8x** |

Output is byte-identical, escapes included. The remaining gap between the two columns is
the single `git status` spawn, about 20 ms, now skipped when the cwd is not in a work tree.

**Benchmark the native build with this same harness** - `render-bench.cmd` takes a `.exe`
as readily as a `.ps1`, and `bench-bash` shapes matter: timing the binary from `cmd`
alone reads 5.8 ms and flatters it, because it omits the 19.9 ms bash wrapper that the
real invocation always pays.

## Do not re-try these

All four were measured and all four failed. Details, with numbers, in
`personal-computer/memory/claude_statusline_render_cost_is_irreducible.md`.

| Attempt | Result |
|---|---|
| Rewrite in bash | Only attacks the 26% startup share; the logic needs `jq`, and each `jq` call is another process |
| Switch to `pwsh` 7 | SLOWER - 422 ms vs 376 ms |
| Turn off CONFIG features | 38 ms of 385 (10%) and costs real display |
| Invert the stale-cache guard (lines 251-267) | Byte-identical output, ZERO speedup - the work relocates to the memoized call in the render path |

The lesson from the fourth: a profiler segment being expensive does not mean skipping it
saves anything. Always measure the variant end to end.

## Port traps - found by reading the source, before writing any Go

Two things that would each have looked like a port bug.

**Every cache file is UTF-8 WITH a BOM.** They are written by PowerShell 5.1
`Set-Content -Encoding UTF8`, which always emits one. Go's `encoding/json` does not skip
it and fails with `invalid character 'ï' looking for beginning of value`. Strip
`\xEF\xBB\xBF` before unmarshalling every one of `weather-cache.json`,
`verse-cache.json`, `verse-cache-yv.json`, `usage-exact.json` and `.credentials.json`.
Confirmed the same day against `usage-exact.json`, where Python needed `utf-8-sig` for
exactly this reason. Anything the port WRITES back must keep the BOM, or a still-running
PowerShell copy would read it differently.

**Verse output is deliberately non-deterministic**, so raw byte comparison can never
pass. `Format-Verse` picks each word's color with `New-Object System.Random`, per word,
per render, from a 10-entry palette. Two runs of the *unmodified* PowerShell script do
not match each other. The ANSI-strip in the comparison recipe above already handles it -
after stripping, the verse TEXT is stable - but this is why the strip is mandatory rather
than cosmetic, and why verse COLOR fidelity has to be checked by eye.

## Frequency cannot be reduced

`statusLine.refreshInterval` is in SECONDS and is an **additive idle timer, not a minimum
spacing**. The command also re-runs on a new assistant message, `/compact` finishing, a
permission-MODE change, a vim-mode toggle, a change to the `command` itself, a rate-limit
window reset, and prompt-cache expiry. Updates debounce at 300 ms, and an in-flight script
is CANCELLED if a new update fires. So in an agentic tool loop the rate tracks activity,
and raising `refreshInterval` changes nothing. There is no setting, environment variable,
or flag that caps it, and no daemon or cached-output mode.
