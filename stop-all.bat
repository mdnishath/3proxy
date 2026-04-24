@echo off
REM Stop all proxy-farm processes (3proxy, ssh tunnels, rotation agent)
taskkill /F /IM 3proxy.exe >nul 2>&1
taskkill /F /IM ssh.exe >nul 2>&1

REM Kill any tunnel-loop cmd windows (hidden or not)
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name = 'cmd.exe'\" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*tunnel-loop*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

REM Kill the rotation agent (runs as powershell.exe hosting agent.ps1)
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name = 'powershell.exe'\" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*agent.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

echo Stopped all proxy-farm processes.
