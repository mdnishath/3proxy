<#
.SYNOPSIS
  ClientFlow Proxy Farm - local HTTP control agent.

.DESCRIPTION
  Listens on 127.0.0.1:8901 and accepts admin commands from the panel
  (which reaches the PC via a reverse SSH tunnel on VPS port 40101).
  Authentication = shared secret in the X-Agent-Secret header, read from
  C:\proxy-farm\keys\agent-secret.txt.

  Endpoints:
    POST /rotate        body: { "router": "1" }            - start rotation (async)
    GET  /rotations/:id                                    - poll state json
    GET  /status                                           - adapters + cooldowns
    GET  /health                                           - simple liveness

  Rotations fire and forget - rotate-runner.ps1 is spawned detached and
  writes progress to logs\rotations\<task_id>.json. The panel polls
  /rotations/:id until status is 'done' or 'failed'.

  Per-router config (adapter names, hashed creds) lives in
  C:\proxy-farm\config\routers.json. See routers.json.example.
#>

[CmdletBinding()]
param(
  [string]$Listen = 'http://127.0.0.1:8901/',
  [int]$CooldownSec = 600  # 10 min - SFR carrier cache would hand out the same IP anyway
)

$ErrorActionPreference = 'Continue'
$DEST          = 'C:\proxy-farm'
$LOG           = "$DEST\logs\agent.log"
$SECRET_FILE   = "$DEST\keys\agent-secret.txt"
$ROUTERS_FILE  = "$DEST\config\routers.json"
$ADAPTERS_FILE = "$DEST\config\adapters.json"
$RUNNER        = "$DEST\rotate-runner.ps1"
$STATE_DIR     = "$DEST\logs\rotations"

New-Item -ItemType Directory -Force -Path (Split-Path $LOG -Parent) | Out-Null
New-Item -ItemType Directory -Force -Path $STATE_DIR                | Out-Null

function Log {
  param([string]$Msg)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts] $Msg"
  Write-Host $line
  try { Add-Content -Path $LOG -Value $line -ErrorAction SilentlyContinue } catch {}
}

# --- Load shared secret ---
if (-not (Test-Path $SECRET_FILE)) {
  Log "FATAL: shared-secret file missing at $SECRET_FILE"
  exit 1
}
$SECRET = ((Get-Content $SECRET_FILE -Raw -ErrorAction Stop) -as [string]).Trim()
if (-not $SECRET) { Log "FATAL: $SECRET_FILE is empty"; exit 1 }

# --- Start listener ---
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Listen)
try {
  $listener.Start()
} catch {
  Log "FATAL: cannot bind listener to $Listen : $($_.Exception.Message)"
  exit 1
}
Log "agent listening on $Listen (cooldown=${CooldownSec}s)"

# Per-router cooldown: router-key -> DateTime of last rotation start
$script:cooldown = @{}

function Send-Json {
  param($Response, [int]$Status, $Obj)
  $Response.StatusCode = $Status
  $Response.ContentType = 'application/json'
  $json = $Obj | ConvertTo-Json -Depth 10 -Compress
  $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Response.ContentLength64 = $buf.Length
  try {
    $Response.OutputStream.Write($buf, 0, $buf.Length)
  } catch {
    Log "WARN: could not write response: $($_.Exception.Message)"
  } finally {
    $Response.OutputStream.Close()
  }
}

function Read-Body {
  param($Request)
  if (-not $Request.HasEntityBody) { return '' }
  $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
  $body = $reader.ReadToEnd()
  $reader.Close()
  return $body
}

function Get-AdapterStatus {
  $adapters = @()
  $list = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|USB|802\.11' } |
    Sort-Object ifIndex
  foreach ($a in $list) {
    $ip = $null
    try {
      $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notmatch '^169\.254' -and $_.IPAddress -ne '127.0.0.1' } |
             Select-Object -First 1).IPAddress
    } catch {}
    $adapters += [ordered]@{
      name   = $a.Name
      status = $a.Status.ToString()
      mac    = $a.MacAddress
      ip     = $ip
    }
  }
  return $adapters
}

