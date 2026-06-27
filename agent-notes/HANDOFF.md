# Handoff — cc-tabs (iTerm2 ⇄ Claude Code session manager)

Notes for the next AI agent taking over this project. Read this first, then `README.md`.

- **Repo:** https://github.com/kasimtasdemir/iterm2-claude-session-restore (public, MIT)
- **Local path:** `/Users/kasimtasdemir/Documents/projects/CC-sessions`
- **Default branch:** `master`
- **Status (2026-06-27):** working end-to-end on the user's machine. 24/24 offline checks pass. Verified across a real reboot and a real `ccs restore`.

## What this is

macOS restores iTerm2 windows/tabs after a reboot, but the processes inside are gone — you get bare shells. This tool gives every tab a stable identity, remembers which Claude Code session ran in it, and re-attaches the right session. It grew into a small session manager: name tabs, list them, rebuild a closed window.

## Architecture — three cooperating pieces

1. **iTerm2 AutoLaunch daemon** — `iterm2/cc_tabs_daemon.py`
   Owns tab identity. Stamps each session with a `user.cc_tab` UUID, persists a registry, reconciles restored tabs after a reboot, exports `CC_TAB` into the shell, applies sticky tab titles, runs the live refresh loop, and services `ccs restore` requests. Runs under iTerm2's bundled Python (the `iterm2` module is provided by iTerm2 for AutoLaunch scripts).

2. **Claude Code plugin** — `plugins/cc-tabs/` (a real CC plugin)
   A `SessionStart` hook (`hooks/save-session.sh`) that, when `CC_TAB` is set in the env, writes `~/.config/cc-tabs/by-tab/<CC_TAB> = <session_id>`. Installed via `/plugin marketplace add <repo>` + `/plugin install cc-tabs@cc-tabs` + `/reload-plugins`.

3. **Shell functions** — `shell/cc.zsh` (sourced from `~/.zshrc`)
   - `cc [claude args]` — the hot path. Resumes this tab's session via `claude --resume <saved-id>` (falls back to fresh). Applies `$CC_ARGS` to every launch.
   - `ccs` umbrella: `ls`, `name [label]`, `restore [--all|-n]`, `status`, `prune`.

### Data flow loop
```
daemon  --exports CC_TAB-->  shell  --runs cc-->  claude
  ^                                                  |
  +--------  hook writes by-tab/<CC_TAB> = sid  <-----+
```

## On-disk data model — `~/.config/cc-tabs/`

| Path | Owner | Meaning |
|---|---|---|
| `registry.json` | daemon | `{uuid: {cwd, profile, tab_index, name, updated_at}}` — reconciliation metadata |
| `by-tab/<uuid>` | hook | tab uuid → Claude `session_id` (what makes a tab "resumable") |
| `by-name/<uuid>` | `ccs name` | explicit per-tab label |
| `by-session/<sid>` | daemon + `ccs name` | label that **follows a session** across tabs (so restore re-applies names) |
| `live` | daemon | uuids of currently-open tabs (one per line); powers `ccs ls`/`restore` |
| `restore.req` | `ccs restore` | JSON list the daemon consumes to rebuild tabs |

Label precedence (`resolve_label`): explicit tab label (`by-name`) > session-carried label (`by-session`) > native tab title.

## The core hard problem (read this)

**`user.cc_tab` does NOT reliably survive iTerm2's window restoration on the user's setup.** Everything hard flows from this:

- When it's lost, identity must be re-derived by **reconcile**: same `cwd` (required) → same `name` → same `profile` → nearest `tab_index`.
- Same-folder, unnamed tabs are only told apart by position, which can shuffle. **Naming a tab (`ccs name`) is the robust fix** — it re-links by name.
- Because a new uuid is minted each reboot, **one session accumulates many tab-uuids**. `dedupe_sessions()` collapses these (keep most-recent per session) at startup, and reconcile **prefers resumable entries**. This was the cause of the most recent bug (reboot not auto-resuming + "opened twice").

If you can find a way to make `user.cc_tab` (or any per-tab identity) actually survive restoration, most of this complexity goes away. Worth investigating.

## How to develop & test

- **Offline test harness:** `./test/verify.sh` — 24 checks. Covers daemon syntax + iTerm2 API method existence, plugin/marketplace validation, the hook, `cc` resume/fallback/CC_ARGS, and the `ccs` CLI (selection logic via `--dry-run`, prune, name mirror).
- **Pure-logic unit tests:** `test/test_daemon_logic.py` — `real_title`, `reconcile` (incl. resumable preference), `dedupe_sessions`, `prune`, `resolve_label`. Run by `verify.sh` under an iterm2-capable python.
- **iterm2 API validation:** there's a local venv at `./venv-iterm/` (gitignored, ~150MB) with `pip install iterm2`. Used to (a) confirm API method names exist before shipping — a wrong method name crashes the daemon silently at launch — and (b) import the daemon for unit tests. Recreate with `python3 -m venv venv-iterm && ./venv-iterm/bin/pip install iterm2`.
- The daemon guards `iterm2.run_forever(main)` under `if __name__ == "__main__":` so it's importable for tests.

