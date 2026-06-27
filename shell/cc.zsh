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

# CC_ARGS: default flags applied to EVERY launch, including the daemon's bare
# `cc` on reboot-restore (which passes no args of its own). Set it in ~/.zshrc, e.g.
#     export CC_ARGS="--enable-auto-mode"
# Per-invocation args you type ("$@") are appended after these.
cc() {
  emulate -L zsh
  local -a extra
  extra=(${(z)CC_ARGS})           # word-split, honoring quotes; empty if unset
  local map="$HOME/.config/cc-tabs/by-tab/$CC_TAB"
  if [[ -n "$CC_TAB" && -r "$map" ]]; then
    local sid
    sid="$(<"$map")"
    if [[ -n "$sid" ]]; then
      # Resume the mapped session. If the id is stale/gone, claude exits non-zero
      # and we fall through to a fresh session below.
      claude --resume "$sid" $extra "$@" && return
    fi
  fi
  claude $extra "$@"
}

# cctab [name] — give this tab a human label. The daemon shows it as a sticky
# iTerm2 tab title (beating the theme's auto cwd-title) and uses it to re-link
# the tab to its Claude session after a reboot — more robust than tab position
# when several tabs share one folder. With no argument, prints the current label.
cctab() {
  emulate -L zsh
  if [[ -z "$CC_TAB" ]]; then
    print -u2 "cctab: \$CC_TAB is unset — is the cc_tabs daemon running?"
    return 1
  fi
  local dir="$HOME/.config/cc-tabs/by-name"
  mkdir -p "$dir"
  if (( $# == 0 )); then
    local cur=""; [[ -r "$dir/$CC_TAB" ]] && cur="$(<"$dir/$CC_TAB")"
    print -r -- "tab $CC_TAB: ${cur:-<unnamed>}"
    return 0
  fi
  local name="$*"
  print -r -- "$name" > "$dir/$CC_TAB"
  printf '\033]0;%s\007' "$name"     # instant feedback; daemon makes it sticky
  print -r -- "named this tab: $name"
}
