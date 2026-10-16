#!/bin/bash
# Hoot hook for Claude Code. Installed by Hoot.app; see its README.
#
#   hoot.sh permission   PermissionRequest: waits for an answer from the menu bar
#   hoot.sh event        Notification / UserPromptSubmit: fire and forget
#
# Contract: never fail and never hang. On any problem this prints nothing and exits 0,
# so Claude Code carries on exactly as if the hook weren't installed.

dir="$HOME/Library/Application Support/Hoot"
sock="$dir/hoot.sock"
auth="$dir/auth-header"

drain() { cat >/dev/null 2>&1; exit 0; }

# Only talk to Hoot through a socket in a private directory owned by this user.
# That is what stops anything else from posing as Hoot and answering for you.
[ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || drain
[ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ] || drain
[ -S "$sock" ] && [ -O "$sock" ] || drain
[ -f "$auth" ] && [ ! -L "$auth" ] && [ -O "$auth" ] || drain

case "$1" in
  permission)
    wait=300
    v=$(sed -n 's/^wait=\([1-9][0-9]\{0,4\}\)$/\1/p' "$dir/hook.conf" 2>/dev/null | head -n 1)
    [ -n "$v" ] && wait=$v
    out=$(curl --silent --fail --max-time $((wait + 5)) \
            --header @"$auth" --header 'Content-Type: application/json' \
            --data-binary @- --unix-socket "$sock" http://hoot/permission 2>/dev/null) || exit 0
    case "$out" in
      '{"hookSpecificOutput":'*) printf '%s\n' "$out" ;;
    esac
    ;;
  event)
    curl --silent --fail --max-time 2 \
         --header @"$auth" --header 'Content-Type: application/json' \
         --data-binary @- --unix-socket "$sock" http://hoot/event >/dev/null 2>&1
    ;;
  *)
    drain
    ;;
esac
exit 0
