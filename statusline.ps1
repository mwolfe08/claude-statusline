param([switch]$RefreshOnly)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================== CONFIG ==============================
# Personal settings. Everything below this block is generic logic, so a
# re-sync from a working copy only needs to preserve these lines.
#   Weather: coordinates for the Open-Meteo forecast (its timezone is
#   auto-resolved from them). Leave EITHER value blank to disable weather.
$WEATHER_LAT = ''           # latitude   e.g. '40.7128'  (empty = no weather)
$WEATHER_LON = ''           # longitude  e.g. '-74.0060'
#   Account tag (row 3): label the running account. $PROFILE_TAGS is matched
#   first, by CLAUDE_CONFIG_DIR profile-folder name; $ACCOUNT_TAGS is the
#   fallback, by email-domain suffix. No match -> the email's username.
$PROFILE_TAGS = @{}                     # e.g. @{ 'work' = 'wk'; 'personal' = 'me' }
$ACCOUNT_TAGS = @{ 'gmail.com' = 'me' } # e.g. @{ 'yourcompany.com' = 'work' }
#   Cost chip (row 2): $true renders the four-window view s/h/7d/30d, pooling
#   spend across every session via the cost-tracker dir; $false renders only
#   this session's figure and skips the tracker entirely (no files written).
#   $BILLING_ANCHOR_DAY is the day of the month the plan renews -- the 30d
#   window resets at 00:00 local on it (clamped to the month's length).
$COST_WINDOWS       = $true
$BILLING_ANCHOR_DAY = 1
#   Prompt-cache countdown (row 1 "cache" chip). Claude Code caches the
#   conversation's prompt prefix with a 1-HOUR TTL that every main-chain API
#   call refreshes. Warm, the prefix re-reads at 0.1x input price; lapsed, the
#   next turn rewrites the WHOLE prefix at 2x -- about a 20x swing (on a 500K
#   context that is roughly $0.75 vs $15). The chip counts that hour down so a
#   session can be deliberately re-armed (send anything) or abandoned before it
#   lapses, instead of the cost landing invisibly on the next turn.
#   TRAP: under usage overage Anthropic drops the TTL to 5 min, and nothing in
#   the JSON on stdin reveals it. If that happens, set $CACHE_TTL_MIN to 5.
$CACHE_TTL_MIN  = 60   # cache lifetime in minutes (0 disables the chip)
$CACHE_WARN_MIN = 15   # <= this many minutes left -> yellow (heads up)
$CACHE_CRIT_MIN = 6    # <= this many minutes left -> blinking red (act now)
#   Verse of the Day lines. Bible Gateway is requested as ESV. YouVersion serves
#   its default translation, currently NIV, and cannot be pinned: the only URL
#   that still works there is the unparameterised one, because adding
#   ?version=<id> (59 = ESV) now returns a bot-protection "Client Challenge"
#   page instead of the verse. Each line is labelled with what it actually
#   carries. Set $VERSE_YOUVERSION = $false for an ESV-only statusline.
$VERSE_YOUVERSION = $true
$VERSE_BIBLEGATEWAY = $true
# ===================================================================

# Active Claude config dir (fuller note below) -- needed by BOTH the normal render
# path and the -RefreshOnly background path, so it is resolved first.
$cfgDir = if ($env:CLAUDE_CONFIG_DIR -and (Test-Path $env:CLAUDE_CONFIG_DIR)) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

# ==================== STALE-WHILE-REVALIDATE NETWORK CACHE ====================
# The render path NEVER blocks on the network. Every network-backed detail (weather,
# subscription quota, verses) is served from a cache file; when a cache goes stale the
# render fires a DETACHED background copy of this very script (-RefreshOnly) that
# refetches + rewrites the caches, then exits. Net effect: each render is cache-only
# and fast (no multi-second network stalls), data at most one render-cycle behind.
# Timeouts below are generous precisely BECAUSE they run off the render hot path.
$weatherCache = Join-Path $env:USERPROFILE '.claude\weather-cache.json'
$usageCache   = Join-Path $cfgDir 'usage-exact.json'
$credPath     = Join-Path $cfgDir '.credentials.json'
$verseBGCache = Join-Path $env:USERPROFILE '.claude\verse-cache.json'
$verseYVCache = Join-Path $env:USERPROFILE '.claude\verse-cache-yv.json'
$WEATHER_MAXAGE = 43200    # 12 hr
$USAGE_MAXAGE   = 300      # 5 min  (Anthropic rate-limits /api/oauth/usage hard)
$VERSE_MAXAGE   = 43200    # 12 hr
function Get-CacheAge($p) { if (Test-Path $p) { ((Get-Date) - (Get-Item $p).LastWriteTime).TotalSeconds } else { [double]::MaxValue } }

# ---- NEGATIVE CACHE (retry backoff) ----
# A fetcher that CANNOT succeed -- dead endpoint, changed markup, bot challenge -- used
# to pin the refresh trigger permanently ON. The trigger below is an OR across all four
# caches, so one unfixable item meant every active ACCOUNT spawned a detached refresh
# process every 45s, forever, retrying something that could never work. Found 2026-08-06:
# YouVersion's verse cache had been stale 31h and was doing exactly that.
# Each failure bumps a count in <cache>.fail; the item is then not "due" again until an
# exponentially growing backoff elapses (5m, 10m, 20m ... capped at 6h). Any success
# clears the marker, so a transient outage costs one short delay and nothing more.
$FAIL_BASE = 300      # 5 min after the first failure
$FAIL_CAP  = 21600    # 6 hour ceiling
function Get-FailBackoff($p) {
    if (-not (Test-Path "$p.fail")) { return 0 }
    $n = 1; try { $n = [int]((Get-Content "$p.fail" -Raw).Trim()) } catch { $n = 1 }
    if ($n -lt 1) { $n = 1 }
    [Math]::Min($FAIL_BASE * [Math]::Pow(2, [Math]::Min($n - 1, 10)), $FAIL_CAP)
}
# Due = past its max age AND not inside a failure backoff window.
function Test-CacheDue($p, $maxAge) {
    if ((Get-CacheAge $p) -le $maxAge) { return $false }
    (Get-CacheAge "$p.fail") -ge (Get-FailBackoff $p)
}
function Set-FetchFailed($p) {
    $n = 0; if (Test-Path "$p.fail") { try { $n = [int]((Get-Content "$p.fail" -Raw).Trim()) } catch { $n = 0 } }
    try { Set-Content -Path "$p.fail" -Value ([string]($n + 1)) -Encoding ASCII } catch {}
}
function Clear-FetchFailed($p) { Remove-Item "$p.fail" -Force -ErrorAction SilentlyContinue }

# Verse fetchers (ESV). Return @{ text=..; ref=.. } or $null. Used only by -RefreshOnly.
$fetchVerseBG = {
    $r = Invoke-RestMethod -Uri 'https://www.biblegateway.com/votd/get/?format=json&version=ESV' -TimeoutSec 6
    $t = [System.Net.WebUtility]::HtmlDecode([string]$r.votd.text)
    $t = ($t -replace '<[^>]+>','').Trim()
    $t = ($t -replace '^[\s"\u201C\u201D]+', '' -replace '[\s"\u201C\u201D]+$', '').Trim()
    $t = [char]0x201C + $t + [char]0x201D
    @{ text = $t; ref = "$([string]$r.votd.reference) ESV, Bible Gateway" }
}
$fetchVerseYV = {
    # NO QUERY STRING. `?version=59` (ESV) now returns a 3 KB bot-protection interstitial
    # titled "Client Challenge" instead of the page -- that is what silently killed this
    # fetcher (cache went 31h stale before anyone noticed, 2026-08-06). The bare URL is
    # still edge-served and returns the real 550 KB page with og:description intact.
    # COST OF THE FIX: the bare URL serves YouVersion's default translation, NIV
    # (version=111), not ESV -- and there is no way back to ESV here. A cookie does not
    # change it, and every parameterised form trips the same challenge. No keyless ESV
    # verse-of-the-day API exists (licensing); Bible Gateway ESV already covers the other
    # line. So this line is labelled NIV rather than pretending to be ESV.
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        'Accept'     = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    }
    $resp = Invoke-WebRequest -Uri 'https://www.bible.com/verse-of-the-day' -Headers $headers -TimeoutSec 6 -UseBasicParsing
    $html = [string]$resp.Content
    if ($html -match '<meta\s+property="og:description"\s+content="([^"]+)"') {
        $content = [System.Net.WebUtility]::HtmlDecode($Matches[1])
        # [\s\S] not . -- the description now carries the verse's own line breaks
        # ("...to your light,\nand kings to..."), and `.` does not cross a newline, so the
        # old anchored pattern failed on the text even once the page was reachable again.
        if ($content -match '^((?:\d\s+)?[A-Za-z]+(?:\s+of\s+\w+)?)\s+(\d+:\d+(?:-\d+)?)\s+([\s\S]+)$') {
            $vt = ($Matches[3] -replace '\s+', ' ').Trim()
            $vt = ($vt -replace '^[\s"\u201C\u201D]+', '' -replace '[\s"\u201C\u201D]+$', '').Trim()
            if (-not $vt) { return $null }
            $vt = [char]0x201C + $vt + [char]0x201D
            return @{ text = $vt; ref = "$($Matches[1]) $($Matches[2]) NIV, YouVersion" }
        }
    }
    return $null
}

