# =================================================================
# ClientFlow Proxy Farm - Client Laptop Installer (France, Windows 10)
#
# One-shot setup:
#  1. Copy files to C:\proxy-farm\
#  2. Add Windows Defender exclusion (3proxy is flagged HackTool false-positive)
#  3. Detect the Wi-Fi USB adapters (non-default Wi-Fi) + their IPs
#  4. Generate 3proxy.cfg bound to the 2 adapter IPs
#  5. Install scheduled task "ProxyFarm" (runs start-all.bat at startup)
#  6. Start everything now
#
# Usage (Admin PowerShell):
#   Set-ExecutionPolicy -Scope Process Bypass; .\install.ps1
# =================================================================

$ErrorActionPreference = 'Stop'

# Must be admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Must run as Administrator." -ForegroundColor Red
    Write-Host "    Right-click PowerShell -> Run as Administrator, then re-run." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

$DEST = "C:\proxy-farm"
$SRC = $PSScriptRoot

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "           ClientFlow Proxy Farm Installer (France)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# ---- Step 1: Windows Defender exclusion ----
Write-Host "[1/6] Adding Windows Defender exclusion for $DEST ..." -ForegroundColor Green
try {
    Add-MpPreference -ExclusionPath $DEST -ErrorAction SilentlyContinue
    Write-Host "      OK" -ForegroundColor DarkGreen
} catch {
    Write-Host "      Warning: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---- Step 2: Copy files ----
Write-Host "[2/6] Copying files to $DEST ..." -ForegroundColor Green
if (Test-Path $DEST) {
    Get-Process 3proxy, ssh -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
New-Item -ItemType Directory -Force -Path $DEST | Out-Null
New-Item -ItemType Directory -Force -Path "$DEST\bin" | Out-Null
New-Item -ItemType Directory -Force -Path "$DEST\config" | Out-Null
New-Item -ItemType Directory -Force -Path "$DEST\keys" | Out-Null
New-Item -ItemType Directory -Force -Path "$DEST\logs" | Out-Null

Copy-Item -Path "$SRC\bin\*" -Destination "$DEST\bin\" -Force
Copy-Item -Path "$SRC\config\passwd" -Destination "$DEST\config\passwd" -Force
Copy-Item -Path "$SRC\keys\panel_id_ed25519" -Destination "$DEST\keys\panel_id_ed25519" -Force
Copy-Item -Path "$SRC\start-all.bat" -Destination "$DEST\start-all.bat" -Force
Copy-Item -Path "$SRC\start-all.ps1" -Destination "$DEST\start-all.ps1" -Force
Copy-Item -Path "$SRC\tunnel-loop.bat" -Destination "$DEST\tunnel-loop.bat" -Force
Copy-Item -Path "$SRC\stop-all.bat" -Destination "$DEST\stop-all.bat" -Force
Copy-Item -Path "$SRC\enable-autostart.ps1" -Destination "$DEST\enable-autostart.ps1" -Force

# Lock down the SSH private key
icacls "$DEST\keys\panel_id_ed25519" /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null

Write-Host "      OK" -ForegroundColor DarkGreen

# ---- Step 3: Detect Wi-Fi adapters ----
Write-Host "[3/6] Detecting Wi-Fi adapters with internet ..." -ForegroundColor Green

$wifiAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -eq 'Up' -and
    ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|TP-Link|Realtek|Edimax|Mediatek|Ralink|Atheros|USB')
} | Sort-Object ifIndex)

Write-Host ""
Write-Host "      Found $($wifiAdapters.Count) active Wi-Fi adapter(s):" -ForegroundColor DarkGreen
$wifiInfo = @()
$idx = 0
foreach ($a in $wifiAdapters) {
    $idx++
    $ip = $null
    try {
        $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notmatch '^169\.254' -and $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1).IPAddress
    } catch {}
    if (-not $ip) {
        Write-Host ("      [{0}] {1}  (no IPv4 - skipped)" -f $idx, $a.Name) -ForegroundColor DarkGray
        continue
    }
    $ssid = '(not Wi-Fi)'
    try {
        $ssidLines = netsh wlan show interfaces name="$($a.Name)" 2>$null |
                     Select-String '^\s+SSID\s+:' |
                     Where-Object { $_.Line -notmatch 'BSSID' }
        if ($ssidLines) { $ssid = ($ssidLines[0].Line -split ':',2)[1].Trim() }
    } catch {}
    $wifiInfo += [PSCustomObject]@{
        Index = $idx
        Name = $a.Name
        Description = $a.InterfaceDescription
        IP = $ip
        SSID = $ssid
    }
    Write-Host ("      [{0}] {1}  IP={2}  SSID={3}" -f $idx, $a.Name, $ip, $ssid) -ForegroundColor White
}

