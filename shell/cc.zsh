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
  local cmd="${1:-menu}"          # bare `ccs` opens the interactive manager
  (( $# )) && shift
  case "$cmd" in
    menu|ui|tui)     _ccs_menu ;;
    name)            _ccs_name "$@" ;;
    ls|list)         _ccs_ls "$@" ;;
    restore)         _ccs_restore "$@" ;;
    jump|go)         _ccs_jump "$@" ;;
    status|st)       _ccs_status ;;
    prune)           _ccs_prune ;;
    help|-h|--help)  _ccs_help ;;
    *) print -u2 "ccs: unknown subcommand '$cmd' (try: ccs help)"; return 2 ;;
  esac
}

_ccs_help() {
  print -r -- "ccs — iTerm2 <-> Claude Code session manager
  ccs                       open the interactive manager (TUI)
  ccs ls                    list known tabs: label, state, cwd
  ccs name [label]          label this tab (no arg prints current label)
  ccs restore [sel...]      rebuild tabs; with no selector: all closed+resumable
                            sel = a name or uuid; --all includes live; -n dry-run
  ccs jump <name|uuid>      focus an already-open tab
  ccs status                this tab's CC_TAB, label, mapped session
  ccs prune                 drop mappings whose Claude session no longer exists"
}

# Write a label for an arbitrary tab uuid (used by `ccs name` and the menu).
# Mirrors onto by-session so the label follows the session across a restore.
_ccs_name_uuid() {
  local uuid="$1"; shift; local name="$*"
  local cfg="$HOME/.config/cc-tabs"; mkdir -p "$cfg/by-name"
  print -r -- "$name" > "$cfg/by-name/$uuid"
  local sid=""; [[ -r "$cfg/by-tab/$uuid" ]] && sid="$(<"$cfg/by-tab/$uuid")"
  if [[ -n "$sid" ]]; then mkdir -p "$cfg/by-session"; print -r -- "$name" > "$cfg/by-session/$sid"; fi
}

