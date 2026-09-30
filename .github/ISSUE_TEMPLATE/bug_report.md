---
name: Bug report
about: Something behaves differently from how it is documented
title: ''
labels: bug
assignees: ''
---

**What happens**

<!-- What you see. -->

**What you expected**

<!-- What the README promises, or what it did before. -->

**Steps**

1.
2.
3.

**Environment**

- Windows version:
- Python version:
- Commit: <!-- `git log -1 --format=%h` -->
- Player in use: <!-- NetEase, QQ Music, Spotify, browser, ... -->
- Theme: light / dark / auto
- Viewport or device: <!-- e.g. 390x844 phone, 1280x720 desktop -->

**Verifier output**

<!-- This is the highest-value part of the report. Paste whatever the three
     verifiers printed; a failing assertion names the invariant it was guarding. -->

```
pwsh -File tools/verify-api.ps1
```

```
pwsh -File tools/verify-disc.ps1
```

**Anything else**

<!-- Screenshots are welcome for visual issues. Console errors matter. -->