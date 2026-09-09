@echo off
REM Time N renders of a status line implementation.
REM
REM   render-bench.cmd <impl> <payload.json> <N>
REM
REM <impl> is either a .ps1 (run through powershell 5.1) or a native .exe.
REM Time the WHOLE invocation from outside, e.g. from PowerShell:
REM   $sw=[Diagnostics.Stopwatch]::StartNew(); .\render-bench.cmd X.ps1 p.json 20; $sw.Stop()
REM   $sw.ElapsedMilliseconds / 20
REM
REM TRAP: do NOT time this with Start-Process - it inflates Windows spawn timing
REM about 10x. A native cmd loop is the only accurate harness on this box.
REM TRAP: always run a few warmup iterations first. The status line spawns a
REM detached background cache refresh on its first run, throttled to 45s after.
setlocal
set IMPL=%~1
set PAYLOAD=%~2
set N=%~3
if "%N%"=="" set N=20

if /I "%~x1"==".ps1" (
  for /L %%i in (1,1,%N%) do @powershell -NoProfile -ExecutionPolicy Bypass -File "%IMPL%" < "%PAYLOAD%" > nul 2>&1
) else (
  for /L %%i in (1,1,%N%) do @"%IMPL%" < "%PAYLOAD%" > nul 2>&1
)
endlocal
