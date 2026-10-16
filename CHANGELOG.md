# Changelog

## 0.1.0

First public release.

- Answer Claude Code permission requests from the menu bar or the notification: Allow Once, Always Allow (from the options Claude Code offered), or Deny with a reason. The terminal dialog keeps working alongside; whichever answers first wins.
- Answer Claude's multiple-choice questions (pick options or type your own) and review plans (approve, or send them back with feedback) from the menu, with readable notifications instead of raw JSON.
- Readable previews: full Bash commands and diffs for edits, with hidden and direction-changing characters made visible.
- Notifications only when your terminal or editor isn't in front, with an optional single reminder.
- Usage: today's and 7-day tokens, sessions, most active project, a 7-day chart, and an API-price cost estimate from an editable pricing file.
- Plan limits (opt-in, through a statusline): 5-hour session and weekly usage, shown as bars and, optionally, as a percentage next to the menu-bar icon.
- Reviewed, reversible install of hooks and statusline into `~/.claude/settings.json`, with backups.
- Hooks reach the app through a private Unix socket with a per-launch token; nothing listens on the network.
