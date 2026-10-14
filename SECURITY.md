# Security Policy

UsageBar reads login tokens that Cursor and Claude Code keep on your computer, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through [GitHub's security advisories](https://github.com/yavuzceliker/usagebar/security/advisories/new). You will get a reply within a few days.

Useful things to include: the platform, the version, what an attacker could do, and steps to reproduce.

## What UsageBar promises

- Tokens are read on demand and only sent to the vendor's own API (`api2.cursor.sh`, `api.anthropic.com`).
- Tokens are never written to disk, logged, cached or sent anywhere else.
- Logins are never refreshed or modified.

Anything that breaks one of these is a security bug.
