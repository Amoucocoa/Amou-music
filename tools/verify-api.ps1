<#
.SYNOPSIS
  Smoke-tests every control route. Rendering checks cannot see this layer.

.DESCRIPTION
  "the disc is centred" and "the volume slider does nothing" are independent
  failures, and only one of them shows up on screen. A refactor once turned
  `_read_state` from a module function into a method and missed four call sites
  in the module-level helpers; every control route answered 503 for three days
  while the page rendered perfectly. Nothing in the visual suite could have
  caught it, because the buttons were drawn correctly the whole time.

  So this walks every route the UI can reach. Volume and mute are exercised with
  their CURRENT values, which makes the calls idempotent, and the originals are
  restored in `finally` even if a check throws.

  No browser and no dependencies: run it first, it finishes in about a second.

.PARAMETER Url
  Base URL of a running server.

.EXAMPLE
  pwsh -File tools/verify-api.ps1
#>
[CmdletBinding()]
param([string]$Url = 'http://127.0.0.1:8765/')

$ErrorActionPreference = 'Stop'
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0
$script:Saved = $null

function Assert-That {
  param([bool]$Condition, [string]$Message, [string]$Detail = '')
  $script:Checks++
  if ($Condition) {
    Write-Host "  [PASS] $Message" -ForegroundColor DarkGreen
  } else {
    Write-Host "  [FAIL] $Message $Detail" -ForegroundColor Red
    $script:Failures.Add("$Message | $Detail")
  }
}

function Invoke-Api {
  param([string]$Path, [string]$Method = 'GET', $Body = $null)
  $params = @{ Uri = ($Url.TrimEnd('/') + $Path); Method = $Method; TimeoutSec = 15 }
  if ($Body) { $params.ContentType = 'application/json'; $params.Body = $Body }
  try {
    $r = Invoke-WebRequest @params -UseBasicParsing
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = $r.Content; Type = $r.Headers['Content-Type']; Error = '' }
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    $text = ''
    try { $text = $_.ErrorDetails.Message } catch { }
    # Collapse the body to one line: a JSON error is several lines long, and a
    # multi-line detail turns the failure summary into a wall of text.
    $flat = (($text -replace '\s+', ' ').Trim())
    if ($flat.Length -gt 160) { $flat = $flat.Substring(0, 160) + '...' }
    return [pscustomobject]@{ Status = $code; Body = ''; Type = ''; Error = "$code $flat" }
  }
}

try {
  Write-Host "`nAPI smoke - $Url" -ForegroundColor Cyan

  # --- reads ------------------------------------------------------------
  Write-Host "`n1. Read routes" -ForegroundColor Cyan
  $state = Invoke-Api '/api/state'
  Assert-That ($state.Status -eq 200) 'GET /api/state answers' $state.Error
  $s = $null
  if ($state.Status -eq 200) { $s = $state.Body | ConvertFrom-Json }
  Assert-That ($null -ne $s) 'state is valid JSON'
  foreach ($k in @('volume', 'muted', 'playing', 'device')) {
    Assert-That ($null -ne $s.PSObject.Properties[$k]) "state carries '$k'"
  }
  Assert-That ($s.volume -ge 0 -and $s.volume -le 1) 'volume is in range' "$($s.volume)"

  $out = Invoke-Api '/api/outputs'
  Assert-That ($out.Status -eq 200) 'GET /api/outputs answers' $out.Error

  # --- writes, exercised at their current values ------------------------
  # Same value in, same value out: the call really does traverse the COM path
  # (which is the whole point) but leaves the machine exactly as it found it.
  Write-Host "`n2. Control routes (idempotent, current values)" -ForegroundColor Cyan
  $script:Saved = @{ volume = $s.volume; muted = $s.muted }

  $v = Invoke-Api '/api/volume' 'POST' (@{ value = [double]$s.volume } | ConvertTo-Json -Compress)
  Assert-That ($v.Status -eq 200) 'POST /api/volume reaches the device' $v.Error

  $m = Invoke-Api '/api/mute' 'POST' (@{ muted = [bool]$s.muted } | ConvertTo-Json -Compress)
  Assert-That ($m.Status -eq 200) 'POST /api/mute reaches the device' $m.Error

  # --- artwork ----------------------------------------------------------
  Write-Host "`n3. Cover route" -ForegroundColor Cyan
  $cover = Invoke-Api '/api/cover?song_id=999999999999'
  Assert-That ($cover.Status -eq 404) 'unknown song_id is a 404, not a 500' $cover.Error

  # --- rejections -------------------------------------------------------
  # A malformed request must be refused by validation, never reach the device
  # and die there. A 500 here means the guard was removed.
  Write-Host "`n4. Input validation" -ForegroundColor Cyan
  $bad1 = Invoke-Api '/api/volume' 'POST' '{"value":"loud"}'
  Assert-That ($bad1.Status -eq 400) 'non-numeric volume is rejected with 400' "got $($bad1.Status)"
  $bad2 = Invoke-Api '/api/mute' 'POST' '{}'
  Assert-That ($bad2.Status -eq 400) 'mute without a boolean is rejected with 400' "got $($bad2.Status)"
  $bad3 = Invoke-Api '/api/cover?song_id=../../secret'
  Assert-That ($bad3.Status -eq 400 -or $bad3.Status -eq 404) 'non-numeric song_id is refused' "got $($bad3.Status)"

  # --- state survived ----------------------------------------------------
  $after = Invoke-Api '/api/state'
  $a = $after.Body | ConvertFrom-Json
  Assert-That ([Math]::Abs($a.volume - $s.volume) -lt 0.02) `
      'volume is unchanged by the idempotent call' `
      "$($s.volume) -> $($a.volume)"
  Assert-That ($a.muted -eq $s.muted) 'mute is unchanged by the idempotent call'

  Write-Host ''
  if ($script:Failures.Count -eq 0) {
    Write-Host "PASS - $script:Checks checks" -ForegroundColor Green
    exit 0
  }
  Write-Host "FAIL - $($script:Failures.Count) of $script:Checks checks failed" -ForegroundColor Red
  $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
finally {
  if ($script:Saved) {
    try {
      Invoke-Api '/api/volume' 'POST' (@{ value = [double]$script:Saved.volume } | ConvertTo-Json -Compress) | Out-Null
      Invoke-Api '/api/mute' 'POST' (@{ muted = [bool]$script:Saved.muted } | ConvertTo-Json -Compress) | Out-Null
    } catch { }
  }
}