# Refetch whatever is stale and rewrite its cache. Each block fails soft (a stale
# cache is left untouched on any error).
function Invoke-CacheRefresh {
    if ($WEATHER_LAT -and $WEATHER_LON -and (Test-CacheDue $weatherCache $WEATHER_MAXAGE)) {
        try {
            $wUrl = "https://api.open-meteo.com/v1/forecast?latitude=$WEATHER_LAT&longitude=$WEATHER_LON&current=temperature_2m,weather_code,wind_speed_10m,wind_direction_10m&daily=weather_code,precipitation_sum,wind_speed_10m_max,precipitation_probability_max&temperature_unit=fahrenheit&wind_speed_unit=mph&timezone=auto&forecast_days=16"
            $w = Invoke-RestMethod -Uri $wUrl -TimeoutSec 6
            @{ fetched_at = (Get-Date).ToString('o'); weather = $w } | ConvertTo-Json -Depth 10 | Set-Content -Path $weatherCache -Encoding UTF8
            Clear-FetchFailed $weatherCache
        } catch { Set-FetchFailed $weatherCache }
    }
    if ((Test-CacheDue $usageCache $USAGE_MAXAGE) -and (Test-Path $credPath)) {
        try {
            $tok = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
            if ($tok) {
                $h = @{ Authorization = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20' }
                $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -TimeoutSec 6
                $email = ''
                try { $prof = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/profile' -Headers $h -TimeoutSec 6; $email = [string]$prof.account.email } catch {}
                $resp | Add-Member -NotePropertyName '_email' -NotePropertyValue $email -Force
                $resp | ConvertTo-Json -Depth 6 | Set-Content -Path $usageCache -Encoding UTF8
                Clear-FetchFailed $usageCache
            }
        } catch { Set-FetchFailed $usageCache }
    }
    # A disabled line must not be fetched either -- otherwise it keeps writing a cache
    # nothing renders, and a broken one keeps burning its backoff retries.
    $verseJobs = @()
    if ($VERSE_BIBLEGATEWAY) { $verseJobs += , @($verseBGCache, $fetchVerseBG) }
    if ($VERSE_YOUVERSION)   { $verseJobs += , @($verseYVCache, $fetchVerseYV) }
    foreach ($v in $verseJobs) {
        if (Test-CacheDue $v[0] $VERSE_MAXAGE) {
            try {
                $fresh = & $v[1]
                if ($fresh -and $fresh.text -and $fresh.ref) {
                    @{ fetched_at = (Get-Date).ToString('o'); text = $fresh.text; ref = $fresh.ref } | ConvertTo-Json | Set-Content -Path $v[0] -Encoding UTF8
                    Clear-FetchFailed $v[0]
                } else {
                    # Reached the endpoint but could not parse it -- the exact shape that
                    # spun forever before. A soft null is a FAILURE, not a no-op.
                    Set-FetchFailed $v[0]
                }
            } catch { Set-FetchFailed $v[0] }
        }
    }
}

# Background mode: refresh stale caches, then EXIT without rendering (no stdin read).
if ($RefreshOnly) { Invoke-CacheRefresh; return }

# Normal render mode: if any cache is stale, launch ONE detached background refresh
# (throttled per-account to ~45s), then fall straight through to render from cache.
# Test-CacheDue, not raw Get-CacheAge: an item inside its failure backoff is NOT due, so
# a permanently-broken fetcher can no longer hold this OR true and respawn a refresh
# process every 45s in every account for ever.
if ((Test-CacheDue $weatherCache $WEATHER_MAXAGE) -or
    (Test-CacheDue $usageCache   $USAGE_MAXAGE)   -or
    ($VERSE_BIBLEGATEWAY -and (Test-CacheDue $verseBGCache $VERSE_MAXAGE)) -or
    ($VERSE_YOUVERSION   -and (Test-CacheDue $verseYVCache $VERSE_MAXAGE))) {
    $refreshMarker = Join-Path $cfgDir 'statusline-refresh.marker'
    if ((Get-CacheAge $refreshMarker) -ge 45) {
        try {
            Set-Content -Path $refreshMarker -Value (Get-Date).ToString('o') -Encoding ASCII
            $selfExe = try { (Get-Process -Id $PID).Path } catch { 'powershell' }
            if (-not $selfExe) { $selfExe = 'powershell' }
            Start-Process -FilePath $selfExe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-RefreshOnly'
            ) | Out-Null
        } catch {}
    }
}

$raw = [Console]::In.ReadToEnd()
$j = $raw | ConvertFrom-Json

$model    = $j.model.display_name
$modelId  = [string]$j.model.id
$cwd      = $j.workspace.current_dir; if (-not $cwd) { $cwd = $j.cwd }
$dir = ''
if ($cwd) {
    $leaf   = Split-Path -Leaf $cwd
    $parent = Split-Path -Leaf (Split-Path -Parent $cwd)
    $dir    = if ($parent) { "$parent/$leaf" } else { $leaf }
}
$tpath    = $j.transcript_path
$permMode = $j.permission_mode; if (-not $permMode) { $permMode = 'default' }
$style    = $j.output_style.name

# Active Claude config dir: the ccc/ccfg/ccg switcher exports CLAUDE_CONFIG_DIR,
# which even this -NoProfile statusline inherits. Read the SESSION's own creds +
# usage from it so the account tag + quota match the RUNNING account, not whichever
# canonical ~/.claude login is current. Falls back to canonical for plain `claude`.
$cfgDir = if ($env:CLAUDE_CONFIG_DIR -and (Test-Path $env:CLAUDE_CONFIG_DIR)) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

# Git status — branch + dirty/ahead/behind markers
# ONE git spawn, not two. `status --porcelain=v1 -b` ALREADY reports the branch on its
# `## ...` header line, so the `rev-parse --abbrev-ref HEAD` that used to gate it was
# pure duplicate work. That matters far more than it looks: a git.exe spawn costs
# 30-160ms on this box (bimodal -- Defender rescans the image whenever it falls out of
# its cache), and this block runs on EVERY render in EVERY open session. Measured
# 2026-08-06 it was the single most expensive avoidable thing in the script.
# Do NOT reintroduce rev-parse "for clarity" -- the branch is already in hand.
$branch = ''
$gitMarks = ''
if ($cwd -and (Test-Path $cwd)) {
    Push-Location $cwd
    $porcelain = & git status --porcelain=v1 -b 2>$null
    if ($porcelain) {
        $headLine = $porcelain | Select-Object -First 1
        # `## <branch>` shapes: "main", "main...origin/main", "main...origin/main [ahead 1]",
        # "No commits yet on main", and detached "HEAD (no branch)" -- which rev-parse
        # --abbrev-ref rendered as a bare "HEAD", so keep that spelling for continuity.
        if     ($headLine -match '^## HEAD \(no branch\)') { $branch = 'HEAD' }
        elseif ($headLine -match '^## (?:No commits yet on )?(.+?)(?:\.\.\.|\s\[|$)') { $branch = $Matches[1] }
        if ($branch) {
            $ahead  = if ($headLine -match 'ahead (\d+)')  { [int]$Matches[1] } else { 0 }
            $behind = if ($headLine -match 'behind (\d+)') { [int]$Matches[1] } else { 0 }
            $dirty  = ($porcelain | Select-Object -Skip 1 | Measure-Object).Count
            if ($dirty  -gt 0) { $gitMarks += '*' }
            if ($ahead  -gt 0) { $gitMarks += "+$ahead" }
            if ($behind -gt 0) { $gitMarks += "-$behind" }
        }
    }
    Pop-Location
}

# 1M context detection — id like "claude-opus-4-7[1m]" (explicit marker, e.g. GLM);
# current-gen Anthropic models default to 1M with NO marker: Fable/Mythos 5, Opus 4.6-4.8,
# Sonnet 4.6+ (incl. Sonnet 5) — legacy Sonnet/Opus 4.5-and-earlier still need the beta/marker.
$is1m  = $modelId -match '\[1m\]|-1m\b|fable|mythos|opus-4-[678]|sonnet-4-6|sonnet-5'
$limit = if ($is1m) { 1000000 } else { 200000 }
$shortModel = $model -replace '\s*\(1M context\)\s*$', '' `
                       -replace '^Opus\s+', 'Op' `
                       -replace '^Sonnet\s+', 'So' `
                       -replace '^Haiku\s+', 'Ha' `
                       -replace '^Fable\s+', 'F' `
                       -replace '^DeepSeek[\s-]*V?4[\s-]*Flash', 'DS4F' `
                       -replace '^glm-5\.2:cloud(\[1m\])?$', 'glm5.2'
$modelLabel = if ($is1m) { "$shortModel 1M" } else { $shortModel }

# Token usage - last assistant message's usage in transcript + session counters
# Counts user prompts (#N) + assistant API calls (LLM calls N) while tracking the last
# usage-bearing line for the live token totals.
#
# INCREMENTAL, not a full re-read. The transcript is append-only and this box writes
# ~0.9 MB/hour of it, so re-reading the whole thing on a 60s timer made this the one
# cost in the script that got WORSE the longer a session ran -- and therefore worst in
# exactly the long sessions where the statusline is watched most. Measured 2026-08-06:
# 163 ms on a 15.6 MB / 7,395-line transcript, 184 ms on a 35.6 MB one, against ~2 ms
# on a fresh session. Everything this block produces is either a RUNNING TOTAL (the
# two counters) or a LAST-WINS value (the token bar, the cache anchor, the TTL kind),
# and both kinds survive being carried forward -- so persist them beside a byte OFFSET
# and parse only the bytes appended since the previous render. Cost becomes
# proportional to one minute of new transcript instead of to the whole session: flat.
#
# REJECTED: scanning BACKWARD to find just the last usage line. It only optimizes the
# cheap half -- the two counters genuinely need every line, so a full forward read
# would still have been paid on every render. Carrying state makes the counters
# incremental as well, which subsumes the backward scan entirely.
$tokens = 0
$newTokens = $null
$promptCount = 0
$llmCount = 0
$lastMainTs = $null
$lastTtlKind = $null
if ($tpath -and (Test-Path $tpath)) {
    # Per-session state file, keyed by session_id (1:1 with the transcript path), so two
    # concurrent sessions can never share one. Contrast the cost tracker's windows.cache,
    # which IS read by every session and therefore needs the atomic tmp+move dance: a
    # single writer means a plain write is enough here. A torn file fails the field-count
    # check below and costs exactly one full rescan.
    $txDir   = Join-Path $env:USERPROFILE '.claude\transcript-cache'
    $txKey   = ([string]$j.session_id) -replace '[^A-Za-z0-9]', ''
    if (-not $txKey) { $txKey = ($tpath -replace '[^A-Za-z0-9]', '') }
    if (-not $txKey) { $txKey = 'default' }
    $txState = Join-Path $txDir "tx-$txKey.state"

    # Carried state: v1 <offset> <prompts> <llm> <inp> <cread> <ccrt> <ttlKind> <ts>,
    # with '-' for an absent value. Nine whitespace-free fields on one line.
    $scanFrom  = 0L
    $haveCarry = $false
    $cInp = 0; $cCread = 0; $cCcrt = 0; $cTs = $null
    # KEEP the cmdlets here (Test-Path / -split / New-Item below). Swapping them for the
    # "obviously cheaper" .NET equivalents -- [IO.File]::Exists, .Split([char]32),
    # [IO.Directory]::Exists/CreateDirectory -- measured 3.2-3.9 ms SLOWER per render on
    # both a 40-line and a 15.6 MB transcript (15 interleaved runs each, 2026-08-06).
    # In a -NoProfile 5.1 process the cmdlets are already loaded, while each new .NET
    # type reference pays resolution; the operator forms are compiled into the AST.
    # Third instance of this trap in this file, after regex-vs-TryParse and
    # ReadLines-vs-Get-Content: in PowerShell the lower-level call is not the faster one.
    try {
        if (Test-Path $txState) {
            $f = ([System.IO.File]::ReadAllText($txState)).Trim() -split '\s+'
            if ($f.Count -eq 9 -and $f[0] -eq 'v1') {
                $scanFrom    = [long]$f[1]
                $promptCount = [int]$f[2]
                $llmCount    = [int]$f[3]
                if ($f[4] -ne '-') { $cInp = [int]$f[4]; $cCread = [int]$f[5]; $cCcrt = [int]$f[6]; $haveCarry = $true }
                if ($f[7] -ne '-') { $lastTtlKind = $f[7] }
                if ($f[8] -ne '-') { $cTs = $f[8] }
            }
        }
    } catch { $scanFrom = 0L; $promptCount = 0; $llmCount = 0; $lastTtlKind = $null; $haveCarry = $false }

    $lastUsage = $null
    $newOffset = 0L
    $newLines  = @()
    try {
        # FileShare::ReadWrite -- the harness holds this file open for append while we
        # read it. Read-only sharing would fail here on every render.
        $fh = [System.IO.File]::Open($tpath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $flen = $fh.Length
            # Two ways a stored offset can be a lie: the file was truncated or rotated
            # (now shorter than the offset), or it was rewritten in place. The first is
            # caught by the length test; the second by requiring the byte just before the
            # offset to still be the newline that ended the last line consumed. Either
            # way the answer is the same -- drop the carried totals and rescan whole,
            # because a wrong baseline would silently poison every later render too.
            if ($scanFrom -gt $flen) { $scanFrom = 0L }
            if ($scanFrom -gt 0) {
                $fh.Position = $scanFrom - 1
                if ($fh.ReadByte() -ne 10) { $scanFrom = 0L }
            }
            if ($scanFrom -eq 0) { $promptCount = 0; $llmCount = 0; $lastTtlKind = $null; $haveCarry = $false }
            $newOffset = $scanFrom
            $want = $flen - $scanFrom
            if ($want -gt 0) {
                $fh.Position = $scanFrom
                $buf = New-Object byte[] $want
                $got = 0
                while ($got -lt $want) {
                    $n = $fh.Read($buf, $got, $want - $got)
                    if ($n -le 0) { break }
                    $got += $n
                }
                # Stop at the LAST newline. Anything after it is a record the harness is
                # still writing: consuming it would parse a half-written line AND advance
                # the offset past a line about to be completed, losing it for good.
                # Cutting on a newline is also what makes reading from a byte offset safe
                # at all -- UTF-8 never places 0x0A inside a multi-byte sequence, so the
                # boundary cannot fall mid-character.
                $cut = -1
                for ($k = $got - 1; $k -ge 0; $k--) { if ($buf[$k] -eq 10) { $cut = $k; break } }
                if ($cut -ge 0) {
                    $newOffset = $scanFrom + $cut + 1
                    # .Split([char]10), NOT -split "`n". PowerShell's -split operator is
                    # REGEX-based even for a one-character literal, and on a whole-file
                    # string that difference is the entire cold-path budget: measured on
                    # this 15.6 MB transcript, -split 113 ms vs String.Split 22 ms. It is
                    # invisible on the hot path (a few KB) and dominates on the cold one.
                    # Same trap family as the cost tracker's regex-vs-TryParse note: the
                    # cheap-looking operator is not always the cheap one -- measure.
                    $newLines = [System.Text.Encoding]::UTF8.GetString($buf, 0, $cut + 1).Split([char]10)
                }
            }
        } finally { $fh.Dispose() }
    } catch {}
    foreach ($line in $newLines) {
        # TRAP: a Task (subagent) COMPLETION record is written on the MAIN chain as a
        # type:user tool_result with isSidechain:FALSE, and it republishes the
        # subagent's entire usage block -- input_tokens, cache_read, and the
        # ephemeral_5m/1h split. It therefore sails straight past the isSidechain
        # gate below and poisons every consumer here: the token bar snaps to the
        # subagent's context, $lastTtlKind flips to '5m' (subagents cache at the
        # 5-minute TTL), and the cache clock re-anchors to the subagent's finish
        # time -- so a perfectly healthy 1h main cache renders "cache DEAD" about 5
        # minutes after ANY subagent returns, mid-session, while work is running.
        # Only an assistant message's own usage counts: toolUseResult is a user-side
        # field, so no genuine assistant line carries it. This also stops $llmCount
        # double-counting -- the subagent's real calls are already counted one by one
        # as sidechain lines, and this record is just their summary.
        if ($line -match '"input_tokens"' -and $line -notmatch '"toolUseResult"') {
            $llmCount++
            # MAIN-CHAIN ONLY for the token bar + the cache clock. A subagent
            # (isSidechain) runs its own prompt with its own prefix, so (a) its
            # usage is not THIS conversation's context -- letting it win made the
            # bar snap to the subagent's smaller total mid-run -- and (b) its API
            # call does NOT refresh this conversation's cached prefix, so it must
            # not reset the TTL. $llmCount still counts EVERY call: that chip
            # means total work done, subagents included.
            if ($line -notmatch '"isSidechain"\s*:\s*true') {
                $lastUsage = $line
                # Which cache TTL the API actually used, straight from the data rather
                # than assumed: usage.cache_creation splits into ephemeral_1h_input_tokens
                # / ephemeral_5m_input_tokens. Most turns are pure cache READS with both
                # at zero and say nothing, so remember the most recent turn that actually
                # WROTE cache. Regex on the raw line on purpose -- only the final
                # $lastUsage line gets fully parsed, and this has to stay cheap.
                # \s* after the colon: the harness writes compact JSON so it has never
                # mattered in the wild, but a pretty-printed line would silently never
                # match and the TTL would stay at its assumed default -- a fail-quiet the
                # rest of this chip is built to avoid.
                if     ($line -match '"ephemeral_1h_input_tokens":\s*[1-9]') { $lastTtlKind = '1h' }
                elseif ($line -match '"ephemeral_5m_input_tokens":\s*[1-9]') { $lastTtlKind = '5m' }
            }
        }
        # Real user turn: type=user, no tool_use_id (excludes tool results),
        # not isMeta (excludes <local-command-caveat> injections), and not
        # the slash-command wrapper or its captured stdout.
        if ($line -match '"type":"user"' `
            -and $line -notmatch '"tool_use_id"' `
            -and $line -notmatch '"isMeta":true' `
            -and $line -notmatch '<command-name>' `
            -and $line -notmatch '<local-command-stdout>') {
            $promptCount++
        }
        # Interrupt: user typed a message while a tool was running. Stored as
        # type=attachment with a queued_command payload (paired with a
        # queue-operation enqueue event; we count the attachment side since
        # that's the message actually delivered to the model).
        if ($line -match '"queued_command"') {
            $promptCount++
        }
    }
    # A render usually appends no main-chain usage line at all (the timer fires between
    # turns), so the last-wins values come from the carried state instead. Parity with
    # the old full scan is exact: when a new line IS present it wins outright, exactly as
    # re-finding it in a full scan did -- including the case where it parses badly and
    # leaves the bar at zero. The carry is consulted ONLY when this render saw no new
    # main-chain usage line, which is the case the full scan never had to consider.
    $inp = 0; $cread = 0; $ccrt = 0
    $haveUsage = $false
    if (-not $lastUsage -and $haveCarry) {
        $inp = $cInp; $cread = $cCread; $ccrt = $cCcrt
        $haveUsage = $true
        $lastMainTs = $cTs
    }
    if ($lastUsage) {
        try {
            $o = $lastUsage | ConvertFrom-Json
            # Cache anchor: wall-clock of the last main-chain API call -- the call
            # that (re)wrote this conversation's prompt cache. Read off the PARSED
            # object rather than regexing the raw line, because nested content can
            # carry its own "timestamp" keys that a regex would match first.
            if ($o.timestamp) { $lastMainTs = [string]$o.timestamp }
            $u = $o.message.usage
            if ($u -and ($u.input_tokens -ne $null)) {
                $inp   = [int]$u.input_tokens
                $cread = [int]$u.cache_read_input_tokens
                $ccrt  = [int]$u.cache_creation_input_tokens
                $haveUsage = $true
            }
        } catch {}
    }
    if ($haveUsage) {
        $tokens = $inp + $cread + $ccrt
        if ($tokens -gt 0) {
            # NEW data on this turn = everything NOT served from cache. That's
            # what moves the bill: a cache WRITE bills at 2x base input on the
            # 1h TTL, versus 0.1x for a read, so these are the expensive tokens.
            # HISTORY: this used to be $cread/$tokens ("what fraction was
            # cached"), which is pinned near 100% in any warm session -- measured
            # over 864 real main-chain turns, 24% rendered exactly "100%" and
            # ~85% fell in the 97-100% band, because median cache_read is ~128K
            # against ~1.5K of new data. It was correct and useless. Do not
            # restore it; the raw new-token count is the number with signal.
            $newTokens = $inp + $ccrt
        }
    }

    # Publish the state this render ends on, for the next one to resume from.
    # $newOffset stays 0 when the transcript holds no complete line yet (or the read
    # failed outright), and nothing is written in that case -- better to rescan a
    # 1-line file next time than to record an offset the scan never actually reached.
    if ($newOffset -gt 0) {
        try {
            if (-not (Test-Path $txDir)) { New-Item -ItemType Directory -Path $txDir -Force | Out-Null }
            $fUse = if ($haveUsage) { '{0} {1} {2}' -f $inp, $cread, $ccrt } else { '- - -' }
            $fTtl = if ($lastTtlKind) { $lastTtlKind } else { '-' }
            $fTs  = if ($lastMainTs)  { $lastMainTs }  else { '-' }
            [System.IO.File]::WriteAllText($txState, ('v1 {0} {1} {2} {3} {4} {5}' -f $newOffset, $promptCount, $llmCount, $fUse, $fTtl, $fTs))
            # One state file per session, so prune on the FULL-RESCAN path -- which every
            # new session hits on its first render, and no hot path ever hits. A session's
            # state is worthless once it ends, and letting these accumulate would repeat
            # the cost tracker's per-PID forerunner (~1700 files, slow enough that Claude
            # Code cancelled the script and the whole line went blank).
            if ($scanFrom -eq 0) {
                $txCutoff = (Get-Date).AddDays(-3)
                foreach ($old in [System.IO.Directory]::GetFiles($txDir, 'tx-*.state')) {
                    if ([System.IO.File]::GetLastWriteTime($old) -lt $txCutoff) {
                        Remove-Item $old -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {}
    }
}

$pct = if ($limit -gt 0) { [math]::Round(($tokens / $limit) * 100, 1) } else { 0 }
if ($pct -gt 100) { $pct = 100 }

# Progress bar (10 cells)
$barLen = 5
$filled = [int][math]::Floor(($pct / 100) * $barLen)
if ($filled -gt $barLen) { $filled = $barLen }
$bar = ([string][char]0x2588) * $filled + ([string][char]0x2591) * ($barLen - $filled)

function Fmt-Tok($n) {
    if     ($n -ge 1000000) { '{0:0.#}M' -f ($n / 1000000.0) }
    elseif ($n -ge 1000)    { '{0:0.#}K' -f ($n / 1000.0) }
    else                    { "$n" }
}
$tokStr = "$(Fmt-Tok $tokens)/$(Fmt-Tok $limit)"

# ANSI
$E = [char]27
$cyan="$E[36m"; $bold="$E[1m"; $yellow="$E[33m"; $green="$E[32m"
$red="$E[31m"; $dim="$E[2m"; $magenta="$E[35m"; $reset="$E[0m"
$orange="$E[38;5;208m"; $maroon="$E[38;5;88m"; $blue="$E[34m"
# $pop = the "run finished" highlight for the trailing duration chip: bold + vivid
# green so WHEN the last run finished jumps out. Swap 46 for another 256-color code to
# retint (e.g. 201 hot-pink, 51 bright-cyan, 226 bright-yellow, 208 orange).
$pop="$E[1m$E[38;5;46m"
# $alarm = "act now" -- bold + BLINK + the most saturated red (256-color 196). Used by
# the prompt-cache chip in its last few minutes, while re-arming is still possible.
# If a terminal renders blink as a solid block, drop the $E[5m.
$alarm="$E[1m$E[5m$E[38;5;196m"
# $tomb = "the prompt cache is already gone". Deliberately NOT blinking: blink means
# "act now", and once the cache has lapsed there is nothing left to save. A filled
# block (near-white on dark maroon) reads as a different KIND of thing from blinking
# red text, so the two states can never be confused at a glance.
$tomb="$E[1m$E[38;5;231m$E[48;5;52m"
$pipe = " $dim|$reset "

# Color the bar by pressure
# 1M model: yellow at 200K (premium pricing tier), red at 800K (capacity)
# 200K model: yellow at 70%, red at 90%
if ($is1m) {
    $barColor = if     ($tokens -ge 800000) { $red }
                elseif ($tokens -ge 600000) { $maroon }
                elseif ($tokens -ge 400000) { $orange }
                elseif ($tokens -ge 200000) { $yellow }
                else                        { $green }
} else {
    $barColor = if ($pct -ge 90) { $red } elseif ($pct -ge 70) { $yellow } else { $green }
}

# Weather -- Open-Meteo, location from the $WEATHER_LAT/$WEATHER_LON CONFIG knobs.
# Served from cache ONLY; the background -RefreshOnly pass refetches it (12-hour max
# age). $weatherCache is defined up top; blank coords simply yield no cached weather.
$weather = $null
try { $weather = (Get-Content $weatherCache -Raw | ConvertFrom-Json).weather } catch {}

$weatherChip   = ''
$forecastChips = @()
if ($weather) {
    $temp = [int][math]::Round([double]$weather.current.temperature_2m)
    $wcode = [int]$weather.current.weather_code
    $wdeg  = [double]$weather.current.wind_direction_10m
    $wmph  = [int][math]::Round([double]$weather.current.wind_speed_10m)

    $glyph = if     ($wcode -eq 0)                          { [char]0x2600 }
             elseif ($wcode -in 1,2,3)                      { [char]0x26C5 }
             elseif ($wcode -in 45,48)                      { [char]::ConvertFromUtf32(0x1F32B) }
             elseif ($wcode -ge 51 -and $wcode -le 67)      { [char]::ConvertFromUtf32(0x1F327) }
             elseif ($wcode -ge 71 -and $wcode -le 77)      { [char]0x2744 }
             elseif ($wcode -ge 80 -and $wcode -le 82)      { [char]::ConvertFromUtf32(0x1F327) }
             elseif ($wcode -ge 95 -and $wcode -le 99)      { [char]0x26C8 }
             # [char]0x00B7, NOT a literal '.' glyph. This file is UTF-8 with NO BOM, and
             # Windows PowerShell 5.1 decodes a BOM-less script using the ANSI codepage --
             # so the two UTF-8 bytes of a middle dot arrived as TWO chars and this branch
             # rendered "A." instead of a dot. It was the only non-ASCII STRING literal in
             # the file (the rest of the non-ASCII is in comments, where it is harmless);
             # every sibling branch above already used the escape. Found 2026-08-06.
             else                                            { [char]0x00B7 }

    $dirs = @('N','NE','E','SE','S','SW','W','NW')
    $compass = $dirs[([int][math]::Round($wdeg / 45.0)) % 8]

    $wColor = if     ($wcode -le 1)                          { $yellow }
              elseif ($wcode -ge 71 -and $wcode -le 77)      { $cyan }
              elseif ($wcode -ge 51 -and $wcode -le 82)      { $blue }
              elseif ($wcode -ge 95)                         { $magenta }
              else                                           { $dim }

    $weatherChip = "$wColor$glyph ${temp}F $compass/${wmph}mph$reset"

    $today = (Get-Date).Date
    $rainAlert = $null
    $windAlert = $null
    for ($i = 1; $i -lt $weather.daily.time.Count; $i++) {
        try { $dt = [datetime]::Parse($weather.daily.time[$i]) } catch { continue }
        $daysOut = ($dt.Date - $today).Days
        $dayName = $dt.ToString('ddd')

        if (-not $rainAlert) {
            $prob = [int]$weather.daily.precipitation_probability_max[$i]
            if ($prob -ge 50) {
                $rainAlert = "${blue}rain $dayName+${daysOut}d ${prob}%$reset"
            }
        }
        if (-not $windAlert) {
            $maxMph = [int][math]::Round([double]$weather.daily.wind_speed_10m_max[$i])
            if ($maxMph -ge 20) {
                $windAlert = "${yellow}wind $dayName+${daysOut}d ${maxMph}mph$reset"
            }
        }
        if ($rainAlert -and $windAlert) { break }
    }
    if ($rainAlert) { $forecastChips += $rainAlert }
    if ($windAlert) { $forecastChips += $windAlert }
}
# Weather + its forecast alerts travel together as one group. They ride the VERSE
# REFERENCE line at the very bottom (see "Verse of the Day"), not row 1 -- row 1 is
# reserved for session state (model, dir, duration, cache countdown), and weather is
# ambient, so it belongs with the other ambient text.
$weatherParts = @()
if ($weatherChip) { $weatherParts += $weatherChip }
foreach ($fc in $forecastChips) { $weatherParts += $fc }

# Verse of the Day -- Bible Gateway (ESV) + YouVersion (NIV; see the fetcher for why ESV
# is no longer reachable there), served from cache ONLY (the
# background -RefreshOnly pass refetches them; 12-hour max age). Read UP HERE, before
# row 1 is assembled, purely so row 1 can know whether a verse line will exist to carry
# the weather. With no verse cached (fresh install, failed fetch) there is no reference
# line to hang it on, so weather falls back to row 1 rather than vanishing.
function Get-VerseCache($cacheFile) {
    if (Test-Path $cacheFile) {
        try {
            $c = Get-Content $cacheFile -Raw | ConvertFrom-Json
            return @{ text = [string]$c.text; ref = [string]$c.ref }
        } catch {}
    }
    return $null
}
# A disabled line is simply absent. Nulling it HERE flows through everything downstream
# for free: $weatherOnVerse below, the divider (drawn only when BOTH exist), and the
# weather's fallback onto row 1 when no reference line gets rendered at all.
$verseBG = if ($VERSE_BIBLEGATEWAY) { Get-VerseCache $verseBGCache } else { $null }
$verseYV = if ($VERSE_YOUVERSION)   { Get-VerseCache $verseYVCache } else { $null }
$weatherOnVerse = [bool]($verseYV -or $verseBG)

# Explicit 4-line grouping — fixed structure regardless of terminal width.
# Row 1: identity (model, dir, duration, cache)  Row 2: progress (branch, bar, tokens)
# Row 3: cost   (duration, cost, cache)   Row 4: quota (account, 5h, 7d)
$row1 = @("$cyan$modelLabel$reset")
if ($dir) { $row1 += "$bold$dir$reset" }
if (-not $weatherOnVerse) { foreach ($wp in $weatherParts) { $row1 += $wp } }

$row2 = @()
if ($branch) {
    $branchStr = if ($gitMarks) { "$branch $gitMarks" } else { $branch }
    $row2 += "$yellow$branchStr$reset"
}
$row2 += "$barColor$bar $pct%$reset"
$row2 += "$barColor$tokStr$reset"

# Gate cost/quota/cache to real Anthropic sessions only. Local models (Ollama) won't
# have an Anthropic model name. The check here is the ONLY gate — don't layer additional
# null checks on top that can kill the block even when _isAnthropic is true.
$isAnthropic = $model -match '^Opus|^Sonnet|^Haiku|^Fable|^Mythos|^claude-' -or
               $modelId -match 'claude-|anthropic-opus|anthropic-sonnet|anthropic-haiku|anthropic-fable'

$row3 = @()

# Last main-chain API call, as local time. This one value anchors BOTH the "@ time"
# stamp and the prompt-cache countdown, so the two can never disagree. Prefer the
# timestamp parsed out of the transcript (the true moment of the API call); fall back
# to the transcript's mtime only when that is unavailable (older/short transcripts).
# Why not mtime outright: a long subagent run keeps bumping mtime while the MAIN
# conversation's cache quietly ages out, so mtime would report "fresh" at exactly the
# moment the cache the countdown is about was expiring.
$lastActivity = $null
if ($lastMainTs) {
    try {
        $lastActivity = ([datetime]::Parse($lastMainTs, [Globalization.CultureInfo]::InvariantCulture,
                                           [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime()
    } catch {}
}
if (-not $lastActivity) {
    $lastActivity = if ($tpath -and (Test-Path $tpath)) { (Get-Item $tpath).LastWriteTime } else { Get-Date }
}

$durPart = $null
$workMs = $j.cost.total_api_duration_ms
if ($workMs -eq $null) { $workMs = $j.cost.total_duration_ms }
if ($workMs -ne $null) {
    $secs = [int]([double]$workMs / 1000)
    $h = [int]([math]::Floor($secs / 3600))
    $m = [int]([math]::Floor(($secs % 3600) / 60))
    $s = [int]($secs % 60)
    $dur = if ($h -gt 0) { '{0}h {1:D2}m' -f $h,$m } `
           elseif ($m -gt 0) { '{0}m {1:D2}s' -f $m,$s } `
           else { '{0}s' -f $s }
    # "@ time" = when the last main-chain API call happened ($lastActivity, above), so it
    # FREEZES while the session sits idle -- a refreshInterval tick re-runs us, but this
    # stays pinned to the last real activity rather than tracking the wall clock.
    # Elapsed ("23m 19s") stays $dim/faded; the stamp is ALWAYS bold lime-green ($pop).
    # It used to escalate to blinking red at 55 min idle; the cache chip below now owns
    # that warning outright, with real precision and a countdown, so keeping the
    # escalation here would just double-blink two things that mean the same thing.
    $endTime = $lastActivity.ToString('h:mm tt')
    $durPart = "$dim$dur$reset $pop@ $endTime$reset"
}

# Prompt-cache countdown -- the money chip. Per session (anchored to THIS session's
# transcript), so other terminals can never move it. Four states, escalating:
#   green  >15m left   fine
#   yellow <=15m left  heads up, wrap up or plan to re-arm
#   RED    <=6m  left  blinking: act now (send anything to refresh the cache)
#   TOMB   expired     solid block, counts UP: too late, resuming pays a full re-cache
# Anthropic-only: a local/Ollama session has no comparable 1h prefix cache to warn
# about. Needs "refreshInterval" in settings.json, else the statusline will not re-run
# while idle to tick the countdown down -- event-driven renders go quiet with no new
# messages. Failure-soft: no network, no extra file reads, no throw.
#
# Renders as ONE chip carrying both cache signals: "cache 55m/+1.5K". The minutes say how
# long the cache still LIVES; the "+N" says how much NEW (non-cached) data the last turn
# had to pay premium for. They are independent, so each keeps its own color and only the
# "/" is dim (same convention as the cost chip). Both sit here, on row 1, so everything
# named "cache" reads in one place instead of straddling two rows.
$cachePart = $null
if ($isAnthropic) {
    $ttlPart = $null
    # Effective TTL: trust the API's own report ($lastTtlKind, read off
    # usage.cache_creation) over the configured default. Under usage overage Anthropic
    # silently drops the cache to a 5-minute TTL -- assuming 60 there would leave the
    # countdown wildly optimistic at exactly the moment cost matters most. Thresholds
    # scale with it, so a 5-min TTL warns proportionally instead of never warning
    # (a fixed 15-min warn band cannot fire inside a 5-min life).
    $effTtl = if ($CACHE_TTL_MIN -le 0) { 0 } elseif ($lastTtlKind -eq '5m') { 5 } else { $CACHE_TTL_MIN }
    $ttlScale = if ($CACHE_TTL_MIN -gt 0) { $effTtl / $CACHE_TTL_MIN } else { 1 }
    # Say WHICH lifetime is in force whenever it is not the configured default. Without
    # this the downgrade is invisible and the chip looks broken: a session idle 18 minutes
    # renders "cache DEAD 13m", which is correct on a 5-minute TTL and impossible on a
    # 60-minute one, so the honest reading is indistinguishable from a miscalculation.
    # CONFIRMED IN THE WILD 2026-08-11: 384 consecutive main-chain writes reported
    # ephemeral_1h, then every write from roughly two minutes later on reported
    # ephemeral_5m -- same model, no subagent record involved. The account had just hit
    # 100% of its 5-hour budget and rolled onto extra-usage credits. Silent, mid-session,
    # and it never announces itself in the transcript: this tag is the only warning.
    $ttlTag = if ($effTtl -gt 0 -and $effTtl -ne $CACHE_TTL_MIN) { "(${effTtl}m)" } else { '' }
    if ($lastActivity -and $effTtl -gt 0) {
        try {
            $minsLeft = $effTtl - ((Get-Date) - $lastActivity).TotalMinutes
            if ($minsLeft -gt 0) {
                # "cache" stays tinted WITH the countdown (not dimmed) so the crit state
                # blinks as a whole word -- dimming the label would soften the one alarm
                # that has to be unmissable.
                $cColor = if     ($minsLeft -le ($CACHE_CRIT_MIN * $ttlScale)) { $alarm }
                          elseif ($minsLeft -le ($CACHE_WARN_MIN * $ttlScale)) { $yellow }
                          else                                                 { $green }
                $ttlPart = "${cColor}cache$ttlTag $([int][math]::Ceiling($minsLeft))m$reset"
            } else {
                # Count UP since expiry: "just lost it" and "gone for hours, do not bother"
                # are different decisions, and only the elapsed number tells them apart.
                $goneM   = [int][math]::Floor(-$minsLeft)
                $goneStr = if ($goneM -ge 60) { '{0}h {1:D2}m' -f [int]($goneM / 60), ($goneM % 60) } else { "${goneM}m" }
                $ttlPart = "$tomb cache$ttlTag DEAD $goneStr $reset"
            }
        } catch {}
    }
    # NEW tokens on the last main-chain turn (uncached input + cache writes) -- the data
    # you actually paid premium for. Green under 10K covers the ordinary turn (measured
    # p90 is ~6.9K); yellow/red mark the genuine outliers, where a big cache write at 2x
    # base input is real money (a 162K-token write on Opus is roughly $5).
    $newPart = $null
    if ($newTokens -ne $null) {
        $nColor = if ($newTokens -ge 50000) { $red } elseif ($newTokens -ge 10000) { $yellow } else { $green }
        $newPart = "$nColor+$(Fmt-Tok $newTokens)$reset"
    }
    # Either half can be absent (countdown disabled via $CACHE_TTL_MIN = 0, or no usage
    # parsed yet). A lone "+N" still needs the "cache" label the countdown would have
    # supplied, so it gets a dim one.
    $cachePart = if     ($ttlPart -and $newPart) { "$ttlPart$dim/$reset$newPart" }
                 elseif ($ttlPart)               { $ttlPart }
                 elseif ($newPart)               { "${dim}cache $reset$newPart" }
                 else                            { $null }
}
if ($isAnthropic -and $j.cost.total_cost_usd -ne $null -and $j.cost.total_cost_usd -gt 0) {
    $costVal = [double]$j.cost.total_cost_usd

    # Four-window cost: s = THIS SESSION's cost / h = 5h / 7d / 30d spend across all
    # sessions, pooled over every account (the canonical cost-tracker dir).
    #
    # total_cost_usd is the harness's PER-SESSION cost. Keep one time series per
    # session — "<epoch> <cumulative>" in ~/.claude\cost-tracker\sess-<id>.series —
    # and compute each window as the sum of POSITIVE deltas across every session's
    # series (one curve per session => summing IS the real cross-session total). A
    # frozen reconstruction file seed.series carries older history.
    #
    # (History: ~2026-06-24 a Claude Code bug briefly made total_cost_usd report a
    # SHARED, per-account cumulative growing into the thousands; the old statusline
    # summed that one shared curve once per PID-keyed file and ballooned 30d to
    # ~$1,000,000. It reverted to the normal per-session value ~2026-06-25 21:1x.
    # seed.series reconstructs that window's real spend. Keying by session_id —
    # directly available, no ~600 ms CIM process-tree walk — is both correct for the
    # normal per-session value and far cheaper than the old per-PID resolution.)
    # Window starts align to:
    #   h   -> five_hour.resets_at   (snap to most recent boundary at/before now)
    #   7d  -> seven_day.resets_at   (same snap, 7-day blocks)
    #   30d -> $anchorDay of the month at 00:00 local (billing renewal)
    # resets_at is read from the ACTIVE account's cache ($cfgDir).
    $sessId = [string]$j.session_id
    if (-not $sessId) { $sessId = ($tpath -replace '[^A-Za-z0-9]', '_') }
    $serKey = ($sessId -replace '[^A-Za-z0-9]', '_')
    if (-not $serKey) { $serKey = 'default' }
    $costDir = Join-Path $env:USERPROFILE '.claude\cost-tracker'
    $fiveHourTotal  = 0.0
    $sevenDayTotal  = 0.0
    $thirtyDayTotal = 0.0
    if ($COST_WINDOWS) {
        try {
            if (-not (Test-Path $costDir)) {
                New-Item -ItemType Directory -Path $costDir -Force | Out-Null
            }
            $now        = Get-Date
            $nowEpoch   = [long]([DateTimeOffset]$now).ToUnixTimeSeconds()
            $pruneEpoch = $nowEpoch - (32 * 86400)   # > widest displayed window (30d) + margin

            # Append this session's cumulative to its series, throttled to ~1 sample
            # / 10 min, pruning samples older than 32 days. Most renders only read the
            # last line; the file is rewritten only when adding a sample.
            $myseries  = Join-Path $costDir "sess-$serKey.series"
            $winCache  = Join-Path $costDir 'windows.cache'
            $lastEpoch = 0
            # This session's last cumulative ALREADY ON DISK. Needed because the shared
            # aggregate below covers only on-disk samples, so this session's spend since
            # its last write has to be added back separately. Kept as a second, separate
            # -match so the throttle above behaves exactly as before if the second field
            # is ever missing or malformed.
            $myLastCm  = 0.0
            $myHasCm   = $false
            if (Test-Path $myseries) {
                $tail = Get-Content $myseries -Tail 1
                if ($tail -match '^(\d+)\s') { $lastEpoch = [long]$Matches[1] }
                if ($tail -match '^\d+\s+([0-9.]+)') { $myLastCm = [double]$Matches[1]; $myHasCm = $true }
            }
            if (($nowEpoch - $lastEpoch) -ge 600) {
                # @() must wrap the WHOLE if-expression: a single-element pipeline
                # result otherwise unwraps to a scalar string, so $keep += would
                # string-concatenate every sample onto one line (corrupting the
                # series — broke -Tail 1 throttling and the window parser).
                $keep = @(if (Test-Path $myseries) {
                    Get-Content $myseries | Where-Object { $_ -match '^(\d+)\s' -and [long]$Matches[1] -ge $pruneEpoch }
                } else { @() })
                $keep += ('{0} {1:R}' -f $nowEpoch, $costVal)
                Set-Content -Path $myseries -Value $keep -Encoding ASCII
                # A new on-disk sample just landed, so any shared aggregate computed before
                # now is short by exactly that delta. Drop it rather than serve a stale sum;
                # the next render recomputes. Appends are throttled to ~1/10min per session,
                # so this invalidation is rare.
                Remove-Item $winCache -Force -ErrorAction SilentlyContinue
                $myLastCm = [double]$costVal   # what we just wrote IS the current value
                $myHasCm  = $true
            }

            # Window starts. Each boundary recurs on a fixed grid; snap to the most
            # recent one at/before now so even a stale resets_at anchor yields the
            # CURRENT window instead of reaching back a whole extra block.
            $winStart5h = $now.AddHours(-5)
            $winStart7d = $now.AddDays(-7)
            try {
                $uc = Get-Content (Join-Path $cfgDir 'usage-exact.json') -Raw | ConvertFrom-Json
                if ($uc.five_hour.resets_at) {
                    # NB: do not name these $reset — that's the ANSI reset escape ($E[0m).
                    $resetAt5h  = [datetime]::Parse($uc.five_hour.resets_at)
                    $blocks5h   = [math]::Floor((($now - $resetAt5h).TotalHours) / 5.0)
                    $winStart5h = $resetAt5h.AddHours(5 * $blocks5h)
                }
                if ($uc.seven_day.resets_at) {
                    $resetAt7d  = [datetime]::Parse($uc.seven_day.resets_at)
                    $blocks7d   = [math]::Floor((($now - $resetAt7d).TotalDays) / 7.0)
                    $winStart7d = $resetAt7d.AddDays(7 * $blocks7d)
                }
            } catch {}

            # 30d billing window: most recent $anchorDay at 00:00 local, clamped to
            # the month length so short months never overflow. The 1..31 clamp is on
            # the CONFIG value itself: Get-Date -Day 0 throws, and this whole block is
            # inside a swallowing try, so a bad knob would silently zero every window.
            $anchorDay = [math]::Max(1, [math]::Min(31, [int]$BILLING_ANCHOR_DAY))
            $aNow = [math]::Min($anchorDay, [datetime]::DaysInMonth($now.Year, $now.Month))
            if ($now.Day -ge $aNow) {
                $winStart30d = Get-Date -Year $now.Year -Month $now.Month -Day $aNow -Hour 0 -Minute 0 -Second 0
            } else {
                $prev  = $now.AddMonths(-1)
                $aPrev = [math]::Min($anchorDay, [datetime]::DaysInMonth($prev.Year, $prev.Month))
                $winStart30d = Get-Date -Year $prev.Year -Month $prev.Month -Day $aPrev -Hour 0 -Minute 0 -Second 0
            }
            $e5h  = [long]([DateTimeOffset]$winStart5h).ToUnixTimeSeconds()
            $e7d  = [long]([DateTimeOffset]$winStart7d).ToUnixTimeSeconds()
            $e30d = [long]([DateTimeOffset]$winStart30d).ToUnixTimeSeconds()

            # Sum each window across every terminal's series:
            #   spend = (latest cumulative) - (cumulative at/just-before the start).
            # No sample at/before the start => the terminal began inside the window,
            # so its baseline is its first sample. Negatives (a counter reset) clamp
            # to 0. This terminal uses its live value; others use their last sample.
            # SHARED AGGREGATE. Every open session was independently summing the SAME ~610
            # files to the SAME answer once a minute -- N sessions paying N times over for
            # one result. The on-disk portion is session-independent, so compute it once and
            # publish it here; the only session-specific part is this session's live delta,
            # which is added after the loop.
            # Reused ONLY when all three window boundaries match. They snap to a fixed grid
            # and hold for hours, but the no-resets_at fallback slides continuously, and a
            # sum taken against a different boundary is simply the wrong number -- so that
            # degraded case misses every time and recomputes: correct-but-slow, never
            # fast-but-wrong.
            $COST_CACHE_TTL_SEC = 60
            $sum5h = $null; $sum7d = 0.0; $sum30d = 0.0
            try {
                if (Test-Path $winCache) {
                    $wc = ([System.IO.File]::ReadAllText($winCache)).Trim() -split '\s+'
                    if ($wc.Count -eq 7 -and
                        [long]$wc[0] -le $nowEpoch -and
                        [long]$wc[0] -ge ($nowEpoch - $COST_CACHE_TTL_SEC) -and
                        [long]$wc[1] -eq $e5h -and [long]$wc[2] -eq $e7d -and [long]$wc[3] -eq $e30d) {
                        $sum5h = [double]$wc[4]; $sum7d = [double]$wc[5]; $sum30d = [double]$wc[6]
                    }
                }
            } catch { $sum5h = $null }
            $cacheHit = ($null -ne $sum5h)
            if (-not $cacheHit) { $sum5h = 0.0; $sum7d = 0.0; $sum30d = 0.0 }
            $myBase = "sess-$serKey"
            # On a cache HIT this is empty, so the scan below is skipped by an empty
            # collection rather than by another nesting level -- the scan keeps its shape,
            # and pruning rides along with the recompute (~1/min) exactly as before.
            # [IO.Directory]::GetFiles over Get-ChildItem: returns bare path strings instead
            # of constructing 600+ FileInfo objects, and nothing below needs FileInfo.
            $scanFiles = if ($cacheHit) { @() } else { [System.IO.Directory]::GetFiles($costDir, '*.series') }
            foreach ($sfPath in $scanFiles) {
                $sfBase = [System.IO.Path]::GetFileNameWithoutExtension($sfPath)
                # STREAMING single pass -- no ArrayLists, no per-line regex. The previous
                # shape built two ArrayLists per file, copied BOTH with .ToArray(), then
                # walked the copies; across ~600 files that allocation churn plus a regex
                # per line was the 2nd-costliest thing in the script (290-353ms measured
                # 2026-08-06). Deltas accumulate into locals and are only committed to the
                # running totals AFTER the prune test, which is all the two-pass shape was
                # actually buying. Semantics are unchanged: positive deltas only, attributed
                # to a window by the LATER sample's epoch.
                $n = 0; $lastEp = 0L; $prevCm = 0.0
                $a5 = 0.0; $a7 = 0.0; $a30 = 0.0
                try {
                    # KEEP THE REGEX. Measured over the real 610-file / 7,167-line dir:
                    #   streaming + regex            39.9 ms   <-- this
                    #   streaming + Split + -as      55.5 ms
                    #   regex + ArrayList (old)     206.7 ms
                    #   Substring + TryParse([ref]) 319.7 ms   <-- 1.5x WORSE than the old code
                    # PowerShell's -match is a cached compiled regex and is cheap; passing
                    # [ref] to a .NET TryParse is NOT -- every call marshals through a
                    # PSReference. The ArrayLists were the cost here, never the regex.
                    foreach ($ln in [System.IO.File]::ReadAllLines($sfPath)) {
                        if ($ln -match '^(\d+)\s+([0-9.]+)') {
                            $ep = [long]$Matches[1]; $cm = [double]$Matches[2]
                            if ($n -gt 0) {
                                $d = $cm - $prevCm
                                if ($d -gt 0) {
                                    if ($ep -gt $e5h)  { $a5  += $d }
                                    if ($ep -gt $e7d)  { $a7  += $d }
                                    if ($ep -gt $e30d) { $a30 += $d }
                                }
                            }
                            $n++; $prevCm = $cm; $lastEp = $ep
                        }
                    }
                } catch { continue }
                if ($n -eq 0) { continue }
                # Keep the directory bounded by pruning files that can no longer affect
                # any window — they otherwise pile up one-per-session (the per-PID
                # forerunner reached ~1700 files, slow enough to blank the line):
                #   - newest sample past the widest (30d) window, or
                #   - a lone sample from a finished session (baseline == latest => $0).
                # Skip the current session's own file; give a just-started session 1200s
                # (2x the 600s throttle) before its single-sample file is treated done.
                # seed.series (last sample frozen at reconstruction) self-cleans at 32d.
                if (($sfBase -ne $myBase) -and (
                        $lastEp -lt $pruneEpoch -or
                        ($n -le 1 -and $lastEp -lt ($nowEpoch - 1200)))) {
                    Remove-Item $sfPath -Force -ErrorAction SilentlyContinue
                    continue
                }
                # Per-window spend = sum of POSITIVE deltas between consecutive samples
                # whose later sample falls in the window (accumulated in the pass above).
                # For a clean monotonic series this equals (latest - cumulative at the
                # window start). Clamping each delta at 0 tolerates a cumulative DROP (a
                # billing/account reset, or a legacy recycled-PID file) by treating the
                # lower run as a fresh baseline instead of letting it undercount.
                # NOTE: this session's live delta is deliberately NOT added in here any
                # more. It is session-specific, and this total is published for EVERY
                # session to read -- baking one session's costVal into it would corrupt
                # the figure every other session displays. It is added after the loop.
                # Commit only now: a pruned file must contribute nothing, which is the one
                # thing the old collect-then-walk ordering was really enforcing.
                $sum5h += $a5; $sum7d += $a7; $sum30d += $a30
            }
            # Publish the on-disk aggregate for every other session to read. Temp file plus
            # atomic overwrite-move, so a concurrent reader sees either the whole old value
            # or the whole new one and never a half-written line. Two sessions racing to
            # recompute derive the same answer, so losing that race costs nothing.
            if (-not $cacheHit) {
                $tmpWc = "$winCache.$PID.tmp"
                try {
                    [System.IO.File]::WriteAllText($tmpWc, ('{0} {1} {2} {3} {4:R} {5:R} {6:R}' -f $nowEpoch, $e5h, $e7d, $e30d, $sum5h, $sum7d, $sum30d))
                    # Move-Item -Force, NOT [IO.File]::Move($s,$d,$true). THIS SCRIPT RUNS
                    # UNDER WINDOWS POWERSHELL 5.1 (see the statusLine command in
                    # settings.json: "powershell -NoProfile ... -File"), and .NET Framework
                    # has no 3-argument Move overload -- only pwsh 7 does. The 3-arg form
                    # threw MethodException on every render, the catch below swallowed it,
                    # the cache was never created, and a 100-byte .tmp leaked into this
                    # directory each minute. Test statusline changes with `powershell`, not
                    # `pwsh`; a pwsh-only API fails silently and looks like a cache miss.
                    Move-Item -LiteralPath $tmpWc -Destination $winCache -Force -ErrorAction Stop
                } catch {
                } finally {
                    # Never orphan the temp, whatever went wrong above.
                    if (Test-Path $tmpWc) { Remove-Item $tmpWc -Force -ErrorAction SilentlyContinue }
                }
                # Sweep any temps stranded by an earlier failure (only on the ~1/min
                # recompute path, so this costs nothing on the hot path).
                foreach ($stale in [System.IO.Directory]::GetFiles($costDir, 'windows.cache.*.tmp')) {
                    Remove-Item $stale -Force -ErrorAction SilentlyContinue
                }
            }
            # This session's own live delta -- the part that is NOT shareable: spend since
            # its last on-disk sample. Same clamp-at-zero rule as every other delta.
            # Guarded by $myHasCm so a missing or unparseable series file contributes
            # nothing, rather than counting this session's whole cumulative as fresh spend.
            if ($myHasCm) {
                $dLive = [double]$costVal - $myLastCm
                if ($dLive -gt 0) {
                    if ($nowEpoch -gt $e5h)  { $sum5h  += $dLive }
                    if ($nowEpoch -gt $e7d)  { $sum7d  += $dLive }
                    if ($nowEpoch -gt $e30d) { $sum30d += $dLive }
                }
            }
            $fiveHourTotal  = $sum5h
            $sevenDayTotal  = $sum7d
            $thirtyDayTotal = $sum30d
        } catch {}
    }

    # Per-window color, escalating thresholds (green -> yellow -> red).
    $cS  = if ($costVal -ge 5)         { $red } elseif ($costVal -ge 1)         { $yellow } else { $green }
    $cH  = if ($fiveHourTotal -ge 20)  { $red } elseif ($fiveHourTotal -ge 5)   { $yellow } else { $green }
    $c7  = if ($sevenDayTotal -ge 75)  { $red } elseif ($sevenDayTotal -ge 25)  { $yellow } else { $green }
    $c30 = if ($thirtyDayTotal -ge 300){ $red } elseif ($thirtyDayTotal -ge 150){ $yellow } else { $green }
    $vS  = '{0:N2}' -f $costVal
    $vH  = '{0:N2}' -f $fiveHourTotal
    $v7  = '{0:N2}' -f $sevenDayTotal
    $v30 = '{0:N2}' -f $thirtyDayTotal
    # s$0.00/h$2.33/7d$23.33/30d$200.02 — labels + slashes dim, amounts colored.
    # With $COST_WINDOWS off the three window figures are all 0.00 and would read as
    # real zeros, so emit the session figure alone rather than a row of empty windows.
    if ($COST_WINDOWS) {
        $row3 += "${dim}s$reset$cS`$$vS$reset${dim}/h$reset$cH`$$vH$reset${dim}/7d$reset$c7`$$v7$reset${dim}/30d$reset$c30`$$v30$reset"
    } else {
        $row3 += "$cS`$$vS$reset"
    }
}
# (Cache-hit % used to be emitted here, on row 2. It now lives in the row-1 "cache"
# chip -- see $cachePart above -- so both cache signals read as one "cache 55m/100%".)
# (Prompt count "#N" used to sit here on row 2. It moved to the bottom row, immediately
# left of "LLM calls N" -- the two are the same kind of counter, so they read together as
# "Prompts #6 | LLM calls 186": turns you took vs API calls that cost.)
# Subscription usage (5h + 7d + scoped caps) via undocumented OAuth endpoint -- read
# from cache ONLY here; the background -RefreshOnly pass refetches it (5-min max age,
# rate-limit-aware). $usageCache / $credPath are defined up top.

$partsBottom = @()
if ($isAnthropic -and (Test-Path $usageCache)) {
    try {
        $u = Get-Content $usageCache -Raw | ConvertFrom-Json
        if ($u._email) {
            # Profile-folder match wins (distinguishes accounts sharing a domain);
            # else email-domain suffix; else the email's username.
            $profLeaf = if ($env:CLAUDE_CONFIG_DIR) { Split-Path -Leaf $env:CLAUDE_CONFIG_DIR } else { '.claude' }
            $tag = $PROFILE_TAGS[$profLeaf]
            if (-not $tag) {
                foreach ($dom in $ACCOUNT_TAGS.Keys) {
                    if ($u._email -match ([regex]::Escape($dom) + '$')) { $tag = $ACCOUNT_TAGS[$dom]; break }
                }
            }
            if (-not $tag) { $tag = ($u._email -split '@')[0] }
            $partsBottom += "$magenta$tag$reset"
        }
        if ($u.five_hour -and $u.five_hour.utilization -ne $null) {
            $bp = [int]$u.five_hour.utilization
            $bc = if ($bp -ge 80) { $red } elseif ($bp -ge 50) { $yellow } else { $green }
            $rt = ''
            if ($u.five_hour.resets_at) {
                try { $rt = ([datetime]::Parse($u.five_hour.resets_at)).ToString('h:mm tt') } catch {}
            }
            $seg = "${bc}5h $bp%$reset"
            if ($rt) { $seg += "$dim $([char]0x21BB) $rt$reset" }
            $partsBottom += $seg
        }
        if ($u.seven_day -and $u.seven_day.utilization -ne $null) {
            $wp = [int]$u.seven_day.utilization
            $wc = if ($wp -ge 80) { $red } elseif ($wp -ge 50) { $yellow } else { $green }
            $wrt = ''
            if ($u.seven_day.resets_at) {
                try {
                    $wdt = [datetime]::Parse($u.seven_day.resets_at)
                    $days = [int][math]::Ceiling(($wdt - (Get-Date)).TotalDays)
                    if ($days -lt 1) { $days = 1 }
                    $wrt = $wdt.ToString('ddd h:mm tt') + " (${days}d)"
                } catch {}
            }
            $wseg = "${wc}7d $wp%$reset"
            if ($wrt) { $wseg += "$dim $([char]0x21BB) $wrt$reset" }
            $partsBottom += $wseg
        }
        # Model-scoped weekly limits (e.g. Fable) live ONLY in the limits[] array —
        # there is NO top-level utilization key for them like five_hour/seven_day. Surface
        # one lean chip per scoped model after 7d — 2-letter label (Fable->Fa) + %, same colors.
        foreach ($lim in @($u.limits | Where-Object { $_.kind -eq 'weekly_scoped' -and $_.scope.model.display_name })) {
            if ($lim.percent -eq $null) { continue }
            $mp = [int]$lim.percent
            $mc = if ($mp -ge 80) { $red } elseif ($mp -ge 50) { $yellow } else { $green }
            $dn = [string]$lim.scope.model.display_name
            $mlabel = if ($dn.Length -ge 2) { $dn.Substring(0, 2) } else { $dn }
            $partsBottom += "$mc$mlabel $mp%$reset"
        }
    } catch {}
}

if ($style -and $style -ne 'default') { $row3 += "$dim$style$reset" }

$row2 = (($row2 + $row3) -join $pipe)
$row3 = $null

# One counter chip: prompts you sent -> API calls they turned into. The arrow carries the
# relationship that two separate chips ("Prompts #7 | LLM calls 250") left implicit, and
# the gap between the numbers IS the signal -- it is the subagent + tool-loop work each
# turn spawned. Dim: reference, not something to act on.
if ($promptCount -gt 0 -or $llmCount -gt 0) {
    $partsBottom += "${dim}#$promptCount$([char]0x2192)$llmCount calls$reset"
}
# Duration ("how long + when the last run finished") trails the TOP row, after weather,
# with the prompt-cache countdown last so the urgent chip sits at the end of the row.
if ($durPart)   { $row1 += $durPart }
if ($cachePart) { $row1 += $cachePart }

foreach ($row in @($row1, $row2, $row3, $partsBottom)) {
    if ($row -and $row.Count -gt 0) { Write-Output ($row -join $pipe) }
}

# Second line — context warning only (harness already shows bypass mode)
if ($pct -ge 90) { Write-Output "$red! context $pct%$reset" }

# Verse of the Day output. The verses themselves were read UP TOP (before row 1) so row
# 1 could tell whether a reference line would exist to carry the weather chips.
$termWidth = try { [Console]::WindowWidth } catch { 160 }
if (-not $termWidth -or $termWidth -le 0) { $termWidth = 160 }
$wrapAt  = [math]::Max(60, [int][math]::Floor($termWidth / 2))
$palette = @(52, 94, 95, 130, 131, 136, 137, 138, 143, 180)
$rnd     = New-Object System.Random

function Format-Verse {
    # $suffix is appended to the REFERENCE line (the last line) -- that is where the
    # weather chips ride, so the bottom line reads "<ref> | <weather> | <forecast>".
    param($verse, $wrapAt, $rnd, $palette, $E, $reset, $magenta, $suffix)
    $words = $verse.text -split '\s+' | Where-Object { $_ }
    $lines = @()
    $cur = ''
    foreach ($w in $words) {
        if ($cur.Length -eq 0) {
            $cur = $w
        } elseif (($cur.Length + 1 + $w.Length) -le $wrapAt) {
            $cur = "$cur $w"
        } else {
            $lines += $cur
            $cur = $w
        }
    }
    if ($cur) { $lines += $cur }

    $output = @()
    foreach ($line in $lines) {
        $colored = @()
        foreach ($w in ($line -split '\s+' | Where-Object { $_ })) {
            if ($w -cmatch '^(God|Jesus|LORD|Lord)([^A-Za-z].*)?$') {
                $colored += "$E[31m$w$reset"
            } else {
                $c = $palette[$rnd.Next(0, $palette.Length)]
                $colored += "$E[38;5;${c}m$w$reset"
            }
        }
        $output += ($colored -join ' ')
    }
    $refLine = "$magenta$($verse.ref)$reset"
    if ($suffix) { $refLine += $suffix }
    $output += $refLine
    return $output
}

# Weather rides the FIRST reference line rendered -- YouVersion when present, else Bible
# Gateway. Only one of them carries it; whichever verse comes second gets a bare ref.
$wSuffix = if ($weatherOnVerse -and $weatherParts.Count -gt 0) { $pipe + ($weatherParts -join $pipe) } else { '' }
if ($verseYV) {
    foreach ($l in (Format-Verse $verseYV $wrapAt $rnd $palette $E $reset $magenta $wSuffix)) { Write-Output $l }
    $wSuffix = ''
}
if ($verseBG -and $verseYV) {
    $div = ([string][char]0x2500) * $wrapAt
    Write-Output "$dim$div$reset"
}
if ($verseBG) {
    foreach ($l in (Format-Verse $verseBG $wrapAt $rnd $palette $E $reset $magenta $wSuffix)) { Write-Output $l }
}
