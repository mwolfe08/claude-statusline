# Generate a realistic stdin payload for benchmarking the statusline.
#
# Claude Code pipes a JSON object to the status line command on stdin. The script
# reads transcript_path and walks the session transcript, so a payload with a FAKE
# transcript path under-measures badly - always point it at a real .jsonl.
#
# Usage:
#   .\make-payload.ps1                      # newest transcript in the active profile
#   .\make-payload.ps1 -OutFile p.json      # choose the output path
#
# No personal values are hardcoded here; everything is resolved from the environment
# at run time, so this file is safe to publish.

param(
    [string]$OutFile = (Join-Path $env:TEMP 'statusline-bench-payload.json'),
    [string]$Cwd     = (Get-Location).Path
)

$cfgDir = if ($env:CLAUDE_CONFIG_DIR -and (Test-Path $env:CLAUDE_CONFIG_DIR)) {
    $env:CLAUDE_CONFIG_DIR
} else {
    Join-Path $env:USERPROFILE '.claude'
}

$projects = Join-Path $cfgDir 'projects'
$tx = Get-ChildItem $projects -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $tx) {
    Write-Error "No transcript .jsonl found under $projects - cannot build a representative payload."
    exit 1
}

@{
    session_id      = [IO.Path]::GetFileNameWithoutExtension($tx.Name)
    transcript_path = $tx.FullName
    cwd             = $Cwd
    permission_mode = 'bypassPermissions'
    model           = @{ display_name = 'Opus 5 (1M context)'; id = 'claude-opus-5[1m]' }
    workspace       = @{ current_dir = $Cwd }
    output_style    = @{ name = 'default' }
    cost            = @{ total_cost_usd = 1.23; total_duration_ms = 45000; total_api_duration_ms = 30000 }
} | ConvertTo-Json -Depth 6 -Compress | Set-Content $OutFile -Encoding ASCII -NoNewline

"payload written: $OutFile"
"  transcript    : $($tx.FullName)  ($([math]::Round($tx.Length/1MB,2)) MB)"
"  cwd           : $Cwd"
