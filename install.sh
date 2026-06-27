#!/usr/bin/env bash
# install.sh — wire up the three cc-tabs pieces on this machine.
#
#   1. iTerm2 AutoLaunch daemon  (owns per-tab identity, drives resume)
#   2. `cc` shell function       (sourced from ~/.zshrc)
#   3. Claude Code plugin        (SessionStart hook; printed install command)
#
# Re-runnable. Nothing is overwritten without -f. No sudo.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE="${1:-}"
AUTOLAUNCH="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
ZSHRC="$HOME/.zshrc"
SOURCE_LINE="source \"$REPO/shell/cc.zsh\""

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
SHELL_INTEGRATION_OK=0

# iTerm2 Shell Integration gives restored tabs a reliable `cwd`, which the daemon
# needs to reconcile a tab whose identity variable was lost across a reboot.
# Not strictly required (exact re-link via user.cc_tab works without it), but the
# reboot-survival fallback depends on it — so detect, and offer to install it.
ensure_shell_integration() {
  local file="$HOME/.iterm2_shell_integration.zsh"
  local src='test -e "${HOME}/.iterm2_shell_integration.zsh" && source "${HOME}/.iterm2_shell_integration.zsh"'
  if [[ -f "$file" ]]; then
    say "iTerm2 Shell Integration already installed"
    SHELL_INTEGRATION_OK=1
    return
  fi
  warn "iTerm2 Shell Integration is NOT installed."
  warn "Without it, tabs whose identity is lost on reboot can't be reconciled by cwd."
  if [[ ! -t 0 ]]; then
    warn "Non-interactive shell — skipping. Install later: iTerm2 menu > Install Shell Integration"
    return
  fi
  local reply=""
  printf '    Install it now (downloads %s)? [y/N] ' "$file"
  read -r reply || true
  if [[ "$reply" != [yY] ]]; then
    warn "Skipped. The rest still installs; reboot-survival fallback may not work until you add it."
    return
  fi
  if curl -fsSL https://iterm2.com/shell_integration/zsh -o "$file"; then
    grep -Fqs "$src" "$ZSHRC" 2>/dev/null || {
      printf '\n# iTerm2 shell integration\n%s\n' "$src" >> "$ZSHRC"
    }
    say "  -> installed Shell Integration and sourced it from ~/.zshrc"
    SHELL_INTEGRATION_OK=1
  else
    warn "Download failed. Install manually: iTerm2 menu > Install Shell Integration"
  fi
}

# 1. Daemon -------------------------------------------------------------------
say "Installing iTerm2 AutoLaunch daemon"
mkdir -p "$AUTOLAUNCH"
dest="$AUTOLAUNCH/cc_tabs_daemon.py"
if [[ -e "$dest" && "$FORCE" != "-f" ]]; then
  warn "$dest exists — re-run with -f to overwrite. Skipping."
else
  cp "$REPO/iterm2/cc_tabs_daemon.py" "$dest"
  say "  -> $dest"
fi

# 2. cc shell function --------------------------------------------------------
say "Wiring \`cc\` into $ZSHRC"
if grep -Fqs "$SOURCE_LINE" "$ZSHRC" 2>/dev/null; then
  say "  already sourced"
else
  {
    printf '\n# cc-tabs: resume Claude Code per iTerm2 tab\n'
    printf '%s\n' "$SOURCE_LINE"
  } >> "$ZSHRC"
  say "  -> appended source line (open a new shell to pick it up)"
fi

# 3. Claude Code plugin -------------------------------------------------------
say "Claude Code plugin (SessionStart hook)"
cat <<EOF
  Install the hook plugin from inside Claude Code:

      /plugin marketplace add $REPO
      /plugin install cc-tabs@cc-tabs
      /reload-plugins

  (Or point the marketplace at the GitHub repo URL once pushed.)
  Then quit & reopen iTerm2 — and click "Allow" if it asks to control iTerm2.
EOF

# 4. Shell Integration (a requirement for the reboot fallback) ----------------
say "Checking iTerm2 Shell Integration"
ensure_shell_integration

# jq (the hook needs it) ------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  say "jq present"
else
  warn "jq is missing — the SessionStart hook needs it. Install with: brew install jq"
fi

# Prereq reminders ------------------------------------------------------------
say "Remaining one-time GUI prerequisites (can't be scripted):"
cat <<'EOF'
  - iTerm2 > Settings > General > Magic > Enable Python API
  - iTerm2 > Settings > General > Startup > Use System Window Restoration Setting
  - System Settings > Desktop & Dock > "Close windows when quitting an application" = OFF

Then quit & reopen iTerm2 once so the daemon auto-launches.
EOF

echo
if [[ "$SHELL_INTEGRATION_OK" -eq 1 ]]; then
  say "Done. Verify the full wiring with:  ./test/verify.sh"
else
  warn "Done, but Shell Integration is unmet — reboot-survival fallback may not work yet."
  say  "Verify the full wiring with:  ./test/verify.sh"
fi
