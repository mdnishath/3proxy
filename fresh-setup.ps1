# =================================================================
# ClientFlow Proxy Farm - FRESH SETUP (run as Administrator)
#
# One-shot reset + install that replaces the old "Interactive / At
# logon" scheduled task with a properly hidden ONSTART task that
# auto-runs on every boot without any cmd window flashing up.
#
# What it does:
#   1. Kill every running 3proxy / ssh / tunnel-loop (even elevated).
#   2. Delete the old ProxyFarm scheduled task completely.
#   3. Wipe stale C:\proxy-farm\config\3proxy.cfg and reset
#      adapters.json to the fresh Wi-Fi 2 + Wi-Fi 4 slot map.
#   4. Copy updated start-all.ps1, launcher.vbs, run-hidden.vbs
#      from this package folder to C:\proxy-farm.
#   5. Register a new ONSTART task that launches
#      wscript.exe launcher.vbs (invisible). Prefers "run whether
#      logged on or not" (stored credential); falls back to
#      ONLOGON interactive if no password supplied.
#   6. Enable Windows auto-login + set all saved Wi-Fi profiles
#      to auto-connect (belt-and-suspenders for post-boot Wi-Fi).
#   7. Kick the launcher now so the farm is live immediately.
#
# Usage (Administrator PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\fresh-setup.ps1
#   powershell -ExecutionPolicy Bypass -File .\fresh-setup.ps1 -SkipPassword
# =================================================================

param(
    [switch]$SkipPassword
)

$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Must run as Administrator." -ForegroundColor Red
    Write-Host "    Right-click PowerShell -> Run as Administrator, cd to the package folder," -ForegroundColor Yellow
    Write-Host "    then: powershell -ExecutionPolicy Bypass -File .\fresh-setup.ps1" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

$user = $env:USERNAME
$DEST = 'C:\proxy-farm'
$SRC  = $PSScriptRoot

Write-Host ""
Write-Host "=== ClientFlow Proxy Farm - FRESH SETUP ===" -ForegroundColor Cyan
Write-Host "  User:    $user"
Write-Host "  Package: $SRC"
Write-Host "  Deploy:  $DEST"
Write-Host ""

# Password is optional - needed only for the preferred ONSTART
# "run whether logged on or not" mode. Blank / -SkipPassword = fallback to ONLOGON.
$plain = ''
if (-not $SkipPassword) {
    Write-Host "Optional: enter Windows password for '$user' to enable 'run whether logged on" -ForegroundColor DarkCyan
    Write-Host "or not' (task fires at boot even before login). Press Enter to skip (task will"  -ForegroundColor DarkCyan
    Write-Host "run at logon only; auto-login is configured as a fallback either way)."            -ForegroundColor DarkCyan
    $sec = Read-Host "Password (blank to skip)" -AsSecureString
    if ($sec -and $sec.Length -gt 0) {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        )
    }
} else {
    Write-Host "-SkipPassword specified - using ONLOGON fallback." -ForegroundColor DarkCyan
}
$havePw = [bool]$plain

# --- 1. Kill every running proxy-farm process (admin-elevated ones too) ---
Write-Host "[1/7] Stopping 3proxy / ssh / tunnel-loop processes ..." -ForegroundColor Green
cmd.exe /c "taskkill /F /IM 3proxy.exe /T >nul 2>&1"
cmd.exe /c "taskkill /F /IM ssh.exe /T >nul 2>&1"
Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*tunnel-loop*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*run-hidden.vbs*' -or $_.CommandLine -like '*launcher.vbs*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1
Write-Host "      OK" -ForegroundColor DarkGreen

# --- 2. Delete the old ProxyFarm scheduled task ---
Write-Host "[2/7] Removing old ProxyFarm scheduled task ..." -ForegroundColor Green
cmd.exe /c "schtasks /delete /tn ProxyFarm /f >nul 2>&1"
Write-Host "      OK" -ForegroundColor DarkGreen

# --- 3. Copy updated files from package to C:\proxy-farm (skip if SRC==DEST) ---
Write-Host "[3/7] Deploying fresh files to $DEST ..." -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $DEST          | Out-Null
New-Item -ItemType Directory -Force -Path "$DEST\config" | Out-Null
New-Item -ItemType Directory -Force -Path "$DEST\logs"   | Out-Null

