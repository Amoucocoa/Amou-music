# Contributing

Thanks for looking at it. This file is mostly a list of things that look
independently editable but are not — every one of them was broken at least once,
and none of them announced anything when they broke.

## Setup

Windows only. The device layer talks to COM (`pycaw`, `comtypes`) and enumerates
processes with `psutil`; there is no cross-platform path and adding one is a
larger project than it looks.

    git clone https://github.com/Amoucocoa/Amou-music.git
    cd Amou-music
    start.bat

`start.bat` creates the venv, installs `requirements.txt`, and starts the server.
It also offers to add a Windows Firewall inbound rule, which needs an
administrator shell.

## Before you open a pull request

CI runs on every push and pull request, but it can only cover part of this. It
parses every module and runs the lyric state machine, on both Linux and Windows.
It cannot run the other two, and that is not an oversight:

> `server.py` constructs `DeviceWorker()` at startup, which initialises COM
> against the local audio stack. A hosted runner has no sound card, so the
> service will not start — and both remaining verifiers need a live service. The
> visual one also needs a browser.

So run the two it cannot, locally. All three are independent and each catches a
different class of failure — functional, state-machine, and visual.

    pwsh -File tools/verify-api.ps1     # 16 checks, ~1s, no browser
    python tools/verify-lyrics.py       # 2 cases, ~1s, no browser
    pwsh -File tools/verify-disc.ps1    # 34 checks, needs Playwright CLI

`verify-syntax.py` and `verify-lyrics.py` are the two CI runs; you can run them
too. `verify-syntax.py` parses rather than imports on purpose — importing
`device.py` would initialise COM.

`verify-disc.ps1` starts its own browser session. If it reports that the
reference viewport did not take effect, close stray Edge windows and re-run —
that check exists because the window size silently drifted and every pixel
threshold became meaningless.

## Why the verifiers look the way they do

This is the reasoning the README deliberately does not carry. If you are about to
change what a verifier checks, read this first.

### Why there is an API check at all

Rendering checks and interface checks are orthogonal. A button can be drawn
perfectly and still do nothing.

That is not hypothetical. `d47f15c` (2026-09-27) turned `_read_state` from a
module function into a `DeviceWorker` method and missed the call sites in four
module-level helpers. Every control route answered 503 for three days while all
visual checks stayed green — the buttons looked exactly right and simply did
nothing when pressed. The first version of `verify-api.ps1` caught both 503s on
its initial run.

It exercises writes idempotently: read the current volume, write the same value
back. That really traverses the device layer while changing nothing on the
machine, and `finally` restores regardless. It also checks the rejections —
`{"value":"loud"}` must be 400, never 500, because a 500 means validation was
removed and the request reached the device before failing.

### Why the geometry check pins its viewport

`verify-disc.ps1` kills any old browser session, opens a fresh one, resizes to
1280x900, and then **asserts that `innerWidth/innerHeight` actually took**.

Not asserting this is how the baseline drifts. A reused session clamps
`setViewportSize` to whatever its window happens to be: the same request for
1280x900 came back as 1280x720, which measured a 210px disc when the script
believed it had a 288px one. Every pixel threshold below became meaningless
while the run still reported success.

The read-back assertion then caught its own author. The resize originally read
`"$RefViewport[0]"` — and **PowerShell does not index an array inside an
interpolated string**, so that expanded to the literal `"1280 900[0]"`. The
command failed silently, the viewport never moved, and nothing said so. Hence
scalars `RefW` / `RefH`, and a read-back for anything that sets up the
environment.

### Tolerance comes from the measured distribution

The disc-centroid ceiling is 0.5px, taken from three runs at the pinned window
(0.16, 0.27, 0.31px). That spread is not pixel noise — an ~870px circumference
would average it to hundredths — it is the artwork being slightly off-balance as
it turns, which is inherent to the content. The old 1.0px ceiling passed a real
half-pixel regression; 0.3px flaked on a healthy page.

### Every assertion is reverse-validated

An assertion nobody has seen fail is not known to work. Each of these was
provoked and confirmed to go red before being trusted:

| Provocation | Caught by | Exit |
| --- | --- | --- |
| lyric window 2 rows -> 3 | row-height assertion + 5px overflow at 360x640 | 1 |
| artwork label 70% -> 40% | `0.4 (want 0.70 +/-0.02)` | 1 |
| glass plate circle -> square | `border-radius 12px` | 1 |

When you add an assertion, do the same: break the invariant, confirm the script
fails, restore. A number that has never gone red is decoration.

### What the disc check actually measures

Two unrelated causes make a centred record *look* off-centre, and geometry alone
only sees one of them.

- **Geometry** — differencing a frame against a baseline captured with the disc
  hidden; the disc mask must be a circle of constant size whose centre lands on
  the plate centre in every sampled phase. Healthy: under 0.2px.
- **Perceived offset** — the disc is dead centre but appears to slide, because an
  asymmetric `box-shadow` rides the rotation and orbits the dark mass once per
  turn. Asserted twice: statically, every shadow layer on a rotating element must
  have zero x/y offset; dynamically, the shadow centroid must stay put across
  phases. The old implementation drifted 40px.
- **Picture disc** — artwork concentric with the record, in phase, diameter ratio
  inside 0.30-0.85, and record `opacity` at 1. Break any one and the grooves get
  covered by the artwork again.
