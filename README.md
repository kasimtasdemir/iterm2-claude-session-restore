# cc-tabs

An **iTerm2 ⇄ Claude Code session manager.** Every tab keeps a stable identity
and remembers its Claude Code session, so you can **resume the right session in
each tab after a reboot**, name tabs, list them, and rebuild a closed window —
via `cc` and the `ccs` command.

macOS restores your iTerm2 windows and tabs, but the processes inside them are
gone — you come back to bare shells. `cc-tabs` gives every tab a stable identity,
remembers which Claude Code session was running in it, and re-attaches the
correct session automatically when the tab comes back.

```
 before reboot                 after reboot (with cc-tabs)
 ┌───────────┬───────────┐     ┌───────────┬───────────┐
 │ tab A     │ tab B     │     │ tab A     │ tab B     │
 │ claude ▸  │ claude ▸  │ ──▶ │ claude ▸  │ claude ▸  │
 │ session 1 │ session 2 │     │ session 1 │ session 2 │   ← resumed, not lost
 └───────────┴───────────┘     └───────────┴───────────┘
```

## How it works

Three cooperating pieces, one per layer of the problem:

| Piece | Lives in | Job |
|---|---|---|
| `iterm2/cc_tabs_daemon.py` | iTerm2 AutoLaunch | Owns tab identity. Stamps each session with a `user.cc_tab` UUID, persists a small registry, and after a reboot re-links each restored tab to its old UUID by **cwd + profile + tab position**. Exports `CC_TAB` into the shell and runs `cc`. |
| `plugins/cc-tabs` (Claude Code plugin) | `~/.claude` | A `SessionStart` hook that writes the live `session_id` to `~/.config/cc-tabs/by-tab/<CC_TAB>` every time Claude starts. |
| `shell/cc.zsh` | `~/.zshrc` | The `cc` function: looks up the saved session id for this tab and runs `claude --resume <id>`, falling back to a fresh `claude` if there's no mapping or the id is stale. |

The data flow is a loop:

```
daemon  ──exports CC_TAB──▶  shell  ──runs `cc`──▶  claude
  ▲                                                   │
  └──────  hook writes by-tab/<CC_TAB> = session_id  ◀┘
```

Identity survives a reboot two ways, belt-and-suspenders: if iTerm2 preserves the
`user.cc_tab` variable across window restoration, re-linking is **exact**. If it
doesn't, the daemon **reconciles** restored tabs to the registry by cwd (required),
then profile, then nearest tab position.

## Install

```bash
git clone https://github.com/kasimtasdemir/iterm2-claude-session-restore
cd iterm2-claude-session-restore
./install.sh          # copies daemon, appends `cc` to ~/.zshrc, prints plugin command
```

Then, inside Claude Code, install the hook plugin (`cc-tabs` is the plugin's name,
`@cc-tabs` is the marketplace name — both independent of the repo name):

```
/plugin marketplace add kasimtasdemir/iterm2-claude-session-restore
/plugin install cc-tabs@cc-tabs
/reload-plugins
```

`/reload-plugins` activates the SessionStart hook in the current session (the
install command prompts you to run it). New sessions pick it up automatically.

