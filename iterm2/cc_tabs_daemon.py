#!/usr/bin/env python3
"""
cc_tabs_daemon.py — iTerm2 AutoLaunch daemon for per-tab Claude Code session resume.

What it does
------------
Each iTerm2 session gets a stable identity (`user.cc_tab`, a UUID set as an iTerm2
user-defined variable — immune to OSC title clobbering). The daemon owns a small
on-disk registry so identity survives a full reboot even if the user variable does
not: restored sessions are reconciled to their old UUID by cwd + profile + tab
position. Once a tab's UUID is established, the daemon exports CC_TAB into the
shell and runs `cc`, which resumes the mapped Claude Code session (or starts fresh).

Division of labour
------------------
  * This daemon  -> owns tab identity (CC_TAB) + reconciliation, drives resume.
  * `cc` shell fn -> reads CC_TAB, looks up the saved session id, resumes/falls back.
  * CC SessionStart hook -> writes  ~/.config/cc-tabs/by-tab/<CC_TAB> = session_id.

Install
-------
  pip3 install iterm2
  cp cc_tabs_daemon.py "~/Library/Application Support/iTerm2/Scripts/AutoLaunch/"
  # iTerm2 -> Scripts menu should show it; it auto-launches on next start.

Prereqs for reboot survival
---------------------------
  * System Settings -> Desktop & Dock -> "Close windows when quitting an
    application" = OFF.
  * iTerm2 -> Settings -> General -> Startup -> "Use System Window Restoration
    Setting".
  * iTerm2 -> Settings -> General -> Magic -> Enable Python API.
  * Install iTerm2 Shell Integration (so restored tabs report cwd reliably).
"""

import asyncio
import json
import os
import time
import uuid

import iterm2

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CFG_DIR = os.path.expanduser("~/.config/cc-tabs")
BY_TAB_DIR = os.path.join(CFG_DIR, "by-tab")          # <uuid> -> cc session id (hook writes)
REGISTRY_PATH = os.path.join(CFG_DIR, "registry.json")  # daemon-owned reconciliation metadata

# Sessions already handled this run (guards startup-enumeration vs. new-session monitor).
PROVISIONED: set[str] = set()

SHELL_NAMES = {"zsh", "bash", "fish", "sh", "login", "tcsh", "dash", "ksh"}


# ---------------------------------------------------------------------------
# Registry IO (atomic, tolerant)
# ---------------------------------------------------------------------------
def load_registry() -> dict:
    try:
        with open(REGISTRY_PATH) as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_registry(reg: dict) -> None:
    os.makedirs(CFG_DIR, exist_ok=True)
    tmp = REGISTRY_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(reg, f, indent=2, sort_keys=True)
    os.replace(tmp, REGISTRY_PATH)


def by_tab_path(tab_uuid: str) -> str:
    return os.path.join(BY_TAB_DIR, tab_uuid)


def new_uuid() -> str:
    return uuid.uuid4().hex[:12]


def now() -> int:
    return int(time.time())


# ---------------------------------------------------------------------------
# Session inspection helpers
# ---------------------------------------------------------------------------
async def get_var(session, name: str) -> str:
    try:
        return (await session.async_get_variable(name)) or ""
    except Exception:
        return ""


def is_shell_job(job: str) -> bool:
    job = (job or "").lower().lstrip("-")
    base = job.rsplit("/", 1)[-1]
    return base in SHELL_NAMES


async def fingerprint(app, session) -> tuple[str, str, int]:
    """(cwd, profileName, tab_index) — the signals used to re-link a restored tab."""
    cwd = await get_var(session, "path")
    profile = await get_var(session, "profileName")
    tab_index = -1
    try:
        win, tab = app.get_window_and_tab_for_session(session)
        if win and tab:
            tab_index = win.tabs.index(tab)
    except Exception:
        pass
    return cwd, profile, tab_index


async def wait_for_shell(session, timeout: float = 120.0, interval: float = 0.5) -> bool:
    """Restored tabs may not have a live shell immediately (or until focused)."""
    waited = 0.0
    while waited < timeout:
        if is_shell_job(await get_var(session, "jobName")):
            return True
        await asyncio.sleep(interval)
        waited += interval
    return False


