@echo off
REM =================================================
REM ClientFlow Proxy Farm — wrapper
REM Delegates to dynamic start-all.ps1 which auto-detects
REM all Wi-Fi adapters and assigns stable slots per MAC.
REM =================================================
setlocal
set DEST=C:\proxy-farm
if not exist %DEST%\logs mkdir %DEST%\logs
echo [%DATE% %TIME%] start-all.bat -^> start-all.ps1 >> "%DEST%\logs\start.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DEST%\start-all.ps1"
