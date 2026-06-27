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
import shlex
import time
import uuid

import iterm2

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CFG_DIR = os.path.expanduser("~/.config/cc-tabs")
BY_TAB_DIR = os.path.join(CFG_DIR, "by-tab")          # <uuid> -> cc session id (hook writes)
BY_NAME_DIR = os.path.join(CFG_DIR, "by-name")        # <uuid> -> human label (`ccs name` writes)
BY_SESSION_DIR = os.path.join(CFG_DIR, "by-session")  # <session-id> -> label (follows a session across tabs)
REGISTRY_PATH = os.path.join(CFG_DIR, "registry.json")  # daemon-owned reconciliation metadata
LIVE_PATH = os.path.join(CFG_DIR, "live")             # uuids of currently-open tabs (one per line)
RESTORE_REQ_PATH = os.path.join(CFG_DIR, "restore.req")  # `ccs restore` drops a JSON list here

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


def write_live(uuids) -> None:
    """Record currently-open tab UUIDs so `ccs` can tell live tabs from closed ones."""
    os.makedirs(CFG_DIR, exist_ok=True)
    tmp = LIVE_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(sorted(uuids)))
    os.replace(tmp, LIVE_PATH)


def by_tab_path(tab_uuid: str) -> str:
    return os.path.join(BY_TAB_DIR, tab_uuid)


def by_name_path(tab_uuid: str) -> str:
    return os.path.join(BY_NAME_DIR, tab_uuid)


def read_name_file(tab_uuid: str) -> str:
    """The explicit label set by `ccs name` for this tab, or '' if none."""
    try:
        with open(by_name_path(tab_uuid)) as f:
            return f.read().strip()
    except (FileNotFoundError, OSError):
        return ""


def read_session_id(tab_uuid: str) -> str:
    """The Claude session id mapped to this tab (hook-written), or '' if none."""
    try:
        with open(by_tab_path(tab_uuid)) as f:
            return f.read().strip()
    except (FileNotFoundError, OSError):
        return ""


def by_session_path(sid: str) -> str:
    return os.path.join(BY_SESSION_DIR, sid)


def read_session_name(sid: str) -> str:
    """A label that follows a session across tabs (so resume re-applies the name)."""
    if not sid:
        return ""
    try:
        with open(by_session_path(sid)) as f:
            return f.read().strip()
    except (FileNotFoundError, OSError):
        return ""


def write_session_name(sid: str, name: str) -> None:
    os.makedirs(BY_SESSION_DIR, exist_ok=True)
    tmp = by_session_path(sid) + ".tmp"
    with open(tmp, "w") as f:
        f.write(name)
    os.replace(tmp, by_session_path(sid))


def resolve_label(tab_uuid: str, native: str) -> str:
    """Effective label: explicit tab label > the session's carried label > native title."""
    return read_name_file(tab_uuid) or read_session_name(read_session_id(tab_uuid)) or native


def real_title(cwd: str, title: str) -> str:
    """
    A tab title only counts as a *human label* if it isn't just the folder name
    (or a path) that shells/themes set automatically. Otherwise return '' so the
    daemon falls back to position — i.e. unnamed tabs behave exactly as before.
    """
    title = (title or "").strip()
    if not title or "/" in title:          # paths are auto-titles, never labels
        return ""
    base = os.path.basename(cwd.rstrip("/")) if cwd else ""
    if base and title.lower() == base.lower():
        return ""
    return title


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


async def get_tab_var(tab, name: str) -> str:
    try:
        return (await tab.async_get_variable(name)) or ""
    except Exception:
        return ""


async def apply_title(tab, label: str) -> None:
    """Make `label` a sticky tab-title override (beats theme/OSC auto-titles)."""
    try:
        if label and (await get_tab_var(tab, "title")) != label:
            await tab.async_set_title(label)
    except Exception:
        pass


def is_shell_job(job: str) -> bool:
    job = (job or "").lower().lstrip("-")
    base = job.rsplit("/", 1)[-1]
    return base in SHELL_NAMES


