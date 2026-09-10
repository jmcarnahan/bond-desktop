#!/usr/bin/env python3
"""PreToolUse gate for `git commit`: the commit is checked before it exists.

1. Not on main.
2. Nothing secret or non-fictional is staged (this repo is PUBLIC).
3. A schema change is complete: schemaVersion bumped, the new drift_schemas
   json and generated snapshot staged, and the snapshot diff is a sane size
   (the corrupted-snapshot shape is ~30k added lines).
4. The gates ran: a green stamp from gate.sh newer than every staged source.
   Without one, the analyzer runs here (5 s); tests are then reported as
   unverified in the context the model sees.
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hooklib import (GIT, ask, bare_command, current_branch, deny, effective_cwd, git,  # noqa: E402
                     hooks_off, pre_tool, read_input, repo_root, run_analyze, stamp_path)

SECRET_PATTERNS = [
    (r"client_secret\s*[:=]\s*['\"]?[A-Za-z0-9~._-]{12,}", "client secret"),
    (r"\bAKIA[0-9A-Z]{16}\b", "AWS access key"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key"),
    (r"\bxox[abp]-[A-Za-z0-9-]{10,}", "Slack token"),
    (r"\bghp_[A-Za-z0-9]{20,}\b", "GitHub token"),
    (r"\bsk-[A-Za-z0-9]{20,}\b", "API key"),
    (r"\beyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}\.", "JWT"),
]
SECRET_FILES = re.compile(r"(^|/)(\.env(\..*)?|.*\.env|local\.mk|SigningLocal\.xcconfig|.*\.(p12|pem|key|mobileprovision|p8|cer|keychain|dmg))$"
                          r"(?<!\.example)(?<!\.sample)(?<!\.template)(?<!\.dist)")
# dist/local/ is the one directory whose whole contents are machine-local: the
# notarization key, the Sparkle signing key and dist.env. Extension alone does
# not catch them (dist.env is covered, AuthKey_X.p8 is, a stray note is not),
# so the directory itself is the rule.
SECRET_DIRS = re.compile(r"(^|/)dist/local/")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")
# Every domain the tracked tree already uses as a fixture (git grep sweep,
# 2026-09-09) plus the reserved fictional TLDs. Anything containing "example"
# is fictional by construction (example.com, corp.example, sub.example.co.uk).
FICTIONAL_DOMAINS = re.compile(
    r"(example|northwind|fabrikam|contoso|adventure-?works|acme|fake|dummy|placeholder"
    r"|(^|\.)(test|local|invalid|localhost)$|(^|\.)bond\.\w+$"
    r"|(^|\.)(x\.com|y\.com|b\.com|lo\.com|bulk\.com|bank\.com|news\.com|noreply\.com"
    r"|odata\.bind|onmicrosoft\.com|anthropic\.com|noreply\.github\.com|github\.com|microsoft\.com)$)",
    re.I,
)
# Test and doc trees hold fixtures; a credential-shaped string there is a
# question for the user, not a hard stop.
FIXTURE_DIRS = re.compile(r"^(app/test/|docs/|tmp/)")
GENERATED_DIR = "app/test/drift/bond/generated"
SNAPSHOT_LINE_CAP = 8000


def staged_files(root):
    return [l for l in git(root, "diff", "--cached", "--name-only").splitlines() if l]


def staged_added_lines(root, *paths):
    diff = git(root, "diff", "--cached", "-U0", "--", *paths, timeout=30)
    for line in diff.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            yield line[1:]


def schema_version(text):
    m = re.search(r"int\s+get\s+schemaVersion\s*=>\s*(\d+)\s*;", text or "")
    return int(m.group(1)) if m else None


def _drift_statements(text):
    text = re.sub(r"--[^\n]*", "", text or "")
    return sorted(re.sub(r"\s+", " ", s).strip() for s in text.split(";") if s.strip())


def drift_semantic_change(root):
    """True when the staged schema.drift differs from HEAD in more than
    comments, whitespace or statement order; only then is a version bump due."""
    head = git(root, "show", "HEAD:app/lib/data/schema.drift", timeout=30)
    staged = git(root, "show", ":app/lib/data/schema.drift", timeout=30)
    return _drift_statements(head) != _drift_statements(staged)


def check_schema(root, staged):
    if "app/lib/data/schema.drift" not in staged or not drift_semantic_change(root):
        return
    problems = []
    if "app/lib/data/database.dart" not in staged:
        problems.append("database.dart is not staged (bump schemaVersion and add the fromXToY step)")
        new_v = None
    else:
        new_v = schema_version(git(root, "show", ":app/lib/data/database.dart"))
        old_v = schema_version(git(root, "show", "HEAD:app/lib/data/database.dart"))
        if new_v is None or old_v is None or new_v <= old_v:
            problems.append("schemaVersion was not bumped (HEAD %s, staged %s)" % (old_v, new_v))
    if new_v:
        # The set a real bump commit carries (see d5ffc0a, v13->v14): the
        # snapshot json, the generated test snapshot and its version switch,
        # the migration steps, and the data classes.
        for want in ("app/drift_schemas/bond/drift_schema_v%d.json" % new_v,
                     "%s/schema_v%d.dart" % (GENERATED_DIR, new_v),
                     "%s/schema.dart" % GENERATED_DIR,
                     "app/lib/data/database.steps.dart",
                     "app/lib/data/database.g.dart"):
            if want not in staged:
                problems.append("%s is not staged — run `make app-migrations` then `make app-gen` and stage the generated output" % want)
    added = sum(1 for _ in staged_added_lines(root, GENERATED_DIR))
    if added > SNAPSHOT_LINE_CAP:
        problems.append("%d added lines under %s — that is the corrupted-snapshot shape (raw make-migrations); "
                        "regenerate with `make app-migrations`" % (added, GENERATED_DIR))
    if problems:
        deny("Schema change is incomplete:\n- " + "\n- ".join(problems)
             + "\n(If the generated files are deliberately landing in a later commit, the user can set BOND_HOOKS_OFF=1 for that commit.)")


def staged_added_lines_by_file(root):
    diff = git(root, "diff", "--cached", "-U0", timeout=30)
    current = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
        elif line.startswith("+") and not line.startswith("+++"):
            yield current or "", line[1:]


def check_secrets(root, staged):
    hard, soft = [], []
    for f in staged:
        if SECRET_FILES.search(f) or SECRET_DIRS.search(f):
            hard.append("staged file %s is a local secret/config file" % f)
    for f, line in staged_added_lines_by_file(root):
        fixture = bool(FIXTURE_DIRS.match(f))
        for pat, label in SECRET_PATTERNS:
            if re.search(pat, line):
                (soft if fixture else hard).append("%s in %s: %s" % (label, f, line.strip()[:100]))
        for m in EMAIL.finditer(line):
            if not FICTIONAL_DOMAINS.search(m.group(1)):
                soft.append("email address at a domain not on the fictional list, in %s: %s" % (f, m.group(0)))
    if hard:
        deny("Public-repo scan found:\n- " + "\n- ".join(sorted(set(hard))[:12]))
    if soft:
        ask("Public-repo scan: please confirm these are fixtures, not real data:\n- " + "\n- ".join(sorted(set(soft))[:12]))


def check_gates(root, staged):
    stamp = stamp_path(root, "last-green")
    newest = 0.0
    for f in staged:
        try:
            newest = max(newest, os.path.getmtime(os.path.join(root, f)))
        except OSError:
            pass
    fresh = os.path.exists(stamp) and os.path.getmtime(stamp) >= newest
    if fresh:
        try:
            info = json.load(open(stamp))
            return "Green gate stamp: %s passed / %s skipped, analyzer clean (%s)." % (
                info.get("passed"), info.get("skipped"), info.get("when"))
        except (OSError, ValueError):
            return "Green gate stamp present."
    if not any(f.endswith((".dart", ".drift", ".yaml", ".lock")) for f in staged):
        return "No Dart sources staged; gates not required."
    status, tail = run_analyze(root, timeout=40)
    if status == "issues":
        deny("No fresh green gate stamp and `flutter analyze` is not clean:\n" + "\n".join(tail.splitlines()[-15:]) +
             "\nFix the issues, then run .claude/hooks/gate.sh before committing.")
    if status == "unavailable":
        return ("No green gate stamp newer than the staged files, and the hook could not run the analyzer (%s). "
                "Nothing was verified for this commit; run `.claude/hooks/gate.sh <label>` yourself." % tail)
    open(stamp_path(root, "analyze-ok", create=True), "w").write(str(time.time()))
    return ("Analyzer clean at commit time, but no green gate stamp newer than the staged files: "
            "the test suite was NOT verified for this commit. Run `.claude/hooks/gate.sh <label>` "
            "(cd app && flutter analyze && flutter test) before the commit that closes a phase.")


def main():
    data = read_input()
    if hooks_off() or data.get("tool_name") != "Bash":
        return
    cmd = data.get("tool_input", {}).get("command", "") or ""
    if not re.search(GIT + r"commit\b", bare_command(cmd)):
        return
    cwd = effective_cwd(cmd, data.get("cwd") or os.getcwd())
    root = repo_root(cwd)
    if not root:
        return
    if current_branch(root) == "main":
        deny("Never commit to main: create or switch to the round's feature branch first.")
    staged = staged_files(root)
    if not staged:
        return
    check_secrets(root, staged)
    check_schema(root, staged)
    note = check_gates(root, staged)
    pre_tool(context="commit-gate: " + note)


if __name__ == "__main__":
    main()
