#!/usr/bin/env zsh
# cc.zsh — the `cc` launcher for the cc-tabs system.
#
# Source this from ~/.zshrc:  source /path/to/cc-tabs/shell/cc.zsh
#
# The cc_tabs daemon exports CC_TAB into each tab's shell. The SessionStart
# hook records the live Claude Code session id at  ~/.config/cc-tabs/by-tab/$CC_TAB.
# `cc` reads that mapping and resumes the right session; if there is no mapping
# (new tab) or the id is stale, it falls back to a fresh `claude`.

# Keep the daemon's leading-space commands (" export CC_TAB=..." / " cc") out of
# shell history. Harmless if already set.
setopt HIST_IGNORE_SPACE 2>/dev/null

cc() {
  emulate -L zsh
  local map="$HOME/.config/cc-tabs/by-tab/$CC_TAB"
  if [[ -n "$CC_TAB" && -r "$map" ]]; then
    local sid
    sid="$(<"$map")"
    if [[ -n "$sid" ]]; then
      # Resume the mapped session. If the id is stale/gone, claude exits non-zero
      # and we fall through to a fresh session below.
      claude --resume "$sid" "$@" && return
    fi
  fi
  claude "$@"
}
