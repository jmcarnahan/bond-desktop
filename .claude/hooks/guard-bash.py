#!/usr/bin/env python3
"""PreToolUse guard for Bash: the house rules, judged on parsed commands.

deny  = the command breaks a rule that has bitten this repo before; the reason
        names the right form so the retry is immediate.
ask   = the user owns the action (push, PR, main sync, live app/servers).
rewrite = zsh expands an unquoted `=word` (two or more characters: `==`,
        `===`, `=foo`) as a command path (`echo ===` failed 87 times in 24
        sessions); the word is quoted in place. zsh's `[` accepts a quoted
        `==`, so the rewrite is always safe. A lone `=` is fine and untouched.

Git commands are parsed into subcommand + tokens (after hooklib.bare_command
has removed quoted strings and data heredocs the shell would not execute),
so bundled short flags (`-qam`), a second flag token (`clean -d -f`), global
options (`-C <dir>`, `--work-tree=.`) and quoted paths are all seen.
Destructive file operations (rm, mv, truncate, cp, `>` redirection, find
-delete) are resolved against the repo root before matching the protected
paths, so `cd tmp && rm -rf *` and `rm -rf "$PWD/tmp"` are caught.

Inside a subagent (hook input carries `agent_id`) the git rules are stricter:
agents report diffs; they never touch the index, commits, or branches.
Set BOND_HOOKS_OFF=1 in the environment to skip every rule for one session.
Run `python3 .claude/hooks/test_hooks.py` after editing any rule.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hooklib import (GIT, ask, bare_command, current_branch, deny,  # noqa: E402
                     effective_cwd, hooks_off, pre_tool, read_input, repo_root,
                     rewrite_code)

# ---------------------------------------------------------------- git rules
_GIT_CALL = re.compile(GIT + r"(?P<sub>[a-z][\w-]*)(?P<rest>[^|;&\n]*)")
_BRANCH_TAKES_VALUE = {"-b", "-B", "--orphan", "--conflict", "--pathspec-from-file"}

EVERYTHING = {".", "./", ":/", ":/.", "*", "-A", "--all", "--no-ignore-removal"}
AGENT_MUTATING = {"add", "stage", "commit", "checkout", "switch", "push", "tag", "merge",
                  "rebase", "cherry-pick", "restore", "apply", "am", "revert", "update-ref",
                  "symbolic-ref", "notes", "filter-branch", "reset", "stash", "rm", "mv",
                  "worktree", "replace"}
AGENT_READ_ONLY_FORMS = {  # subcommands in AGENT_MUTATING that have a read-only spelling
    "stash": ("list", "show"), "worktree": ("list",), "notes": ("list", "show"),
    "tag": ("-l", "--list", "-n", "--contains", "--points-at", "--merged", "--no-merged"),
}
AGENT_BRANCH_FLAGS = {"-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy",
                      "-f", "--force", "-u", "--set-upstream-to", "--unset-upstream"}


def bundle_has(tok, letter):
    """`-qam` carries `a`; `--all` does not count as a bundle."""
    return tok.startswith("-") and not tok.startswith("--") and letter in tok[1:]


def positional(toks, value_flags=()):
    out, skip = [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if t in value_flags:
            skip = True
            continue
        if t.startswith("-") or re.match(r"\d*[<>]", t):
            continue
        out.append(t)
    return out


def looks_like_path(tok, cwd):
    if tok in (".", "./", "*") or "*" in tok or tok.startswith(("./", "../", "/")):
        return True
    return os.path.exists(os.path.join(cwd, tok))


def judge_git(sub, toks, cwd, in_agent, branch_created=False):
    if in_agent:
        ro = AGENT_READ_ONLY_FORMS.get(sub)
        if ro and (toks[0] if toks else "") in ro:
            return
        if sub in AGENT_MUTATING or (sub == "branch" and any(t in AGENT_BRANCH_FLAGS or bundle_has(t, "D") or bundle_has(t, "d") or bundle_has(t, "f") for t in toks)):
            deny("Agents never stage, commit, or move branches: report the diff and the file list; the main loop decides the commit.")
    if sub in ("add", "stage"):
        if any(t in EVERYTHING or bundle_has(t, "A") for t in toks):
            deny("House rule: stage named paths only — `git add <path> …`, never -A / . / --all.")
        if any(t in ("-u", "--update") for t in toks) and not positional(toks):
            deny("House rule: stage named paths only — `git add -u` with no path stages every tracked change.")
    elif sub == "commit":
        if any(t == "--all" or bundle_has(t, "a") for t in toks):
            deny("House rule: stage named paths, then `git commit`; never `commit -a`.")
        if any(t == "--no-verify" or bundle_has(t, "n") for t in toks):
            deny("--no-verify (-n) skips the hooks this repo relies on.")
        if not branch_created and current_branch(cwd) == "main":
            deny("Never commit to main: create or switch to the round's feature branch first.")
    elif sub == "checkout":
        if any(t in ("--ours", "--theirs", "--merge", "-m") for t in toks):
            return   # picking a side of a conflict is merge resolution, not a discard
        if "--" in toks:
            deny("`git checkout -- <path>` discards uncommitted phase work. If the tree really must be reset, stop and ask the user.")
        if any(t in ("-f", "--force", "-p", "--patch") or bundle_has(t, "f") or bundle_has(t, "p") for t in toks):
            deny("`git checkout -f/-p` throws away working-tree changes. Stop and ask the user.")
        pos = positional(toks, _BRANCH_TAKES_VALUE)
        if any(t in _BRANCH_TAKES_VALUE for t in toks):
            return   # creating a branch; a trailing `main` is its start point
        if len(pos) >= 2:
            deny("`git checkout <ref> <path>` overwrites a working file. Stop and ask the user instead.")
        if len(pos) == 1 and looks_like_path(pos[0], cwd):
            deny("`git checkout <path>` discards uncommitted changes to that path. Stop and ask the user instead.")
        if "main" in pos:
            ask("Main-branch sync, merges, rebases and branch deletion are the user's call.")
    elif sub == "switch":
        if any(t in ("-f", "--force", "--discard-changes") or bundle_has(t, "f") for t in toks):
            deny("`git switch -f/--discard-changes` throws away working-tree changes. Stop and ask the user.")
        if "main" in positional(toks, {"-c", "-C"}) and not any(t in ("-c", "-C") for t in toks):
            ask("Main-branch sync, merges, rebases and branch deletion are the user's call.")
    elif sub == "restore":
        staged = any(t in ("--staged", "-S") or bundle_has(t, "S") for t in toks)
        worktree = any(t in ("--worktree", "-W") or bundle_has(t, "W") for t in toks)
        if not staged or worktree:
            deny("`git restore` discards uncommitted phase work (only `git restore --staged <path>` is an unstage). Stop and ask the user instead.")
    elif sub == "stash":
        if (toks[0] if toks else "push") not in ("list", "show"):
            deny("`git stash` moves uncommitted phase work out of the tree; a later step forgets to pop it. Stop and ask the user.")
    elif sub == "reset":
        if any(t in ("--hard", "--merge") for t in toks):
            deny("`git reset --hard/--merge` discards uncommitted work. Stop and ask the user.")
    elif sub == "clean":
        if any(t == "--force" or bundle_has(t, "f") for t in toks):
            deny("`git clean -f` deletes untracked files (plans live in tmp/). Stop and ask the user.")
    elif sub == "push":
        if any(t in ("--dry-run", "-n") or bundle_has(t, "n") for t in toks):
            return
        if any(t in ("--force", "--force-with-lease", "--force-if-includes") or bundle_has(t, "f") or t.startswith("+") for t in toks):
            deny("Force pushes are never done from this session.")
        if "--no-verify" in toks:
            deny("--no-verify skips the hooks this repo relies on.")
        ask("The user owns pushes and PRs (house rule: one PR per round, opened by the user).")
    elif sub in ("pull", "merge", "rebase"):
        ask("Main-branch sync, merges, rebases and branch deletion are the user's call.")
    elif sub == "branch":
        if any(t in ("-d", "-D", "--delete", "-f", "--force", "-M") or bundle_has(t, "d") or bundle_has(t, "D") or bundle_has(t, "f") for t in toks):
            ask("Main-branch sync, merges, rebases and branch deletion are the user's call.")
    elif sub == "worktree":
        if toks and toks[0] in ("remove", "prune", "move"):
            ask("Removing a worktree deletes its uncommitted work and plan files; the user decides.")


# ---------------------------------------------------------- non-git denies
DENY = [
    (r"\b(dart|flutter)\s+format\b(?![^|;&]*(--output[= ](none|show|json)|-o\s*(none|show|json)|--set-exit-if-changed|--help|\s-h\b))",
     "Gates are analyze + test only; never reformat tracked files (a format run once rewrote inbox_screen.dart). "
     "Use `dart format --output=none --set-exit-if-changed <file>` to check without writing."),
    (r"(\bdrift_dev\s+(make-migrations|schema\s+generate)\b|\bbuild_runner\s+(build|watch)\b)(?![^|;&]*(--help|\s-h\b))",
     "Schema codegen runs only through `make app-migrations` then `make app-gen` from the repo root: "
     "the raw drift_dev command rewrites every test/drift/bond/generated snapshot with ~30k lines that do not compile."),
]

# A runner word in front of a signing script (`env`, `nohup`, `time`, `sudo`,
# a shell) must not turn the run into an unattended one.
_RUN = r"(?:bash|sh|zsh|env|nohup|time|caffeinate|sudo|command)\s+"

ASK = [
    (r"\bgh\s+pr\s+(create|merge|close|ready|edit|review|comment)\b|\bgh\s+repo\s+(create|delete|edit|rename|archive|sync|fork)\b"
     r"|\bgh\s+api\b[^|;&]*(\s(-X|--method)\s*(POST|PATCH|PUT|DELETE)\b|\s(-f|-F|--field|--raw-field|--input)\b)",
     "The user owns pushes and PRs (house rule: one PR per round, opened by the user)."),
    (r"\bflutter\s+run\b(?![^|;&]*--help)|\bmake\b(?![^|;&]*(\s-n\b|--dry-run|--just-print))(?:\s+(?:-C\s+\S+|-\S+))*\s+(app-run|model|fast|embed|omlx|setup|install|stop|clean-model)\b"
     r"|\bopen\s+-a\b|\bopen\s+\S*\.app\b|(?:^|[;&|(]\s*)\S*\.app/Contents/MacOS/\S+"
     r"|\bxcodebuild\b(?![^|;&]*(-showBuildSettings|-list|-version|-showsdks|-showdestinations))",
     "The user drives the live app and the model servers; gates are serverless."),
    # The distribution commands fall into three groups.
    #
    # 1. Targets that always reach a real identity, Apple's notary service or
    #    the Sparkle key: `make dist`, `dist-sign`, `dist-notarize`,
    #    `dist-appcast`. dist-llama/dist-app/dist-check/dist-clean compile,
    #    copy and report and stay unattended, so `(?![-\w])` after each target
    #    keeps them out — and keeps `make distclean` out too.
    #
    #    The repeated group spans everything make allows BEFORE a goal: flags,
    #    `-C dir`, variable assignments and earlier goals. Without the last two,
    #    `make VERSION=2 dist` and `make dist-llama dist` both slipped through
    #    unattended. It stays greedy on purpose, so a trailing `AD_HOC=1` ends
    #    with nothing left to match.
    #
    # 2. `make dist-dmg` WITHOUT an AD_HOC=<non-empty> in the same segment.
    #    Since Phase 5 a non-ad-hoc dist-dmg pulls in dist-notarize, signs the
    #    image and uploads it; with AD_HOC=1 it is still the unattended tester
    #    build it always was.
    #
    # 3. The scripts themselves, because a make target is not the only way to
    #    reach them. A segment that starts with optional VAR=value assignments
    #    and then sign.sh / notarize.sh / dmg.sh / appcast.sh asks, unless one
    #    of those assignments is AD_HOC=<non-empty>. Anchoring on the segment
    #    start is what keeps `cat dist/sign.sh`, `bash -n dist/dmg.sh` and
    #    `grep -n x dist/notarize.sh` allowed: there the script name is an
    #    argument, not the command. `(?:\S*/)?` lets the script be named by
    #    `./`, a worktree-relative or an absolute path alike; a runner word in
    #    front (`env`, `nohup`, `time`, `sudo`, a shell) and a second line of
    #    a multi-line command are still the command. A quoted-empty
    #    `AD_HOC=''` is an EMPTY value to the shell, which is the real path,
    #    so it does not count as set. Out of reach of any path rule, and
    #    accepted as such: `cd dist && ./sign.sh` and `bash -c "…"`.
    (r"\bmake\b(?![^|;&]*(\s-n\b|--dry-run|--just-print))(?:\s+(?:-C\s+\S+|-\S+|\S+=\S+|[\w./-]+))*\s+(dist-notarize|dist-appcast|dist-sign|dist)(?![-\w])"
     r"|\bmake\b(?![^|;&]*(\s-n\b|--dry-run|--just-print))(?![^|;&]*\bAD_HOC=(?![\"']{2})\S)(?:\s+(?:-C\s+\S+|-\S+|\S+=\S+|[\w./-]+))*\s+dist-dmg(?![-\w])"
     r"|(?:^|[;&|(\n]\s*)(?!(?:" + _RUN + r")*(?:\w+=\S*\s+)*AD_HOC=(?![\"']{2})\S)(?:" + _RUN + r")*(?:\w+=\S*\s+)*(?:" + _RUN + r")*(?:\S*/)?dist/(sign|notarize|dmg|appcast)\.sh\b"
     r"|\bxcrun\s+notarytool\s+(submit|store-credentials)\b"
     r"|\bsecurity\s+(import|create-keychain|set-key-partition-list)\b"
     r"|\bgh\s+release\s+(create|upload|delete|edit)\b",
     "Signing with a real identity, uploading to Apple or GitHub, and touching keychains are the user's call."),
]

# ------------------------------------------------------- protected paths
# Matched against the path RELATIVE TO THE REPO ROOT (or worktree root).
# Recursive removal (rm -r, mv, rmdir, find -delete) of these subtrees:
PROTECTED_TREES = [
    r"^tmp$", r"^app/lib(/|$)", r"^app/test(/|$)", r"^app/drift_schemas(/|$)",
    r"^docs$", r"^docs/(pipeline|releasenotes)(/|$)", r"^\.claude(?!/worktrees)(/|$)",
]
# Any removal, move, truncation or `>` overwrite of these files:
PROTECTED_FILES = [
    r"^tmp/[^/]*\.md$", r"^tmp/PLAN-",
    # a glob directly under tmp/ that could match a plan: tmp/*, tmp/*.md,
    # tmp/PLAN*, tmp/[A-Z]* — but not tmp/*.log or tmp/bench-*.json
    r"^tmp/[^/]*\*(?![^/]*\.(?!md$)\w+$)[^/]*$",
    r"drift_schema_v\d+\.json$", r"^docs/releasenotes/[^/]*\.md$", r"^docs/pipeline/[^/]*\.md$",
    r"^app/test/drift/bond/generated/", r"^\.claude/hooks/[^/]*\.(py|sh)$", r"^\.claude/settings\.json$",
    r"^CLAUDE\.md$", r"^app/CLAUDE\.md$", r"^Makefile$", r"^\.gitignore$",
]
# `git rm` / `git mv` are tracked, reversible operations and are not file ops.
_FILE_OPS = re.compile(r"(?<![\w/.-])(?<!git )(rm|mv|truncate|cp|rmdir)\s+([^|;&\n]*)")
# A `>` redirect destroys its target only when nothing meaningful is written:
# `: > f`, `> f`, `true > f`, `echo "" > f`, `printf '' > f`. `cat > f <<EOF`,
# `tee f`, `python3 gen.py > f` are how plans and docs get WRITTEN.
_REDIRECT = re.compile(r"(?:^|[;&|(]|\n)\s*(?::|true|echo(?:\s+(?:\"\"|''))?|printf\s+(?:\"\"|''))?\s*>(?!>)\s*([^\s|;&]+)")
_FIND_DELETE = re.compile(r"\bfind\s+(\S+)[^|;&\n]*(-delete\b|-exec\s+rm\b)")


def _resolve(tok, base):
    tok = re.sub(r"^(\$PWD|\$\(pwd\)|`pwd`)", base, tok)
    if "$" in tok or "`" in tok:
        return None
    return os.path.normpath(os.path.join(base, os.path.expanduser(tok)))


def destructive_targets(bare):
    """Yield (recursive, token) for every path an operation would destroy."""
    for m in _FILE_OPS.finditer(bare):
        op, rest = m.group(1), m.group(2).split()
        flags = [t for t in rest if t.startswith("-")]
        args = [t for t in rest if not t.startswith("-")]
        recursive = op == "rmdir" or any(bundle_has(f, "r") or bundle_has(f, "R") or f == "--recursive" for f in flags)
        if op == "cp":
            # Copying content over a plan or doc is how they get written;
            # only `cp /dev/null <f>` empties it.
            args = args[-1:] if "/dev/null" in args[:-1] else []
        elif op == "mv":
            # The moved-away source is lost; the destination is a content write
            # (`mv x.tmp x` is the conflict-resolution shape).
            args = args[:-1]
        for a in args:
            # mv of a whole protected tree is destructive; mv of one file inside
            # it is a rename (the tree patterns are checked root-only for mv).
            yield ("root" if op == "mv" else recursive), a
    for m in _REDIRECT.finditer(bare):
        yield False, m.group(1)          # truncation, see _REDIRECT
    for m in _FIND_DELETE.finditer(bare):
        yield True, m.group(1)


def check_destructive(bare, cwd):
    root = repo_root(cwd)
    if not root:
        return
    for recursive, tok in destructive_targets(bare):
        if "__pycache__" in tok:
            continue
        absolute = _resolve(tok, cwd)
        if not absolute:
            continue
        rel = os.path.relpath(absolute, root)
        if rel.startswith(".."):
            continue
        if tok.endswith("*") and not rel.endswith("*"):
            rel += "*"
        if recursive == "root":
            pats = PROTECTED_FILES + [p.replace("(/|$)", "$") for p in PROTECTED_TREES]
        else:
            pats = PROTECTED_FILES + (PROTECTED_TREES if recursive else [])
        for pat in pats:
            if re.search(pat, rel):
                deny("Destructive operation on a protected path (%s): plans, generated schema, release notes, docs, "
                     "the hooks and whole source trees are never deleted or overwritten from a session." % tok)


# ------------------------------------------------------------------ zsh
# An unquoted word of two or more characters starting with `=`.
ZSH_EQ = re.compile(r"(?<![\w\-./'\"=])(=[^\s'\"|;&<>()]+)")


def zsh_eq_hits(bare):
    hits = [m.group(1) for m in ZSH_EQ.finditer(bare)]
    if "[[" in bare:
        hits = [h for h in hits if h not in ("==", "=~")]
    return hits


# ----------------------------------------------------------------- main
def main():
    data = read_input()
    if hooks_off() or data.get("tool_name") != "Bash":
        return
    cmd = data.get("tool_input", {}).get("command", "") or ""
    cwd = effective_cwd(cmd, data.get("cwd") or os.getcwd())
    bare = bare_command(cmd)
    in_agent = bool(data.get("agent_id"))

    branch_created = False   # `git switch -c x && git commit` is judged on x, not on main
    for m in _GIT_CALL.finditer(bare):
        # $(…), ${…} and `…` are one word to the shell whatever they contain.
        rest = re.sub(r"\$\([^)]*\)|\$\{[^}]*\}|`[^`]*`", "$X", m.group("rest"))
        toks = rest.split()
        judge_git(m.group("sub"), toks, cwd, in_agent, branch_created)
        if m.group("sub") in ("switch", "checkout") and any(t in ("-c", "-C", "-b", "-B") for t in toks):
            branch_created = True

    for pat, why in DENY:
        if re.search(pat, bare):
            deny(why)

    check_destructive(bare, cwd)

    for pat, why in ASK:
        if re.search(pat, bare):
            ask(why)

    # Heredoc bodies are never word-split by zsh, so judge `=` words only on
    # the parts zsh itself parses, and quote them in place.
    if zsh_eq_hits(bare_command(cmd, keep_shell_heredocs=False, keep_words=False)):
        fixed = rewrite_code(cmd, lambda t: ZSH_EQ.sub(lambda m: "'%s'" % m.group(1), t),
                             keep_shell_heredocs=False)
        if fixed != cmd and not zsh_eq_hits(bare_command(fixed, keep_shell_heredocs=False, keep_words=False)):
            new_input = dict(data.get("tool_input", {}))
            new_input["command"] = fixed
            pre_tool(updated_input=new_input,
                     context="Hook quoted an unquoted `=…` word: under zsh `=word` expands to a command path. Quote such words yourself (echo '===').")
            return
        deny("zsh expands an unquoted word starting with `=` (two or more characters, e.g. `==`, `===`, `=x`) as a command path "
             "(this failed 87 times in past sessions). Quote it: echo '====' — or use printf '%s\\n' ---.")


if __name__ == "__main__":
    main()
