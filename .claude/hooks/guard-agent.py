#!/usr/bin/env python3
"""PreToolUse guard for Agent and Workflow: every spawned agent runs on Opus.

The house rule lives in ~/.claude/CLAUDE.md; this makes it enforced rather
than remembered. Forks ignore the model field and are exempt.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hooklib import deny, hooks_off, read_input  # noqa: E402


def main():
    data = read_input()
    if hooks_off():
        return
    tool = data.get("tool_name")
    inp = data.get("tool_input", {}) or {}
    if tool == "Agent":
        if inp.get("subagent_type") == "fork":
            return
        if inp.get("model") != "opus":
            deny("House rule: every spawned agent runs on Opus — add `model: \"opus\"` to this Agent call "
                 "(got %r). Compensate with a fully specified prompt." % (inp.get("model"),))
    elif tool == "Workflow":
        script = inp.get("script") or ""
        if not script:
            return
        # Count calls in code, not in comments or string literals.
        script = re.sub(r"/\*.*?\*/", " ", script, flags=re.S)
        script = re.sub(r"//[^\n]*", " ", script)
        script = re.sub(r"`(?:\\.|[^`\\])*`|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'",
                        lambda m: "'opus'" if "opus" in m.group(0) else "''", script)
        agents = len(re.findall(r"\bagent\s*\(", script))
        opus = len(re.findall(r"model\s*:\s*['\"]opus['\"]", script))
        if agents > opus:
            deny("House rule: every `agent()` call in a Workflow script sets `model: 'opus'` "
                 "(%d agent() calls, %d with model: 'opus')." % (agents, opus))


if __name__ == "__main__":
    main()
