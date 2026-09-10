#!/usr/bin/env python3
"""SessionStart (startup / resume / compact): the re-orientation a phase's
Step 0 otherwise spends three to five tool calls on.

Prints the checkout and worktree boundary, branch state, the active plan's
phase table, the last green gate stamp, and the rules the hooks enforce.
Stdout is injected into the model's context.
"""
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hooklib import git, hooks_off, read_input, repo_root  # noqa: E402

MAX_TABLE_ROWS = 14
SCOPE_WIDTH = 96


def phase_table(path):
    rows, header, in_table = [], None, False
    for line in open(path, encoding="utf-8", errors="replace"):
        if re.match(r"^\|\s*Phase\s*\|", line):
            header, in_table = line.rstrip(), True
            continue
        if in_table:
            if not line.startswith("|"):
                break
            if re.match(r"^\|\s*-", line):
                continue
            rows.append(line.rstrip())
    return header, rows


def state_of(row):
    cells = [c.strip() for c in row.strip().strip("|").split("|")]
    return cells[2].lower() if len(cells) > 2 else ""


def active_plans(root):
    found = []
    for p in glob.glob(os.path.join(root, "tmp", "PLAN-*.md")):
        header, rows = phase_table(p)
        if not header or not rows:
            continue
        open_rows = [r for r in rows if not re.search(r"\b(done|committed|merged|closed|shipped|landed|skipped)\b", state_of(r))]
        if open_rows:
            found.append((os.path.getmtime(p), p, header, rows, len(open_rows)))
    found.sort(reverse=True)
    return found


def shorten(row):
    cells = [c.strip() for c in row.strip().strip("|").split("|")]
    cells = [c if len(c) <= SCOPE_WIDTH else c[:SCOPE_WIDTH - 1] + "…" for c in cells]
    return "| " + " | ".join(cells) + " |"


def main():
    data = read_input()
    if hooks_off():
        return
    cwd = data.get("cwd") or os.getcwd()
    root = repo_root(cwd)
    if not root:
        return
    main_checkout = os.environ.get("CLAUDE_PROJECT_DIR") or root
    lines = ["## bond-desktop session context (hook, %s)" % data.get("source", "start")]
    if os.path.realpath(root) != os.path.realpath(main_checkout):
        lines.append("checkout: WORKTREE %s (main checkout %s) — every path and command stays inside the worktree" % (root, main_checkout))
    else:
        lines.append("checkout: %s (main checkout)" % root)
    status = git(root, "status", "--porcelain=v1", "-b").splitlines()
    branch_line = status[0][3:] if status else "?"
    dirty = len(status) - 1 if status else 0
    lines.append("branch: %s · %s" % (branch_line, "clean" if dirty == 0 else "%d dirty path(s)" % dirty))
    wt = [l for l in git(root, "worktree", "list").splitlines() if l]
    if len(wt) > 1:
        lines.append("worktrees: " + "; ".join(wt))
    plans = active_plans(root)
    if plans:
        _, p, header, rows, n_open = plans[0]
        lines.append("active plan: %s (%d phase(s) not done)" % (os.path.relpath(p, root), n_open))
        lines.append(header)
        for r in rows[:MAX_TABLE_ROWS]:
            lines.append(shorten(r))
        if len(rows) > MAX_TABLE_ROWS:
            lines.append("| … | %d more rows in the plan file | | |" % (len(rows) - MAX_TABLE_ROWS))
        if len(plans) > 1:
            lines.append("other plans with open phases: " + ", ".join(os.path.basename(x[1]) for x in plans[1:]))
    else:
        lines.append("active plan: none (no tmp/PLAN-*.md has an open phase)")
    stamp = os.path.join(root, "tmp", ".gate", "last-green")
    try:
        info = json.load(open(stamp))
        age = int((time.time() - os.path.getmtime(stamp)) / 60)
        lines.append("last green gate: %s passed / %s skipped on %s (%s, %d min ago)" % (
            info.get("passed"), info.get("skipped"), info.get("branch"), info.get("head"), age))
    except (OSError, ValueError):
        lines.append("last green gate: none recorded — `.claude/hooks/gate.sh <label>` runs analyze+test and records it")
    lines.append("hooks enforce: named-path staging; no checkout --/restore/stash/reset; no dart format; "
                 "schema codegen via make app-migrations; push/PR/main-sync/live-app are asks; agents run on Opus; "
                 "commits need a green gate. BOND_HOOKS_OFF=1 disables for a session.")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
