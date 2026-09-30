## What this changes

<!-- One or two sentences. -->

## Why

<!-- What was wrong, or what is now possible. If you touched anything listed in
     CONTRIBUTING.md's invariants list, say which one and why the obvious version
     is wrong — that is the part a reviewer cannot guess. -->

## Verification

- [ ] `pwsh -File tools/verify-api.ps1` passes
- [ ] `python tools/verify-lyrics.py` passes
- [ ] `pwsh -File tools/verify-disc.ps1` passes
- [ ] Frontend changes only: all 5 inline `<script>` blocks pass `node --check`
- [ ] Backend changes: `ast.parse` clean

## Invariants

- [ ] I did not change `--chrome` and the column `max-width` apart
- [ ] I did not re-tune disc sizes individually instead of via `--art-scale`
- [ ] The record is still < 100% of the plate, and the plate is still circular
- [ ] No CSS `@keyframes` on an element whose `transform` a tween also writes
- [ ] No new rotating element carries a directional `box-shadow`
- [ ] `.playwright-cli/` is not staged

## Not done

<!-- Anything deliberately left out, so a reviewer does not go looking for it. -->