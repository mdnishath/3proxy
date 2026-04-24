@echo off
REM =================================================
REM Auto-reconnecting SSH reverse tunnel
REM Args: %1 = VPS port (40001/40002), %2 = local PC port (51081/51082)
REM =================================================

setlocal
set DEST=C:\proxy-farm
set LOG=%DEST%\logs\tunnel-%1.log
set KEY=%DEST%\keys\panel_id_ed25519
set VPS_PORT=%1
set LOCAL_PORT=%2

if "%VPS_PORT%"=="" set VPS_PORT=40001
if "%LOCAL_PORT%"=="" set LOCAL_PORT=51081

title Tunnel %VPS_PORT% -> %LOCAL_PORT%

echo [%DATE% %TIME%] tunnel-loop started (VPS:%VPS_PORT% -^> PC:%LOCAL_PORT%) >> "%LOG%"

:loop
REM Clean any stale sshd holding this port on VPS (from previous disconnect)
echo [%DATE% %TIME%] cleaning stale VPS port %VPS_PORT% ... >> "%LOG%"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=5 -o BatchMode=yes -i "%KEY%" root@144.79.218.148 "ss -tlnp 2>/dev/null | grep :%VPS_PORT% | grep -oE 'pid=[0-9]+' | cut -d= -f2 | xargs -r kill -9 2>/dev/null; true" >> "%LOG%" 2>&1

REM Open reverse tunnel with aggressive keep-alive
echo [%DATE% %TIME%] connecting tunnel ... >> "%LOG%"
ssh -N ^
    -o StrictHostKeyChecking=no ^
    -o UserKnownHostsFile=NUL ^
    -o ServerAliveInterval=5 ^
    -o ServerAliveCountMax=2 ^
    -o ExitOnForwardFailure=yes ^
    -o TCPKeepAlive=yes ^
    -o ConnectTimeout=10 ^
    -i "%KEY%" ^
    -R 0.0.0.0:%VPS_PORT%:127.0.0.1:%LOCAL_PORT% ^
    root@144.79.218.148 >> "%LOG%" 2>&1

echo [%DATE% %TIME%] tunnel dropped, reconnecting in 3s ... >> "%LOG%"
timeout /t 3 /nobreak >nul
goto loop
