#!/usr/bin/env python3
"""Stop hook: a handback never claims a clean analyzer without proof.

If any .dart file under app/lib or app/test is newer than the last clean
analyze stamp, run `flutter analyze` (5-10 s). Issues in files changed since
the stamp block the stop once, with the list; issues confined to untouched
files are reported to stderr only (they are not this session's to fix). A
clean run refreshes the stamp. `stop_hook_active` guards against looping.
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hooklib import (dart_files_newer_than, hooks_off, read_input, repo_root,  # noqa: E402
                     run_analyze, stamp_path)

_ISSUE = re.compile(r"^\s*(error|warning|info)\s+•.*?•\s+(\S+?):\d+:\d+\s+•", re.M)


def main():
    data = read_input()
    if hooks_off() or data.get("stop_hook_active") or data.get("agent_id"):
        return
    root = repo_root(data.get("cwd") or os.getcwd())
    if not root or not os.path.isdir(os.path.join(root, "app", "lib")):
        return
    stamp = stamp_path(root, "analyze-ok", create=True)
    try:
        last = os.path.getmtime(stamp)
    except OSError:
        last = 0.0
    changed = dart_files_newer_than(root, last)
    if not changed:
        return
    status, text = run_analyze(root, timeout=40)
    if status == "clean":
        open(stamp, "w").write(str(time.time()))
        return
    if status == "unavailable":
        # Missing toolchain is a note for the log, never a reason to block.
        sys.stderr.write("stop-analyze: skipped (%s)\n" % text)
        return
    changed_set = set(changed)
    mine, theirs = [], []
    for line in text.splitlines():
        m = _ISSUE.search(line)
        if not m:
            continue
        rel = os.path.normpath(os.path.join("app", m.group(2)))
        (mine if rel in changed_set else theirs).append(line.strip())
    if not mine:
        sys.stderr.write("stop-analyze: %d analyzer issue(s) only in files not changed since the last clean run; not blocking.\n" % len(theirs))
        return
    print(json.dumps({
        "decision": "block",
        "reason": "`flutter analyze` reports issues in files changed since the last clean run:\n"
                  + "\n".join(mine[:20])
                  + "\nFix these only in files you edited this session; if a file was changed by the user, "
                    "report the issue instead of editing it, then hand back.",
    }))


if __name__ == "__main__":
    main()
