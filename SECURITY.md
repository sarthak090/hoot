# Security

Hoot can approve commands that Claude Code runs on your machine, so security problems matter a lot. Thank you for reporting them carefully.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead: the repository's **Security** tab › **Report a vulnerability**. Include what you found, how to reproduce it, and what an attacker could do with it.

You'll get a reply within a week. Fixes are released as soon as they're ready, and reporters are credited unless they'd rather not be.

## What's in scope

Anything that could let something other than you approve a permission request, see request contents or tokens, or run code through Hoot. For example:

- reaching the hook socket or forging requests
- previews that don't show what will actually run (hidden characters, truncation)
- the `settings.json` installer writing something you didn't review
- the statusline script running untrusted input

How Hoot defends against these is described under **Security** in the [README](README.md#security).

## Supported versions

Only the latest release gets fixes.
