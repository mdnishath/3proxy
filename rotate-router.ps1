<#
.SYNOPSIS
  Rotate the 4G IP of one MEIG MT579 pocket router.

.DESCRIPTION
  Logs into the router's admin web UI (/goform/login), toggles the cellular
  data switch off, waits, toggles it back on (forcing a new PDP context with
  fresh IP from the SFR carrier), then logs out.

  Both routers share gateway IP 192.168.60.1 but sit on different Wi-Fi SSIDs.
  Windows picks one route by metric. This script temporarily disables the
  OTHER adapter so 192.168.60.1 traffic reaches the correct router. The other
  adapter is re-enabled in a finally block no matter what happens.

  Requires Administrator (for Disable-/Enable-NetAdapter).

  The login payload contains pre-hashed username/password values because the
  router's JS hashes them client-side before POSTing. Since the plaintext
  credentials are static, the hash is deterministic - capture once via
  DevTools, store in routers.json, reuse forever.

.PARAMETER RouterIp
  Gateway IP, almost always 192.168.60.1.

.PARAMETER ThroughAdapter
  Wi-Fi adapter name connected to THIS router (e.g. "Wi-Fi 2", "Wi-Fi 4").

.PARAMETER OtherAdapters
  One or more Wi-Fi adapter names that must be temporarily disabled (all OTHER
  pocket-router adapters) so 192.168.60.1 traffic is forced through
  $ThroughAdapter. All of them are re-enabled in a finally block.

.PARAMETER UsernameHash
  Pre-hashed username (32 hex) as captured from /goform/login payload.

.PARAMETER PasswordHash
  Pre-hashed password (32 hex) as captured.

.PARAMETER DisconnectWaitSec
  Seconds to wait after disconnect before reconnecting. SFR typically caches
  the IP for 1-5 minutes, so 6-8s teardown is fine but the fresh-IP odds
  improve if we leave it longer.

.PARAMETER ConnectWaitSec
  Seconds to wait after reconnect for DHCP + PDP context to stabilise.

