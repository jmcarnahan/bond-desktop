"""Shared helpers for the bond-desktop Claude Code hooks.

Every hook reads one JSON object from stdin (the hook input), decides, and
either exits 0 silently (allow / nothing to add) or prints a JSON object.
Exit code 2 with a sentence on stderr is the hard-block path.
"""
import json
import os
import re
import shutil
import subprocess
import sys


def read_input():
    try:
        return json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return {}


def hooks_off():
    return os.environ.get("BOND_HOOKS_OFF") == "1"


def repo_root(cwd):
    """The checkout (or worktree) that `cwd` lives in, or None."""
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def git(cwd, *args, timeout=10):
    try:
        out = subprocess.run(
            ["git", "-C", cwd, *args], capture_output=True, text=True, timeout=timeout
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout


def current_branch(cwd):
    return git(cwd, "branch", "--show-current").strip()


# `git` plus any global options that may precede the subcommand, in both the
# `--opt value` and `--opt=value` spellings, so `git -C <dir> add -A` and
# `git --work-tree=. add -A` are judged exactly like `git add -A`.
GIT = (r"\bgit\s+(?:(?:-C|-c|--git-dir|--work-tree|--namespace|--exec-path)(?:=\S+|\s+\S+)\s+"
       r"|--no-pager\s+|-P\s+|--no-optional-locks\s+|--literal-pathspecs\s+)*")

_CD_PREFIX = re.compile(r"^\s*\(?\s*(?:cd|pushd)\s+([^\s;&|)]+)\s*(?:&&|;)")
_GIT_C = re.compile(r"\bgit\s+(?:-C\s+|-C=)([^\s;&|]+)")


def effective_cwd(cmd, cwd):
    """Where a git command will actually run: a leading `cd <dir> &&` (also
    inside a subshell, or `pushd`) or a `git -C <dir>` wins over the session
    cwd. Paths are expanded; a path that does not exist falls back to `cwd`."""
    cand = None
    m = _CD_PREFIX.match(cmd)
    if m:
        cand = m.group(1)
    else:
        m = _GIT_C.search(cmd)
        if m:
            cand = m.group(1)
    if not cand:
        return cwd
    cand = os.path.expanduser(os.path.expandvars(cand.strip("'\"")))
    if not os.path.isabs(cand):
        cand = os.path.join(cwd, cand)
    return os.path.normpath(cand) if os.path.isdir(cand) else cwd


_HEREDOC_OPEN = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")
# A heredoc fed to a SHELL is executed line by line as commands; one fed to
# python/dart or a file is data. The command word before the `<<` decides,
# as does `cat <<EOF | bash` (a pipe into a shell after the opener).
_SHELL_BEFORE = re.compile(r"(?<![\w.-])(?:bash|sh|zsh|eval|source)\s+(?:-\S+\s+)*(?:-\s+)?$")
_SHELL_AFTER = re.compile(r"\|\s*(?:bash|sh|zsh)\b")
# A quoted string right after `sh -c` / `bash -lc` / `eval` IS a command.
_EXEC_STRING = re.compile(r"(?:(?<![\w.-])(?:bash|sh|zsh)\s+(?:-\S+\s+)*-[a-zA-Z]*c\s*|(?<![\w.-])eval\s+)$")


def segments(cmd, keep_shell_heredocs=True):
    """Split a command into (text, is_code) pieces in one left-to-right pass,
    the way the shell reads it: double-quoted strings, single-quoted strings
    and data heredoc bodies are data; everything else is code the shell
    parses. A heredoc opener counts only in code state (one inside a quoted
    string is text), and its body starts after the end of the opener's line,
    ending at the first line that is exactly the terminator word — exactly
    the shell's rule, so a data heredoc whose body contains its own
    terminator ends early for the hook as it does for the shell. A quoted
    string that follows `sh -c`/`bash -lc`/`eval` is a command and counts as
    code (its quotes dropped). A backslash-newline is a space. An
    unterminated quote runs to the end, as in the shell. A heredoc fed to
    bash/sh/zsh is code unless keep_shell_heredocs is False (zsh never
    word-splits any heredoc body, so the `=` check passes False)."""
    out, buf, pending = [], [], []
    line_code = []   # code characters of the current line, for the heredoc decision
    i, n = 0, len(cmd)

    def flush():
        if buf:
            out.append(("".join(buf), True))
            del buf[:]

    def code_tail():
        return "".join(line_code)

    while i < n:
        ch = cmd[i]
        if ch == "\\" and i + 1 < n:
            if cmd[i + 1] == "\n":
                buf.append(" "); line_code.append(" ")
            else:
                buf.append(cmd[i:i + 2]); line_code.append(cmd[i:i + 2])
            i += 2
            continue
        if ch == '"' or ch == "'":
            if ch == '"':
                j = i + 1
                while j < n and cmd[j] != '"':
                    j += 2 if cmd[j] == "\\" else 1
            else:
                j = cmd.find("'", i + 1)
                if j == -1:
                    j = n - 1
            executed = keep_shell_heredocs and bool(_EXEC_STRING.search(code_tail()))
            flush()
            if executed:
                out.append((cmd[i + 1:j], True))
            else:
                out.append((cmd[i:j + 1], False))
            i = j + 1
            continue
        if ch == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|("):
            j = cmd.find("\n", i)
            j = n if j == -1 else j
            flush(); out.append((cmd[i:j], False)); i = j
            continue
        if ch == "<" and cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            m = _HEREDOC_OPEN.match(cmd, i)
            if m:
                pending.append((m.group(2), len(code_tail())))
                buf.append(m.group(0)); line_code.append(m.group(0)); i = m.end()
                continue
        if ch == "\n" and pending:
            buf.append("\n"); flush(); i += 1
            line = code_tail()
            for word, at in pending:
                is_shell = keep_shell_heredocs and bool(
                    _SHELL_BEFORE.search(line[:at]) or _SHELL_AFTER.search(line[at:]))
                mt = re.compile(r"^[ \t]*%s[ \t]*$" % re.escape(word), re.M).search(cmd, i)
                end = mt.end() if mt else n
                out.append((cmd[i:end], is_shell)); i = end
            pending, line_code = [], []
            continue
        if ch == "\n":
            line_code = []
        buf.append(ch); line_code.append(ch); i += 1
    flush()
    return [(t, c) for t, c in out if t]


def bare_command(cmd, keep_shell_heredocs=True, keep_words=True):
    """The command as the rules see it: code untouched; a quoted string that
    is a single word (a path or a flag: "tmp", '--hard', "$PWD/tmp") keeps its
    content without the quotes (unless keep_words is False); any other quoted
    string (a message, a grep pattern) becomes empty quotes; a data heredoc
    body becomes a space."""
    parts = []
    for text, is_code in segments(cmd, keep_shell_heredocs):
        if is_code:
            parts.append(text)
        elif keep_words and text[:1] in ("'", '"') and text[-1:] == text[:1] and len(text) >= 2:
            inner = text[1:-1]
            parts.append(inner if inner and not re.search(r"\s", inner) else text[0] * 2)
        elif text[:1] in ("'", '"'):
            parts.append(text[0] * 2)
        else:
            parts.append(" ")
    return "".join(parts)


def rewrite_code(cmd, fn, keep_shell_heredocs=True):
    """Apply `fn` to the code segments only; quoted strings and data heredoc
    bodies are passed through untouched."""
    return "".join(fn(t) if c else t for t, c in segments(cmd, keep_shell_heredocs))


def pre_tool(decision=None, reason=None, updated_input=None, context=None):
    out = {"hookEventName": "PreToolUse"}
    if decision:
        out["permissionDecision"] = decision
        out["permissionDecisionReason"] = reason or ""
    if updated_input is not None:
        out["updatedInput"] = updated_input
    if context:
        out["additionalContext"] = context
    print(json.dumps({"hookSpecificOutput": out}))


def deny(reason):
    pre_tool("deny", reason)
    sys.exit(0)


def ask(reason):
    pre_tool("ask", reason)
    sys.exit(0)


def dart_files_newer_than(root, since, subdirs=("app/lib", "app/test")):
    """Repo-relative .dart paths under `subdirs` modified after `since`."""
    out = []
    for sub in subdirs:
        base = os.path.join(root, sub)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in (".dart_tool", "build", "generated")]
            for f in filenames:
                if not f.endswith(".dart"):
                    continue
                p = os.path.join(dirpath, f)
                try:
                    if os.path.getmtime(p) > since:
                        out.append(os.path.relpath(p, root))
                except OSError:
                    continue
    return out


def stamp_path(root, name, create=False):
    d = os.path.join(root, "tmp", ".gate")
    if create:
        os.makedirs(d, exist_ok=True)
    return os.path.join(d, name)


def find_flutter():
    """`flutter` on PATH, else the places this machine keeps it; None if absent.
    Hooks must degrade to a note when the toolchain is missing, never block."""
    found = shutil.which("flutter")
    if found:
        return found
    for cand in ("~/software/flutter/bin/flutter", "~/flutter/bin/flutter",
                 "~/fvm/default/bin/flutter", "/opt/homebrew/bin/flutter"):
        p = os.path.expanduser(cand)
        if os.access(p, os.X_OK):
            return p
    return None


def run_analyze(root, timeout=40):
    """Runs `flutter analyze` in app/.
    Returns (status, text) with status one of 'clean', 'issues', 'unavailable'."""
    flutter = find_flutter()
    if not flutter:
        return "unavailable", "flutter is not on PATH for the hook environment"
    app = os.path.join(root, "app")
    try:
        out = subprocess.run(
            [flutter, "analyze"], cwd=app, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return "unavailable", "flutter analyze timed out after %ds" % timeout
    except OSError as e:
        return "unavailable", "flutter analyze could not start: %s" % e
    text = (out.stdout + out.stderr).strip()
    lines = [l for l in text.splitlines() if l.strip()]
    tail = "\n".join(lines[-15:])
    if out.returncode == 0 and "No issues found" in text:
        return "clean", tail
    if re.search(r"\d+ issues? found", text):
        if re.search(r"Target of URI doesn't exist|Couldn't resolve the package|run 'flutter pub get'", text):
            return "unavailable", "packages are not resolved in this checkout (run `flutter pub get` in app/)"
        return "issues", text
    return "unavailable", tail