$sameRoot = ((Resolve-Path $SRC).Path.TrimEnd('\') -ieq (Resolve-Path $DEST).Path.TrimEnd('\'))
if ($sameRoot) {
    Write-Host "      (SRC == DEST, skipping file copies)" -ForegroundColor DarkYellow
} else {
    $files = @(
        'start-all.ps1','start-all.bat','tunnel-loop.bat','stop-all.bat',
        'launcher.vbs','run-hidden.vbs',
        'agent.ps1','rotate-router.ps1','rotate-runner.ps1'
    )
    foreach ($f in $files) {
        if (Test-Path "$SRC\$f") {
            Copy-Item -Path "$SRC\$f" -Destination "$DEST\$f" -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path "$SRC\config\adapters.json") {
        Copy-Item -Path "$SRC\config\adapters.json" -Destination "$DEST\config\adapters.json" -Force -ErrorAction SilentlyContinue
    }
    # Seed routers.json (rotation creds) only if missing - preserve hand-edited hashes across reinstalls
    New-Item -ItemType Directory -Force -Path "$DEST\keys"   | Out-Null
    New-Item -ItemType Directory -Force -Path "$DEST\config" | Out-Null
    if (-not (Test-Path "$DEST\config\routers.json") -and (Test-Path "$SRC\config\routers.json.example")) {
        Copy-Item -Path "$SRC\config\routers.json.example" -Destination "$DEST\config\routers.json" -Force
        Write-Host "      seeded config\routers.json from example (fill in the hashes)" -ForegroundColor DarkYellow
    }
}

# --- agent shared secret: generate once, preserve on re-runs ---
$secretFile = "$DEST\keys\agent-secret.txt"
if (-not (Test-Path $secretFile)) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $secret = -join ($bytes | ForEach-Object { '{0:x2}' -f $_ })
    Set-Content -Path $secretFile -Value $secret -Encoding ASCII -NoNewline
    Write-Host "      generated new agent-secret.txt (copy to VPS .env as ROTATION_AGENT_SECRET)" -ForegroundColor DarkYellow
}
cmd.exe /c "icacls `"$secretFile`" /inheritance:r >nul 2>&1"
cmd.exe /c "icacls `"$secretFile`" /grant:r `"$env:USERNAME`":R >nul 2>&1"
cmd.exe /c "icacls `"$secretFile`" /grant:r `"SYSTEM`":R >nul 2>&1"

# --- always write the canonical slot map + passwd so state is deterministic ---
@'
{
  "00-E0-4C-5D-88-0F": 1,
  "00-E0-4C-5D-89-33": 2
}
'@ | Out-File -Encoding ASCII -FilePath "$DEST\config\adapters.json" -Force

@'
router1:CL:5a8dd1e89a7add2cdfeb
router2:CL:080c6133bcaec0ccffdb
'@ | Out-File -Encoding ASCII -FilePath "$DEST\config\passwd" -Force

# wipe stale 3proxy.cfg - will be regenerated by start-all.ps1
Remove-Item "$DEST\config\3proxy.cfg" -Force -ErrorAction SilentlyContinue
Write-Host "      OK (adapters.json and passwd reset to canonical state)" -ForegroundColor DarkGreen

# --- 4. Register fresh ProxyFarm task ---
Write-Host "[4/7] Registering fresh ProxyFarm scheduled task ..." -ForegroundColor Green
$taskCmd = "wscript.exe `"$DEST\launcher.vbs`""
if ($havePw) {
    # ONSTART + run whether logged on or not (stored cred, no visible window)
    $sch = "schtasks /create /tn ProxyFarm /tr `"$taskCmd`" /sc ONSTART /ru `"$user`" /rp `"$plain`" /rl HIGHEST /delay 0001:30 /f"
    cmd.exe /c $sch | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      ONSTART with stored cred failed - falling back to ONLOGON" -ForegroundColor Yellow
        cmd.exe /c "schtasks /create /tn ProxyFarm /tr `"$taskCmd`" /sc ONLOGON /ru `"$user`" /rl HIGHEST /f" | Out-Null
        Write-Host "      registered as ONLOGON (requires user login, auto-login will handle)" -ForegroundColor DarkYellow
    } else {
        Write-Host "      registered as ONSTART + run-whether-logged-on (boot-time, invisible)" -ForegroundColor DarkGreen
    }
} else {
    # ONLOGON interactive (runs on user logon; auto-login will fire it after boot)
    cmd.exe /c "schtasks /create /tn ProxyFarm /tr `"$taskCmd`" /sc ONLOGON /ru `"$user`" /rl HIGHEST /f" | Out-Null
    Write-Host "      registered as ONLOGON (auto-login triggers it after reboot)" -ForegroundColor DarkGreen
}

