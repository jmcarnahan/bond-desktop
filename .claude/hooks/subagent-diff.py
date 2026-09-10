#!/usr/bin/env python3
"""NOT WIRED. Kept only as a record of why.

The idea was a SubagentStop hook handing the main loop `git status --short`
after each agent. In practice `additionalContext` on SubagentStop does not
annotate the result: it CONTINUES the agent, so a finished reviewer was woken
again and again (23 firings in one transcript) and its final report was
replaced by complaints about the loop. The only non-continuing outputs on
SubagentStop are silence or a hard block, neither of which carries context.
A PostToolUse hook on the Agent tool would only cover synchronous agents.
So the main loop keeps running `git status --short` itself; this file may be
deleted.
"""
