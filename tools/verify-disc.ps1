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
  # Observed across repeated runs at the pinned reference window (disc r=138px):
  # 0.16, 0.27, 0.31px. The spread is not pixel noise - a ~870px circumference
  # would average that away to hundredths of a pixel - it is the artwork itself
  # being slightly off-balance as it turns, which is inherent to the content.
  # So the ceiling is set from the observed distribution, not from a wish:
  #   1.0px (the old value) passed a real half-pixel regression;
  #   0.3px flaked on a healthy page.
  # 0.5px still catches the failure this check exists for - an asymmetric shadow
  # orbited the disc by 15-40px, two orders of magnitude above this.
  [double]$MaxDiscOffsetPx = 0.5,
  [double]$MaxShadowWanderPx = 6.0,
  # Max luminance gap between opposite points of the groove ring, 0-255.
  # A single-arc sheen measures ~28; a 180deg-periodic one measures < 3.
  [double]$MaxSheenAsymmetry = 6.0,
  # Angular resolution of the ring sampling.
  [int]$SheenBins = 72
)

# Reference window for the geometry sections. Wide enough that the disc sits far
# above the sub-pixel noise floor, short enough to need no scrolling.
#
# Scalars, not an array, on purpose. PowerShell does not index an array inside an
# interpolated string: "$arr[0]" expands the WHOLE array and appends a literal
# "[0]". The resize was therefore being called with the argument "1280 900[0]",
# failed silently, and left the viewport at the browser default - so the run
# measured a 210px disc while believing it had a 288px one. The viewport is
# asserted below precisely because a silent no-op here is invisible.
$RefW = 1280
$RefH = 900

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0
$script:FixtureInjected = $false

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

# Run on BOTH exit paths. The reduced-motion early exit used to skip this
# entirely, so a page carrying a real JS error still reported green on any
# machine that had the accessibility setting switched on.
function Test-Console {
  $raw = Invoke-Cli @('console', 'error')
  $errs = @($raw -split "`r?`n" | Where-Object { $_ -match 'Uncaught|SyntaxError|TypeError|\[ERROR\]' })
  Assert-That ($errs.Count -eq 0) 'no console errors' ($errs -join ' | ')
}

