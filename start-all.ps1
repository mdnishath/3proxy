# =================================================================
# ClientFlow Proxy Farm - dynamic start (auto-detect USB adapters)
#
# On every run:
#   1. Wait briefly for network
#   2. Enumerate all UP USB Wi-Fi adapters with a real IPv4
#      (PCI/built-in Intel AX201 is excluded - used only as SSH
#       uplink / connectivity backup, never as proxy egress)
#   3. Use a stable MAC -> slot map (config\adapters.json) so each
#      adapter always gets the same ports across reboots
#      - slot N -> local SOCKS 51080+N, VPS tunnel 40000+N
#   4. Auto-generate a 3proxy passwd entry for any new slot and
#      log the credential to logs\new-router-creds.txt (copy to VPS)
#   5. Regenerate config\3proxy.cfg wholesale
#   6. Launch 3proxy + one tunnel-loop per active adapter, both
#      hidden via Start-Process -WindowStyle Hidden.
#
# Add a new USB Wi-Fi / pocket router -> reboot (or re-run this
# script) and a new slot is assigned automatically. Old adapters
# keep their slot even if ifIndex changes.  The preferred-slot
# override block near the top-ish "canonical slot overrides"
# section is the place to hardcode MAC -> slot bindings for a
# specific laptop (on this one: Wi-Fi 2 -> slot 1, Wi-Fi 4 -> slot 2).
# =================================================================

$ErrorActionPreference = 'Continue'
$DEST            = 'C:\proxy-farm'
$VPS             = '144.79.218.148'
$LOCAL_PORT_BASE = 51080
$VPS_PORT_BASE   = 40000
$LOG             = "$DEST\logs\start.log"
$MAP             = "$DEST\config\adapters.json"
$PASSWD          = "$DEST\config\passwd"
$CFG_PATH        = "$DEST\config\3proxy.cfg"
$NEWCREDS        = "$DEST\logs\new-router-creds.txt"
$RUN_HIDDEN      = "$DEST\run-hidden.vbs"

New-Item -ItemType Directory -Force -Path "$DEST\logs" | Out-Null
function Log([string]$m) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$ts] $m" | Out-File -Encoding ASCII -Append -FilePath $LOG
}

Log "=== start-all.ps1 invoked ==="

# --- lock down SSH private key (OpenSSH refuses keys readable by 'Users') ---
$KEY = "$DEST\keys\panel_id_ed25519"
if (Test-Path $KEY) {
    $acl = (icacls $KEY 2>&1 | Out-String)
    if ($acl -match 'Utilisateurs|\\Users:|BUILTIN\\Users') {
        Log "locking down $KEY (was world-readable)"
        cmd.exe /c "icacls `"$KEY`" /inheritance:r >nul 2>&1"
        cmd.exe /c "icacls `"$KEY`" /grant:r `"$env:USERNAME`":R >nul 2>&1"
        cmd.exe /c "icacls `"$KEY`" /grant:r `"SYSTEM`":R >nul 2>&1"
    }
}

# --- helper: USB Wi-Fi adapter with valid (non-APIPA) IPv4? ---
function Get-UsbWifiWithIp {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and
        $_.PnPDeviceID -like 'USB\*' -and
        ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|Realtek|TP-Link|Edimax|Mediatek|Ralink|Atheros') -and
        ($_.InterfaceDescription -notmatch 'Ethernet|GbE Family|PCIe GbE')
    } | ForEach-Object {
        $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notmatch '^169\.254' -and $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1).IPAddress
        if ($ip) {
            [PSCustomObject]@{
                MAC         = $_.MacAddress
                Name        = $_.Name
                Description = $_.InterfaceDescription
                IP          = $ip
            }
        }
    }
}

# --- wait up to 120s for at least one USB Wi-Fi with valid IPv4 ---
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    $have = @(Get-UsbWifiWithIp)
    if ($have.Count -ge 1) { break }
    Start-Sleep 3
}
Log "network wait complete"