# --- 5. Enable Windows auto-login (so ONLOGON path works unattended) ---
Write-Host "[5/7] Configuring Windows auto-login for '$user' ..." -ForegroundColor Green
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon'  -Value '1'   -Force
Set-ItemProperty -Path $winlogon -Name 'DefaultUserName' -Value $user -Force
if ($havePw) {
    Set-ItemProperty -Path $winlogon -Name 'DefaultPassword' -Value $plain -Force
    Write-Host "      auto-login password set" -ForegroundColor DarkGreen
} else {
    Write-Host "      (skipped password - existing one preserved if already set)" -ForegroundColor DarkYellow
}
try { Set-ItemProperty -Path $winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Force } catch {}
try { Set-ItemProperty -Path $winlogon -Name 'AutoLogonCount'    -Value 0 -Force } catch {}

$plain = $null
[gc]::Collect()

# --- 6. Set all saved Wi-Fi profiles to auto-connect ---
Write-Host "[6/7] Setting Wi-Fi profiles to auto-connect ..." -ForegroundColor Green
$profiles = @()
$raw = netsh wlan show profiles 2>$null
foreach ($ln in $raw) {
    if ($ln -match 'All User Profile\s+:\s+(.+)$' -or $ln -match 'User Profile\s+:\s+(.+)$') {
        $name = $Matches[1].Trim()
        if ($name -and $profiles -notcontains $name) { $profiles += $name }
    }
}
foreach ($p in $profiles) {
    cmd.exe /c "netsh wlan set profileparameter name=`"$p`" connectionmode=auto >nul 2>&1"
}
Write-Host "      $($profiles.Count) Wi-Fi profile(s) set to auto-connect" -ForegroundColor DarkGreen

# --- 7. Kick the launcher now ---
Write-Host "[7/7] Launching proxy farm (hidden) ..." -ForegroundColor Green
Start-Process -FilePath "wscript.exe" -ArgumentList "`"$DEST\launcher.vbs`"" -WindowStyle Hidden
Start-Sleep 8
$p3 = @(Get-Process 3proxy -ErrorAction SilentlyContinue)
$ps = @(Get-Process ssh     -ErrorAction SilentlyContinue)
$pa = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*agent.ps1*' })
Write-Host "      3proxy processes: $($p3.Count)   ssh processes: $($ps.Count)   agent processes: $($pa.Count)" -ForegroundColor DarkGreen

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Fresh setup complete." -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Slot map (config\adapters.json):"
Write-Host "    Wi-Fi 2 (00-E0-4C-5D-88-0F) -> slot 1 -> router1 -> ALTICE_DDC54"
Write-Host "    Wi-Fi 4 (00-E0-4C-5D-89-33) -> slot 2 -> router2 -> ALTICE_DDCCD4"
Write-Host "    Intel AX201 (built-in)      -> NOT an egress slot (backup only)"
Write-Host ""
if (Test-Path $secretFile) {
    Write-Host "  --- Agent shared secret (paste into VPS .env) ---" -ForegroundColor Yellow
    Write-Host "    ROTATION_AGENT_SECRET=$(Get-Content $secretFile -Raw)" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
}
Write-Host "  Rotation config:"
Write-Host "    - Edit $DEST\config\routers.json -> fill in router 2's"
Write-Host "      username_hash / password_hash (capture via DevTools on Wi-Fi 4)."
Write-Host "    - Agent listens on 127.0.0.1:8901, tunnelled to VPS:40101."
Write-Host ""
Write-Host "  Verify:"
Write-Host "    Get-Process 3proxy,ssh"
Write-Host "    Get-Content $DEST\logs\start.log -Tail 20"
Write-Host "    Get-Content $DEST\logs\agent.log -Tail 20"
Write-Host "    Get-Content $DEST\config\3proxy.cfg"
Write-Host ""
Write-Host "  Reboot test:"
Write-Host "    - Reboot the laptop, do NOT touch it."
Write-Host "    - After ~2 minutes, on VPS: ss -tlnp | grep -E ':40001|:40002'"
Write-Host "    - No cmd / error windows should appear on the desktop."
Write-Host ""
if (-not $SkipPassword) { Read-Host "Press Enter to close" } else { Start-Sleep 5 }