$JS_PROBE = "function(){function r(s){var e=document.querySelector(s);if(!e)return null;var c=getComputedStyle(e);var m=new DOMMatrix(c.transform);var b=e.getBoundingClientRect();return{tx:m.e,ty:m.f,ang:Math.atan2(m.b,m.a)*180/Math.PI,org:c.transformOrigin,side:e.offsetWidth,sh:c.boxShadow,op:c.opacity,cx:b.left+b.width/2,cy:b.top+b.height/2,bg:c.backgroundImage};}return JSON.stringify({cover:r('.art-cover'),vinyl:r('.vinyl'),rm:matchMedia('(prefers-reduced-motion: reduce)').matches,art:r('.art').side});}"
$JS_FLAT = "function(){var s=document.createElement('style');s.id='qa-flat';s.textContent='html,body{background:#e9ecef !important;}.backdrop,svg,#water,.water{display:none !important;}';document.head.appendChild(s);return JSON.stringify({r:'flat'});}"
$JS_HIDE = "function(){document.querySelector('.art-cover').style.visibility='hidden';document.querySelector('.vinyl').style.visibility='hidden';return JSON.stringify({r:'hidden'});}"
$JS_SHOW = "function(){document.querySelector('.art-cover').style.visibility='';document.querySelector('.vinyl').style.visibility='';return JSON.stringify({r:'shown'});}"
$JS_FOCUS_LYRIC = "function(){var c=document.getElementById('lyricCard');if(!c||c.hidden)return JSON.stringify({r:'skip'});c.focus();return JSON.stringify({r:'focused'});}"
$JS_EXPANDED = "function(){var c=document.getElementById('lyricCard');var b=c.getBoundingClientRect();var t=document.getElementById('deckPrev').getBoundingClientRect();return JSON.stringify({exp:c.classList.contains('is-expanded'),over:Math.max(document.body.scrollHeight,document.documentElement.scrollHeight)-window.innerHeight,clear:b.bottom<=t.top});}"
$JS_LAYOUT = "function(){function m(s){var e=document.querySelector(s);if(!e)return null;var b=e.getBoundingClientRect();var c=getComputedStyle(e);return{w:b.width,h:b.height,side:e.offsetWidth,hidden:e.hidden,radius:c.borderRadius,align:c.textAlign,lh:parseFloat(c.lineHeight)};}function k(id){var e=document.getElementById(id);if(!e)return null;var b=e.getBoundingClientRect();return{w:Math.round(b.width),h:Math.round(b.height)};}return JSON.stringify({card:m('.lyric-card'),line:m('.lyric-line'),art:m('.art'),vinyl:m('.vinyl'),cover:m('.art-cover'),keys:[k('deckPrev'),k('deckPlay'),k('deckNext')]});}"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('verify-disc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[System.IO.Directory]::CreateDirectory($work) | Out-Null

try {
  Write-Host "`nDisc centring verification - $Url" -ForegroundColor Cyan

  # Always start from a fresh browser. Two reasons, both learned the hard way:
  #   - the session expires on idle, so a cold run died on "Browser 'default' is
  #     not open";
  #   - a REUSED session clamps setViewportSize to whatever its window happens to
  #     be, which silently measured a 212px disc where a cold one measures 288px.
  #     Same page, same script, different answer.
  # A cold `open` honours the requested viewport exactly (verified at both 1280x900
  # headless and headed), so the cost is a few seconds and the measurements become
  # comparable between runs.
  Invoke-Cli @('kill-all') | Out-Null
  # kill-all only reaps Playwright's own daemons. If a previous run was
  # interrupted, orphaned msedge processes survive and silently clamp the next
  # window: the same request for 1280x900 came back 1280x720, which measured a
  # 210px disc instead of a 288px one and made every pixel threshold meaningless.
  # Match on the command line rather than the process name, so a browser the user
  # actually has open is never touched - theirs has no 'playwright' in it.
  try {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
      Where-Object { $_.CommandLine -match 'playwright' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch { }
  Start-Sleep -Seconds 1
  Invoke-Cli @('open', '--browser', 'msedge', $Url.TrimEnd('/')) | Out-Null
  Start-Sleep -Seconds 3
  # Pin the window before measuring anything. The session keeps whatever size it
  # was left at, so the pixel section reported a different sleeve diameter from
  # run to run (150px one run, 212px the next) with no change to the page. A
  # geometric assertion whose baseline moves is not an assertion.
  Invoke-Cli @('resize', "$RefW", "$RefH") | Out-Null
  Start-Sleep -Seconds 3
  # setViewportSize is a REQUEST. In a headed browser it is clamped by the real
  # OS window, so a fresh session silently measures a smaller disc than a warm
  # one - which is exactly the drifting baseline this line exists to kill, one
  # level deeper. Do not measure until the viewport is confirmed.
  $vp = Invoke-Eval "function(){return JSON.stringify({w:window.innerWidth,h:window.innerHeight});}"
  Assert-That ($vp.w -eq $RefW -and $vp.h -eq $RefH) `
    'the reference viewport actually took effect' `
    "asked ${RefW}x${RefH}, got $($vp.w)x$($vp.h) - something is clamping the window; close stray Edge windows and re-run"
  if ($vp.w -ne $RefW -or $vp.h -ne $RefH) {
    Write-Host "  [ABORT] measurements below would not be comparable." -ForegroundColor Red
    exit 1
  }

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

  # Groove pitch must be a share of the disc radius. Fixed px made the texture
  # size-dependent - 27 grooves on a 360px phone, 57 on a 1920px monitor - so
  # the same record read as a different material at every breakpoint.
  # Isolate just the repeating-radial-gradient layer, then read its stops.
  # Take ONLY the repeating-radial-gradient(...) value, not everything from its
  # first character to the end of the declaration. The old Substring($at) plus
  # "last percentage in the string" happened to be right because this layer is
  # declared last; append any later layer containing a percentage and the number
  # would silently come from the wrong layer. The stop colours are themselves
  # parenthesised (rgba(...)), so the scan has to balance them.
  $at = $probe.vinyl.bg.IndexOf('repeating-radial-gradient')
  $grooveBody = ''
  if ($at -ge 0) {
    $depth = 0
    for ($i = $at; $i -lt $probe.vinyl.bg.Length; $i++) {
      $ch = $probe.vinyl.bg[$i]
      if ($ch -eq '(') { $depth++ }
      elseif ($ch -eq ')') {
        $depth--
        if ($depth -eq 0) { $grooveBody = $probe.vinyl.bg.Substring($at, $i - $at + 1); break }
      }
    }
  }
  $groovePct = [regex]::Matches($grooveBody, '(-?[\d.]+)%')
  $groovePx = [regex]::Matches($grooveBody, '(-?[\d.]+)px')
  $periodPct = if ($groovePct.Count -ge 2) { [double]$groovePct[$groovePct.Count - 1].Groups[1].Value } else { 0 }
  Assert-That ($periodPct -gt 0) `
    'groove pitch is radius-relative, not a fixed pixel count' `
    "groove layer = '$grooveBody'"
  # `circle` with no explicit size ends at the farthest corner, so one percent of
  # the gradient is 1.414 x one percent of the radius. Dividing by the raw number
  # overstated the ring count by ~41%.
  $periods = if ($periodPct -gt 0) { [Math]::Round(100 / ($periodPct * [Math]::Sqrt(2)), 1) } else { 0 }
  Assert-That ($periodPct -ge 2.0 -and $periodPct -le 5.0) `
    'groove pitch is in a readable range' `
    "period $periodPct% of the gradient -> $periods rings per disc (100 / ($periodPct x sqrt2))"

  # Picture-disc geometry: the artwork is a label printed ON the record, so it
  # must be concentric with the vinyl AND strictly smaller than it - otherwise
  # the black grooves are hidden again and the disc reads as a bare photo.
  $ecc = [Math]::Max([Math]::Abs($probe.cover.cx - $probe.vinyl.cx), [Math]::Abs($probe.cover.cy - $probe.vinyl.cy))
  Assert-That ($ecc -lt 0.5) 'artwork is concentric with the record' "centre offset $([Math]::Round($ecc, 2))px"
  $ratio = $probe.cover.side / $probe.vinyl.side
  Assert-That (($ratio -gt 0.3) -and ($ratio -lt 0.85)) `
    'artwork leaves the vinyl ring visible' "art/vinyl diameter ratio $([Math]::Round($ratio, 3))"
  Assert-That ([double]$probe.vinyl.op -gt 0.99) `
    'the record stays visible under the artwork' "vinyl opacity $($probe.vinyl.op)"

  # `art` is the plate's offsetWidth (a number), not an object. The PLATE is the
  # larger of the two, so the rim is plate minus record - not the other way round.
  $rim = ($probe.art - $probe.vinyl.side) / 2.0
  # 1%-4% of the plate. Under 1% the glass loses its lit edge; over 4% the
  # record stops reading as a record again. Measured 2.03% at 360x640.
  Assert-That (($rim -gt ($probe.art * 0.01)) -and ($rim -lt ($probe.art * 0.04))) `
    'a rim of glass still shows around the record' `
    "rim $rim px = $([Math]::Round(100 * $rim / $probe.art, 2))% of a $($probe.art) px plate (record $($probe.vinyl.side) px)"

  Write-Host "`n2. Pinned layout ratios" -ForegroundColor Cyan
  $lay = Invoke-Eval $JS_LAYOUT
  if (-not $lay.art) {
    Assert-That $false 'the record plate exists'
  } else {
    # A rounded SQUARE plate is the pre-redesign regression: the record is round,
    # so a square frame only adds dead area and reads as a framed photograph.
    Assert-That ($lay.art.radius -eq '50%') `
      'the glass plate is a circle, not a rounded square' `
      "border-radius $($lay.art.radius)"

    $coverOverPlate = $lay.cover.side / $lay.art.side
    Assert-That ([Math]::Abs($coverOverPlate - 0.70) -lt 0.02) `
      'artwork label is 70% of the plate' `
      "$([Math]::Round($coverOverPlate, 4)) (want 0.70 +/-0.02)"

    # 70/96. The record must never reach 100%: it would cover the frost, the
    # inner stroke and the lit edge, and the glass plate would silently stop
    # existing. This ratio is the only thing holding that line.
    $coverOverVinyl = $lay.cover.side / $lay.vinyl.side
    Assert-That (($coverOverVinyl -gt 0.30) -and ($coverOverVinyl -lt 0.85)) `
      'artwork leaves the record ring visible' `
      "$([Math]::Round($coverOverVinyl, 4)) of the record (want 0.30-0.85)"
  }

  if ($lay.card -and -not $lay.card.hidden -and $lay.line) {
    # The two-row window is a fixed budget, not a scroll region. Row height comes
    # from one variable, so a credit line set smaller cannot resize it and make
    # the window jitter as the highlight moves.
    $want = 2 * $lay.line.lh
    Assert-That ([Math]::Abs($lay.card.h - $want) -lt 1.0) `
      'the lyric window is exactly two rows' `
      "$([Math]::Round($lay.card.h, 2))px vs 2 x $([Math]::Round($lay.line.lh, 2))px = $([Math]::Round($want, 2))px"
    Assert-That ($lay.line.align -eq 'center') `
      'lyric lines are centred individually' `
      "text-align $($lay.line.align)"
  } else {
    Write-Host "  [SKIP] no lyric is playing, so the two-row window cannot be measured" -ForegroundColor Yellow
  }

  $tooSmall = @($lay.keys | Where-Object { $_ -and ($_.w -lt 44 -or $_.h -lt 44) })
  Assert-That ($tooSmall.Count -eq 0) `
    'transport keys keep a 44pt touch target' `
    (($lay.keys | ForEach-Object { "$($_.w)x$($_.h)" }) -join ', ')

  Write-Host "`n3. Pixel measurement" -ForegroundColor Cyan
  if ($probe.rm) {
    Write-Host "  [SKIP] prefers-reduced-motion is on; the disc does not turn." -ForegroundColor Yellow
    Write-Host "`n4. Console" -ForegroundColor Cyan
    Test-Console
    Write-Host ''
    if ($script:Failures.Count -eq 0) {
      Write-Host "PASS - $script:Checks checks (rotation checks skipped)." -ForegroundColor Green
      exit 0
    }
    Write-Host "FAIL - $($script:Failures.Count) of $script:Checks checks failed" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
  }

  Invoke-Eval $JS_FLAT | Out-Null
  # Registered for removal in `finally`: this fixture hides EVERY <svg> to drop
  # the animated backdrop, so leaving it behind silently blanks the transport
  # glyphs in the live page. A harness that contaminates the session under test
  # is worse than no harness.
  $script:FixtureInjected = $true
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
  # All sampling bands are shares of the measured disc radius, never absolute
  # pixels: the disc is fluid with the viewport, so absolute radii would fall
  # off the element entirely at the small end.
  $discR = $probe.vinyl.side / 2.0
  $rDisc = $discR * 0.90      # interior of the record
  $rSheenLo = $discR * 0.80   # exposed groove ring
  $rSheenHi = $discR * 0.95
  $rShLo = $discR * 1.02      # halo just outside the record edge
  $rShHi = $discR * 1.40
  Write-Host ("  sleeve {0}x{1}px, centre ({2:N1},{3:N1}), disc r={4:N1}px" -f $base.Width, $base.Height, $cx, $cy, $discR) -ForegroundColor DarkGray
  $offsets = @(); $widths = @(); $heights = @(); $shadowX = @(); $shadowY = @()
  # Luminance sampled around a circle inside the exposed groove ring, so the
  # conic sheen can be tested for 180deg periodicity. Averaged over three radii
  # to suppress antialiasing noise; the ring sits between the artwork edge and
  # the record edge, which is opaque, so the page backdrop cannot contaminate it.
  $ringX = @(); $ringY = @()

  foreach ($p in $framePaths) {
    $bmp = [System.Drawing.Bitmap]::FromFile($p)
    $ringL = New-Object 'double[]' $SheenBins
    $ringN = New-Object 'int[]' $SheenBins
    $dxS = 0.0; $dyS = 0.0; $dxN = 0
    $shX = 0.0; $shY = 0.0; $shN = 0
    $minX = 99999; $maxX = -1; $minY = 99999; $maxY = -1
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y); $q = $base.GetPixel($x, $y)
        if (([Math]::Abs($c.R - $q.R) + [Math]::Abs($c.G - $q.G) + [Math]::Abs($c.B - $q.B)) -lt 12) { continue }
        $ox = $x - $cx + 0.5; $oy = $y - $cy + 0.5
        $r = [Math]::Sqrt($ox * $ox + $oy * $oy)
        if ($r -le $rDisc) {
          $dxS += $ox; $dyS += $oy; $dxN++
          if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
          if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
          if ($r -ge $rSheenLo -and $r -le $rSheenHi) {
            # atan2 spans -PI..PI; shift to 0..2PI so the whole circle is binned.
            $bin = [int][Math]::Floor(([Math]::Atan2($oy, $ox) + [Math]::PI) / (2 * [Math]::PI) * $SheenBins) % $SheenBins
            $ringL[$bin] += (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
            $ringN[$bin]++
          }
        } elseif ($r -ge $rShLo -and $r -le $rShHi) {
          $shX += $ox; $shY += $oy; $shN++
        }
      }
    }
    $bmp.Dispose()
    if ($ringL[0] -or $ringL[1]) { $ringX += , @($ringL); $ringY += , @($ringN) }
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

  # The sheen must be 180deg-periodic: opposite points of the ring carry the
  # same luminance. A single-arc conic gradient leaves 272deg unlit, so the
  # bright mass sits off-centre at every angle - the same failure mode as the
  # orbiting shadow, one layer up.
  if ($ringX.Count -ge 1) {
    $worstSheen = 0.0
    $half = [int]($SheenBins / 2)
    for ($f = 0; $f -lt $ringX.Count; $f++) {
      $L = $ringX[$f]; $N = $ringY[$f]
      for ($i = 0; $i -lt $half; $i++) {
        $j = $i + $half
        if ($N[$i] -le 0 -or $N[$j] -le 0) { continue }
        $a = $L[$i] / $N[$i]; $b = $L[$j] / $N[$j]
        $d = [Math]::Abs($a - $b)
        if ($d -gt $worstSheen) { $worstSheen = $d }
      }
    }
    Assert-That ($worstSheen -lt $MaxSheenAsymmetry) `
      'sheen is 180deg symmetric about the disc' "worst opposite-pair delta $([Math]::Round($worstSheen, 1))/255"
  } else {
    Assert-That $false 'groove ring was measurable' 'no pixels sampled in the ring'
  }

  # Hand the page back BEFORE reading the console. The fixture hides every <svg>
  # to flatten the backdrop, which starves GSAP of icons it is animating and can
  # raise errors that belong to the harness rather than to the product.
  if ($script:FixtureInjected) {
    Invoke-Cli @('--raw', 'eval', "function(){var s=document.getElementById('qa-flat'); if(s) s.remove(); return JSON.stringify({r:'fixture-removed'});}") | Out-Null
    $script:FixtureInjected = $false
  }
  Invoke-Cli @('goto', $Url) | Out-Null
  Start-Sleep -Seconds 2

  Write-Host "`n4. Console" -ForegroundColor Cyan
  Test-Console

  # The page is whole again here, which is the only point at which the layout
  # budget can be measured honestly. A silent scrollbar is exactly the kind of
  # regression that survived three rounds of lyric and disc tuning, because
  # nothing was watching for it.
  Write-Host "`n5. Viewport overflow budget" -ForegroundColor Cyan
  foreach ($vp in @(@(360, 640), @(390, 844), @(430, 932), @(560, 900),
                    @(720, 1000), @(900, 900), @(1280, 720), @(1920, 1080))) {
    Invoke-Cli @('resize', "$($vp[0])", "$($vp[1])") | Out-Null
    Start-Sleep -Milliseconds 700
    $o = Invoke-Eval "function(){return JSON.stringify({over:document.body.scrollHeight-window.innerHeight});}"
    Assert-That ($o.over -le 0) `
      "no page overflow at $($vp[0])x$($vp[1])" `
      "$($o.over)px past the fold"

    # Now the same viewport with the lyrics EXPANDED. The card is an overlay, so
    # it must contribute nothing to the page height -- and the transport row has
    # to stay on screen, or expanding to read a song's lyrics costs you the
    # ability to skip it. Measuring only the collapsed state is what let this
    # regress: the defect was invisible until someone actually opened the card.
    if ((Invoke-Eval $JS_FOCUS_LYRIC).r -ne 'skip') {
      Invoke-Cli @('press', 'Enter') | Out-Null
      Start-Sleep -Milliseconds 700
      $e = Invoke-Eval $JS_EXPANDED
      Assert-That ($e.exp) `
        "the lyric card expands at $($vp[0])x$($vp[1])" `
        'the card did not take the expanded state'
      Assert-That ($e.over -le 0) `
        "no page overflow with the lyrics expanded at $($vp[0])x$($vp[1])" `
        "$($e.over)px past the fold"
      Assert-That $e.clear `
        "the transport row stays reachable while reading at $($vp[0])x$($vp[1])" `
        'the card covers the play / previous / next keys'
      Invoke-Cli @('press', 'Enter') | Out-Null
      Start-Sleep -Milliseconds 400
    }
  }

  # Put the window back before reporting, so the next run starts from the
  # reference size instead of inheriting 1920x1080 from the last loop entry.
  Invoke-Cli @('resize', "$RefW", "$RefH") | Out-Null

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
  if ($script:FixtureInjected) {
    Invoke-Cli @('--raw', 'eval', "function(){var s=document.getElementById('qa-flat'); if(s) s.remove(); return JSON.stringify({r:'fixture-removed'});}") | Out-Null
  }
  # Restore the live page: the run hid the artwork, so a reload is the only way
  # to hand back a page in the state the user actually sees.
  Invoke-Cli @('goto', $Url) | Out-Null
  Invoke-Cli @('resize', "$RefW", "$RefH") | Out-Null
  if ([System.IO.Directory]::Exists($work)) {
    try { [System.IO.Directory]::Delete($work, $true) } catch { }
  }
}