> During `install.sh` you'll be asked for optional default flags (`CC_ARGS`) to
> apply to every `cc` launch — handy if you always start Claude a certain way
> (e.g. `--enable-auto-mode`). Leave blank for none; see [Usage](#usage).

### Prerequisites

`install.sh` handles two of these for you: it **detects iTerm2 Shell Integration
and offers to install it** (needed so restored tabs report their `cwd` for the
reconcile fallback), and it checks that `jq` is present (the hook uses it;
`brew install jq` if not).

The rest are GUI toggles that can't be scripted — set them once:

- **iTerm2 → Settings → General → Magic → Enable Python API**
- **iTerm2 → Settings → General → Startup → "Use System Window Restoration Setting"**
- **System Settings → Desktop & Dock → "Close windows when quitting an application" = OFF**

**Quit & reopen iTerm2 (⌘Q)** so the daemon auto-launches. The first time the
Python API is enabled, iTerm2 shows a dialog asking to let a script **control
iTerm2** — click **Allow** (or **Always Allow for this script**). Without that,
the daemon can't stamp tabs.

### Did it start? (quick check)

Open a fresh tab and run `echo $CC_TAB`. A 12-char hex value means the daemon is
running and stamping tabs. If it's empty:

- **iTerm2 → Scripts** menu should list `cc_tabs_daemon.py`. If it's not there,
  `install.sh` didn't copy it to `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/`.
- **iTerm2 → Scripts → Manage → Console** shows the daemon's stdout/errors — check
  it if the script is listed but `CC_TAB` stays empty (usual cause: Python API not
  enabled, or you dismissed the "Allow control" dialog).
- Confirm **Enable Python API** is on, then fully quit (⌘Q) and reopen iTerm2.

> **Is Shell Integration mandatory?** Not for the tool to run — within a single
> boot everything works without it, and if iTerm2 preserves the `user.cc_tab`
> variable across restoration the re-link is exact. It's only the *fallback*
> (reconciling a tab whose variable was lost, by `cwd`) that needs it — which is
> precisely the reboot case this tool exists for. So `install.sh` doesn't hard-block
> on it; it strongly recommends it and offers to install it in one step.

## Usage

Start Claude with **`cc`** instead of `claude` — that's the launcher that resumes
the right session for the tab (it runs `claude --resume <saved-id>`, falling back
to a fresh session when there's no mapping). Any flags you pass are forwarded:
`cc --model opus` works.

To apply default flags to **every** launch — including the daemon's automatic
`cc` on reboot-restore, which passes no flags of its own — set `CC_ARGS` in
`~/.zshrc`:

```bash
export CC_ARGS="--enable-auto-mode"   # example: always start in auto mode
```

Because resume uses the exact saved session id (not `--continue`, i.e. "most
recent in this folder"), **two tabs open in the same folder each resume their own
session** — which is the whole reason the per-tab mapping exists.

### Commands

`cc` is the hot path; everything else lives under the `ccs` umbrella so there's
one thing to remember:

| Command | What it does |
|---|---|
| `cc [claude args]` | Resume **this tab's** session (fresh if none). Forwards args to `claude`. |
| `ccs ls` | List known tabs: label · state (`live`/`resumable`/`closed`) · cwd. |
| `ccs name [label]` | Label this tab (no arg prints the current label). |
| `ccs restore [--all]` | Rebuild **resumable** tabs — recover a closed window. By default skips tabs that are already open; `--all` includes them; `-n` dry-runs. |
| `ccs status` | This tab's `CC_TAB`, label, and mapped session id. |
| `ccs prune` | Drop on-disk mappings whose Claude session no longer exists. |

### Naming tabs

Same-folder tabs are otherwise told apart only by their left-to-right position,
which can shuffle. Giving a tab a **name** makes its identity stable across
reorders and reboots. Two ways, and they cooperate:

- **`ccs name "my label"`** — labels the current tab. The daemon shows it as a
  sticky iTerm2 tab title (it overrides your theme's auto cwd-title) and stores
  it durably.
- **iTerm2 → Edit Tab Title** (right-click the tab) — the daemon reads this
  natively. A title that's just the folder name is treated as "unnamed" and
  ignored, so only labels you actually choose count.

On restore, a tab with a name re-links by **name first**, falling back to
position only when there's no name — so unnamed tabs behave exactly as before.
Renames (either method) are picked up live within a few seconds. When you close
a tab, its entry is pruned on the next daemon start unless it still has a
resumable session.

### Recovering a closed window

macOS only restores windows on a clean app **quit** (⌘Q), not when you close a
single window. If you close a window by accident, `ccs restore` rebuilds a tab
for each resumable session without needing to quit iTerm2.

`ccs restore` hands the work to the **daemon** (it queues a request the daemon
picks up within a few seconds). The daemon owns tab identity, so it creates each
tab, sets its sticky title, and sends the resume into a real shell — which is why
`CC_TAB` lands in the environment and the **name comes back**, instead of the
resume racing into Claude's prompt. It rebuilds in the saved left-to-right order
and opens **one tab per session** even if the registry has duplicate entries.
`ccs restore --all` also re-opens sessions already live; `ccs restore -n` previews
without doing anything.

## Verify it works

Before trusting it with a real reboot, run the offline harness:

```bash
./test/verify.sh
```

It checks everything that can be checked without rebooting: the daemon compiles
and every iTerm2 API call it makes resolves to a real method; the plugin and
marketplace manifests validate; the hook maps `CC_TAB → session_id` (and safely
no-ops without `CC_TAB`); and `cc` resumes when a mapping exists, falls back when
it doesn't, and recovers from a stale id.

The **one** thing only a reboot can prove — that iTerm2 restores your tabs and the
identities reconcile — is the final manual test:

1. Open a tab, start Claude, do one turn. Check `echo $CC_TAB` is set and
   `cat ~/.config/cc-tabs/by-tab/$CC_TAB` shows the session id.
2. Open a second tab **in the same folder**, start a different Claude session —
   confirm it gets a distinct `CC_TAB`.
3. Reboot. Each tab should auto-run `cc` and land back in its own session.
   Inspect `~/.config/cc-tabs/registry.json` to see how reconcile resolved them.

## Security — read before installing

Both halves run with **your full user permissions**:

- The iTerm2 daemon uses the Python API and can **drive your terminal** (read
  variables, type commands into sessions).
- The Claude Code hook runs a **shell command on every session start**.

That's inherent to what the tool does, not incidental. Everything here is small
and readable — `cc_tabs_daemon.py`, `save-session.sh`, and `cc.zsh` are the whole
surface. Read them before you install, and only install hooks/plugins from
sources you trust. The hook writes exactly one file per tab under
`~/.config/cc-tabs/` and touches nothing else.

## Known edge cases

- **Restored tab with a dead shell.** Some restored tabs don't have a live shell
  until focused. The daemon waits up to 120s, then exports `CC_TAB` and resumes
  once the shell is alive.
- **Two sessions in the same folder, swapped after reboot.** Only happens if
  `user.cc_tab` was lost *and* tab order changed *and* the tabs are unnamed.
  Name them with `ccs name` (or different profiles) and the swap can't happen.
- **Closing a window vs. quitting iTerm2.** macOS window restoration snapshots on
  a clean app **quit** (⌘Q) and replays on relaunch. Closing a single window is
  treated as intentional disposal — the app stays running, so there's no snapshot
  and that window won't come back. Your Claude conversations are still safe on
  disk (`claude --resume <id>` works, and resumable entries stay in the registry);
  only the auto-restore of that window's layout is lost. Use ⌘Q, not window-close,
  if you want a layout back.
- **`ccs name` label latency.** A new label prints instantly but becomes a sticky
  tab title on the daemon's next refresh tick (~5s), not the same instant.
- **No Shell Integration.** Without it the daemon can't read a tab's `cwd`, so the
  reconcile fallback can't match. Exact re-link still works if `user.cc_tab`
  survives, but install Shell Integration for reliability.

## Repo layout

```
iterm2-claude-session-restore/
├── .claude-plugin/marketplace.json   # so `/plugin marketplace add` finds it
├── plugins/cc-tabs/                  # the Claude Code plugin (SessionStart hook)
│   ├── .claude-plugin/plugin.json
│   └── hooks/{hooks.json, save-session.sh}
├── iterm2/cc_tabs_daemon.py          # the iTerm2 AutoLaunch daemon
├── shell/cc.zsh                      # the `cc` function
├── install.sh                        # wires up all three
├── test/verify.sh                    # offline verification harness
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).
