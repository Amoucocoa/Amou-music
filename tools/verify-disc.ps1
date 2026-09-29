<#
.SYNOPSIS
  Verifies that the spinning disc in the player UI is visually centred.

.DESCRIPTION
  "The disc looks off-centre while it spins" has two unrelated root causes, and
  only one of them is geometry - so this checks both, separately.

    GEOMETRY
      The disc element is not actually centred in the sleeve, or drifts while
      it turns. Measured by differencing a frame against a baseline captured
      with the disc hidden: the disc mask must be a circle of constant size
      whose centre sits on the sleeve centre in EVERY sampled phase.

    PERCEIVED OFFSET
      The disc is dead centre but LOOKS like it slides around, because an
      asymmetric box-shadow rides the rotation and orbits the dark mass once
      per turn. Invisible to any geometry probe. Asserted twice: statically, by
      requiring every box-shadow layer on the rotating elements to have a zero
      x/y offset; and dynamically, by requiring the shadow centroid to stay put
      across phases.

  Pixel work needs a flat light backdrop - the page background is an animated
  fluid gradient showing through a translucent sleeve, which contaminates any
  difference image. That fixture is injected at runtime and never touches the
  product.

.PARAMETER Url
  Page under test. The server re-reads web/index.html per request, so a front
  end change needs no restart.

.EXAMPLE
  pwsh -File tools/verify-disc.ps1
