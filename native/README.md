# native/ - the status line as a compiled binary

A Go port of `../statusline.ps1`, byte-for-byte identical in output and about 13x
cheaper to run. Same three rows, same verses, same caches, same files on disk.

## Why

The status line is not slow because of what it computes. It is slow because of what
hosts it. One render, measured 2026-09-08 on this workstation:

| Stage of one PowerShell render | ms | Share |
|---|---|---|
| process startup (powershell 5.1) | 99.3 | 26% |
| parsing the 78 KB script | 33.8 | 9% |
| executing the logic | 247.2 | 65% |
| **total** | **~385** | |

Four optimisations were tried against that and all four failed - see `../bench/README.md`,
which lists them so nobody repeats them. The cost is not in any one section; it is in
being a large interpreted script re-parsed from scratch several times a minute in every
open session. The only remaining lever is the host.

Claude Code runs the status line command through Git Bash on Windows, so `bash -c` at
19.9 ms is a hard floor. A native binary behind it lands near the floor:

Measured 2026-09-08, 20-60 runs per arm, machine at 10.7% of 32 threads, both arms
through the `bash -c` wrapper Claude Code actually uses:

| Shape | cwd IS a git repo | cwd is NOT a repo |
|---|---|---|
| `bash -c "powershell -File statusline.ps1"` | 416.8 ms | 418.0 ms |
| `bash -c "statusline.exe"` | 52.6 ms | **32.7 ms** |
| speedup | 7.9x | **12.8x** |

The two columns differ by the one process this build still starts. `git status` costs
about 20 ms of the 52.6, and it is skipped entirely when the working directory is not in
a work tree - which is the common case here, since the workspace root these sessions run
in is deliberately not a repo. The PowerShell version spawned git there anyway, every
render, to be told there was no branch.

## Build and install

```powershell
pwsh -File ..\install.ps1 -DryRun   # show every change, write nothing
pwsh -File ..\install.ps1           # build, install, seed config, switch over
pwsh -File ..\install.ps1 -Rollback # point settings.json back at statusline.ps1
```

`statusline.ps1` is left in place, so rollback is one settings key.

The binary is deliberately **not committed**. `publish-public.ps1` hash-pins every
binary in the publish tree so a human re-reviews it before it ships; a binary that
changes on every `go build` would abort every publish run. The public mirror gets
buildable source instead.

## The CONFIG block became a config FILE

Lines 6-50 of `statusline.ps1` were the only personal values in it - coordinates,
account tags, billing anchor day. That is the whole reason `sync-live.ps1` exists: every
code sync had to move around them.

A compiled binary cannot carry them, and should not, because the public mirror ships the
same bytes. So they live in `<USERPROFILE>/.claude/statusline-config.json`, which is in
neither repo. `statusline-config.sample.json` here is the public template, and
`install.ps1` seeds a real one by evaluating the CONFIG block of an existing
`statusline.ps1`.

Missing config file = the sample's values, which are exactly what the repo copy of
`statusline.ps1` carries. A fresh clone renders what a fresh clone always rendered.

## Parity

Output must be byte-identical before speed is worth discussing. The comparison strips
SGR escapes only for the verse BODY lines - the verse palette picks a random color per
word, so those can never match between two runs of *either* implementation - and
compares everything else raw, escapes included.

Three parity traps, each of which produced a real difference before it was fixed:

- **`[Console]::WindowWidth` probes the STD_OUTPUT handle, not the console.** Under the
  harness stdout is a pipe, so .NET throws "The handle is invalid", the script's `catch`
  fires, and the width is the 160 fallback. Reading `CONOUT$` instead finds the real
  console (112 here) and rewraps every verse line. `console_windows.go` deliberately
  probes stdout so it fails the same way.
- **Three different rounding modes, none interchangeable.** `[math]::Round(x,d)` and a
  `[int]` cast are banker's rounding; `'{0:N2}'` and `'{0:0.#}'` round half away from
  zero. Go's `strconv` rounds half-to-even, so the format paths in `ansi.go` round the
  decimal STRING instead. Taking the shortest round-trip representation first is what
  reproduces .NET Framework's 15-digit intermediate - the classic 2.675 case comes out
  "2.68" as it must.
- **CRLF, no BOM.** PowerShell's `Write-Output` terminates each line with `\r\n` on this
  host and emits no BOM despite `[Console]::OutputEncoding` being UTF8. Verified by
  hexdump, not assumed.

## On-disk compatibility

Every state file keeps its exact format, so the two implementations can be swapped in
either direction, and can even run side by side across different sessions:

| File | Format |
|---|---|
| `transcript-cache/tx-<key>.state` | `v1 <offset> <prompts> <llm> <inp> <cread> <ccrt> <ttl> <ts>` |
| `cost-tracker/sess-<key>.series` | `<epoch> <cumulative>` per line, CRLF |
| `cost-tracker/windows.cache` | `<stamp> <e5h> <e7d> <e30d> <sum5h> <sum7d> <sum30d>` |
| `usage-exact.json`, `weather-cache.json`, `verse-cache*.json` | JSON, same keys |
| `<cache>.fail` | the failure count, for the exponential backoff |

Readers tolerate the UTF-8 BOM that PowerShell's `Set-Content -Encoding UTF8` writes.

## Files

| File | What it holds |
|---|---|
| `main.go` | render orchestration, row assembly, the cache chip and quota chips |
| `config.go` | the CONFIG block, loaded from JSON |
| `ansi.go` | the palette, and .NET-parity number formatting |
| `cache.go` | cache ages, the failure backoff, the usage-cache identity guard |
| `transcript.go` | the incremental transcript scan and its carried state |
| `cost.go` | the four cost windows and the shared aggregate |
| `usage.go` | the quota document and .NET-style timestamp parsing |
| `weather.go` | the weather chip and its two forecast alerts |
| `verse.go` | verse cache reads, wrapping and coloring |
| `gitstatus.go` | the ONE git spawn - the only process this build still starts |
| `refresh.go` | `-refresh-only`: the detached background fetchers |
| `console_windows.go` | terminal width, and the detached refresh spawn |

## One process fewer than the original

The PowerShell background refresh used `Start-Process -WindowStyle Hidden`, and a hidden
console is still a console, so every refresh also allocated a `conhost.exe`. The Go build
uses `DETACHED_PROCESS`, which allocates none.