async def fingerprint(app, session):
    """(cwd, profileName, tab_index, name, tab) — signals used to re-link a tab.

    `name` is the tab's human label (a real Edit-Tab-Title override, not the
    theme's auto cwd-title); '' when the tab is unnamed. `tab` is returned so the
    caller can stamp a sticky title on it.
    """
    cwd = await get_var(session, "path")
    profile = await get_var(session, "profileName")
    tab_index = -1
    tab = None
    title = ""
    try:
        win, tab = app.get_window_and_tab_for_session(session)
        if win and tab:
            tab_index = win.tabs.index(tab)
            title = await get_tab_var(tab, "title")
    except Exception:
        pass
    return cwd, profile, tab_index, real_title(cwd, title), tab


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
def reconcile(fp, registry: dict, claimed: set[str]) -> str | None:
    """
    Match a restored session to an unclaimed registry entry.
    Require a cwd match (never guess across different projects). A human label is
    the strongest signal — an exact name match within the same cwd wins outright
    (so renamed tabs survive reordering). Otherwise break ties by profile match,
    then nearest tab position. Returns a UUID or None.
    """
    cwd, profile, tab_index, name = fp[0], fp[1], fp[2], fp[3]
    if not cwd:
        return None
    # 1) strongest signal: same cwd + same label.
    if name:
        for tab_uuid, meta in registry.items():
            if tab_uuid in claimed:
                continue
            if meta.get("cwd") == cwd and meta.get("name") == name:
                return tab_uuid
    # 2) fall back to profile + nearest position.
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


def prune(registry: dict, claimed: set[str]) -> bool:
    """
    Drop entries for tabs that are gone (not claimed this startup) AND never had a
    Claude session (no by-tab mapping). Resumable entries are kept. Returns True
    if anything was removed.
    """
    removed = False
    for tab_uuid in list(registry):
        if tab_uuid in claimed:
            continue
        if os.path.exists(by_tab_path(tab_uuid)):   # resumable -> keep
            continue
        registry.pop(tab_uuid, None)
        try:
            os.remove(by_name_path(tab_uuid))
        except OSError:
            pass
        removed = True
    return removed


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
    cwd, profile, tab_index, name, tab = await fingerprint(app, session)

    if mode == "restore" and not (tab_uuid and tab_uuid in registry):
        # User variable was lost across reboot (or unknown) -> reconcile by fingerprint.
        tab_uuid = reconcile((cwd, profile, tab_index, name), registry, claimed) or new_uuid()
    elif not tab_uuid:
        tab_uuid = new_uuid()

    claimed.add(tab_uuid)

    # Stamp identity back onto the session and persist metadata.
    try:
        await session.async_set_variable("user.cc_tab", tab_uuid)
    except Exception:
        pass
    # Effective label: explicit tab label > the session's carried label > native.
    label = resolve_label(tab_uuid, name)
    registry[tab_uuid] = {
        "cwd": cwd, "profile": profile, "tab_index": tab_index,
        "name": label, "updated_at": now(),
    }
    save_registry(registry)

    if label and tab is not None:
        asyncio.create_task(apply_title(tab, label))
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
# Daemon-driven restore: `ccs restore` writes a JSON request; the daemon owns the
# whole operation so identity, title, and the resume command never race with the
# shell (the bug where `export CC_TAB` got typed into Claude instead of bash).
# ---------------------------------------------------------------------------
async def _send_resume(session, tab_uuid: str, cwd: str) -> None:
    """Once the new tab has a live shell, export CC_TAB and resume via `cc`."""
    if not await wait_for_shell(session):
        return
    if not is_shell_job(await get_var(session, "jobName")):
        return
    cd = f"cd {shlex.quote(cwd)} && " if cwd else ""
    try:
        # Leading spaces keep these out of history (HIST_IGNORE_SPACE). `cc`
        # resumes via the by-tab mapping and applies CC_ARGS.
        await session.async_send_text(f" export CC_TAB={tab_uuid}\n {cd}cc\n")
    except Exception:
        pass


