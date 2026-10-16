#!/bin/bash
# Hoot statusline for Claude Code. Installed by Hoot.app; see its README.
#
# Claude Code pipes session JSON (including your plan's rate_limits) to this script.
# It forwards that JSON to Hoot, then prints the status line:
#   - if Hoot wrapped a statusline you already had, that command's output, unchanged;
#   - otherwise Hoot's own short line (model · context · 5h · 7d).
# If Hoot isn't running, your own statusline still works.

dir="$HOME/Library/Application Support/Hoot"
sock="$dir/hoot.sock"
auth="$dir/auth-header"
wrapped="$dir/statusline-command"

input=$(cat)

private_dir=0
if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] && [ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ]; then
  private_dir=1
fi
hoot_up=0
if [ $private_dir = 1 ] && [ -S "$sock" ] && [ -O "$sock" ] && [ -f "$auth" ] && [ ! -L "$auth" ] && [ -O "$auth" ]; then
  hoot_up=1
fi

report() {
  curl --silent --fail --max-time 1 \
       --header @"$auth" --header 'Content-Type: application/json' \
       --data-binary @- --unix-socket "$sock" http://hoot/statusline 2>/dev/null
}

# The wrapped command is only trusted from the private folder, like settings.json itself.
if [ $private_dir = 1 ] && [ -f "$wrapped" ] && [ ! -L "$wrapped" ] && [ -O "$wrapped" ]; then
  if [ $hoot_up = 1 ]; then
    printf '%s' "$input" | report >/dev/null 2>&1 &
  fi
  printf '%s' "$input" | /bin/bash -c "$(cat "$wrapped")"
  exit $?
fi

if [ $hoot_up = 1 ]; then
  line=$(printf '%s' "$input" | report)
  if [ -n "$line" ]; then
    printf '%s\n' "$line"
    exit 0
  fi
fi
printf 'Claude Code\n'
exit 0