# ---------------------------------------------------------------------------
# Reconciliation: restored session -> previously known UUID
# ---------------------------------------------------------------------------
def reconcile(fp: tuple[str, str, int], registry: dict, claimed: set[str]) -> str | None:
    """
    Match a restored session to an unclaimed registry entry.
    Require a cwd match (never guess across different projects); break ties by
    profile match, then nearest tab position. Returns a UUID or None.
    """
    cwd, profile, tab_index = fp
    if not cwd:
        return None
    best, best_score, best_dist = None, -1, 1 << 30
    for tab_uuid, meta in registry.items():
        if tab_uuid in claimed:
            continue
        if meta.get("cwd") != cwd:          # hard requirement
            continue
        score = 3 + (1 if profile and meta.get("profile") == profile else 0)
        dist = abs(tab_index - meta.get("tab_index", -999))
        if score > best_score or (score == best_score and dist < best_dist):
            best, best_score, best_dist = tab_uuid, score, dist
    return best


# ---------------------------------------------------------------------------
# Provisioning
# ---------------------------------------------------------------------------
async def provision(app, session, mode: str, registry: dict, claimed: set[str],
                    lock: asyncio.Lock) -> None:
    """mode == 'restore' (session present at startup) or 'new' (created later)."""
    sid = session.session_id
    async with lock:
        if sid in PROVISIONED:
            return
        PROVISIONED.add(sid)

    tab_uuid = await get_var(session, "user.cc_tab")
    cwd, profile, tab_index = await fingerprint(app, session)

    if mode == "restore" and not (tab_uuid and tab_uuid in registry):
        # User variable was lost across reboot (or unknown) -> reconcile by fingerprint.
        tab_uuid = reconcile((cwd, profile, tab_index), registry, claimed) or new_uuid()
    elif not tab_uuid:
        tab_uuid = new_uuid()

    claimed.add(tab_uuid)

    # Stamp identity back onto the session and persist metadata.
    try:
        await session.async_set_variable("user.cc_tab", tab_uuid)
    except Exception:
        pass
    registry[tab_uuid] = {
        "cwd": cwd, "profile": profile, "tab_index": tab_index, "updated_at": now(),
    }
    save_registry(registry)

    asyncio.create_task(activate(session, tab_uuid, mode))


async def activate(session, tab_uuid: str, mode: str) -> None:
    """Wait for a live shell, export CC_TAB, and (on restore) auto-run `cc`."""
    if not await wait_for_shell(session):
        return  # identity is stamped; manual `cc` will still work once shell starts
    # Don't clobber a session that already has Claude (or anything) running.
    if not is_shell_job(await get_var(session, "jobName")):
        return
    try:
        # Leading space keeps these out of history if HIST_IGNORE_SPACE is set.
        await session.async_send_text(f" export CC_TAB={tab_uuid}\n")
        if mode == "restore" and os.path.exists(by_tab_path(tab_uuid)):
            await session.async_send_text(" cc\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
async def main(connection):
    os.makedirs(BY_TAB_DIR, exist_ok=True)
    app = await iterm2.async_get_app(connection)
    registry = load_registry()
    claimed: set[str] = set()
    lock = asyncio.Lock()

    # Let macOS window restoration settle before we enumerate restored tabs.
    await asyncio.sleep(1.5)

    # Pass 1: everything present at startup == restored. Process in tab order so
    # the position tie-breaker in reconcile() is stable for same-cwd tabs.
    restored = []
    for win in app.terminal_windows:
        for tab in win.tabs:
            for s in tab.sessions:
                idx = win.tabs.index(tab)
                restored.append((idx, s))
    restored.sort(key=lambda t: t[0])
    for _, s in restored:
        await provision(app, s, "restore", registry, claimed, lock)

    # Pass 2: anything created from now on is a genuinely new tab.
    async with iterm2.NewSessionMonitor(connection) as mon:
        while True:
            new_id = await mon.async_get()
            s = app.get_session_by_id(new_id)
            if s is not None:
                await provision(app, s, "new", registry, claimed, lock)


iterm2.run_forever(main)
