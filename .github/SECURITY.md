# Security Policy

## Scope

This server has **no authentication by design**. Anyone who can reach it on the
network can control the host machine's audio. That is a deliberate trade-off for
a personal tool on a home network, not an oversight — but it does have
consequences, and they are written down here so nobody is surprised.

## Threat model

| | |
|---|---|
| **Default bind** | `0.0.0.0` — every network interface, not just loopback |
| **Authentication** | None. No token, no session, no login. |
| **Authorization** | None. Every client is equally trusted. |
| **Transport** | Plain HTTP. No TLS. |
| **Rate limiting** | None. |
| **Static file serving** | Fixed allowlist, so `../` traversal is not reachable. |

Start it with `--host 127.0.0.1` to keep it off the network entirely.

## Known limitations

**Cross-origin requests.** The API answers `application/json` and sets no CORS
headers. A plain `fetch` from an unrelated website is blocked by the browser's
preflight, which is why no CORS handling is needed. That protection is
*incidental*, not designed: there is no `Origin` or `Host` header validation, so
DNS rebinding — an attacker domain that resolves to a LAN address, making the
request same-origin — is a live avenue. This has not been exploited or
reproduced here; it is called out as an area a contributor could harden.

**Plain HTTP.** Anything on-path can read and alter what you control.

**Shared ownership of the machine's sound.** Volume, mute, output device and
media keys are global. On a shared or office network, anyone can change them.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private vulnerability reporting on the Security tab of this
repository. If that is unavailable to you, open a regular issue that says only
"security report available on request" with no technical detail, and a
maintainer will arrange a private channel.

Please include: the affected version or commit, what an attacker can do, and
the steps to reproduce. Give us a reasonable window to ship a fix before
disclosing.

## What is *not* a vulnerability

- **No authentication, by design.** See the threat model above.
- **The host firewall rule.** `start.bat` adds a TCP inbound allow rule when
  run as administrator. Removing it is a supported way to lock the server down.
- **Private-format scraping.** Reading a music player's local cache to display
  track metadata is fragile by nature; the project treats breakage there as a
  bug, not a security issue. See CONTRIBUTING.md for where contributions are
  welcome.