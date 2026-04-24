# =================================================================
# ClientFlow Proxy Farm - one-shot fix + persistence (run as Admin)
#
# Does everything in one elevated run:
#   1. Enable Windows Location Services (Win11 requires this for
#      netsh wlan commands to work at all).
#   2. Force-connect any USB Wi-Fi adapter that has a saved profile
#      but is currently disconnected.
#   3. Kill any stale 3proxy / ssh / tunnel-loop cmd windows.
#   4. Re-register the ProxyFarm scheduled task as ONSTART so it
#      fires at every boot regardless of logon state (cred stored
#      in LSA by Task Scheduler).
#   5. Enable Windows auto-login for the current user so the Wi-Fi
#      user-profiles associate post-boot without a human.
#   6. Set every saved Wi-Fi profile to auto-connect.
#   7. Kick a fresh start-all.bat so the dynamic 3proxy.cfg is live.
#
# Usage (Administrator PowerShell):
#   powershell -ExecutionPolicy Bypass -File C:\proxy-farm\enable-autostart.ps1
# =================================================================

$ErrorActionPreference = 'Continue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Must run as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$user = $env:USERNAME
$DEST = 'C:\proxy-farm'

Write-Host ""
Write-Host "=== ClientFlow Proxy Farm - one-shot fix + persistence ===" -ForegroundColor Cyan
Write-Host "  User: $user"
Write-Host ""

$sec = Read-Host "Enter Windows password for '$user'" -AsSecureString
$plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
)

# --- 1. Enable Location Services (Win11 needs it for netsh wlan) ---
Write-Host "[1/7] Enabling Location Services ..." -ForegroundColor Green
try {
    $locKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
    if (-not (Test-Path $locKey)) { New-Item -Path $locKey -Force | Out-Null }
    Set-ItemProperty -Path $locKey -Name 'SensorPermissionState' -Value 1 -Type DWord -Force
    $capKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
    if (-not (Test-Path $capKey)) { New-Item -Path $capKey -Force | Out-Null }
    Set-ItemProperty -Path $capKey -Name 'Value' -Value 'Allow' -Type String -Force
    Set-Service -Name lfsvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name lfsvc -ErrorAction SilentlyContinue
    Write-Host "      OK" -ForegroundColor DarkGreen
} catch {
    Write-Host "      WARN: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 2. Try to connect any USB Wi-Fi adapter that has a saved profile but is disconnected ---
Write-Host "[2/7] Connecting any disconnected USB Wi-Fi adapters with saved profiles ..." -ForegroundColor Green
$usbDown = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -ne 'Up' -and $_.PnPDeviceID -like 'USB\*'
})
foreach ($a in $usbDown) {
    $ifname = $a.Name
    $raw = netsh wlan show profiles interface="$ifname" 2>$null
    $profiles = @()
    foreach ($ln in $raw) {
        if ($ln -match 'User Profile\s+:\s+(.+)$') { $profiles += $Matches[1].Trim() }
    }
    if ($profiles.Count -eq 0) {
        Write-Host "      $ifname : no saved profile, skipping" -ForegroundColor DarkGray
        continue
    }
    $target = $profiles[0]
    Write-Host "      $ifname : connecting to '$target' ..." -ForegroundColor DarkGray
    cmd.exe /c "netsh wlan connect name=`"$target`" interface=`"$ifname`"" | Out-Null
}
Start-Sleep 8
Write-Host "      done (adapters may still associate in background)" -ForegroundColor DarkGreen

# --- 3. Kill stale 3proxy / ssh / tunnel-loop ---
Write-Host "[3/7] Killing stale 3proxy / ssh / tunnel-loop processes ..." -ForegroundColor Green
cmd.exe /c "taskkill /F /IM 3proxy.exe >nul 2>&1"
cmd.exe /c "taskkill /F /IM ssh.exe >nul 2>&1"
Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*tunnel-loop.bat*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1
Write-Host "      OK" -ForegroundColor DarkGreen

# --- 4. Re-register scheduled task: ONSTART, run-whether-logged-on-or-not ---
Write-Host "[4/7] Re-registering 'ProxyFarm' task (ONSTART, stored cred) ..." -ForegroundColor Green
cmd.exe /c "schtasks /delete /tn ProxyFarm /f >nul 2>&1"
$schCmd = "schtasks /create /tn ProxyFarm /tr `"$DEST\start-all.bat`" /sc ONSTART /ru `"$user`" /rp `"$plain`" /rl HIGHEST /delay 0001:30 /f"
cmd.exe /c $schCmd | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "      ONSTART failed - falling back to At-Logon" -ForegroundColor Yellow
    cmd.exe /c "schtasks /create /tn ProxyFarm /tr `"$DEST\start-all.bat`" /sc ONLOGON /ru `"$user`" /rp `"$plain`" /rl HIGHEST /f" | Out-Null
}
Write-Host "      OK" -ForegroundColor DarkGreen

# --- 5. Enable Windows auto-login ---
Write-Host "[5/7] Enabling Windows auto-login for '$user' ..." -ForegroundColor Green
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon'  -Value '1'    -Force
Set-ItemProperty -Path $winlogon -Name 'DefaultUserName' -Value $user  -Force
Set-ItemProperty -Path $winlogon -Name 'DefaultPassword' -Value $plain -Force
try { Set-ItemProperty -Path $winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Force } catch {}
try { Set-ItemProperty -Path $winlogon -Name 'AutoLogonCount'    -Value 0 -Force } catch {}
Write-Host "      OK" -ForegroundColor DarkGreen

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
Write-Host "      $($profiles.Count) profile(s) set to auto-connect" -ForegroundColor DarkGreen

$plain = $null
[gc]::Collect()

# --- 7. Kick a fresh run so the clean dynamic config is live ---
Write-Host "[7/7] Starting proxy-farm with fresh dynamic config ..." -ForegroundColor Green
Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$DEST\start-all.bat`"" -WindowStyle Hidden
Start-Sleep 6
$p3 = @(Get-Process 3proxy -ErrorAction SilentlyContinue)
$ps = @(Get-Process ssh     -ErrorAction SilentlyContinue)
Write-Host "      3proxy processes: $($p3.Count)   ssh processes: $($ps.Count)" -ForegroundColor DarkGreen

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Done." -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Verify now:"
Write-Host "    Get-NetAdapter -Physical | ft Name,Status,MacAddress"
Write-Host "    Get-Process 3proxy, ssh"
Write-Host "    Get-Content C:\proxy-farm\logs\start.log -Tail 30"
Write-Host ""
Write-Host "  Test reboot-persistence:"
Write-Host "    - Reboot, do NOT log in, wait 3 min."
Write-Host "    - On VPS: ss -tlnp | grep -E ':40001|:40002'"
Write-Host ""
Read-Host "Press Enter to close"
