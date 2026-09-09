# install.ps1 - build the native status line and point Claude Code at it.
#
#     pwsh -File .\install.ps1 -DryRun     # show every change, write nothing
#     pwsh -File .\install.ps1             # build, install, seed config, switch over
#     pwsh -File .\install.ps1 -Rollback   # point settings back at statusline.ps1
#
# What it does, and why each step exists:
#
#  1. `go build` the binary from native/ and copy it to ~/.claude/statusline.exe.
#     The binary is NOT committed (see .gitignore): publish-public.ps1 hash-pins every
#     binary in the publish tree so a human re-reviews it, and one that changes on every
#     build would abort every publish run.
#
#  2. Seed ~/.claude/statusline-config.json from the CONFIG block of an existing
#     ~/.claude/statusline.ps1. That block (lines 6-50) held the ONLY personal values in
#     the script, which is why sync-live.ps1 had to exist. A compiled binary cannot carry
#     them and should not -- the public mirror ships the same bytes -- so they move to a
#     JSON file that never enters either repo. An existing config is never overwritten.
#
#  3. Rewrite statusLine.command in settings.json.
#     TRAP, and the reason canonical is written FIRST and always: the account switcher
#     (claude-accounts.ps1) treats settings.json as a SHARED file and re-copies it from
#     canonical ~/.claude on EVERY launch. Writing a profile's copy alone is futile - the
#     next launch reverts it. Canonical is the file that persists; the profile copies are
#     written too, only so running sessions pick the change up without a relaunch.
#
# statusline.ps1 is left in place either way, so -Rollback is a one-key change.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'

$repo        = Split-Path -Parent $MyInvocation.MyCommand.Path
$nativeDir   = Join-Path $repo 'native'
$canonical   = Join-Path $env:USERPROFILE '.claude'
$liveExe     = Join-Path $canonical 'statusline.exe'
$livePs1     = Join-Path $canonical 'statusline.ps1'
$liveCfg     = Join-Path $canonical 'statusline-config.json'
$profilesDir = Join-Path $env:USERPROFILE '.claude-profiles'

$CmdNative = '"' + ($liveExe -replace '\\', '/') + '"'
$CmdPs1    = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + ($livePs1 -replace '\\', '/')

function Write-Step($msg) { Write-Host "  $msg" }
function Write-Head($msg) { Write-Host "`n$msg" -ForegroundColor Cyan }

# ---- every settings.json that has to agree: canonical first, then each profile ----
function Get-SettingsFiles {
    $files = @()
    $c = Join-Path $canonical 'settings.json'
    if (Test-Path $c) { $files += $c }
    if (Test-Path $profilesDir) {
        # Enumerated, never hardcoded: profile folders are per-machine and a new account
        # must not need an edit here.
        foreach ($d in Get-ChildItem $profilesDir -Directory) {
            $s = Join-Path $d.FullName 'settings.json'
            if (Test-Path $s) { $files += $s }
        }
    }
    $files
}

function Set-StatusLineCommand($file, $command, $dry) {
    $raw = Get-Content $file -Raw
    $j   = $raw | ConvertFrom-Json
    $cur = $null
    if ($j.PSObject.Properties.Name -contains 'statusLine') { $cur = $j.statusLine.command }
    if ($cur -eq $command) { Write-Step "unchanged : $file"; return $false }
    Write-Step "$(if ($dry) { 'would set' } else { 'set      ' }) : $file"
    Write-Step "            from: $cur"
    Write-Step "            to  : $command"
    if ($dry) { return $true }
    if (-not $j.statusLine) {
        $j | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{
            type = 'command'; command = $command; refreshInterval = 60
        }) -Force
    } else {
        $j.statusLine.command = $command
    }
    # Depth 32: settings.json nests hooks -> matcher -> hooks[] several levels deep and a
    # shallow ConvertTo-Json would silently stringify them into "System.Object[]".
    $j | ConvertTo-Json -Depth 32 | Set-Content -Path $file -Encoding UTF8
    return $true
}

