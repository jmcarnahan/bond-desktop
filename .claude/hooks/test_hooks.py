#!/usr/bin/env python3
"""Replays the rule table against guard-bash.py and guard-agent.py.

    python3 .claude/hooks/test_hooks.py

Every case is a real command shape from past sessions or a review finding.
A rule change that flips one of these is a regression, not a refinement.
The commit gate is exercised separately (it needs a staged tree); see its
docstring — except its secret-file rule, whose regex is replayed here
because one lookbehind is all that lets a template be committed. The one
branch-dependent case (`git commit` on main) adapts to the branch the suite
runs on.
"""
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from hooklib import current_branch  # noqa: E402

ON_MAIN = current_branch(ROOT) == "main"


def run(script, payload):
    out = subprocess.run([sys.executable, os.path.join(HERE, script)],
                         input=json.dumps(payload), capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        return "error", out.stderr.strip()
    if not out.stdout.strip():
        return "allow", ""
    hso = json.loads(out.stdout)["hookSpecificOutput"]
    if "updatedInput" in hso:
        return "rewrite", hso["updatedInput"].get("command", "")
    return hso.get("permissionDecision", "allow"), hso.get("permissionDecisionReason", "")


def bash(cmd, agent=False):
    cmd = cmd.replace("/REPO", ROOT)   # cases spell the checkout as /REPO
    p = {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": ROOT, "hook_event_name": "PreToolUse"}
    if agent:
        p["agent_id"] = "agent-test"
    return p


BASH_CASES = [
    # (expected, command, in_agent)
    ("deny", "git add -A && git commit -m x", False),
    ("deny", "git add . ", False),
    ("deny", "git add -f -A", False),
    ("deny", "git add -A; git status", False),
    ("deny", "git add .|cat", False),
    ("deny", "git -C /REPO add -A", False),
    ("deny", "git -C app stash", False),
    ("deny", "git --no-pager -C . reset --hard HEAD", False),
    ("deny", 'cd app && git commit -am "x"', False),
    ("deny", "git checkout -- app/lib/x.dart", False),
    ("deny", "git checkout -- .", False),
    ("deny", "git checkout main -- .", False),
    ("deny", "git checkout HEAD~1 app/lib/x.dart", False),
    ("deny", "git restore app/lib/x.dart", False),
    ("deny", "git restore --staged --worktree app/lib/x.dart", False),
    ("deny", "git stash push -q -- app/lib", False),
    ("deny", "git stash", False),
    ("deny", "git reset --hard HEAD", False),
    ("deny", "git clean -fd", False),
    ("deny", "git push --force origin x", False),
    ("deny", "git commit --no-verify -m x", False),
    ("deny", "cd app && dart format lib/screens/inbox_screen.dart", False),
    ("deny", "cd app && dart run drift_dev make-migrations", False),
    ("deny", "cd app && dart run drift_dev schema generate drift_schemas/bond/ test/drift/bond/generated/", False),
    ("deny", "dart run build_runner build --delete-conflicting-outputs", False),
    ("deny", "rm -rf tmp", False),
    ("deny", "rm -rf ./tmp", False),
    ("deny", "rm -rf /REPO/tmp", False),
    ("deny", "rm -rf tmp/*", False),
    ("deny", "rm -rf tmp/PLAN-*", False),
    ("deny", "rm tmp/PLAN-attachments.md", False),
    ("deny", "cd app && rm -rf test/drift/bond/generated", False),
    ("deny", "rm -f drift_schemas/bond/drift_schema_v13.json", False),
    ("deny", "rm drift_schemas/bond/drift_schema_v13.json", False),
    ("deny", "rm -rf .claude/hooks", False),
    ("rewrite", 'if [ "$a" == "$b" ]; then echo same; fi', False),
    ("rewrite", "echo === 27B temp ===", False),
    ("rewrite", "echo a =b", False),
    # Shell semantics: the apostrophe opens a string, so zsh never runs the
    # `git add -A` here either; the hook mirrors the shell rather than guessing.
    ("allow", "echo don't; git add -A; echo won't", False),
    ("rewrite", "git log --format='%h %s' -3; echo ===", False),
    ("allow", "ioreg -rd1 -c AGXAccelerator | awk -F'= ' '/\"gpu-core-count\"/{print \"gpu:\" $2}'; echo \"=== done ===\"", False),
    ("deny", "bash <<'EOF'\ngit add -A\nEOF", False),
    ("allow", "git stash list", False),
    ("allow", "git stash show -p stash@{0}", False),
    ("allow", "git restore --staged app/lib/x.dart", False),
    ("allow", "git clean -nd", False),
    ("allow", "git checkout -b feat/x", False),
    ("allow", "git checkout -b feat/x origin/main", False),
    ("allow", "git checkout feat/x", False),
    ("allow", "git checkout feat/x 2>&1 | tail -1", False),
    ("allow", "git checkout feat/x; git log -1", False),
    ("allow", "git checkout feat/x || exit 1", False),
    ("allow", "git diff --stat", False),
    ("allow", "git merge-base main HEAD", False),
    ("allow", "git branch --show-current", False),
    ("allow", "gh repo view --json defaultBranchRef -q .defaultBranchRef.name", False),
    ("allow", "gh pr view 21 --json state", False),
    ("allow", "git reset -q app/lib/x.dart", False),
    ("allow", "cd app && dart format --output=none --set-exit-if-changed lib/x.dart", False),
    ("allow", "make app-migrations && make app-gen", False),
    ("allow", "rm -rf /private/tmp/claude-501/x/scratchpad/out", False),
    ("allow", "rm -rf app/build", False),
    ("allow", "rm -rf .claude/worktrees/old-one", False),
    ("allow", "rm -rf .claude/hooks/__pycache__", False),
    ("allow", "rm -rf tmp/bench/run-1", False),
    ("allow", 'grep -rn "git add -A" tmp/PLAN-x.md', False),
    ("allow", "cat > f <<'EOF'\ngit checkout -- .\nEOF", False),
    ("allow", "python3 - <<'PY'\nassert s.count(old) == 1\nPY", False),
    ("allow", "cat > probe.py <<'PY'\ncases = [\"bash <<EOF\", \"git add -A\", \"cat <<EOF | bash\"]\nPY\npython3 probe.py", False),
    # The shell ends the data heredoc at the first EOF line, so nothing runs.
    ("allow", "cat > c.txt <<'EOF'\nbash <<EOF\ngit add -A\nEOF\npython3 x.py", False),
    ("deny", "cat > c.txt <<'EOF'\nnotes\nEOF\nbash <<X\ngit add -A\nX", False),
    ("deny", "cat <<'EOF' | bash\ngit add -A\nEOF", False),
    ("allow", "j() { python3 -c 'import sys; print(\"cat <<EOF | bash\")'; }; j; echo \"=== zsh reality check ===\"", False),
    ("rewrite", "python3 - <<'PY'\nx = 1 == 1\nPY\necho === done", False),
    ("allow", "echo '===' && ls", False),
    ("allow", 'git status && printf "%s\\n" ---', False),
    ("allow", '[[ "$a" == "$b" ]] && echo same', False),
    ("allow", 'if [ "$a" = "$b" ]; then echo same; fi', False),
    ("allow", 'test "$x" = ok && echo yes', False),
    ("allow", "echo =", False),
    ("allow", "FOO=bar make -n model", False),
    ("allow", "git log --format=%h -3", False),
    ("allow", "awk -F= '{print $2}' f | cut -d= -f1", False),
    ("allow", "echo \"=== /users ===\" && grep -rn '\"/users\\|users/\\$' x.py | head -40; echo \"=== chat ===\"", False),
    ("allow", "grep -oiE 'https?://[^ \"'\"'\"')]+' added.txt | sort -u; echo \"=== TENANT ===\"", False),
    ("allow", "cd app/macos && xcodebuild -project Runner.xcodeproj -showBuildSettings | grep -m1 CODE_SIGN", False),
    ("ask", "cd app/macos && xcodebuild -workspace Runner.xcworkspace -scheme Runner build", False),
    ("rewrite", "echo === && ls", False),
    ("rewrite", "ls; echo ======; git status", False),
    ("ask", "git push -u origin feat/x", False),
    ("ask", "gh pr create --title x", False),
    ("ask", "git checkout main && git pull", False),
    ("ask", "git checkout -q main", False),
    ("ask", "git switch --quiet main", False),
    ("ask", "git checkout main 2>&1 | tail -1", False),
    ("ask", "git merge --no-ff feat/x", False),
    ("ask", "gh repo delete x", False),
    ("ask", "make app-run", False),
    ("ask", "flutter run -d macos", False),
    ("ask", "make model", False),
    # --- distribution: the signing half asks, the packaging half does not ---
    ("ask", "make dist", False),
    ("ask", "make dist-sign", False),
    ("ask", "make dist-notarize", False),
    ("ask", "make dist-appcast", False),
    ("allow", "make dist-llama", False),
    ("allow", "make dist-dmg AD_HOC=1", False),
    ("allow", "make dist-check", False),
    ("allow", "make -n dist", False),
    # a goal or a variable assignment before the target must not hide it
    ("ask", "make VERSION=2 dist", False),
    ("ask", "make dist-llama dist", False),
    ("allow", "make AD_HOC=1 dist-dmg", False),
    ("ask", "xcrun notarytool submit x.zip", False),
    ("ask", "security import cert.p12", False),
    ("ask", "gh release create v1 x.dmg", False),
    ("allow", "gh release list", False),
    ("deny", "git add app/lib/x.dart", True),
    ("deny", "git commit -m x", True),
    ("deny", "git -C app commit -m x", True),
    ("deny", "git checkout -b feat/y", True),
    ("deny", "git restore --staged app/lib/x.dart", True),
    ("deny", "git branch -D feat/y", True),
    ("allow", "git branch -v", True),
    ("allow", "git branch --show-current", True),
    ("allow", "git log --oneline main..HEAD && git worktree list && git status --short", True),
    ("deny", "git worktree add ../x feat/x", True),
    ("allow", "git diff --stat && git status --short", True),
    ("allow", "cd app && flutter test test/x_test.dart 2>&1 | tail -3", True),
    # --- red-team round (realistic bypasses, now closed) ---
    ("deny", "git checkout .", False),
    ("deny", "git checkout app/lib/screens/inbox_screen.dart", False),
    ("deny", "git checkout -f feat/x", False),
    ("deny", "git switch --discard-changes feat/x", False),
    ("deny", 'rm -rf "tmp"', False),
    ("deny", "rm -rf 'tmp'", False),
    ("deny", 'rm -rf "$PWD/tmp"', False),
    ("deny", 'rm -rf "tmp/PLAN-x.md"', False),
    ("deny", 'git reset "--hard" HEAD', False),
    ("deny", "git add -u", False),
    ("deny", "git add --update", False),
    ("deny", 'git commit -qam "msg"', False),
    ("deny", "git commit -va -m x", False),
    ("deny", "git commit -n -m x", False),
    ("deny", "git clean -d -f", False),
    ("deny", "git clean -x -f", False),
    ("deny", "git add ./", False),
    ("deny", "git add app/lib/x.dart .", False),
    ("deny", "git add app/ .", False),
    ("deny", "git add -Af", False),
    ("deny", "git add :/", False),
    ("deny", "git add '*'", False),
    ("deny", "git stage -A", False),
    ("deny", "rm -rf app/lib/data", False),
    ("deny", "rm -rf app/test/drift", False),
    ("deny", "git --git-dir=.git --work-tree=. add -A", False),
    ("deny", "git --git-dir .git --work-tree . stash", False),
    ("deny", 'sh -c "git add -A"', False),
    ("deny", "bash -lc 'git add -A'", False),
    ("deny", 'eval "git add -A"', False),
    ("deny", "cat <<'EOF' | bash\ngit add -A\nEOF", False),
    ("deny", "cd app && dart run build_runner watch --delete-conflicting-outputs", False),
    ("deny", ": > tmp/PLAN-attachments.md", False),
    ("deny", 'echo "" > tmp/PLAN-attachments.md', False),
    ("deny", "truncate -s 0 tmp/PLAN-attachments.md", False),
    ("deny", "cp /dev/null tmp/PLAN-attachments.md", False),
    ("deny", "mv tmp ../tmp-backup", False),
    ("deny", "mv tmp /tmp/old-tmp", False),
    ("deny", "cd tmp && rm -rf *", False),
    ("deny", "cd tmp && rm -f *.md", False),
    ("deny", "mv app/drift_schemas/bond/drift_schema_v13.json /tmp/", False),
    ("deny", "find tmp -name '*.md' -delete", False),
    ("deny", "git add \\\n-A", False),
    ("deny", "flutter format lib/x.dart", False),
    ("deny", "git push -uf origin x", False),
    ("deny", "git push origin +HEAD:main", False),
    ("ask", "git worktree remove --force ../wt", False),
    ("ask", "gh api -X POST repos/o/r/pulls -f title=x", False),
    ("ask", "gh api repos/o/r/pulls -f title=x", False),
    ("ask", "make -C app app-run", False),
    ("ask", "open app/build/macos/Build/Products/Debug/bond.app", False),
    ("deny", "git reset --soft HEAD~1", True),
    ("deny", "git apply /tmp/p.patch", True),
    ("deny", "git branch -f main HEAD", True),
    ("deny", 'sh -c "git commit -m x"', True),
    ("allow", "git checkout feat/x", False),
    ("allow", "git checkout v1.2.3", False),
    ("allow", "git checkout -b feat/x origin/main", False),
    ("allow", "git checkout -B feat/x", False),
    ("allow", "dart format -o none lib/x.dart", False),
    ("allow", "dart format --output none lib/x.dart", False),
    ("allow", "git add -u app/", False),
    ("allow", "git add app/lib/x.dart", False),
    ("allow", "git add -N app/lib/new.dart", False),
    ("deny" if ON_MAIN else "allow", "git commit -m x -q", False),
    ("deny" if ON_MAIN else "allow", "git commit --amend --no-edit", False),
    ("allow", "git clean -n -d", False),
    ("allow", "git push --dry-run origin x 2>&1 | head -1", False),
    ("allow", "rm -f /tmp/gate-*.log", False),
    ("allow", "rm -rf /tmp/notes.md", False),
    ("allow", "rm tmp/bench/run.json", False),
    ("allow", "rm -rf tmp/.gate", False),
    ("allow", "flutter test > /tmp/x.log 2>&1", False),
    ("allow", "echo x >> tmp/PLAN-attachments.md", False),
    ("allow", "cp docs/pipeline/README.md /tmp/", False),
    ("allow", "mv /tmp/a.log /tmp/b.log", False),
    ("allow", "git worktree list", False),
    ("allow", "git worktree add .claude/worktrees/x -b feat/x", False),
    ("allow", "gh api repos/o/r/pulls/21 --jq .state", False),
    ("allow", "make -n model", False),
    ("allow", "grep -rn \"--no-verify\" .claude/hooks", False),
    ("allow", "grep -rn 'stash' app/lib | head", False),
    ("allow", "git rm --cached app/lib/old.dart", False),
    ("allow", "git mv app/lib/a.dart app/lib/b.dart", False),
    ("allow", "git log -p -- app/lib/x.dart | head", False),
    ("allow", "git reset app/lib/x.dart", True == False),
    # --- false-deny round ---
    ("allow", "cp ~/.claude/plans/quiet-nebula.md tmp/PLAN-notifications.md && echo synced", False),
    ("deny", "cp /dev/null tmp/PLAN-notifications.md", False),
    ("allow", "mv docs/pipeline/01-sync-ingest.md.tmp docs/pipeline/01-sync-ingest.md", False),
    ("deny", "mv tmp/PLAN-x.md /tmp/", False),
    ("allow", "git checkout --ours docs/pipeline/04-extraction.md docs/pipeline/07-replies.md", False),
    ("allow", "git checkout --theirs app/lib/data/database.steps.dart && make app-migrations", False),
    ("allow", "git checkout -b fix/x main", False),
    ("allow", "git switch -c fix/x main", False),
    ("allow", "cat > tmp/PLAN-new.md <<'EOF'\n# plan\nEOF", False),
    ("allow", "cat > /REPO/tmp/PLAN-new.md <<'EOF'\n# plan\nEOF", False),
    ("allow", "cat > docs/pipeline/13-new.md <<'EOF'\n# doc\nEOF", False),
    ("allow", "python3 gen.py > tmp/PLAN-new.md", False),
    ("allow", "tee tmp/PLAN-new.md < /dev/null", False),
    ("allow", "flutter analyze 2>&1 | tee /tmp/a.log | tail -1", False),
    ("deny", "> tmp/PLAN-attachments.md", False),
    ("deny", "true > tmp/PLAN-attachments.md", False),
    ("deny", "ls; : > tmp/PLAN-attachments.md", False),
    ("allow", "rm tmp/*.log", False),
    ("allow", "rm -f tmp/bench-*.json", False),
    ("deny", "rm -f tmp/*.md", False),
    ("deny", "rm -f tmp/PLAN*", False),
    ("allow", "rm -rf app/build/tmp", False),
    ("allow", "rm -rf ~/tmp/x", False),
    ("allow", "git rm --cached docs/pipeline/x.md", False),
    ("allow", "git checkout feat/x # switch back", False),
    ("allow", "git checkout $(git merge-base main HEAD)", False),
    ("allow", "cat > tool/publish.sh <<'EOF'\ngit checkout -- .\nrm -rf tmp\nEOF\nchmod +x tool/publish.sh", False),
    ("deny", "/bin/bash -c 'git add -A'", False),
    ("allow", "dart format --help", False),
    ("allow", "dart run build_runner build --help", False),
    ("allow", "grep -rn -- --no-verify .claude/hooks/", False),
    ("allow", "rm -f /tmp/drift_schema_v13.json", False),
    ("allow", "rm -rf docs/releasenotes-draft.md", False),
    ("allow", "git checkout -b main-sync origin/main", False),
    ("allow", "flutter run --help", False),
    ("rewrite", "case $x in =*) echo eq;; esac", False),
    ("allow", "git tag -l", True),
    ("allow", "git stash list", True),
    ("deny", "git tag v1", True),
    ("allow", "git switch -c chore/x && git add .gitignore && git commit -m x", False),
    ("allow", "git checkout -b feat/x && git commit -m x", False),
    # Branch-dependent: on main the commit is denied, elsewhere it is allowed.
    ("deny" if ON_MAIN else "allow", "git commit -m gate", False),
]

AGENT_CASES = [
    ("allow", {"tool_name": "Agent", "tool_input": {"model": "opus", "prompt": "x"}}),
    ("deny", {"tool_name": "Agent", "tool_input": {"prompt": "x"}}),
    ("deny", {"tool_name": "Agent", "tool_input": {"model": "sonnet", "prompt": "x"}}),
    ("allow", {"tool_name": "Agent", "tool_input": {"subagent_type": "fork", "prompt": "x"}}),
    ("deny", {"tool_name": "Workflow", "tool_input": {"script": "await agent('a', {model: 'opus'}); await agent('b', {})"}}),
    ("allow", {"tool_name": "Workflow", "tool_input": {"script": "await agent('a', {label: 'a', model: 'opus'})"}}),
    ("allow", {"tool_name": "Workflow", "tool_input": {"script": "// agent(x) in a comment\nawait agent('a', {model: 'opus'}) /* agent( */"}}),
]


# The commit gate's secret-file rule: a template is the one env-shaped file
# that may be committed; everything a real value could live in may not.
SECRET_FILE_CASES = [
    (False, ".env.example"),
    (False, "docs/settings.md"),
    (True, ".env"),
    (True, ".env.local"),
    (True, "app/prod.env"),
    (True, "local.mk"),
    (True, "app/macos/SigningLocal.xcconfig"),
    (True, "certs/dev.p12"),
]


def secret_files():
    spec = importlib.util.spec_from_file_location("commit_gate", os.path.join(HERE, "commit-gate.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.SECRET_FILES


def main():
    failures = 0
    pattern = secret_files()
    for expected, path in SECRET_FILE_CASES:
        got = bool(pattern.search(path))
        ok = got == expected
        failures += not ok
        print("%s %-7s %-7s %s" % ("ok " if ok else "FAIL", "secret" if expected else "plain",
                                   "secret" if got else "plain", path))
    for expected, cmd, agent in BASH_CASES:
        got, detail = run("guard-bash.py", bash(cmd, agent))
        ok = got == expected
        failures += not ok
        print("%s %-7s %-7s %s%s" % ("ok " if ok else "FAIL", expected, got, cmd.replace("\n", "⏎")[:70],
                                     "" if ok else "  <- " + detail[:120]))
    for expected, payload in AGENT_CASES:
        got, detail = run("guard-agent.py", payload)
        ok = got == expected
        failures += not ok
        print("%s %-7s %-7s %s" % ("ok " if ok else "FAIL", expected, got, json.dumps(payload["tool_input"])[:70]))
    total = len(BASH_CASES) + len(AGENT_CASES) + len(SECRET_FILE_CASES)
    print("\n%d/%d hook cases pass (branch: %s)" % (total - failures, total, "main" if ON_MAIN else "feature"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