# --- kill stale processes (task runs elevated, so we can kill prior elevated procs) ---
Get-Process 3proxy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process ssh     -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# kill any orphaned tunnel-loop cmd.exe (including broken empty-arg ones that write tunnel-.log)
Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*tunnel-loop*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1

# --- detect egress-eligible USB Wi-Fi adapters ---
$detected = @(Get-UsbWifiWithIp)

if ($detected.Count -eq 0) {
    Log "ERROR: no USB Wi-Fi adapters with valid IPv4 detected - exiting"
    exit 1
}

Log "detected $($detected.Count) USB Wi-Fi adapter(s):"
foreach ($d in $detected) { Log "  MAC=$($d.MAC) IP=$($d.IP) name=$($d.Name) desc=$($d.Description)" }

# --- load stable MAC -> slot map (preserve prior slots across reboots) ---
$map = @{}
if (Test-Path $MAP) {
    try {
        $raw = Get-Content $MAP -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $map[$p.Name] = [int]$p.Value }
    } catch { Log "WARN: could not parse $MAP, starting fresh" }
}
# --- prune stale entries: drop any MAC that is NOT currently detected ---
# Rationale: adapters the user has retired (or excluded from egress, like the
# Intel PCI one) stick around otherwise and skew new-slot assignment.
$detectedMacs = @($detected | ForEach-Object { $_.MAC })
$stale = @($map.Keys | Where-Object { $detectedMacs -notcontains $_ })
foreach ($m in $stale) {
    Log "pruning stale map entry: $m -> $($map[$m])"
    $map.Remove($m) | Out-Null
}

# --- canonical slot overrides for this specific laptop ---
# If a detected USB adapter matches a known preferred MAC, force its slot.
# This makes reboots idempotent even when the on-disk map drifts.
$preferred = @{
    '00-E0-4C-5D-88-0F' = 1  # Wi-Fi 2 (Realtek 8811CU) -> ALTICE_DDC54
    '00-E0-4C-5D-89-33' = 2  # Wi-Fi 4 (Realtek 8811CU #2) -> ALTICE_DDCCD4
}
foreach ($d in $detected) {
    if ($preferred.ContainsKey($d.MAC)) {
        $want = [int]$preferred[$d.MAC]
        if ($map[$d.MAC] -ne $want) {
            Log "forcing preferred slot: $($d.MAC) -> slot $want (was $($map[$d.MAC]))"
            $map[$d.MAC] = $want
        }
    }
}

$used = @($map.Values | ForEach-Object { [int]$_ })
function Get-NextSlot([int[]]$used) {
    $n = 1
    while ($used -contains $n) { $n++ }
    return $n
}

foreach ($d in $detected) {
    if (-not $map.ContainsKey($d.MAC)) {
        $slot = Get-NextSlot $used
        $map[$d.MAC] = $slot
        $used += $slot
        Log "new adapter MAC=$($d.MAC) ($($d.Description)) assigned slot $slot"
    }
}

# persist map
$map | ConvertTo-Json | Out-File -Encoding ASCII -FilePath $MAP

# --- build active list (only currently-present adapters) ---
$active = @()
foreach ($d in $detected) {
    $slot = [int]$map[$d.MAC]
    $active += [PSCustomObject]@{
        Slot        = $slot
        MAC         = $d.MAC
        IP          = $d.IP
        Name        = $d.Name
        Description = $d.Description
        LocalPort   = $LOCAL_PORT_BASE + $slot
        VpsPort     = $VPS_PORT_BASE + $slot
        User        = "router$slot"
    }
}
$active = $active | Sort-Object Slot

# --- ensure passwd has an entry per active router; autogen if missing ---
$passwdMap = [ordered]@{}
if (Test-Path $PASSWD) {
    foreach ($ln in (Get-Content $PASSWD)) {
        if ($ln -match '^\s*([^:]+):[^:]+:.+$') { $passwdMap[$Matches[1]] = $ln.Trim() }
    }
}

