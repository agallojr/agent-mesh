#!/usr/bin/env /usr/bin/python3
"""PreToolUse git gatekeeper for the agent-mesh.

Replaces the blanket `git add/commit/push` deny in settings.json with a
path-scoped gate: the three mutating git ops are permitted ONLY when their
target repository is on an allowlist; everywhere else they are denied.

Why a hook: Claude Code permission rules match the literal command string and
are NOT path-aware, and `deny` beats `allow` at every scope. So "allow git only
in one repo" cannot be expressed as a permission rule. A PreToolUse hook can
add a deny (best-effort), and — with the blanket deny removed from settings —
becomes the sole authority on these ops.

Contract (Claude Code PreToolUse):
  stdin  : JSON with tool_name, tool_input.command, and cwd.
  stdout : JSON permissionDecision "deny" to block; nothing (exit 0) to defer
           to the normal permission flow (broad Bash allow lets it through).

Posture: FAIL CLOSED. A gated op is denied unless its target repo can be
affirmatively proven to be on the allowlist. Ambiguity denies.

Allowlist: mesh-git-allowlist.txt in the Claude Code config dir (resolved via
CLAUDE_CODE_CONFIG_DIR / CLAUDE_CONFIG_DIR, else ~/.claude), one absolute repo
path per line, blank lines and #-comments ignored. Paths are resolved to real
paths; a target matches if it equals, or is nested under, an allowlisted path.
"""

import json
import os
import re
import shlex
import sys

GATED = {"add", "commit", "push"}

# Resolve the config dir the way Claude Code does, NOT via ~/.claude: on some
# hosts HOME is not the config-dir parent (e.g. HOME=/quantum-data/agallojr/
# install while config lives in /quantum-data/agallojr/.claude), so ~/.claude
# points at a DEPRECATED/empty config dir with no allowlist and the fail-closed
# gate would silently deny ALL gated git. The live config dir is set by
# CLAUDE_CODE_CONFIG_DIR (current var; CLAUDE_CONFIG_DIR is the legacy alias).
# Fall back to ~/.claude only if neither is set.
_CONFIG_DIR = (
    os.environ.get("CLAUDE_CODE_CONFIG_DIR")
    or os.environ.get("CLAUDE_CONFIG_DIR")
    or os.path.expanduser("~/.claude")
)
ALLOWLIST = os.path.join(_CONFIG_DIR, "mesh-git-allowlist.txt")

# git global options that take a value; we must skip the value when scanning
# for the subcommand, and capture -C / --git-dir targets.
VALUE_OPTS = {
    "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path",
    "--super-prefix", "-c", "--config-env",
}