### Deploying daemon changes (IMPORTANT)
The daemon in AutoLaunch is a **copy**. After editing `iterm2/cc_tabs_daemon.py` you MUST:
```bash
cp iterm2/cc_tabs_daemon.py "$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch/cc_tabs_daemon.py"
```
…and **the user must quit (⌘Q) & reopen iTerm2** for it to take effect. The running daemon does not hot-reload. `shell/cc.zsh` is sourced live, so new tabs pick up shell changes; existing tabs need `source ~/.zshrc`.

### What can only be verified live (not offline)
- That iTerm2 actually restores tabs across a real reboot and reconcile re-links them.
- `ccs restore` spawning tabs via the iTerm2 API (tab creation, sending the resume into a real shell).
- Sticky titles beating the theme's/Claude's OSC titles.
Always ask the user to run these and report back.

## Prerequisites (one-time, on the host)
- iTerm2 → Settings → General → Magic → **Enable Python API** (first launch shows an "allow control" dialog → Allow).
- iTerm2 → Settings → General → Startup → **Use System Window Restoration Setting**.
- System Settings → Desktop & Dock → **"Close windows when quitting an application" = OFF**.
- iTerm2 **Shell Integration** installed (daemon needs `cwd`). `install.sh` offers to install it.
- `jq` (the hook + `ccs` use it).
- `export CC_ARGS="--enable-auto-mode"` is set in the user's `~/.zshrc` (their preference).

## Gotchas / war stories (so you don't re-learn them)
- **Only ONE daemon may run. Duplicates silently break `ccs restore`.** Each instance runs its own `refresh_loop`, so N daemons race to consume `restore.req` — a *stale* instance can win the `os.remove`, run an old/broken `process_restore`, and drop the request (tab never opens), while the current instance never sees the file. They also fight over the registry, titles, and CC_TAB stamping. Duplicates pile up from manual relaunches, Scripts-menu reloads, or a partial quit. **Fix (2026-06-27):** `main()` calls `terminate_other_instances()` (`pgrep -f cc_tabs_daemon.py`, SIGTERM everything but self+parent) then `write_pidfile()`, so a fresh launch supersedes all predecessors. If `ccs restore` "does nothing," first run `ps -eo pid,lstart,command | grep cc_tabs_daemon | grep -v grep` — more than one python == the bug. Diagnose restore by counting tabs before/after writing a hand-built `restore.req` (registry `updated_at` not advancing == `process_restore` threw and got swallowed).
- **`export CC_TAB` typed into Claude, not bash.** If a restored tab runs `claude` immediately, the daemon's keystrokes land in Claude's prompt. Fix: `ccs restore` is **daemon-driven** — the daemon creates the tab and sends the resume into a real shell. Don't reintroduce a shell-launches-claude-immediately path.
- **zsh `local a=x b="$a/y"` evaluates `$a` before assigning it** (same statement). Caused `ccs restore` to read `/registry.json`. Split declarations.
- **iTerm2 restores tab-title *overrides*** (set via `tab.async_set_title`, == "Edit Tab Title") across restoration; the theme's OSC auto-title does not stick. That's why the daemon owns titles.
- **AppleScript can't set the tab-title override** (only the Python API can) — another reason restore is daemon-driven, not osascript.
- **~5s latency:** labels/titles update on the daemon's refresh tick (`refresh_loop`, interval 5.0s). `ccs restore` is async for the same reason.
- **Window close ≠ app quit:** macOS only snapshots on ⌘Q. Closing a single window is gone for good (use `ccs restore`). This is a platform limit, not a bug.
- **`cctab` was renamed to `ccs name`** (clean break, no alias). Don't resurrect `cctab`.

## Known limitations / open issues
- Two tabs deliberately given the **same name** are ambiguous to reconcile (prefers resumable + position to break ties). Minor.
- `.claude/settings.local.json` is currently tracked in git — it's machine-local; consider gitignoring/removing it.
- No automated end-to-end test of live iTerm2 behavior (inherent — needs a running iTerm2 + reboot).

## Suggested next steps (none urgent)
- Add a short demo GIF + a "Verified on a real reboot" note to the README (the user asked about polish for sharing).
- Consider renaming default branch `master` → `main`.
- Possible features floated: `ccs open <label>` (jump to/open a named session), make refresh interval configurable, investigate `user.cc_tab` survival to simplify reconcile.

## Working with this user
- They test **live** on their own machine and report back with real terminal output — lean on that; it's the only way to validate the iTerm2 bits.
- They value **honesty about what's verified vs. assumed**. Always separate "tested offline" from "needs your live confirmation."
- They iterate fast and welcome design pushback (e.g., they accepted the `cc`+`ccs` umbrella refactor and the clean break on `cctab`).
- Workflow each change: edit → `verify.sh` green → redeploy daemon → commit + push → tell them exactly what to test.
