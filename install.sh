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

  (Or point the marketplace at the GitHub repo URL once pushed.)
EOF

# Prereq reminders ------------------------------------------------------------
say "Manual prerequisites (one-time):"
cat <<'EOF'
  - iTerm2 > Settings > General > Magic > Enable Python API
  - iTerm2 > Settings > General > Startup > Use System Window Restoration Setting
  - System Settings > Desktop & Dock > "Close windows when quitting an application" = OFF
  - Install iTerm2 Shell Integration so restored tabs report cwd:
        https://iterm2.com/documentation-shell-integration.html
  - jq must be installed (the hook uses it):  brew install jq

Then quit & reopen iTerm2 once so the daemon auto-launches.
Verify the wiring any time with:  ./test/verify.sh
EOF

say "Done."