if ($wifiInfo.Count -lt 2) {
    Write-Host ""
    Write-Host "[!] Need at least 2 Wi-Fi adapters connected to 2 different pocket routers." -ForegroundColor Red
    Write-Host "    Currently found $($wifiInfo.Count). Plug both USB Wi-Fi adapters in and connect each to a different router's SSID, then re-run." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

# Pick the 2 adapters the user designates. Ask if >2.
if ($wifiInfo.Count -eq 2) {
    $router1 = $wifiInfo[0]
    $router2 = $wifiInfo[1]
} else {
    Write-Host ""
    Write-Host "      More than 2 Wi-Fi adapters found. Which TWO are the pocket routers?" -ForegroundColor Yellow
    $r1Idx = Read-Host "      Enter number for Router 1"
    $r2Idx = Read-Host "      Enter number for Router 2"
    $router1 = $wifiInfo | Where-Object { $_.Index -eq [int]$r1Idx } | Select-Object -First 1
    $router2 = $wifiInfo | Where-Object { $_.Index -eq [int]$r2Idx } | Select-Object -First 1
}

Write-Host ""
Write-Host "      Router 1 -> $($router1.SSID) via $($router1.Name) (IP $($router1.IP))" -ForegroundColor Cyan
Write-Host "      Router 2 -> $($router2.SSID) via $($router2.Name) (IP $($router2.IP))" -ForegroundColor Cyan

# ---- Step 4: Generate 3proxy.cfg ----
Write-Host ""
Write-Host "[4/6] Generating 3proxy config ..." -ForegroundColor Green

$cfg = @"
# Auto-generated by ClientFlow install.ps1
service
pidfile "$DEST\logs\3proxy.pid"

nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

users `$"$DEST\config\passwd"

log "$DEST\logs\3proxy.log" D
logformat "- +_L%t.%.  %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 3

# Router 1 - egress via $($router1.Name) ($($router1.IP)) -> SSID: $($router1.SSID)
flush
auth strong
allow router1
allow * * * *
socks -p51081 -a -i127.0.0.1 -e$($router1.IP)

# Router 2 - egress via $($router2.Name) ($($router2.IP)) -> SSID: $($router2.SSID)
flush
auth strong
allow router2
allow * * * *
socks -p51082 -a -i127.0.0.1 -e$($router2.IP)
"@

$cfg | Out-File -Encoding ASCII -NoNewline -FilePath "$DEST\config\3proxy.cfg"
Write-Host "      OK" -ForegroundColor DarkGreen

# ---- Step 5: Install scheduled task ----
Write-Host "[5/6] Installing auto-start scheduled task 'ProxyFarm' ..." -ForegroundColor Green
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
cmd.exe /c "schtasks /delete /tn ProxyFarm /f >nul 2>&1"
cmd.exe /c "schtasks /create /tn ProxyFarm /tr `"$DEST\start-all.bat`" /sc ONSTART /ru SYSTEM /rl HIGHEST /f >nul 2>&1"
$ErrorActionPreference = $prevEAP
Write-Host "      OK" -ForegroundColor DarkGreen

# ---- Step 6: Start everything now ----
Write-Host "[6/6] Starting proxy farm now ..." -ForegroundColor Green
Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$DEST\start-all.bat`"" -WindowStyle Minimized
Start-Sleep -Seconds 4

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Working directory:  $DEST"
Write-Host "  Logs:               $DEST\logs\"
Write-Host "  Auto-start:         Yes (scheduled task 'ProxyFarm')"
Write-Host ""
Write-Host "  Quick commands:"
Write-Host "    Start:   $DEST\start-all.bat"
Write-Host "    Stop:    $DEST\stop-all.bat"
Write-Host "    Check:   Get-Process 3proxy,ssh"
Write-Host ""

Read-Host "Press Enter to close"