$newCreds = @()
foreach ($a in $active) {
    if (-not $passwdMap.Contains($a.User)) {
        $pw = -join ((1..20) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        $passwdMap[$a.User] = "$($a.User):CL:$pw"
        $newCreds += "$($a.User):$pw    (local 127.0.0.1:$($a.LocalPort)  VPS $VPS`:$($a.VpsPort))"
        Log "autogenerated credential for $($a.User)"
    }
}

$passwdMap.Values | Out-File -Encoding ASCII -FilePath $PASSWD
if ($newCreds.Count -gt 0) {
    "=== new credentials generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File -Encoding ASCII -Append $NEWCREDS
    $newCreds                                                                       | Out-File -Encoding ASCII -Append $NEWCREDS
    ""                                                                              | Out-File -Encoding ASCII -Append $NEWCREDS
    Log "new credentials appended to $NEWCREDS - add matching entries on VPS chain"
}

# --- regenerate 3proxy.cfg ---
$cfg = @"
# auto-generated by start-all.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
service
pidfile "$DEST\logs\3proxy.pid"

nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

users `$"$PASSWD"

log "$DEST\logs\3proxy.log" D
logformat "- +_L%t.%.  %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 3
"@

foreach ($a in $active) {
    $cfg += @"


# slot $($a.Slot) - egress via $($a.Description) (IP $($a.IP))
flush
auth strong
allow $($a.User)
socks -p$($a.LocalPort) -a -i127.0.0.1 -e$($a.IP)
"@
}
$cfg | Out-File -Encoding ASCII -NoNewline -FilePath $CFG_PATH
Log "3proxy.cfg regenerated with $($active.Count) listener(s)"

# --- launch 3proxy (hidden) ---
Start-Process -FilePath "$DEST\bin\3proxy.exe" -ArgumentList "`"$CFG_PATH`"" -WindowStyle Hidden
Log "3proxy launched"
Start-Sleep 1

# --- launch tunnel-loops (cmd hidden) ---
# Direct cmd.exe launch - Start-Process -WindowStyle Hidden keeps the console
# off-screen. The earlier wscript/run-hidden.vbs wrapper mangled the args
# (tunnel-loop.bat received empty %1/%2), so we pass args to cmd.exe directly.
foreach ($a in $active) {
    $tArgs = "/c `"`"$DEST\tunnel-loop.bat`" $($a.VpsPort) $($a.LocalPort)`""
    Start-Process -FilePath "cmd.exe" -ArgumentList $tArgs -WindowStyle Hidden
    Log "tunnel slot $($a.Slot): VPS:$($a.VpsPort) -> PC:$($a.LocalPort) ($($a.Description)) launched"
}

# --- rotation agent (optional - only if installed) ---
# Listens on 127.0.0.1:8901 for /rotate /status /rotations/:id /health.
# Reverse-tunnelled to VPS:40101 by a separate tunnel-loop below.
$AGENT_LOCAL_PORT = 8901
$AGENT_VPS_PORT   = 40101
$AGENT_PS1        = "$DEST\agent.ps1"
if (Test-Path $AGENT_PS1) {
    # Kill any orphaned prior agent
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*agent.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    $aArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AGENT_PS1`""
    Start-Process -FilePath "powershell.exe" -ArgumentList $aArgs -WindowStyle Hidden
    Log "rotation agent launched (127.0.0.1:$AGENT_LOCAL_PORT)"

    # Agent reverse tunnel (VPS:40101 -> PC:8901)
    $tArgs = "/c `"`"$DEST\tunnel-loop.bat`" $AGENT_VPS_PORT $AGENT_LOCAL_PORT`""
    Start-Process -FilePath "cmd.exe" -ArgumentList $tArgs -WindowStyle Hidden
    Log "agent tunnel: VPS:$AGENT_VPS_PORT -> PC:$AGENT_LOCAL_PORT launched"
} else {
    Log "rotation agent not installed (no $AGENT_PS1) - skipping agent + agent tunnel"
}

Log "=== startup complete - $($active.Count) slot(s) active ==="