#>
[CmdletBinding()]
param(
  [string]$Url = 'http://127.0.0.1:8765/',
  [int]$Frames = 4,
  [int]$IntervalMs = 1000,
  [double]$MaxDiscOffsetPx = 1.0,
  [double]$MaxShadowWanderPx = 6.0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0

function Assert-That {
  param([bool]$Condition, [string]$Message, [string]$Detail = '')
  $script:Checks++
  if ($Condition) {
    Write-Host "  [PASS] $Message" -ForegroundColor DarkGreen
  } else {
    Write-Host "  [FAIL] $Message $Detail" -ForegroundColor Red
    $script:Failures.Add($Message)
  }
}

function Invoke-Cli {
  param([string[]]$CliArgs)
  return (& npx --yes '@playwright/cli@latest' @CliArgs 2>&1 | Out-String)
}

function Invoke-Eval {
  param([string]$Body)
  $raw = Invoke-Cli @('--raw', 'eval', $Body)
  $line = ($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
  if (-not $line) { throw "eval returned nothing: $raw" }
  return (($line.Trim() | ConvertFrom-Json) | ConvertFrom-Json)
}

$JS_PROBE = "function(){function r(s){var e=document.querySelector(s);if(!e)return null;var c=getComputedStyle(e);var m=new DOMMatrix(c.transform);return{tx:m.e,ty:m.f,ang:Math.atan2(m.b,m.a)*180/Math.PI,org:c.transformOrigin,side:e.offsetWidth,sh:c.boxShadow};}return JSON.stringify({cover:r('.art-cover'),vinyl:r('.vinyl'),rm:matchMedia('(prefers-reduced-motion: reduce)').matches});}"
$JS_FLAT = "function(){var s=document.createElement('style');s.id='qa-flat';s.textContent='html,body{background:#e9ecef !important;}.backdrop,svg,#water,.water{display:none !important;}';document.head.appendChild(s);return JSON.stringify({r:'flat'});}"
$JS_HIDE = "function(){document.querySelector('.art-cover').style.visibility='hidden';document.querySelector('.vinyl').style.visibility='hidden';return JSON.stringify({r:'hidden'});}"
$JS_SHOW = "function(){document.querySelector('.art-cover').style.visibility='';document.querySelector('.vinyl').style.visibility='';return JSON.stringify({r:'shown'});}"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('verify-disc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[System.IO.Directory]::CreateDirectory($work) | Out-Null

try {
  Write-Host "`nDisc centring verification - $Url" -ForegroundColor Cyan

  Invoke-Cli @('goto', $Url) | Out-Null
  Start-Sleep -Seconds 3

  Write-Host "`n1. Transform contract" -ForegroundColor Cyan
  $probe = Invoke-Eval $JS_PROBE

  foreach ($pair in @(@('cover', $probe.cover), @('vinyl', $probe.vinyl))) {
    $name = $pair[0]; $d = $pair[1]
    if (-not $d) { Assert-That $false ".$name exists"; continue }
    Assert-That ([Math]::Abs($d.tx) -lt 0.5 -and [Math]::Abs($d.ty) -lt 0.5) `
      ".$name transform carries no translation" "got ($($d.tx), $($d.ty))"
    $parts = $d.org -split ' '
    $ox = [double]($parts[0] -replace 'px', '')
    $oy = [double]($parts[1] -replace 'px', '')
    $half = $d.side / 2.0
    Assert-That ([Math]::Abs($ox - $half) -lt 0.6 -and [Math]::Abs($oy - $half) -lt 0.6) `
      ".$name turns about its own centre" "origin ($ox, $oy) vs half-side $half"
    $skewed = @()
    foreach ($pair in [regex]::Matches($d.sh, 'rgba?\([^)]*\)\s+(-?[\d.]+)px\s+(-?[\d.]+)px')) {
      if ([Math]::Abs([double]$pair.Groups[1].Value) -gt 0.001 -or [Math]::Abs([double]$pair.Groups[2].Value) -gt 0.001) {
        $skewed += $pair.Value
      }
    }
    Assert-That ($skewed.Count -eq 0) `
      ".$name box-shadow is radially symmetric" "offset layer(s): $($skewed -join ', ')"
  }
  if (-not $probe.rm) {
    $parity = [Math]::Abs($probe.cover.ang - $probe.vinyl.ang)
    $parity = [Math]::Min($parity, 360 - $parity)
    Assert-That ($parity -lt 0.5) 'cover and vinyl turn in phase' "delta $([Math]::Round($parity, 2)) deg"
  }

  Write-Host "`n2. Pixel measurement" -ForegroundColor Cyan
  if ($probe.rm) {
    Write-Host "  [SKIP] prefers-reduced-motion is on; the disc does not turn." -ForegroundColor Yellow
    Write-Host "`nPASS - $script:Checks checks (rotation checks skipped)." -ForegroundColor Green
    exit 0
  }

  Invoke-Eval $JS_FLAT | Out-Null
  Invoke-Eval $JS_HIDE | Out-Null
  Start-Sleep -Milliseconds 200
  $basePath = Join-Path $work 'baseline.png'
  Invoke-Cli @('screenshot', '#artFrame', '--filename', $basePath) | Out-Null
  Invoke-Eval $JS_SHOW | Out-Null

  $framePaths = @()
  for ($i = 1; $i -le $Frames; $i++) {
    $p = Join-Path $work ("frame-$i.png")
    Invoke-Cli @('screenshot', '#artFrame', '--filename', $p) | Out-Null
    $framePaths += $p
    Start-Sleep -Milliseconds $IntervalMs
  }

  $base = [System.Drawing.Bitmap]::FromFile($basePath)
  $cx = $base.Width / 2.0
  $cy = $base.Height / 2.0
  Write-Host ("  sleeve {0}x{1}px, centre ({2:N1},{3:N1})" -f $base.Width, $base.Height, $cx, $cy) -ForegroundColor DarkGray
  $offsets = @(); $widths = @(); $heights = @(); $shadowX = @(); $shadowY = @()

  foreach ($p in $framePaths) {
    $bmp = [System.Drawing.Bitmap]::FromFile($p)
    $dxS = 0.0; $dyS = 0.0; $dxN = 0
    $shX = 0.0; $shY = 0.0; $shN = 0
    $minX = 99999; $maxX = -1; $minY = 99999; $maxY = -1
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y); $q = $base.GetPixel($x, $y)
        if (([Math]::Abs($c.R - $q.R) + [Math]::Abs($c.G - $q.G) + [Math]::Abs($c.B - $q.B)) -lt 12) { continue }
        $ox = $x - $cx + 0.5; $oy = $y - $cy + 0.5
        $r = [Math]::Sqrt($ox * $ox + $oy * $oy)
        if ($r -le 112) {
          $dxS += $ox; $dyS += $oy; $dxN++
          if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
          if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
        } elseif ($r -ge 126 -and $r -le 172) {
          $shX += $ox; $shY += $oy; $shN++
        }
      }
    }
    $bmp.Dispose()
    if ($dxN -gt 0) {
      $offsets += [pscustomobject]@{ x = $dxS / $dxN; y = $dyS / $dxN }
      $widths += ($maxX - $minX + 1); $heights += ($maxY - $minY + 1)
    }
    if ($shN -gt 0) { $shadowX += ($shX / $shN); $shadowY += ($shY / $shN) }
  }
  $base.Dispose()

  if (-not $offsets) { throw 'disc mask was empty - is a cover loaded?' }

  $worst = ($offsets | ForEach-Object { [Math]::Max([Math]::Abs($_.x), [Math]::Abs($_.y)) } | Measure-Object -Maximum).Maximum
  Assert-That ($worst -lt $MaxDiscOffsetPx) "disc centre holds across $Frames phases" "worst $([Math]::Round($worst, 2))px (limit $MaxDiscOffsetPx)"

  $wSpread = ($widths | Measure-Object -Maximum).Maximum - ($widths | Measure-Object -Minimum).Minimum
  $hSpread = ($heights | Measure-Object -Maximum).Maximum - ($heights | Measure-Object -Minimum).Minimum
  Assert-That (($wSpread -le 2) -and ($hSpread -le 2)) 'disc silhouette does not breathe' "w $wSpread h $hSpread"

  $sq = @(); for ($i = 0; $i -lt $widths.Count; $i++) { $sq += [Math]::Abs($widths[$i] - $heights[$i]) }
  $sqMax = ($sq | Measure-Object -Maximum).Maximum
  Assert-That ($sqMax -le 3) 'disc silhouette stays circular' "max |w-h| $sqMax"

  if ($shadowX.Count -ge 2) {
    $mx = ($shadowX | Measure-Object -Average).Average
    $my = ($shadowY | Measure-Object -Average).Average
    $wander = 0.0
    for ($i = 0; $i -lt $shadowX.Count; $i++) {
      $d = [Math]::Sqrt([Math]::Pow($shadowX[$i] - $mx, 2) + [Math]::Pow($shadowY[$i] - $my, 2))
      if ($d -gt $wander) { $wander = $d }
    }
    Assert-That ($wander -lt $MaxShadowWanderPx) 'shadow does not orbit with the rotation' "wander $([Math]::Round($wander, 2))px (limit $MaxShadowWanderPx)"
  } else {
    Assert-That $false 'shadow ring was measurable' 'too few shadow pixels to judge the halo'
  }

  Write-Host "`n3. Console" -ForegroundColor Cyan
  $consoleRaw = Invoke-Cli @('console', 'error')
  $errLines = @($consoleRaw -split "`r?`n" | Where-Object { $_ -match 'Uncaught|SyntaxError|TypeError|\[ERROR\]' })
  Assert-That ($errLines.Count -eq 0) 'no console errors' ($errLines -join ' | ')

  Write-Host ''
  if ($script:Failures.Count -eq 0) {
    Write-Host "PASS - $script:Checks checks, worst disc offset $([Math]::Round($worst, 2))px" -ForegroundColor Green
    exit 0
  }
  Write-Host "FAIL - $($script:Failures.Count) of $script:Checks checks failed" -ForegroundColor Red
  $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
catch {
  Write-Host ("`nUNEXPECTED ERROR at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) -ForegroundColor Red
  Write-Host $_.InvocationInfo.Line -ForegroundColor DarkGray
  exit 1
}
finally {
  if ([System.IO.Directory]::Exists($work)) {
    try { [System.IO.Directory]::Delete($work, $true) } catch { }
  }
}