def deny(reason: str) -> None:
    json.dump({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, sys.stdout)
    sys.exit(0)


def allow_flow() -> None:
    # Emit nothing: defer to the normal permission flow (broad Bash allow).
    sys.exit(0)


def load_allowlist() -> list[str]:
    roots: list[str] = []
    try:
        with open(ALLOWLIST, encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                roots.append(os.path.realpath(os.path.expanduser(line)))
    except FileNotFoundError:
        return []
    return roots


def resolvable_literal(value: str) -> bool:
    """True only if the path token is a plain literal the hook can resolve the
    same way the shell will. Any shell-active metacharacter ($ ` ~ glob) means
    the shell will expand it into something the hook cannot see, so a gated op
    with such a target must be denied. The mesh skill always emits a literal
    absolute path, so this never blocks legitimate mesh git."""
    if not value:
        return False
    return re.fullmatch(r"[A-Za-z0-9_./+ @=-]+", value) is not None


def under_allowlist(target: str, roots: list[str]) -> bool:
    target = os.path.realpath(target)
    for root in roots:
        if target == root:
            return True
        if target.startswith(root + os.sep):
            return True
    return False


def split_subcommands(command: str) -> list[str]:
    """Split a compound shell command on the operators Claude Code recognizes.

    We do not need a full shell parser: we only need to isolate each simple
    command so we can inspect any that invoke git. Splitting conservatively
    (treating each fragment independently) is the safe direction — it can only
    cause us to inspect more git invocations, never fewer.
    """
    # Order matters: match two-char operators before one-char.
    parts = re.split(r"\|\||&&|\|&|[;\n|&]", command)
    return [p.strip() for p in parts if p.strip()]


def _starts_with_git(fragment: str) -> bool:
    """True if the fragment's first command word is git (or a path ending
    /git), ignoring leading `env` and VAR=val assignment prefixes."""
    stripped = fragment.strip()
    # drop leading env-assignment / `env ` prefixes
    while True:
        m = re.match(r"^(env\s+|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)", stripped)
        if not m:
            break
        stripped = stripped[m.end():]
    return bool(re.match(r"^(\S*/)?git(\s|$)", stripped))


def git_invocations(fragment: str) -> list[list[str]]:
    """Return tokenized git invocations within a fragment.

    Handles a leading `env VAR=x` and assignment prefixes, and treats the
    first bare `git` token as the start of a git command. If the fragment
    cannot be tokenized, we only force a deny when the fragment *looks like*
    it starts with a git command — otherwise it is unrelated shell (e.g. a
    multi-line Python heredoc whose quoting broke when split) and we defer.
    """
    try:
        tokens = shlex.split(fragment)
    except ValueError:
        if _starts_with_git(fragment):
            return [["\0UNPARSEABLE"]]
        return []
    out: list[list[str]] = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        # skip leading env assignments and `env`
        if tok == "env" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
            i += 1
            continue
        if tok == "git" or tok.endswith("/git"):
            out.append(tokens[i:])
            break
        # not a git command start; stop scanning this fragment
        break
    return out


def analyze_git(tokens: list[str], fragment: str, cwd: str,
                roots: list[str], cwd_trusted: bool) -> None:
    """Inspect one tokenized git invocation. Deny (and exit) if it is a gated
    op whose target repo is not provably on the allowlist. Otherwise RETURN so
    remaining invocations in a compound command are still inspected — never
    exit-allow here, or `git status && git push` would slip the push through.

    cwd_trusted is False when the command contains a directory-changing
    construct (cd/pushd/popd); a gated op that relies on cwd (no explicit
    -C/--git-dir) is then denied, since the effective directory at exec time
    may differ from the cwd the hook was given."""
    if tokens == ["\0UNPARSEABLE"]:
        deny("git command could not be parsed; denying gated git by policy")

    target_dir = cwd
    explicit_target = False  # set by -C / --git-dir
    target_resolvable = True  # cleared if a path token isn't a plain literal
    i = 1  # tokens[0] == git (or .../git)
    subcommand = None
    while i < len(tokens):
        t = tokens[i]
        if t == "-C" and i + 1 < len(tokens):
            # -C is relative to the prior -C / cwd
            nxt = tokens[i + 1]
            if not resolvable_literal(nxt):
                target_resolvable = False
            target_dir = nxt if os.path.isabs(nxt) else os.path.join(
                target_dir, nxt)
            explicit_target = True
            i += 2
            continue
        if t == "--git-dir" and i + 1 < len(tokens):
            gd = tokens[i + 1]
            if not resolvable_literal(gd):
                target_resolvable = False
            base = gd if os.path.isabs(gd) else os.path.join(target_dir, gd)
            # strip a trailing /.git to get the work tree root
            target_dir = re.sub(r"/\.git/?$", "", base) or base
            explicit_target = True
            i += 2
            continue
        if t.startswith("--git-dir="):
            gd = t.split("=", 1)[1]
            if not resolvable_literal(gd):
                target_resolvable = False
            base = gd if os.path.isabs(gd) else os.path.join(target_dir, gd)
            target_dir = re.sub(r"/\.git/?$", "", base) or base
            explicit_target = True
            i += 1
            continue
        if t in VALUE_OPTS:
            i += 2  # skip option and its value
            continue
        if t.startswith("-"):
            i += 1  # some other global flag/option=value form
            continue
        subcommand = t
        break

    cleanly_gated = subcommand in GATED

    # Fail-closed on command substitution: $(...) or backticks make shlex
    # word-split the substitution, so subcommand detection can be fooled (e.g.
    # `git -C $(echo x) push` splits so `push` is missed and a junk token
    # looks like the subcommand). If a git fragment contains substitution and
    # names a gated keyword, but we did NOT cleanly parse a gated subcommand,
    # we cannot trust the parse — deny. A clean parse (`git -C /repo commit -m
    # "$(date)"`) is unaffected: substitution there is only in later args.
    if not cleanly_gated and re.search(r"\$\(|`", fragment) and \
       re.search(r"(^|\s)(add|commit|push)(\s|$)", fragment):
        deny(
            "git command uses command substitution ($(...) or backticks) the "
            "gate cannot reliably parse around a gated op. Emit a literal "
            "`git -C /abs/repo <add|commit|push> ...`."
        )

    if subcommand is None:
        # `git` with no subcommand (e.g. `git --version` consumed) — harmless.
        return

    if not cleanly_gated:
        return  # pull/fetch/status/log/etc were never gated

    # Gated op: require the target to be provably on the allowlist.
    if not roots:
        deny(
            f"git {subcommand} is gated: no mesh-git allowlist configured "
            f"({ALLOWLIST})"
        )
    if not explicit_target and not cwd_trusted:
        deny(
            f"git {subcommand} denied: command changes directory (cd/pushd) so "
            f"the effective repo can't be trusted from cwd. Use "
            f"`git -C <allowlisted-repo> {subcommand} ...` instead."
        )
    if not target_resolvable:
        deny(
            f"git {subcommand} denied: target path uses shell expansion "
            f"($VAR, $(...), ~, or a glob) the gate cannot resolve. Emit a "
            f"literal absolute path: `git -C /abs/path/to/repo {subcommand} "
            f"...`."
        )
    if under_allowlist(target_dir, roots):
        return
    deny(
        f"git {subcommand} denied: target repo '{target_dir}' is not on the "
        f"mesh-git allowlist. Use `git -C <allowlisted-repo> {subcommand} ...` "
        f"or add the repo to {ALLOWLIST}."
    )


def main() -> None:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw else {}
    except (json.JSONDecodeError, ValueError):
        # Can't read the request — do not silently allow a gated op.
        # Deferring is safe here: only actual git invocations get inspected,
        # and if we can't parse we simply defer to normal flow. But since the
        # blanket deny is gone, defer would ALLOW. So fail closed by denying
        # only when we cannot tell — however with no command we cannot even
        # know it is git. Safest: defer (non-git commands must not be blocked).
        allow_flow()

    if payload.get("tool_name") != "Bash":
        allow_flow()

    command = payload.get("tool_input", {}).get("command", "") or ""
    cwd = payload.get("cwd") or os.getcwd()

    # Fast path: no git token at all.
    if not re.search(r"(^|[\s;|&])git(\s|$)", command) and \
       "/git " not in command:
        allow_flow()

    # If the command changes directory, cwd can't be trusted for a gated op
    # that relies on it (must use explicit -C/--git-dir).
    cwd_trusted = not re.search(r"(^|[\s;|&(])(cd|pushd|popd)(\s|$)", command)

    roots = load_allowlist()
    for fragment in split_subcommands(command):
        for tokens in git_invocations(fragment):
            analyze_git(tokens, fragment, cwd, roots, cwd_trusted)
    # No gated git invocation found → defer to normal flow.
    allow_flow()


if __name__ == "__main__":
    main()
