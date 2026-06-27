#!/usr/bin/env bash
# verify.sh — prove the cc-tabs pieces are wired correctly, WITHOUT a reboot.
#
# It exercises every part that can be checked offline:
#   1. daemon Python compiles and (if an iterm2-capable python is found) every
#      iTerm2 API call it makes resolves to a real method
#   2. the Claude Code plugin + marketplace manifests validate
#   3. the SessionStart hook records session_id keyed by CC_TAB (and no-ops without it)
#   4. the `cc` zsh function resumes when a mapping exists, and falls back otherwise
#
# What it CANNOT prove offline: that iTerm2 actually restores tabs across a real
# reboot and that user.cc_tab survives it. That is the one manual step (see README).

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
no()   { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[1;33mSKIP\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
hdr "1. Daemon: syntax + iTerm2 API surface"
DAEMON="$REPO/iterm2/cc_tabs_daemon.py"
if python3 -m py_compile "$DAEMON" 2>/tmp/ccverr; then
  ok "cc_tabs_daemon.py compiles"
else
  no "cc_tabs_daemon.py syntax error:"; cat /tmp/ccverr
fi

# Find a python that can import iterm2 (repo venv, or iTerm2's bundled env).
ITERM_PY=""
for cand in \
  "$REPO/venv-iterm/bin/python" \
  "$HOME/Library/Application Support/iTerm2/iterm2env/versions"/*/bin/python3; do
  [ -x "$cand" ] && "$cand" -c 'import iterm2' 2>/dev/null && { ITERM_PY="$cand"; break; }
done
if [ -n "$ITERM_PY" ]; then
  "$ITERM_PY" - "$DAEMON" <<'PY'
import ast, sys, iterm2
src = open(sys.argv[1]).read()
# The exact API attributes the daemon depends on.
need = {
 "iterm2": ["async_get_app", "NewSessionMonitor", "run_forever"],
 "App":    ["get_window_and_tab_for_session", "get_session_by_id", "async_activate"],
 "Session":["async_get_variable", "async_set_variable", "async_send_text"],
 "Tab":    ["async_select", "async_close"],
 "Window": ["async_activate", "async_create_tab"],
}
bad = []
for cls, attrs in need.items():
    obj = iterm2 if cls == "iterm2" else getattr(iterm2, cls)
    for attr in attrs:
        if not hasattr(obj, attr): bad.append(cls+"."+attr)
print("MISSING:"+",".join(bad) if bad else "OK")
PY
else
  skip "no iterm2-capable python found (will run under iTerm2's own runtime at launch)"
fi | while read -r line; do
  case "$line" in
    OK) ok "all iTerm2 API methods used by the daemon exist" ;;
    MISSING:*) no "daemon uses non-existent API: ${line#MISSING:}" ;;
  esac
done

# Single-instance guard: duplicate daemons race over restore.req / the registry,
# which is what made `ccs restore` silently no-op. main() must supersede them.
python3 - "$DAEMON" <<'PY' && ok "single-instance guard wired into main()" || no "single-instance guard missing from main()"
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
defs = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
need = {"terminate_other_instances", "write_pidfile"}
main = next((n for n in ast.walk(tree)
             if isinstance(n, ast.AsyncFunctionDef) and n.name == "main"), None)
called = {n.func.id for n in ast.walk(main) if isinstance(n, ast.Call)
          and isinstance(n.func, ast.Name)} if main else set()
sys.exit(0 if need <= defs and need <= called else 1)
PY

# ---------------------------------------------------------------------------
hdr "2. Plugin + marketplace manifests"
if command -v claude >/dev/null; then
  if claude plugin validate "$REPO/plugins/cc-tabs" >/tmp/ccvplug 2>&1; then
    ok "plugins/cc-tabs validates"
  else
    no "plugin validate failed:"; sed 's/^/      /' /tmp/ccvplug
  fi
else
  skip "claude CLI not on PATH"
fi
for j in "$REPO/.claude-plugin/marketplace.json" \
         "$REPO/plugins/cc-tabs/.claude-plugin/plugin.json" \
         "$REPO/plugins/cc-tabs/hooks/hooks.json"; do
  if jq -e . "$j" >/dev/null 2>&1; then ok "valid JSON: ${j#$REPO/}"; else no "invalid JSON: ${j#$REPO/}"; fi
done

# ---------------------------------------------------------------------------
hdr "3. SessionStart hook (save-session.sh)"
HOOK="$REPO/plugins/cc-tabs/hooks/save-session.sh"
[ -x "$HOOK" ] && ok "hook is executable" || no "hook not executable (chmod +x)"
SANDBOX="$(mktemp -d)"
PAYLOAD='{"session_id":"sess-ABC123","cwd":"/tmp/x","hook_event_name":"SessionStart","source":"startup"}'

# 3a. With CC_TAB set -> writes the session id to by-tab/<CC_TAB>
HOME="$SANDBOX" CC_TAB="tab-XYZ" bash "$HOOK" <<<"$PAYLOAD"
got="$(cat "$SANDBOX/.config/cc-tabs/by-tab/tab-XYZ" 2>/dev/null || true)"
[ "$got" = "sess-ABC123" ] && ok "maps CC_TAB -> session_id ($got)" || no "expected sess-ABC123, got '${got:-<nothing>}'"

# 3b. Without CC_TAB -> writes nothing.  env -u CC_TAB so the test is hermetic
# even when run inside a tab the daemon has already stamped.
SANDBOX2="$(mktemp -d)"
env -u CC_TAB HOME="$SANDBOX2" bash "$HOOK" <<<"$PAYLOAD"
if [ -z "$(ls -A "$SANDBOX2/.config/cc-tabs/by-tab" 2>/dev/null)" ]; then
  ok "no CC_TAB -> writes nothing (safe as a global hook)"
else
  no "wrote a mapping even though CC_TAB was unset"
fi

# ---------------------------------------------------------------------------
hdr "4. cc() zsh function: resume vs. fallback"
if command -v zsh >/dev/null; then
  BIN="$(mktemp -d)"; LOG="$BIN/calls.log"
  cat >"$BIN/claude" <<EOF
#!/usr/bin/env bash
echo "CALL:\$*" >> "$LOG"
# Simulate a stale session id: --resume fails when STALE=1
[ "\${STALE:-0}" = "1" ] && [ "\$1" = "--resume" ] && exit 1
exit 0
EOF
  chmod +x "$BIN/claude"
  run_cc() { # args: extra-env...; invokes `cc` in a clean zsh with mock claude
    env -i HOME="$1" PATH="$BIN:/usr/bin:/bin" STALE="${2:-0}" \
      zsh -fc "source '$REPO/shell/cc.zsh'; cc" >/dev/null 2>&1
  }

  # 4a. mapping present -> resume that id
  H1="$(mktemp -d)"; mkdir -p "$H1/.config/cc-tabs/by-tab"
  printf 'sess-ABC123' > "$H1/.config/cc-tabs/by-tab/tab-XYZ"
  : > "$LOG"
  env -i HOME="$H1" PATH="$BIN:/usr/bin:/bin" CC_TAB="tab-XYZ" STALE=0 \
    zsh -fc "source '$REPO/shell/cc.zsh'; cc" >/dev/null 2>&1
  grep -q 'CALL:--resume sess-ABC123' "$LOG" && ok "mapping present -> 'claude --resume sess-ABC123'" \
    || { no "did not resume mapped id"; sed 's/^/      /' "$LOG"; }

  # 4b. no mapping -> plain claude
  H2="$(mktemp -d)"; : > "$LOG"
  env -i HOME="$H2" PATH="$BIN:/usr/bin:/bin" CC_TAB="tab-NONE" STALE=0 \
    zsh -fc "source '$REPO/shell/cc.zsh'; cc" >/dev/null 2>&1
  if grep -q 'CALL:--resume' "$LOG"; then no "resumed despite no mapping"; else ok "no mapping -> plain 'claude'"; fi

  # 4c. stale id -> resume attempted, then fallback to plain claude
  : > "$LOG"
  env -i HOME="$H1" PATH="$BIN:/usr/bin:/bin" CC_TAB="tab-XYZ" STALE=1 \
    zsh -fc "source '$REPO/shell/cc.zsh'; cc" >/dev/null 2>&1
  if grep -q 'CALL:--resume sess-ABC123' "$LOG" && grep -qx 'CALL:' "$LOG"; then
    ok "stale id -> tries resume, then falls back to fresh 'claude'"
  else
    no "stale-id fallback did not behave as expected"; sed 's/^/      /' "$LOG"
  fi

  # 4d. CC_ARGS is injected into every launch (including the daemon's bare `cc`)
  : > "$LOG"
  env -i HOME="$H1" PATH="$BIN:/usr/bin:/bin" CC_TAB="tab-XYZ" STALE=0 \
    CC_ARGS="--enable-auto-mode" \
    zsh -fc "source '$REPO/shell/cc.zsh'; cc" >/dev/null 2>&1
  grep -q 'CALL:--resume sess-ABC123 --enable-auto-mode' "$LOG" \
    && ok "CC_ARGS forwarded -> 'claude --resume sess-ABC123 --enable-auto-mode'" \
    || { no "CC_ARGS not forwarded"; sed 's/^/      /' "$LOG"; }
else
  skip "zsh not found"
fi

# ---------------------------------------------------------------------------
hdr "5. Daemon logic: labels, reconcile-by-name, prune"
if [ -n "$ITERM_PY" ]; then
  if "$ITERM_PY" "$REPO/test/test_daemon_logic.py" >/tmp/ccvlogic 2>&1; then
    ok "real_title / reconcile-by-name / prune all behave"
    grep '    OK' /tmp/ccvlogic | sed 's/^/    /'
  else
    no "daemon logic test failed:"; sed 's/^/      /' /tmp/ccvlogic
  fi
else
  skip "no iterm2-capable python (daemon-logic tests need it)"
fi

# ---------------------------------------------------------------------------
hdr "6. ccs CLI (name / ls / restore / prune)"
if command -v zsh >/dev/null; then
  ZRUN() { env -i HOME="$1" PATH="/usr/bin:/bin" CC_TAB="${2:-}" CC_ARGS="" \
             zsh -fc "source '$REPO/shell/cc.zsh'; ${3}" 2>&1; }

  # Fake config: AAA live+resumable, BBB resumable(closed), CCC closed/no-session
  SB="$(mktemp -d)"; mkdir -p "$SB/.config/cc-tabs/by-tab" "$SB/.config/cc-tabs/by-name"
  printf '{"AAA":{"cwd":"/tmp","name":"alpha"},"BBB":{"cwd":"/tmp","name":"beta"},"CCC":{"cwd":"/tmp","name":"gamma"}}' \
    > "$SB/.config/cc-tabs/registry.json"
  printf 'sidA' > "$SB/.config/cc-tabs/by-tab/AAA"
  printf 'sidB' > "$SB/.config/cc-tabs/by-tab/BBB"
  printf 'AAA'  > "$SB/.config/cc-tabs/live"

  # ccs name
  ZRUN "$SB" "tabX" "ccs name 'my project'" >/dev/null
  got="$(cat "$SB/.config/cc-tabs/by-name/tabX" 2>/dev/null || true)"
  [ "$got" = "my project" ] && ok "ccs name writes label" || no "ccs name failed (got '${got:-none}')"

  # ccs ls states
  lsout="$(ZRUN "$SB" "" "ccs ls")"
  if echo "$lsout" | grep -qE 'AAA .*live' && echo "$lsout" | grep -qE 'BBB .*resumable' \
     && echo "$lsout" | grep -qE 'CCC .*closed'; then
    ok "ccs ls reports live / resumable / closed correctly"
  else
    no "ccs ls states wrong:"; echo "$lsout" | sed 's/^/      /'
  fi

  # ccs restore (default) -> only BBB (resumable, not live); CCC skipped (no session)
  r1="$(ZRUN "$SB" "" "ccs restore -n")"
  if echo "$r1" | grep -q 'would restore 1 tab' && echo "$r1" | grep -q 'BBB' && ! echo "$r1" | grep -q 'AAA'; then
    ok "ccs restore -n rebuilds only closed+resumable (BBB), skips live & no-session"
  else
    no "ccs restore default selection wrong:"; echo "$r1" | sed 's/^/      /'
  fi

  # ccs restore --all -> AAA + BBB
  r2="$(ZRUN "$SB" "" "ccs restore -n --all")"
  echo "$r2" | grep -q 'would restore 2 tab' && ok "ccs restore --all includes live tabs (2)" \
    || { no "ccs restore --all wrong:"; echo "$r2" | sed 's/^/      /'; }

  # ccs restore (non-dry) writes a valid restore.req for the daemon
  ZRUN "$SB" "" "ccs restore" >/dev/null
  req="$SB/.config/cc-tabs/restore.req"
  if [ -f "$req" ] && jq -e '.[0].sid == "sidB" and (length == 1)' "$req" >/dev/null 2>&1; then
    ok "ccs restore writes a valid restore.req (1 entry, BBB's session)"
  else
    no "ccs restore did not write a valid request:"; cat "$req" 2>/dev/null | sed 's/^/      /'
  fi

  # ccs prune -> drops mapping whose session .jsonl is gone, keeps existing
  SP="$(mktemp -d)"; mkdir -p "$SP/.config/cc-tabs/by-tab" "$SP/.config/cc-tabs/by-name" "$SP/.claude/projects/proj"
  printf 'realsid'  > "$SP/.config/cc-tabs/by-tab/REAL"
  printf 'ghostsid' > "$SP/.config/cc-tabs/by-tab/ZZZ"
  : > "$SP/.claude/projects/proj/realsid.jsonl"
  ZRUN "$SP" "" "ccs prune" >/dev/null
  if [ -f "$SP/.config/cc-tabs/by-tab/REAL" ] && [ ! -f "$SP/.config/cc-tabs/by-tab/ZZZ" ]; then
    ok "ccs prune drops stale mapping, keeps the live session"
  else
    no "ccs prune behaved unexpectedly"
  fi

  # restore de-dupes two registry entries mapping to the same session id
  SD="$(mktemp -d)"; mkdir -p "$SD/.config/cc-tabs/by-tab"
  printf '{"D1":{"cwd":"/tmp","name":"x","tab_index":0},"D2":{"cwd":"/tmp","name":"x","tab_index":1}}' \
    > "$SD/.config/cc-tabs/registry.json"
  printf 'sameSID' > "$SD/.config/cc-tabs/by-tab/D1"
  printf 'sameSID' > "$SD/.config/cc-tabs/by-tab/D2"
  rd="$(ZRUN "$SD" "" "ccs restore -n --all")"
  echo "$rd" | grep -q 'would restore 1 tab' \
    && ok "ccs restore de-dupes the same session id (1, not 2)" \
    || { no "dedupe failed:"; echo "$rd" | sed 's/^/      /'; }

  # restore orders by tab_index (ZZZ index 0 before AAA index 1, despite uuid order)
  SO="$(mktemp -d)"; mkdir -p "$SO/.config/cc-tabs/by-tab"
  printf '{"ZZZ":{"cwd":"/tmp","name":"first","tab_index":0},"AAA":{"cwd":"/tmp","name":"second","tab_index":1}}' \
    > "$SO/.config/cc-tabs/registry.json"
  printf 's1' > "$SO/.config/cc-tabs/by-tab/ZZZ"; printf 's2' > "$SO/.config/cc-tabs/by-tab/AAA"
  ro="$(ZRUN "$SO" "" "ccs restore -n")"
  [ "$(echo "$ro" | grep -oE 'ZZZ|AAA' | head -1)" = "ZZZ" ] \
    && ok "ccs restore rebuilds in saved tab_index order" \
    || { no "ordering wrong:"; echo "$ro" | sed 's/^/      /'; }

  # ccs name mirrors the label onto the session (so resume carries it)
  SM="$(mktemp -d)"; mkdir -p "$SM/.config/cc-tabs/by-tab"
  printf 'sessZ' > "$SM/.config/cc-tabs/by-tab/tabM"
  ZRUN "$SM" "tabM" "ccs name 'follow me'" >/dev/null
  [ "$(cat "$SM/.config/cc-tabs/by-session/sessZ" 2>/dev/null)" = "follow me" ] \
    && ok "ccs name mirrors label to by-session" || no "by-session mirror failed"

  # targeted restore: by name -> only that tab (BBB=beta is resumable+closed)
  rt="$(ZRUN "$SB" "" "ccs restore -n beta")"
  if echo "$rt" | grep -q 'would restore 1 tab' && echo "$rt" | grep -q 'BBB'; then
    ok "ccs restore <name> targets a single tab" || true
  else
    no "targeted restore by name wrong:"; echo "$rt" | sed 's/^/      /'
  fi

  # targeted restore: by uuid works too
  ZRUN "$SB" "" "ccs restore BBB" >/dev/null
  if jq -e '.[0].sid == "sidB" and (length == 1)' "$SB/.config/cc-tabs/restore.req" >/dev/null 2>&1; then
    ok "ccs restore <uuid> writes a single-entry request"
  else
    no "targeted restore by uuid failed"; cat "$SB/.config/cc-tabs/restore.req" 2>/dev/null | sed 's/^/      /'
  fi
  rm -f "$SB/.config/cc-tabs/restore.req"

  # targeted restore refuses a live tab (AAA=alpha is live) -> 0, points at jump
  ra="$(ZRUN "$SB" "" "ccs restore -n alpha")"
  echo "$ra" | grep -q 'would restore 0 tab' && echo "$ra" | grep -qi 'jump' \
    && ok "ccs restore <live> refuses and suggests jump" \
    || { no "targeted restore of live tab wrong:"; echo "$ra" | sed 's/^/      /'; }

  # ccs jump (live tab) writes focus.req with the resolved uuid
  ZRUN "$SB" "" "ccs jump alpha" >/dev/null
  [ "$(cat "$SB/.config/cc-tabs/focus.req" 2>/dev/null)" = "AAA" ] \
    && ok "ccs jump <name> writes focus.req for the daemon" \
    || { no "ccs jump did not write focus.req"; }
  rm -f "$SB/.config/cc-tabs/focus.req"

  # ccs jump refuses a non-live tab (BBB is resumable/closed)
  jb="$(ZRUN "$SB" "" "ccs jump beta" 2>&1)"
  [ ! -f "$SB/.config/cc-tabs/focus.req" ] && echo "$jb" | grep -qi "isn't open" \
    && ok "ccs jump <closed> refuses (no focus.req)" \
    || { no "ccs jump should refuse closed tab:"; echo "$jb" | sed 's/^/      /'; }

  # bare `ccs` (menu) with no TTY falls back to a plain listing
  mb="$(ZRUN "$SB" "" "ccs")"
  echo "$mb" | grep -qE 'AAA .*live' \
    && ok "bare ccs (menu) falls back to ls when non-interactive" \
    || { no "menu non-TTY fallback wrong:"; echo "$mb" | sed 's/^/      /'; }

  # ccs close (live tab) writes close.req; refuses a non-live tab
  ZRUN "$SB" "" "ccs close alpha" >/dev/null
  [ "$(cat "$SB/.config/cc-tabs/close.req" 2>/dev/null)" = "AAA" ] \
    && ok "ccs close <live> writes close.req" || no "ccs close did not write close.req"
  rm -f "$SB/.config/cc-tabs/close.req"
  cb="$(ZRUN "$SB" "" "ccs close beta" 2>&1)"
  [ ! -f "$SB/.config/cc-tabs/close.req" ] && echo "$cb" | grep -qi "isn't open" \
    && ok "ccs close <closed> refuses (no close.req)" \
    || { no "ccs close should refuse closed tab:"; echo "$cb" | sed 's/^/      /'; }

  # ccs forget (non-live) writes forget.req; refuses a live tab
  ZRUN "$SB" "" "ccs forget beta" >/dev/null
  [ "$(cat "$SB/.config/cc-tabs/forget.req" 2>/dev/null)" = "BBB" ] \
    && ok "ccs forget <closed> writes forget.req" || no "ccs forget did not write forget.req"
  rm -f "$SB/.config/cc-tabs/forget.req"
  fb="$(ZRUN "$SB" "" "ccs forget alpha" 2>&1)"
  [ ! -f "$SB/.config/cc-tabs/forget.req" ] && echo "$fb" | grep -qi "is live" \
    && ok "ccs forget <live> refuses (no forget.req)" \
    || { no "ccs forget should refuse live tab:"; echo "$fb" | sed 's/^/      /'; }
else
  skip "zsh not found"
fi

# ---------------------------------------------------------------------------
hdr "7. Host prerequisites"
command -v jq  >/dev/null && ok "jq present" || no "jq missing (hook needs it): brew install jq"
[ -f "$HOME/.iterm2_shell_integration.zsh" ] && ok "iTerm2 Shell Integration installed" \
  || skip "iTerm2 Shell Integration not detected — cwd reconcile fallback won't work without it"

# ---------------------------------------------------------------------------
printf '\n\033[1mSummary:\033[0m \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m, \033[1;33m%d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