# ---- rollback is just the command swap; nothing else is undone ----
if ($Rollback) {
    Write-Head 'Rollback: pointing settings.json back at statusline.ps1'
    if (-not (Test-Path $livePs1)) { throw "No $livePs1 to roll back to." }
    foreach ($f in Get-SettingsFiles) { [void](Set-StatusLineCommand $f $CmdPs1 $DryRun) }
    Write-Host "`nDone. The binary and its config are left in place." -ForegroundColor Green
    exit 0
}

# ---- 1. build ----
Write-Head '1. Build'
if (-not (Get-Command go -ErrorAction SilentlyContinue)) { throw 'go is not on PATH.' }
Write-Step "go build in $nativeDir"
if (-not $DryRun) {
    Push-Location $nativeDir
    try {
        & go build -ldflags='-s -w' -o statusline.exe .
        if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}
$built = Join-Path $nativeDir 'statusline.exe'
if (-not $DryRun -and -not (Test-Path $built)) { throw "build produced no $built" }

# ---- 2. install the binary ----
Write-Head '2. Install binary'
Write-Step "$(if ($DryRun) { 'would copy' } else { 'copy     ' }) : $built -> $liveExe"
if (-not $DryRun) {
    # Copy to a temp name and move into place: a running render holds the old image open,
    # and an in-place overwrite would fail with a sharing violation.
    $tmp = "$liveExe.new"
    Copy-Item $built $tmp -Force
    Move-Item $tmp $liveExe -Force
}

# ---- 3. seed the config from the PowerShell CONFIG block ----
Write-Head '3. Config'
if (Test-Path $liveCfg) {
    Write-Step "exists, left alone : $liveCfg"
} elseif (Test-Path $livePs1) {
    $text = Get-Content $livePs1 -Raw
    # The CONFIG block is delimited by the two `# ===...===` banner lines. Only assignment
    # statements live between them, so evaluating that slice in a child scope is safe and
    # is the one way to read a PowerShell hashtable literal without writing a parser.
    $m = [regex]::Match($text, '(?ms)^# =+ CONFIG =+\s*$(.*?)^# =+\s*$')
    if (-not $m.Success) { throw "Could not find the CONFIG block in $livePs1" }
    $sb = [scriptblock]::Create($m.Groups[1].Value)
    $vars = & {
        . $sb
        [pscustomobject]@{
            weather_lat        = [string]$WEATHER_LAT
            weather_lon        = [string]$WEATHER_LON
            profile_tags       = $PROFILE_TAGS
            account_tags       = $ACCOUNT_TAGS
            cost_windows       = [bool]$COST_WINDOWS
            billing_anchor_day = [int]$BILLING_ANCHOR_DAY
            cache_ttl_min      = [int]$CACHE_TTL_MIN
            cache_warn_min     = [int]$CACHE_WARN_MIN
            cache_crit_min     = [int]$CACHE_CRIT_MIN
            verse_youversion   = [bool]$VERSE_YOUVERSION
            verse_biblegateway = [bool]$VERSE_BIBLEGATEWAY
        }
    }
    Write-Step "$(if ($DryRun) { 'would write' } else { 'write      ' }) : $liveCfg (from the CONFIG block of statusline.ps1)"
    if (-not $DryRun) { $vars | ConvertTo-Json -Depth 6 | Set-Content -Path $liveCfg -Encoding UTF8 }
} else {
    Write-Step "no statusline.ps1 to read; copying the sample template"
    if (-not $DryRun) { Copy-Item (Join-Path $nativeDir 'statusline-config.sample.json') $liveCfg }
}

# ---- 4. point Claude Code at the binary ----
Write-Head '4. settings.json'
$changed = 0
foreach ($f in Get-SettingsFiles) { if (Set-StatusLineCommand $f $CmdNative $DryRun) { $changed++ } }

Write-Head 'Summary'
Write-Step "settings files touched : $changed"
Write-Step "statusLine.command     : $CmdNative"
Write-Step "roll back with         : pwsh -File .\install.ps1 -Rollback"
if ($DryRun) { Write-Host "`nDRY RUN - nothing was written." -ForegroundColor Yellow }
else { Write-Host "`nInstalled. Open sessions pick it up on their next render." -ForegroundColor Green }