# Resolve { adapter, other_adapters } for a given slot number by joining
# adapters.json (MAC -> slot) with the currently-connected USB Wi-Fi adapters.
# Returns $null if no connected adapter maps to the requested slot.
function Resolve-SlotAdapters {
  param([Parameter(Mandatory)][string]$Slot)

  if (-not (Test-Path $ADAPTERS_FILE)) {
    throw "adapters.json missing at $ADAPTERS_FILE"
  }
  $map = Get-Content $ADAPTERS_FILE -Raw | ConvertFrom-Json

  # Build MAC -> adapter-name table for currently-Up USB Wi-Fi adapters
  $usb = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -eq 'Up' -and
    $_.PnPDeviceID -like 'USB\*' -and
    ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|Realtek|TP-Link|Edimax|Mediatek|Ralink|Atheros')
  }
  $macToName = @{}
  foreach ($a in $usb) { $macToName[$a.MacAddress] = $a.Name }

  # Find MAC(s) assigned to this slot, and collect OTHER-slot MACs
  $thisMacs  = @()
  $otherMacs = @()
  foreach ($p in $map.PSObject.Properties) {
    if ([string]$p.Value -eq [string]$Slot) { $thisMacs += $p.Name }
    else                                    { $otherMacs += $p.Name }
  }

  # Names of currently-connected adapters for this slot (usually exactly 1)
  $throughNames = @($thisMacs | Where-Object { $macToName.ContainsKey($_) } | ForEach-Object { $macToName[$_] })
  if ($throughNames.Count -eq 0) { return $null }

  $otherNames = @($otherMacs | Where-Object { $macToName.ContainsKey($_) } | ForEach-Object { $macToName[$_] })

  return [pscustomobject]@{
    Adapter       = $throughNames[0]
    OtherAdapters = $otherNames
  }
}

