#!/usr/bin/env python3
"""Replay every Bash command in this project's Claude Code transcripts through
guard-bash.py and report what the guard would have done.

    python3 .claude/hooks/replay_history.py            # summary by rule
    python3 .claude/hooks/replay_history.py --show 'checkout <'   # commands in matching groups

This is the convergence test for the rule table: every deny or ask it prints
is either a genuine past rule break (there were about sixty in the first 24
sessions) or a false positive to fix; every rewrite must leave quoted data
untouched (checked here). Git lookups are stubbed so 20k commands take
seconds; the main-branch rule is therefore not exercised (it is trivially
right). Runs in-process; nothing is executed.
"""
import collections
import glob
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from hooklib import segments  # noqa: E402

spec = importlib.util.spec_from_file_location("gb", os.path.join(HERE, "guard-bash.py"))
gb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gb)


class Decision(Exception):
    def __init__(self, kind, reason):
        self.kind, self.reason = kind, reason


def _deny(reason):
    raise Decision("deny", reason)


def _ask(reason):
    raise Decision("ask", reason)


def _pre_tool(decision=None, reason=None, updated_input=None, context=None):
    raise Decision("rewrite", (updated_input or {}).get("command", ""))


gb.deny, gb.ask, gb.pre_tool = _deny, _ask, _pre_tool
gb.current_branch = lambda cwd: "feature"
gb.repo_root = lambda cwd: ROOT
gb.effective_cwd = lambda cmd, cwd: cwd
gb.hooks_off = lambda: False
_payload = {}
gb.read_input = lambda: _payload


def judge(cmd, agent):
    _payload.clear()
    _payload.update({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": ROOT})
    if agent:
        _payload["agent_id"] = "replay"
    try:
        gb.main()
    except Decision as d:
        return d.kind, d.reason
    return "allow", ""


def transcripts():
    slug = "-" + ROOT.strip("/").replace("/", "-")
    base = os.path.expanduser("~/.claude/projects/%s/" % slug)
    return glob.glob(base + "*.jsonl") + glob.glob(base + "*/subagents/*.jsonl")


def commands():
    for f in transcripts():
        agent = "/subagents/" in f
        with open(f) as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if o.get("type") != "assistant":
                    continue
                for c in o.get("message", {}).get("content", []):
                    if c.get("type") == "tool_use" and c.get("name") == "Bash":
                        yield (c["input"].get("command", "") or ""), agent


def data_segments(cmd):
    return [t for t, code in segments(cmd, False) if not code]


def main():
    show = None
    if len(sys.argv) > 2 and sys.argv[1] == "--show":
        show = sys.argv[2]
    by_kind = collections.Counter()
    groups = collections.defaultdict(list)
    broken_rewrites = []
    n = 0
    for cmd, agent in commands():
        n += 1
        kind, reason = judge(cmd, agent)
        by_kind[kind] += 1
        if kind in ("deny", "ask"):
            groups[(kind, "agent" if agent else "main", reason[:70])].append(cmd)
        elif kind == "rewrite":
            before, after = data_segments(cmd), data_segments(reason)
            it = iter(after)
            if not all(any(x == t for x in it) for t in before):
                broken_rewrites.append(cmd)
    print("commands replayed: %d   decisions: %s" % (n, dict(by_kind)))
    print("rewrites that touched quoted data (must be 0): %d" % len(broken_rewrites))
    for cmd in broken_rewrites[:5]:
        print("   BROKEN:", re.sub(r"\s+", " ", cmd)[:140])
    print()
    for (kind, who, reason), cmds in sorted(groups.items(), key=lambda kv: (kv[0][0], -len(kv[1]))):
        print("%-5s %-5s %4d  %s" % (kind, who, len(cmds), reason))
        if show and show in reason:
            for c in cmds:
                print("        ", re.sub(r"\s+", " ", c)[:150])
    sys.exit(1 if broken_rewrites else 0)


if __name__ == "__main__":
    main()
