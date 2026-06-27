#!/usr/bin/env bash
# save-session.sh — Claude Code SessionStart hook for cc-tabs.
#
# Reads the SessionStart event JSON on stdin and, when the launching tab carries
# a CC_TAB identity (exported by cc_tabs_daemon.py), records the current
# session id at  ~/.config/cc-tabs/by-tab/<CC_TAB>.  The `cc` shell function
# reads that file to resume the session after a reboot.
#
# No-ops quietly when CC_TAB is unset (e.g. a tab the daemon hasn't stamped, or
# Claude Code launched outside iTerm2), so it is safe as a global hook.

set -euo pipefail

# Nothing to key the mapping on -> do nothing.
[ -n "${CC_TAB:-}" ] || exit 0

dir="$HOME/.config/cc-tabs/by-tab"
mkdir -p "$dir"

# session_id is guaranteed in the SessionStart payload; bail if jq/json is odd.
sid="$(jq -r '.session_id // empty')"
[ -n "$sid" ] || exit 0

# Atomic write so a half-written file is never read by `cc`.
tmp="$(mktemp "$dir/.tmp.XXXXXX")"
printf '%s' "$sid" > "$tmp"
mv -f "$tmp" "$dir/$CC_TAB"