function Handle-Request {
  param($Context)
  $req = $Context.Request
  $res = $Context.Response
  $path   = $req.Url.AbsolutePath
  $method = $req.HttpMethod

  Log "$method $path from $($req.RemoteEndPoint)"

  # Health endpoint is unauthenticated
  if ($method -eq 'GET' -and $path -eq '/health') {
    Send-Json $res 200 @{ ok = $true; now = (Get-Date).ToString('o') }
    return
  }

  # Everything else needs the shared secret
  $client = $req.Headers['X-Agent-Secret']
  if ($client -ne $SECRET) {
    Log "  rejected: bad/missing X-Agent-Secret"
    Send-Json $res 401 @{ error = 'unauthorized' }
    return
  }

  # --- GET /status ---
  if ($method -eq 'GET' -and $path -eq '/status') {
    $cooldowns = @{}
    foreach ($k in $script:cooldown.Keys) {
      $cooldowns[$k] = @{
        last_start_at = ([datetime]$script:cooldown[$k]).ToString('o')
        ready_at      = ([datetime]$script:cooldown[$k]).AddSeconds($CooldownSec).ToString('o')
      }
    }
    Send-Json $res 200 @{
      ok        = $true
      now       = (Get-Date).ToString('o')
      adapters  = Get-AdapterStatus
      cooldowns = $cooldowns
    }
    return
  }

  # --- GET /rotations/<id> ---
  if ($method -eq 'GET' -and $path -match '^/rotations/([A-Za-z0-9_\-]+)$') {
    $taskId = $matches[1]
    $file = Join-Path $STATE_DIR "$taskId.json"
    if (-not (Test-Path $file)) {
      Send-Json $res 404 @{ error = 'task not found'; task_id = $taskId }
      return
    }
    $state = Get-Content $file -Raw | ConvertFrom-Json
    Send-Json $res 200 $state
    return
  }

  # --- POST /rotate ---
  if ($method -eq 'POST' -and $path -eq '/rotate') {
    $body = Read-Body $req
    try { $data = $body | ConvertFrom-Json } catch {
      Send-Json $res 400 @{ error = 'invalid json'; body = $body }
      return
    }
    $routerKey = [string]$data.router
    if (-not $routerKey) {
      Send-Json $res 400 @{ error = 'missing "router" field' }
      return
    }

    if (-not (Test-Path $ROUTERS_FILE)) {
      Send-Json $res 500 @{ error = "routers.json missing at $ROUTERS_FILE" }
      return
    }
    $routers = Get-Content $ROUTERS_FILE -Raw | ConvertFrom-Json
    $cfg = $routers.$routerKey
    if (-not $cfg) {
      Send-Json $res 400 @{ error = "no config for router '$routerKey' in routers.json" }
      return
    }
    if (-not $cfg.username_hash -or -not $cfg.password_hash -or
        $cfg.username_hash -like 'REPLACE_ME*' -or $cfg.password_hash -like 'REPLACE_ME*') {
      Send-Json $res 400 @{ error = "routers.json has placeholder creds for router '$routerKey' - capture hashes from DevTools and fill in" }
      return
    }

    # Dynamically resolve the adapter names for this slot via adapters.json.
    # This way the rotation tracks the current adapter even if USB dongles get
    # reshuffled between reboots (MAC -> slot is stable, name is not).
    $adapterInfo = $null
    try { $adapterInfo = Resolve-SlotAdapters -Slot $routerKey } catch {
      Send-Json $res 500 @{ error = "adapter resolve failed: $($_.Exception.Message)" }
      return
    }
    if ($null -eq $adapterInfo) {
      Send-Json $res 400 @{ error = "no currently-connected USB adapter is mapped to slot '$routerKey' (check adapters.json vs plugged-in dongles)" }
      return
    }

    # Cooldown gate
    if ($script:cooldown.ContainsKey($routerKey)) {
      $last = [datetime]$script:cooldown[$routerKey]
      $elapsed = ([datetime]::Now - $last).TotalSeconds
      if ($elapsed -lt $CooldownSec) {
        $remain = [int]($CooldownSec - $elapsed)
        Send-Json $res 429 @{
          error             = 'cooldown'
          seconds_remaining = $remain
          router            = $routerKey
        }
        return
      }
    }

    # Allocate task id, mark cooldown, spawn runner detached
    $taskId = "r{0}-{1}" -f $routerKey, ([int][double]::Parse((Get-Date -UFormat %s)))
    $script:cooldown[$routerKey] = [datetime]::Now

    # Build runner args. OtherAdapters is an array param — we have to join for
    # the command line and pass through a PowerShell -Command invocation so the
    # array survives.
    $others = @($adapterInfo.OtherAdapters)
    $routerIp = $cfg.router_ip; if (-not $routerIp) { $routerIp = '192.168.60.1' }

    $quotedOthers = if ($others.Count -gt 0) {
      ($others | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    } else { "@()" }

    # We use -Command with a direct invocation because -File doesn't bind
    # string[] array params correctly from CLI.
    $innerCmd = @"
& '$RUNNER' -TaskId '$taskId' -Router '$routerKey' -RouterIp '$routerIp' ``
    -ThroughAdapter '$($adapterInfo.Adapter)' -OtherAdapters @($quotedOthers) ``
    -UsernameHash '$($cfg.username_hash)' -PasswordHash '$($cfg.password_hash)'
"@
    $runnerArgs = @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-Command', $innerCmd
    )
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList $runnerArgs `
        -WindowStyle Hidden `
        -PassThru

    Log "  spawned runner pid=$($proc.Id) task=$taskId slot=$routerKey through='$($adapterInfo.Adapter)' others='$($others -join ",")'"
    Send-Json $res 202 @{
      ok             = $true
      task_id        = $taskId
      router         = $routerKey
      adapter        = $adapterInfo.Adapter
      other_adapters = $others
      pid            = $proc.Id
      started_at     = (Get-Date).ToString('o')
      cooldown_until = ([datetime]::Now).AddSeconds($CooldownSec).ToString('o')
    }
    return
  }

  Send-Json $res 404 @{ error = 'not found'; method = $method; path = $path }
}

# --- Main loop ---
try {
  while ($listener.IsListening) {
    $ctx = $null
    try {
      $ctx = $listener.GetContext()
      Handle-Request -Context $ctx
    } catch {
      Log "ERROR in request loop: $($_.Exception.Message)"
      if ($ctx) {
        try { Send-Json $ctx.Response 500 @{ error = 'internal' } } catch {}
      }
    }
  }
} finally {
  try { $listener.Stop(); $listener.Close() } catch {}
  Log "agent listener stopped"
}