- **Sheen symmetry** — luminance sampled in 72 angular bins around the exposed
  groove ring; opposite bins must differ by under 6/255. A single-arc sheen
  measures ~25. Compare per-bin *means*, not pixel sums — bins hold unequal pixel
  counts, so summing compares population rather than brightness.
- **Pinned ratios and layout** — plate `border-radius: 50%`, label 70% +/-0.02 of
  the plate, glass rim 1%-4% of plate width, lyric window exactly two rows and
  centred per line, transport keys at least 44pt, and no page overflow at any of
  eight viewports from 360x640 to 1920x1080.

## Invariants

### The height budget is a coupled pair

`--chrome` and the column `max-width` are two halves of one inequality,
`W + chrome(W) <= 100dvh`, solved with the same coefficients. Change one
without the other and the page grows a scrollbar on some viewport sizes with no
error anywhere. The discriminant is 1.86 and the intercept is 231; they appear
in both places. If you change one, grep for the other.

### `--art-scale` is the only disc-size knob

Scaling the **plate** is enough: the record and the label are percentages of it
and the groove pitch is a share of the radius, so the whole disc shrinks as one
piece. Do not re-tune the three sizes separately; you will silently change the
proportions.

### Picture-disc ratios

Glass plate `border-radius: 50%`, record 96%, label 70%.

The record must **never** reach 100%. At 100% it covers the frost, the inner
stroke and the lit edge, and the "glass plate" silently stops existing. This is
asserted, and the assertion is there because someone would otherwise "tidy" it
to 100% one day.

The plate is **circular, not a rounded square** — a round record in a square
frame leaves dead corners and reads as a framed photograph.

The plate's colour is **neutral on purpose**. It sits directly under a black
record, so an accent-tinted rim reads as a coloured halo bleeding out from
behind the disc.

### One property, one author

Do not put a CSS `@keyframes` animation on any element whose `transform` a GSAP
tween also writes. CSS animations sit **above** author inline styles in the
cascade, so if any keyframe declares `transform`, every value the tween writes
is discarded. This happened: the background-speed slider moved the noise but not
the parallax, and both animations ran at 40s so it looked alive.

If two things appear to fight over a property, one of them is already dead.
Grep for the keyframe name before assuming a setting does nothing.

This is also why the disc and its artwork are centred with `inset: 0` plus
`margin: auto`, and never with `transform: translate(-50%, -50%)`. It is the
tempting way to centre an absolutely-positioned element, and it silently works
until the rotation tween starts writing the same property — at which point the
element jumps and the geometry assertions start failing for reasons that look
unrelated to CSS. The stylesheet must contribute nothing to `transform` on
anything that turns.

### Groove pitch has a floor

The pitch is a percentage of the radius (currently 2.4%), never a pixel count —
fixed pixels made the same record show 27 grooves on a phone and 57 on a
monitor. But do not go finer than roughly 2px: below that the dark line falls
under a device pixel and shimmers as the disc turns.

The sheen is **two arcs 180 degrees apart**. A single bright arc makes the disc
look crooked at every angle. Every `box-shadow` on a rotating element must have
zero x/y offset, because a directional shadow orbits once per turn.

### The lyric window is two rows, on purpose

Long lines get the two rows and the next line is pushed out of view rather than
being clipped or ellipsed. Row height comes from a single variable so a credit
line set in a smaller size cannot resize the window and make it jitter.

The long-press expand has four failure modes that are all easy to reintroduce:
reset `scrollTop` when collapsing, swallow exactly one `click` after a long
press fires, cancel the timer on movement, and keep a keyboard equivalent.

### Fader thumb centring

WebKit positions the thumb by offset, not centred. `margin-top` must stay
derived from the same expression as the track height and thumb size, or the
thumb drifts as the column resizes.

## Repository hygiene

`.playwright-cli/` holds page snapshots that Playwright CLI writes during
verification. It is in `.gitignore`; if snapshots ever appear in `git status`,
they were added before the rule existed — `git rm --cached` them. A tool that
contaminates the thing it measures is worse than no tool.

`git add -A` in a scratch directory will happily stage a temporary script you
were about to delete. Check `git status` before committing.

## Where contributions are welcome, and where to be careful

**Welcome, and low-risk:** the interface and motion layer, the verification
tooling, accessibility, the responsive strategy, and adapting the metadata layer
to other players.

**Be careful:** `metadata.py` reads NetEase Cloud Music's **private local cache
formats** (`Library/webdb.dat`, `Statics/index.dat`, `Temp/index.dat`). These
are undocumented and reverse-engineered. Work on that file is legally and
ethically murkier than the rest of the project, and a change there can break on
a player update in ways no test will catch. Contributions that avoid deepening
the reverse engineering — better error handling, clearer degradation, a new
`MetadataSource` for a player with a *public* API — are much easier to merge.

**Windows-only device layer:** the COM access must stay on the single worker
thread. It is initialised per thread, and the serialisation is also what makes a
burst of fader requests safe. Do not call COM from a request thread.

## Commit messages

The history is in Chinese and explains *why*, not *what*. Please keep that
spirit — especially for changes to anything in the invariants list above, where
the interesting part is always the reason the obvious version is wrong.