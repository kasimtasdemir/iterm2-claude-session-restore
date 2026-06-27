#!/usr/bin/env python3
"""Pure-logic unit tests for cc_tabs_daemon (no live iTerm2 needed).

Run with an iterm2-capable python (the daemon imports iterm2 at module load).
Exits non-zero if any check fails.
"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "iterm2", "cc_tabs_daemon.py")
spec = importlib.util.spec_from_file_location("ccd", DAEMON)
ccd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ccd)  # safe: run_forever is guarded by __main__

fails = 0


def check(cond, msg):
    global fails
    print(("    OK   " if cond else "    FAIL ") + msg)
    if not cond:
        fails += 1


# --- real_title: only genuine labels survive --------------------------------
check(ccd.real_title("/a/b/CC-sessions", "CC-sessions") == "", "title == folder name -> ignored")
check(ccd.real_title("/a/b/CC-sessions", "cc tabs") == "cc tabs", "real label -> kept")
check(ccd.real_title("/a/b/CC-sessions", "~/a/b/CC-sessions") == "", "path-like title -> ignored")
check(ccd.real_title("/a/b/CC-sessions", "") == "", "empty title -> ignored")

# --- reconcile: a name match beats position ---------------------------------
reg = {
    "A": {"cwd": "/p", "profile": "Default", "tab_index": 0, "name": "cc tabs"},
    "B": {"cwd": "/p", "profile": "Default", "tab_index": 1, "name": ""},
}
check(ccd.reconcile(("/p", "Default", 9, "cc tabs"), reg, set()) == "A",
      "same cwd + name match wins over far position")
check(ccd.reconcile(("/p", "Default", 1, ""), reg, set()) == "B",
      "no name -> nearest position")
check(ccd.reconcile(("/other", "Default", 0, ""), reg, set()) is None,
      "different cwd -> no match")

# --- prune: drop gone+unused, keep resumable --------------------------------
with tempfile.TemporaryDirectory() as d:
    ccd.CFG_DIR = d
    ccd.BY_TAB_DIR = os.path.join(d, "by-tab")
    ccd.BY_NAME_DIR = os.path.join(d, "by-name")
    os.makedirs(ccd.BY_TAB_DIR)
    os.makedirs(ccd.BY_NAME_DIR)
    open(ccd.by_tab_path("M"), "w").write("sess")     # M: resumable (has session)
    open(ccd.by_name_path("U"), "w").write("ghost")   # U: gone, only a label
    reg2 = {"M": {"cwd": "/p"}, "U": {"cwd": "/p"}, "C": {"cwd": "/p"}}
    ccd.prune(reg2, claimed={"C"})
    check("C" in reg2, "claimed (live) tab kept")
    check("M" in reg2, "unclaimed but resumable kept")
    check("U" not in reg2, "unclaimed + no session pruned")
    check(not os.path.exists(ccd.by_name_path("U")), "pruned tab's by-name file removed")

# --- resolve_label: explicit tab label > session-carried label > native -----
with tempfile.TemporaryDirectory() as d:
    ccd.BY_TAB_DIR = os.path.join(d, "by-tab")
    ccd.BY_NAME_DIR = os.path.join(d, "by-name")
    ccd.BY_SESSION_DIR = os.path.join(d, "by-session")
    for p in (ccd.BY_TAB_DIR, ccd.BY_NAME_DIR, ccd.BY_SESSION_DIR):
        os.makedirs(p)
    open(ccd.by_tab_path("T1"), "w").write("S1")        # tab T1 -> session S1
    open(ccd.by_session_path("S1"), "w").write("beta")  # session carries "beta"
    check(ccd.resolve_label("T1", "native") == "beta", "session label used when tab has none")
    open(ccd.by_name_path("T1"), "w").write("alpha")    # explicit tab label
    check(ccd.resolve_label("T1", "native") == "alpha", "explicit tab label beats session label")
    check(ccd.resolve_label("T2", "native") == "native", "no labels -> native title")

sys.exit(1 if fails else 0)
