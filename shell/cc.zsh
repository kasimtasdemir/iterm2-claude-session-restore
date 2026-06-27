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

# ---------------------------------------------------------------------------
# ccs — iTerm2 <-> Claude Code session manager (subcommands)
#   ccs ls                list known tabs: label, state (live/resumable/closed), cwd
#   ccs name [label]      label this tab (no arg prints the current label)
#   ccs restore [--all]   rebuild resumable tabs (recover a closed window)
#   ccs status            this tab's CC_TAB, label, mapped session
#   ccs prune             drop on-disk mappings whose Claude session is gone
# ---------------------------------------------------------------------------
ccs() {
  emulate -L zsh
  local cmd="${1:-status}"
  (( $# )) && shift
  case "$cmd" in
    name)            _ccs_name "$@" ;;
    ls|list)         _ccs_ls "$@" ;;
    restore)         _ccs_restore "$@" ;;
    status|st)       _ccs_status ;;
    prune)           _ccs_prune ;;
    help|-h|--help)  _ccs_help ;;
    *) print -u2 "ccs: unknown subcommand '$cmd' (try: ccs help)"; return 2 ;;
  esac
}

_ccs_help() {
  print -r -- "ccs — iTerm2 <-> Claude Code session manager
  ccs ls                list known tabs: label, state, cwd
  ccs name [label]      label this tab (no arg prints current label)
  ccs restore [--all]   rebuild resumable tabs; --all includes live ones; -n dry-run
  ccs status            this tab's CC_TAB, label, mapped session
  ccs prune             drop mappings whose Claude session no longer exists"
}

_ccs_name() {
  if [[ -z "$CC_TAB" ]]; then
    print -u2 "ccs: \$CC_TAB is unset — is the cc_tabs daemon running?"; return 1
  fi
  local dir="$HOME/.config/cc-tabs/by-name"; mkdir -p "$dir"
  if (( $# == 0 )); then
    [[ -r "$dir/$CC_TAB" ]] && print -r -- "$(<"$dir/$CC_TAB")" || print -- "<unnamed>"
    return 0
  fi
  local name="$*"
  print -r -- "$name" > "$dir/$CC_TAB"
  printf '\033]0;%s\007' "$name"      # instant feedback; daemon makes it sticky
  print -r -- "named this tab: $name"
}

_ccs_status() {
  local cfg="$HOME/.config/cc-tabs"
  if [[ -z "$CC_TAB" ]]; then
    print -- "CC_TAB:   (unset — daemon not active in this tab)"; return 0
  fi
  local label="<unnamed>" sid="<none yet>"
  [[ -r "$cfg/by-name/$CC_TAB" ]] && label="$(<"$cfg/by-name/$CC_TAB")"
  [[ -r "$cfg/by-tab/$CC_TAB"  ]] && sid="$(<"$cfg/by-tab/$CC_TAB")"
  print -- "CC_TAB:   $CC_TAB"
  print -- "label:    $label"
  print -- "session:  $sid"
}

_ccs_ls() {
  local cfg="$HOME/.config/cc-tabs" reg="$HOME/.config/cc-tabs/registry.json"
  if [[ ! -r "$reg" ]]; then print -u2 "ccs: no registry yet ($reg)"; return 1; fi
  local live=""; [[ -r "$cfg/live" ]] && live="$(<"$cfg/live")"
  printf "%-2s %-12s %-16s %-10s %s\n" "" "TAB" "LABEL" "STATE" "CWD"
  local uuid name cwd state cur
  for uuid in ${(f)"$(jq -r 'keys[]' "$reg" 2>/dev/null)"}; do
    name="$(jq -r --arg u "$uuid" '.[$u].name // ""' "$reg")"
    cwd="$(jq -r --arg u "$uuid" '.[$u].cwd // ""' "$reg")"
    if print -r -- "$live" | grep -qx "$uuid"; then
      state="live"
    elif [[ -f "$cfg/by-tab/$uuid" ]]; then
      state="resumable"
    else
      state="closed"
    fi
    cur=" "; [[ "$uuid" == "$CC_TAB" ]] && cur="*"
    printf "%-2s %-12s %-16s %-10s %s\n" "$cur" "$uuid" "${name:-—}" "$state" "${cwd/#$HOME/~}"
  done
}

_ccs_restore() {
  local all=0 dry=0
  while (( $# )); do
    case "$1" in
      --all)         all=1 ;;
      --dry-run|-n)  dry=1 ;;
      *) print -u2 "ccs restore: unknown flag '$1'"; return 2 ;;
    esac; shift
  done
  local cfg="$HOME/.config/cc-tabs"
  local reg="$cfg/registry.json"
  [[ -r "$reg" ]] || { print -u2 "ccs: no registry yet"; return 1; }
  local live=""; [[ -r "$cfg/live" ]] && live="$(<"$cfg/live")"
  local uuid sid cwd name n=0
  for uuid in ${(f)"$(jq -r 'keys[]' "$reg" 2>/dev/null)"}; do
    [[ -f "$cfg/by-tab/$uuid" ]] || continue                         # resumable only
    if (( ! all )) && print -r -- "$live" | grep -qx "$uuid"; then continue; fi  # skip live
    sid="$(<"$cfg/by-tab/$uuid")"
    cwd="$(jq -r --arg u "$uuid" '.[$u].cwd // ""' "$reg")"
    name="$(jq -r --arg u "$uuid" '.[$u].name // ""' "$reg")"
    [[ -n "$sid" && -d "$cwd" ]] || continue
    local shcmd="cd ${(q)cwd} && claude --resume ${sid} ${CC_ARGS}"
    if (( dry )); then
      print -r -- "would restore  ${name:-—}  [$uuid]  ${cwd/#$HOME/~}"
    else
      _ccs_open_tab "$shcmd" "$name"
    fi
    (( n++ ))
  done
  print -r -- "${dry:+(dry-run) }restored $n tab(s)"
}

_ccs_open_tab() {
  /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
  set theCmd to item 1 of argv
  set theName to item 2 of argv
  tell application "iTerm2"
    if (count of windows) = 0 then
      create window with default profile
    else
      tell current window to create tab with default profile
    end if
    tell current session of current window
      write text theCmd
      if theName is not "" then set name to theName
    end tell
  end tell
end run
APPLESCRIPT
}

_ccs_prune() {
  local cfg="$HOME/.config/cc-tabs" proj="$HOME/.claude/projects" n=0 f sid uuid
  setopt local_options null_glob
  for f in "$cfg/by-tab"/*; do
    [[ -f "$f" ]] || continue
    sid="$(<"$f")"; uuid="${f:t}"
    local matches=($proj/*/"$sid.jsonl")
    if [[ -z "$sid" || ${#matches} -eq 0 ]]; then
      rm -f "$f" "$cfg/by-name/$uuid"; (( n++ ))
    fi
  done
  print -r -- "pruned $n stale mapping(s)"
}