_ccs_name() {
  if [[ -z "$CC_TAB" ]]; then
    print -u2 "ccs: \$CC_TAB is unset — is the cc_tabs daemon running?"; return 1
  fi
  local cfg="$HOME/.config/cc-tabs"; mkdir -p "$cfg/by-name"
  if (( $# == 0 )); then
    [[ -r "$cfg/by-name/$CC_TAB" ]] && print -r -- "$(<"$cfg/by-name/$CC_TAB")" || print -- "<unnamed>"
    return 0
  fi
  local name="$*"
  _ccs_name_uuid "$CC_TAB" "$name"
  printf '\033]0;%s\007' "$name"      # instant feedback; daemon makes it sticky
  print -r -- "named this tab: $name"
}

# Resolve a selector (exact uuid, else first name match in tab order) to a uuid.
_ccs_resolve() {
  local reg="$HOME/.config/cc-tabs/registry.json" s="$1"
  if jq -e --arg u "$s" 'has($u)' "$reg" >/dev/null 2>&1; then print -r -- "$s"; return 0; fi
  local u
  u="$(jq -r --arg n "$s" \
        'to_entries | sort_by(.value.tab_index) | map(select(.value.name==$n)) | .[0].key // empty' "$reg")"
  [[ -n "$u" ]] && { print -r -- "$u"; return 0; }
  return 1
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
  emulate -L zsh
  local all=0 dry=0
  local -a sel
  while (( $# )); do
    case "$1" in
      --all)         all=1 ;;
      --dry-run|-n)  dry=1 ;;
      --)            shift; sel+=("$@"); break ;;
      -*)            print -u2 "ccs restore: unknown flag '$1'"; return 2 ;;
      *)             sel+=("$1") ;;      # a name or uuid to restore specifically
    esac; shift
  done
  local cfg="$HOME/.config/cc-tabs"
  local reg="$cfg/registry.json"
  [[ -r "$reg" ]] || { print -u2 "ccs: no registry yet"; return 1; }
  local live=""; [[ -r "$cfg/live" ]] && live="$(<"$cfg/live")"

  # Decide the candidate order. Explicit selectors -> just those (resolved, in the
  # order given). Otherwise every tab in saved left-to-right order, so a rebuilt
  # window matches the old one.
  local targeted=0
  local -a order
  if (( ${#sel} )); then
    targeted=1
    local s u
    for s in "${sel[@]}"; do
      if u="$(_ccs_resolve "$s")"; then order+=("$u")
      else print -u2 "ccs restore: no tab matches '$s'"; fi
    done
    (( ${#order} )) || return 1
  else
    order=(${(f)"$(jq -r 'to_entries | sort_by(.value.tab_index) | .[].key' "$reg" 2>/dev/null)"})
  fi

  local uuid sid cwd name n=0
  local -A seen                                                      # de-dupe by session id
  local tmpf="$(mktemp)"
  for uuid in "${order[@]}"; do
    if [[ ! -f "$cfg/by-tab/$uuid" ]]; then                          # resumable only
      (( targeted )) && print -u2 "ccs restore: '$uuid' has no session to resume"
      continue
    fi
    if print -r -- "$live" | grep -qx "$uuid"; then                  # already open
      (( targeted )) && print -u2 "ccs restore: '$uuid' is live (use: ccs jump)"
      (( all || targeted )) || continue
      (( targeted )) && continue
    fi
    sid="$(<"$cfg/by-tab/$uuid")"
    [[ -n "$sid" ]] || continue
    [[ -n "${seen[$sid]}" ]] && continue                            # one tab per session
    seen[$sid]=1
    cwd="$(jq -r --arg u "$uuid" '.[$u].cwd // ""' "$reg")"
    name="$(jq -r --arg u "$uuid" '.[$u].name // ""' "$reg")"
    [[ -d "$cwd" ]] || continue
    if (( dry )); then
      print -r -- "would restore  ${name:-—}  [$uuid]  ${cwd/#$HOME/~}"
    else
      jq -nc --arg uuid "$uuid" --arg sid "$sid" --arg cwd "$cwd" --arg name "$name" \
        '{uuid:$uuid,sid:$sid,cwd:$cwd,name:$name}' >> "$tmpf"
    fi
    (( n++ ))
  done
  if (( dry )); then
    rm -f "$tmpf"
    print -r -- "would restore $n tab(s)"
    return 0
  fi
  # Hand the work to the daemon: it owns tab identity, so the resume command goes
  # into a real shell (CC_TAB lands in the env, the hook tags the session, the
  # name comes back) instead of racing into Claude.
  (( n > 0 )) && jq -s '.' "$tmpf" > "$cfg/restore.req"
  rm -f "$tmpf"
  print -r -- "queued $n tab(s); the daemon will open them in a few seconds."
}

# Focus an already-open tab. The shell can't select an iTerm2 tab itself, so we
# drop the uuid for the daemon, which brings it to the front on its next tick.
_ccs_jump() {
  emulate -L zsh
  local cfg="$HOME/.config/cc-tabs" reg="$HOME/.config/cc-tabs/registry.json"
  (( $# )) || { print -u2 "usage: ccs jump <name|uuid>"; return 2; }
  [[ -r "$reg" ]] || { print -u2 "ccs: no registry yet"; return 1; }
  local uuid
  uuid="$(_ccs_resolve "$1")" || { print -u2 "ccs jump: no tab matches '$1'"; return 1; }
  local live=""; [[ -r "$cfg/live" ]] && live="$(<"$cfg/live")"
  if ! print -r -- "$live" | grep -qx "$uuid"; then
    print -u2 "ccs jump: '$1' isn't open (try: ccs restore $1)"; return 1
  fi
  print -r -- "$uuid" > "$cfg/focus.req"
  print -r -- "jumping to '$1'…"
}

_ccs_prune() {
  local cfg="$HOME/.config/cc-tabs" proj="$HOME/.claude/projects" n=0 f sid uuid
  setopt local_options null_glob
  for f in "$cfg/by-tab"/*; do
    [[ -f "$f" ]] || continue
    sid="$(<"$f")"; uuid="${f:t}"
    local matches=($proj/*/"$sid.jsonl")
    if [[ -z "$sid" || ${#matches} -eq 0 ]]; then
      rm -f "$f" "$cfg/by-name/$uuid"
      [[ -n "$sid" ]] && rm -f "$cfg/by-session/$sid"
      (( n++ ))
    fi
  done
  print -r -- "pruned $n stale mapping(s)"
}

# ---------------------------------------------------------------------------
# Interactive manager (bare `ccs`). A no-dependency zsh TUI: it redraws each
# tick, you pick a row by number, then choose an action. Non-interactive
# callers (no TTY) get a plain `ccs ls` instead so scripts/tests stay sane.
# ---------------------------------------------------------------------------
_ccs_menu() {
  emulate -L zsh
  [[ -t 0 && -t 1 ]] || { _ccs_ls; return 0; }
  local cfg="$HOME/.config/cc-tabs" reg="$HOME/.config/cc-tabs/registry.json"
  [[ -r "$reg" ]] || { print -u2 "ccs: no registry yet ($reg)"; return 1; }
  local -a uuids names cwds states
  local sel live u i cur
  while true; do
    uuids=(); names=(); cwds=(); states=()
    live=""; [[ -r "$cfg/live" ]] && live="$(<"$cfg/live")"
    for u in ${(f)"$(jq -r 'to_entries | sort_by(.value.tab_index) | .[].key' "$reg" 2>/dev/null)"}; do
      uuids+=("$u")
      names+=("$(jq -r --arg u "$u" '.[$u].name // ""' "$reg")")
      cwds+=("$(jq -r --arg u "$u" '.[$u].cwd // ""' "$reg")")
      if print -r -- "$live" | grep -qx "$u"; then states+=("live")
      elif [[ -f "$cfg/by-tab/$u" ]]; then states+=("resumable")
      else states+=("closed"); fi
    done
    clear 2>/dev/null
    print -r -- "iTerm2 ⇄ CC session manager"
    print -r -- ""
    printf "  %-3s %-16s %-10s %s\n" "#" "LABEL" "STATE" "CWD"
    for (( i=1; i<=${#uuids}; i++ )); do
      cur=" "; [[ "${uuids[i]}" == "$CC_TAB" ]] && cur="*"
      printf "%1s %-3s %-16s %-10s %s\n" "$cur" "$i" "${names[i]:-—}" "${states[i]}" "${cwds[i]/#$HOME/~}"
    done
    print -r -- ""
    print -rn -- "Pick # for actions, or: [r]efresh [p]rune [q]uit > "
    read -r sel || { print -r -- ""; return 0; }
    case "$sel" in
      ""|q|Q)  clear 2>/dev/null; return 0 ;;
      r|R)     ;;
      p|P)     _ccs_prune; print -rn -- "press enter… "; read -r _ ;;
      *)
        if [[ "$sel" == <-> ]] && (( sel >= 1 && sel <= ${#uuids} )); then
          _ccs_menu_actions "${uuids[sel]}" "${names[sel]}" "${states[sel]}" "${cwds[sel]}" || return 0
        fi ;;
    esac
  done
}

# Action submenu for one tab. Returns non-zero to quit the whole manager.
_ccs_menu_actions() {
  emulate -L zsh
  local uuid="$1" name="$2" state="$3" cwd="$4" cfg="$HOME/.config/cc-tabs"
  local a nn resumable
  while true; do
    [[ -f "$cfg/by-tab/$uuid" ]] && resumable=1 || resumable=0
    clear 2>/dev/null
    print -r -- "Tab: ${name:-—}   [$uuid]"
    print -r -- "  state: $state    cwd: ${cwd/#$HOME/~}"
    print -r -- ""
    local -a acts
    [[ "$state" == "live" ]] && acts+=("[j]ump to it")
    [[ "$state" != "live" && "$resumable" == 1 ]] && acts+=("[o]pen / restore")
    acts+=("[n]ame" "[b]ack" "[q]uit")
    print -r -- "  ${(j:    :)acts}"
    print -rn -- "> "
    read -r a || return 1
    case "$a" in
      j|J) [[ "$state" == "live" ]] && { _ccs_jump "$uuid"; print -rn -- "press enter… "; read -r _; return 0; } ;;
      o|O) [[ "$state" != "live" && "$resumable" == 1 ]] && { _ccs_restore "$uuid"; print -rn -- "press enter… "; read -r _; return 0; } ;;
      n|N) print -rn -- "new name (blank=cancel): "; read -r nn
           [[ -n "$nn" ]] && { _ccs_name_uuid "$uuid" "$nn"; name="$nn"; } ;;
      b|B|"") return 0 ;;
      q|Q) clear 2>/dev/null; return 1 ;;
    esac
  done
}