.EXAMPLE
  .\rotate-router.ps1 -RouterIp 192.168.60.1 `
      -ThroughAdapter "Wi-Fi 2" -OtherAdapters @("Wi-Fi 4") `
      -UsernameHash "4cc68e3626e5b94602c325f7c4ca5dee" `
      -PasswordHash "3c8385ad382b48bce6ec06985795ae76"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RouterIp,
  [Parameter(Mandatory)][string]$ThroughAdapter,
  [Parameter(Mandatory)][string[]]$OtherAdapters,
  [Parameter(Mandatory)][string]$UsernameHash,
  [Parameter(Mandatory)][string]$PasswordHash,
  [int]$DisconnectWaitSec = 8,
  [int]$ConnectWaitSec = 15
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Log {
  param([string]$Message, [string]$Color = 'Gray')
  $ts = Get-Date -Format 'HH:mm:ss'
  Write-Host "[$ts] $Message" -ForegroundColor $Color
}

function Invoke-RouterApi {
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    $Body = $null
  )
  $url = "http://$RouterIp$Path"
  $iwrArgs = @{
    Uri              = $url
    Method           = $Method
    WebSession       = $Session
    ContentType      = 'application/json'
    TimeoutSec       = 15
    UseBasicParsing  = $true
    Headers          = @{
      'Accept'           = 'application/json, text/javascript, */*; q=0.01'
      'Referer'          = "http://$RouterIp/html/settings.html"
      'X-Requested-With' = 'XMLHttpRequest'
    }
  }
  if ($null -ne $Body) {
    $iwrArgs.Body = ($Body | ConvertTo-Json -Compress)
  }
  return Invoke-WebRequest @iwrArgs
}

$disabledNames = @()

try {
  Log "rotate-router: router=$RouterIp through='$ThroughAdapter' others='$($OtherAdapters -join ",")'" Cyan

  # 1. Disable all OTHER adapters so 192.168.60.1 routes through $ThroughAdapter
  foreach ($nm in $OtherAdapters) {
    if (-not $nm) { continue }
    $a = Get-NetAdapter -Name $nm -ErrorAction SilentlyContinue
    if ($a -and $a.Status -eq 'Up') {
      Log "Disabling '$nm' so routing follows '$ThroughAdapter'" Yellow
      Disable-NetAdapter -Name $nm -Confirm:$false
      $disabledNames += $nm
    } else {
      Log "'$nm' is already down or not present - skipping" DarkGray
    }
  }
  if ($disabledNames.Count -gt 0) { Start-Sleep -Seconds 3 }

  # 2. Verify $ThroughAdapter is Up with an IP
  $through = Get-NetAdapter -Name $ThroughAdapter -ErrorAction Stop
  if ($through.Status -ne 'Up') {
    throw "Through-adapter '$ThroughAdapter' is not Up (status=$($through.Status))"
  }

  # 3. Login
  Log "Logging in to $RouterIp ..." Cyan
  $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  $loginBody = @{ username = $UsernameHash; password = $PasswordHash }
  $loginResp = Invoke-RouterApi -Session $session -Method 'POST' -Path '/goform/login' -Body $loginBody
  Log "  login HTTP=$($loginResp.StatusCode) body=$($loginResp.Content)" DarkGray

  # 4. Disconnect (dialup_dataswitch = off)
  Log "Disconnecting 4G (dialup_dataswitch=off)" Yellow
  $offResp = Invoke-RouterApi -Session $session -Method 'POST' -Path '/action/dialup_set_dataswitch' `
      -Body @{ dialup_dataswitch = 'off'; dialup_roamswitch = 'off' }
  Log "  disconnect HTTP=$($offResp.StatusCode) body=$($offResp.Content)" DarkGray

  Log "Waiting ${DisconnectWaitSec}s for carrier teardown ..." DarkGray
  Start-Sleep -Seconds $DisconnectWaitSec

  # 5. Reconnect (dialup_dataswitch = on)
  Log "Reconnecting 4G (dialup_dataswitch=on)" Green
  $onResp = Invoke-RouterApi -Session $session -Method 'POST' -Path '/action/dialup_set_dataswitch' `
      -Body @{ dialup_dataswitch = 'on'; dialup_roamswitch = 'off' }
  Log "  connect HTTP=$($onResp.StatusCode) body=$($onResp.Content)" DarkGray

  Log "Waiting ${ConnectWaitSec}s for new PDP context ..." DarkGray
  Start-Sleep -Seconds $ConnectWaitSec

  # 6. Best-effort logout
  try {
    Invoke-RouterApi -Session $session -Method 'POST' -Path '/action/logout' | Out-Null
    Log "Logged out" DarkGray
  } catch {
    Log "Logout failed (non-fatal): $($_.Exception.Message)" DarkYellow
  }

  Log "Rotation complete." Green
  exit 0

} catch {
  Log "ROTATION FAILED: $($_.Exception.Message)" Red
  exit 1
} finally {
  # Re-enable all adapters we disabled
  foreach ($nm in $disabledNames) {
    Log "Re-enabling '$nm'" Cyan
    try {
      Enable-NetAdapter -Name $nm -Confirm:$false
    } catch {
      Log "Re-enable of '$nm' failed: $($_.Exception.Message)" Red
    }
  }

  if ($disabledNames.Count -gt 0) {
    # Give the radio + supplicant time to come back. Driver init alone is ~3-4s.
    Start-Sleep -Seconds 6

    # For each previously-disabled adapter, if it isn't connected, force-attach
    # it to the saved Wi-Fi profile. After Disable/Enable, Windows often loses
    # the SSID association and just sits in Disconnected limbo.
    foreach ($nm in $disabledNames) {
      $a = Get-NetAdapter -Name $nm -ErrorAction SilentlyContinue
      if (-not $a) { continue }
      if ($a.Status -eq 'Up') {
        Log "'$nm' came back Up on its own" DarkGreen
        continue
      }
      # Find any saved profile attached to this interface
      $raw = netsh wlan show profiles interface="$nm" 2>$null
      $profile = $null
      foreach ($ln in $raw) {
        if ($ln -match 'User Profile\s+:\s+(.+)$') { $profile = $matches[1].Trim(); break }
      }
      if (-not $profile) {
        Log "'$nm' has no saved Wi-Fi profile - cannot auto-reconnect" Red
        continue
      }
      Log "Force-connecting '$nm' to '$profile' ..." Yellow
      cmd.exe /c "netsh wlan connect name=`"$profile`" interface=`"$nm`"" | Out-Null
    }

    # Final wait + status report. We don't fail the rotation if reconnect
    # is slow - the IP rotation itself succeeded; the OS just needs more time.
    Start-Sleep -Seconds 8
    foreach ($nm in $disabledNames) {
      $a = Get-NetAdapter -Name $nm -ErrorAction SilentlyContinue
      if ($a) { Log "'$nm' final status: $($a.Status)" Cyan }
    }
  }
}
