@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it with: winget install --exact --id Microsoft.PowerShell
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0workbench.ps1" start
if errorlevel 1 (
  echo Workbench startup failed. Run workbench.ps1 diagnostics and inspect its output.
  pause
  exit /b 1
)
start "" "http://localhost:8787"
endlocal
