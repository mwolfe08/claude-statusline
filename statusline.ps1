# claude-statusline — a rich PowerShell status bar for Claude Code
# https://github.com/mwolfe08/claude-statusline
#
# Configure the variables below, then point Claude Code at this script:
#   Settings > statusline > command: "powershell -File C:/path/to/statusline.ps1"

# ─── CONFIG ─────────────────────────────────────────────────────────────────────
# Weather: set your coordinates (https://open-meteo.com) or leave empty to disable
$WEATHER_LAT  = ''   # e.g. '40.7128'
$WEATHER_LON  = ''   # e.g. '-74.0060'

# Account tags: map email domain suffixes to short labels shown in the status bar.
# The script reads the logged-in account email from the Anthropic OAuth cache.
$ACCOUNT_TAGS = @{
    # 'example.com' = 'work'
    # 'gmail.com'   = 'personal'
}
# ────────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

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

# Git status — branch + dirty/ahead/behind markers
$branch = ''
$gitMarks = ''
if ($cwd -and (Test-Path $cwd)) {
    Push-Location $cwd
    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
    if ($branch) {
        $porcelain = & git status --porcelain=v1 -b 2>$null
        if ($porcelain) {
            $headLine = $porcelain | Select-Object -First 1
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

# 1M context detection — id like "claude-opus-4-7[1m]"
$is1m  = $modelId -match '\[1m\]|-1m\b'
$limit = if ($is1m) { 1000000 } else { 200000 }
$shortModel = $model -replace '\s*\(1M context\)\s*$', '' `
                       -replace '^Opus\s+', 'Op' `
                       -replace '^Sonnet\s+', 'So' `
                       -replace '^Haiku\s+', 'Ha'
$modelLabel = if ($is1m) { "$shortModel 1M" } else { $shortModel }

# Token usage — last assistant message's usage in transcript + session counters
$tokens = 0
$cacheHitPct = $null
$promptCount = 0
$llmCount = 0
if ($tpath -and (Test-Path $tpath)) {
    $lines = Get-Content $tpath
    $lastUsage = $null
    foreach ($line in $lines) {
        if ($line -match '"input_tokens"') {
            $llmCount++
            $lastUsage = $line
        }
        if ($line -match '"type":"user"' `
            -and $line -notmatch '"tool_use_id"' `
            -and $line -notmatch '"isMeta":true' `
            -and $line -notmatch '<command-name>' `
            -and $line -notmatch '<local-command-stdout>') {
            $promptCount++
        }
        if ($line -match '"queued_command"') {
            $promptCount++
        }
    }
    if ($lastUsage) {
        try {
            $o = $lastUsage | ConvertFrom-Json
            $u = $o.message.usage
            if ($u -and ($u.input_tokens -ne $null)) {
                $inp   = [int]$u.input_tokens
                $cread = [int]$u.cache_read_input_tokens
                $ccrt  = [int]$u.cache_creation_input_tokens
                $tokens = $inp + $cread + $ccrt
                if ($tokens -gt 0) {
                    $cacheHitPct = [math]::Round(($cread / $tokens) * 100, 0)
                }
            }
        } catch {}
    }
}

$pct = if ($limit -gt 0) { [math]::Round(($tokens / $limit) * 100, 1) } else { 0 }
if ($pct -gt 100) { $pct = 100 }

# Progress bar (5 cells)
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
$pipe = " $dim|$reset "

# Color the bar by context pressure
if ($is1m) {
    $barColor = if     ($tokens -ge 800000) { $red }
                elseif ($tokens -ge 600000) { $maroon }
                elseif ($tokens -ge 400000) { $orange }
                elseif ($tokens -ge 200000) { $yellow }
                else                        { $green }
} else {
    $barColor = if ($pct -ge 90) { $red } elseif ($pct -ge 70) { $yellow } else { $green }
}

# Weather via Open-Meteo (free, no API key). 30-min cache; stale-on-failure fallback.
$weatherCache  = Join-Path $env:USERPROFILE '.claude\weather-cache.json'
$weatherMaxAge = 1800
$weather = $null
$weatherChip   = ''
$forecastChips = @()

if ($WEATHER_LAT -and $WEATHER_LON) {
    $weatherAge = if (Test-Path $weatherCache) {
        ((Get-Date) - (Get-Item $weatherCache).LastWriteTime).TotalSeconds
    } else { [double]::MaxValue }

    if ($weatherAge -gt $weatherMaxAge) {
        try {
            $wUrl = "https://api.open-meteo.com/v1/forecast?latitude=$WEATHER_LAT&longitude=$WEATHER_LON&current=temperature_2m,weather_code,wind_speed_10m,wind_direction_10m&daily=weather_code,precipitation_sum,wind_speed_10m_max,precipitation_probability_max&temperature_unit=fahrenheit&wind_speed_unit=mph&timezone=auto&forecast_days=16"
            $weather = Invoke-RestMethod -Uri $wUrl -TimeoutSec 5
            @{ fetched_at = (Get-Date).ToString('o'); weather = $weather } |
                ConvertTo-Json -Depth 10 | Set-Content -Path $weatherCache -Encoding UTF8
        } catch {
            if (Test-Path $weatherCache) {
                try { $weather = (Get-Content $weatherCache -Raw | ConvertFrom-Json).weather } catch {}
            }
        }
    } else {
        try { $weather = (Get-Content $weatherCache -Raw | ConvertFrom-Json).weather } catch {}
    }

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
                 else                                            { '·' }

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
}

# Row layout: Row 1 = identity, Row 2 = progress + cost, Row 3 = quota
$row1 = @("$cyan$modelLabel$reset")
if ($dir) { $row1 += "$bold$dir$reset" }
if ($weatherChip) { $row1 += $weatherChip }
foreach ($fc in $forecastChips) { $row1 += $fc }

$row2 = @()
if ($branch) {
    $branchStr = if ($gitMarks) { "$branch $gitMarks" } else { $branch }
    $row2 += "$yellow$branchStr$reset"
}
$row2 += "$barColor$bar $pct%$reset"
$row2 += "$barColor$tokStr$reset"

$row3 = @()
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
    $endTime = (Get-Date).ToString('HHmm')
    $durPart = "$dim$dur @ $endTime$reset"
}
if ($j.cost.total_cost_usd -ne $null) {
    $costVal = [double]$j.cost.total_cost_usd
    $costColor = if ($costVal -ge 5)   { $red }
                 elseif ($costVal -ge 1) { $yellow }
                 else                    { $green }
    $costStr = '{0:N2}' -f $costVal
    $row3 += "$costColor`$$costStr$reset"
}
if ($cacheHitPct -ne $null) {
    $cacheColor = if ($cacheHitPct -ge 80) { $green } elseif ($cacheHitPct -ge 50) { $yellow } else { $red }
    $row3 += "${cacheColor}cache $cacheHitPct%$reset"
}
if ($promptCount -gt 0) { $row3 += "$dim#$promptCount$reset" }

# Subscription usage (5h + 7d quotas) via Anthropic OAuth endpoint. 5-min cache.
$usageCache = Join-Path $env:USERPROFILE '.claude\usage-exact.json'
$credPath   = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$refreshSec = 300

$cacheAge = if (Test-Path $usageCache) {
    ((Get-Date) - (Get-Item $usageCache).LastWriteTime).TotalSeconds
} else { [double]::MaxValue }

if ($cacheAge -gt $refreshSec -and (Test-Path $credPath)) {
    $lockFile = Join-Path $env:TEMP 'claude-usage-refresh.lock'
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'Write', 'None')
        $tok = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
        if ($tok) {
            $h = @{ Authorization = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20' }
            $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -TimeoutSec 4
            $email = ''
            try {
                $prof = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/profile' -Headers $h -TimeoutSec 4
                $email = [string]$prof.account.email
            } catch {}
            $resp | Add-Member -NotePropertyName '_email' -NotePropertyValue $email -Force
            $resp | ConvertTo-Json -Depth 6 | Set-Content -Path $usageCache -Encoding UTF8
        }
    } catch {}
    finally { if ($fs) { $fs.Close() } }
}

$partsBottom = @()
if (Test-Path $usageCache) {
    try {
        $u = Get-Content $usageCache -Raw | ConvertFrom-Json
        if ($u._email -and $ACCOUNT_TAGS.Count -gt 0) {
            $tag = $null
            foreach ($domain in $ACCOUNT_TAGS.Keys) {
                if ($u._email -match [regex]::Escape($domain) + '$') {
                    $tag = $ACCOUNT_TAGS[$domain]
                    break
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
                try { $rt = ([datetime]::Parse($u.five_hour.resets_at)).ToString('HHmm') } catch {}
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
                    $wrt = $wdt.ToString('ddd HHmm') + " (${days}d)"
                } catch {}
            }
            $wseg = "${wc}7d $wp%$reset"
            if ($wrt) { $wseg += "$dim $([char]0x21BB) $wrt$reset" }
            $partsBottom += $wseg
        }
    } catch {}
}

if ($style -and $style -ne 'default') { $row3 += "$dim$style$reset" }

if ($durPart) { $row3 += $durPart }
$row2 = (($row2 + $row3) -join $pipe)
$row3 = $null

if ($llmCount -gt 0) { $partsBottom += "${dim}LLM calls $llmCount$reset" }

foreach ($row in @($row1, $row2, $row3, $partsBottom)) {
    if ($row -and $row.Count -gt 0) { Write-Output ($row -join $pipe) }
}

if ($pct -ge 90) { Write-Output "$red! context $pct%$reset" }

# Verse of the Day — Bible Gateway + YouVersion (both ESV). 12-hour cache; stale-on-failure.
# Comment out or remove this section if you don't want scripture verses in your status bar.
function Get-CachedVerse {
    param($cacheFile, $maxAgeSec, $fetcher)
    $age = if (Test-Path $cacheFile) {
        ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalSeconds
    } else { [double]::MaxValue }
    if ($age -gt $maxAgeSec) {
        try {
            $fresh = & $fetcher
            if ($fresh -and $fresh.text -and $fresh.ref) {
                @{ fetched_at = (Get-Date).ToString('o'); text = $fresh.text; ref = $fresh.ref } |
                    ConvertTo-Json | Set-Content -Path $cacheFile -Encoding UTF8
                return $fresh
            }
        } catch {}
    }
    if (Test-Path $cacheFile) {
        try {
            $c = Get-Content $cacheFile -Raw | ConvertFrom-Json
            return @{ text = [string]$c.text; ref = [string]$c.ref }
        } catch {}
    }
    return $null
}

$verseBG = Get-CachedVerse (Join-Path $env:USERPROFILE '.claude\verse-cache.json') 43200 {
    $r = Invoke-RestMethod -Uri 'https://www.biblegateway.com/votd/get/?format=json&version=ESV' -TimeoutSec 6
    $t = [System.Net.WebUtility]::HtmlDecode([string]$r.votd.text)
    $t = ($t -replace '<[^>]+>','').Trim()
    $t = ($t -replace '^[\s"“”]+', '' -replace '[\s"“”]+$', '').Trim()
    $t = [char]0x201C + $t + [char]0x201D
    @{ text = $t; ref = "$([string]$r.votd.reference) ESV, Bible Gateway" }
}

$verseYV = Get-CachedVerse (Join-Path $env:USERPROFILE '.claude\verse-cache-yv.json') 43200 {
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        'Accept'     = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    }
    $resp = Invoke-WebRequest -Uri 'https://www.bible.com/verse-of-the-day?version=59' -Headers $headers -TimeoutSec 8 -UseBasicParsing
    $html = [string]$resp.Content
    if ($html -match '<meta\s+property="og:description"\s+content="([^"]+)"') {
        $content = [System.Net.WebUtility]::HtmlDecode($Matches[1])
        if ($content -match '^((?:\d\s+)?[A-Za-z]+(?:\s+of\s+\w+)?)\s+(\d+:\d+(?:-\d+)?)\s+(.+)$') {
            $vt = ($Matches[3].Trim() -replace '^[\s"“”]+', '' -replace '[\s"“”]+$', '').Trim()
            $vt = [char]0x201C + $vt + [char]0x201D
            return @{ text = $vt; ref = "$($Matches[1]) $($Matches[2]) ESV, YouVersion" }
        }
    }
    return $null
}

$termWidth = try { [Console]::WindowWidth } catch { 160 }
if (-not $termWidth -or $termWidth -le 0) { $termWidth = 160 }
$wrapAt  = [math]::Max(60, [int][math]::Floor($termWidth / 2))
$palette = @(52, 94, 95, 130, 131, 136, 137, 138, 143, 180)
$rnd     = New-Object System.Random

function Format-Verse {
    param($verse, $wrapAt, $rnd, $palette, $E, $reset, $magenta)
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
    $output += "$magenta$($verse.ref)$reset"
    return $output
}

if ($verseYV) {
    foreach ($l in (Format-Verse $verseYV $wrapAt $rnd $palette $E $reset $magenta)) { Write-Output $l }
}
if ($verseBG -and $verseYV) {
    $div = ([string][char]0x2500) * $wrapAt
    Write-Output "$dim$div$reset"
}
if ($verseBG) {
    foreach ($l in (Format-Verse $verseBG $wrapAt $rnd $palette $E $reset $magenta)) { Write-Output $l }
}