async def process_restore(app, connection, registry: dict, entries: list) -> None:
    for e in entries:
        if not isinstance(e, dict):
            continue
        tab_uuid = e.get("uuid")
        sid = e.get("sid")
        cwd = e.get("cwd", "")
        name = e.get("name", "")
        if not (tab_uuid and sid):
            continue
        try:
            win = app.current_terminal_window
            if win is None:
                win = await iterm2.Window.async_create(connection)
                tab = win.tabs[0] if win.tabs else None
            else:
                tab = await win.async_create_tab()
            if tab is None:
                continue
            session = tab.current_session
            if session is None:
                continue
            # Claim the new session so our own NewSessionMonitor provisioning skips
            # it (no await between create and this add -> no provision can sneak in).
            PROVISIONED.add(session.session_id)
            await session.async_set_variable("user.cc_tab", tab_uuid)
            registry[tab_uuid] = {**registry.get(tab_uuid, {}),
                                  "cwd": cwd, "name": name, "updated_at": now()}
            if name:
                asyncio.create_task(apply_title(tab, name))
            asyncio.create_task(_send_resume(session, tab_uuid, cwd))
        except Exception:
            pass
    save_registry(registry)


async def consume_restore_request(app, connection, registry: dict) -> None:
    """Pick up and execute a pending `ccs restore` request, if any."""
    try:
        if not os.path.exists(RESTORE_REQ_PATH):
            return
        with open(RESTORE_REQ_PATH) as f:
            entries = json.load(f)
        os.remove(RESTORE_REQ_PATH)
        if isinstance(entries, list):
            await process_restore(app, connection, registry, entries)
    except Exception:
        try:
            os.remove(RESTORE_REQ_PATH)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Live label refresh: catch renames (native Edit-Tab-Title or `ccs name`) without a
# restart, and keep each tab's title sticky.
# ---------------------------------------------------------------------------
async def refresh_loop(app, connection, registry: dict, interval: float = 5.0) -> None:
    prev_live = None
    while True:
        await asyncio.sleep(interval)
        await consume_restore_request(app, connection, registry)
        changed = False
        live: set[str] = set()
        try:
            for win in app.terminal_windows:
                for tab in win.tabs:
                    for s in tab.sessions:
                        tab_uuid = await get_var(s, "user.cc_tab")
                        if not tab_uuid:
                            continue
                        live.add(tab_uuid)
                        if tab_uuid not in registry:
                            continue
                        cwd = registry[tab_uuid].get("cwd", "")
                        native = real_title(cwd, await get_tab_var(tab, "title"))
                        label = resolve_label(tab_uuid, native)
                        if label and label != registry[tab_uuid].get("name"):
                            registry[tab_uuid]["name"] = label
                            registry[tab_uuid]["updated_at"] = now()
                            changed = True
                            asyncio.create_task(apply_title(tab, label))
                        # Mirror the label onto the session so a future resume
                        # (in any tab) re-applies it — fixes names lost on restore.
                        sid = read_session_id(tab_uuid)
                        if label and sid and read_session_name(sid) != label:
                            write_session_name(sid, label)
        except Exception:
            pass
        if changed:
            save_registry(registry)
        if live != prev_live:
            write_live(live)
            prev_live = live


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
async def main(connection):
    os.makedirs(BY_TAB_DIR, exist_ok=True)
    os.makedirs(BY_NAME_DIR, exist_ok=True)
    os.makedirs(BY_SESSION_DIR, exist_ok=True)
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

    # Closed-tab cleanup: now that every restored tab has claimed its UUID, drop
    # entries that are gone and were never resumable.
    if prune(registry, claimed):
        save_registry(registry)
    write_live(claimed)

    # Keep labels + the live set fresh, and service `ccs restore` requests.
    asyncio.create_task(refresh_loop(app, connection, registry))

    # Pass 2: anything created from now on is a genuinely new tab.
    async with iterm2.NewSessionMonitor(connection) as mon:
        while True:
            new_id = await mon.async_get()
            s = app.get_session_by_id(new_id)
            if s is not None:
                await provision(app, s, "new", registry, claimed, lock)


if __name__ == "__main__":
    iterm2.run_forever(main)
