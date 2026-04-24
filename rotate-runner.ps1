<#
.SYNOPSIS
  Wrapper that writes task state to logs\rotations\<task_id>.json before,
  during, and after calling rotate-router.ps1. Lets the agent track
  rotation progress without keeping an HTTP connection open.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$TaskId,
  [Parameter(Mandatory)][string]$Router,
  [Parameter(Mandatory)][string]$RouterIp,
  [Parameter(Mandatory)][string]$ThroughAdapter,
  [Parameter(Mandatory)][string[]]$OtherAdapters,
  [Parameter(Mandatory)][string]$UsernameHash,
  [Parameter(Mandatory)][string]$PasswordHash
)

$DEST = 'C:\proxy-farm'
$stateDir = "$DEST\logs\rotations"
$stateFile = "$stateDir\$TaskId.json"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Write-State {
  param($State)
  $State | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $stateFile
}

$state = [ordered]@{
  task_id     = $TaskId
  router      = $Router
  started_at  = (Get-Date).ToString('o')
  finished_at = $null
  status      = 'running'
  exit_code   = $null
  output      = @()
}
Write-State $state

try {
  $out = & "$DEST\rotate-router.ps1" `
      -RouterIp       $RouterIp `
      -ThroughAdapter $ThroughAdapter `
      -OtherAdapters  $OtherAdapters `
      -UsernameHash   $UsernameHash `
      -PasswordHash   $PasswordHash 2>&1
  $code = $LASTEXITCODE
  $state.output = @($out | ForEach-Object { $_.ToString() })
  $state.exit_code = $code
  $state.status = if ($code -eq 0) { 'done' } else { 'failed' }
} catch {
  $state.status = 'failed'
  $state.exit_code = -1
  $state.output = @("EXCEPTION: $($_.Exception.Message)")
} finally {
  $state.finished_at = (Get-Date).ToString('o')
  Write-State $state
}
