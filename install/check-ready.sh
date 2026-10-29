#!/bin/sh
# check-ready.sh: read-only readiness check of one mesh node, before and
# after the bus's memory/ and agent-tmp/ move into the core, lore and
# scratch spaces.
#
#   check-ready.sh before --bus <bus clone> [--env <class>] [--migrating]
#                         [--core-url <url>] [--lore-url <url>] [--tmp-url <url>]
#   check-ready.sh after  --bus <bus clone> [--env <class>]
#
# It prints one line per item, then a last line, and exits:
#
#   OK <class> <item> <detail>
#   MISSING <class> <item> <detail>: <operator step>
#   INFO <class> <item> <detail>                  not counted
#   READY <class>                                 exit 0
#   NOT READY <class>: <n> missing                exit 1
#
# A usage error exits 2. --env defaults to AGENT_CONTEXT in
# ~/.agent-identity.env; the space URLs default to the bus's .gitmodules
# entries once mounted; the Claude Code config is $CLAUDE_CODE_CONFIG_DIR,
# else $CLAUDE_CONFIG_DIR, else ~/.claude, the order the git gate reads them
# in. Details are versions, URLs (never their user:password part) and
# paths relative to the bus or the config: no line holds a home path, a
# hostname, an agent id or a credential name. The tool writes only in a temp
# folder it deletes, and its write probes are git push --dry-run. It is POSIX
# sh with BSD or GNU tools; its Python part runs under /usr/bin/python3, any
# Python 3.6 or later.

set -u

PROG=check-ready.sh
PY=/usr/bin/python3
CAP_S=30                                  # cap on each network probe, in s
PROBE_REF=refs/heads/check-ready-probe    # write probes dry-run push to it
POD_ROLES="spec plan lead build test review"
POD_SKILLS="swe-pod mesh-on mesh-off mesh-post mesh-check mesh-load"
POD_SKILLS="$POD_SKILLS space-librarian"
SPACES="core lore tmp"
TAB=$(printf '\t')
NL=$(printf '\nx')
NL=${NL%x}

usage() {
    cat >&2 <<'EOF'
usage: check-ready.sh before --bus <bus clone> [--env <class>] [--migrating]
                      [--core-url <url>] [--lore-url <url>] [--tmp-url <url>]
       check-ready.sh after  --bus <bus clone> [--env <class>]
EOF
    exit 2
}

die() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit 2
}

# ------------------------------------------------------------ arguments

[ $# -ge 1 ] || usage
MODE=$1
shift
case $MODE in
    before | after) ;;
    *) usage ;;
esac
BUS_ARG=
CLASS=
MIGRATING=no
CORE_URL=
LORE_URL=
TMP_URL=
while [ $# -gt 0 ]; do
    case $1 in
        --bus | --env | --core-url | --lore-url | --tmp-url)
            [ $# -ge 2 ] || usage
            case $1 in
                --bus) BUS_ARG=$2 ;;
                --env) CLASS=$2 ;;
                *)
                    [ "$MODE" = before ] || usage
                    case $1 in
                        --core-url) CORE_URL=$2 ;;
                        --lore-url) LORE_URL=$2 ;;
                        *) TMP_URL=$2 ;;
                    esac
                    ;;
            esac
            shift 2
            ;;
        --migrating)
            [ "$MODE" = before ] || usage
            MIGRATING=yes
            shift
            ;;
        *) usage ;;
    esac
done
[ -n "$BUS_ARG" ] || usage

# ------------------------------------------------------------ the node

[ -n "${HOME:-}" ] || die "HOME is not set"
IDENTITY=$HOME/.agent-identity.env

ident() {  # ident <key>: the last value of <key> in the identity file
    [ -r "$IDENTITY" ] || return 0
    sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
        "$IDENTITY" | sed -n '$p' |
        sed 's/[[:space:]]#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' |
        sed "s/^[\"']//; s/[\"']\$//"
}

[ -n "$CLASS" ] || CLASS=$(ident AGENT_CONTEXT)
[ -n "$CLASS" ] ||
    die "no --env given and no AGENT_CONTEXT in ~/.agent-identity.env"
case $CLASS in
    *[!A-Za-z0-9._-]*) die "--env must be an environment class" ;;
esac
ROLES=$(ident AGENT_ROLES)
[ -n "$ROLES" ] || ROLES=$(ident AGENT_ROLE)
TRACK=$(ident MESH_PRODUCT_TRACK)

BUS=$(cd "$BUS_ARG" 2>/dev/null && pwd) || die "--bus is not a folder"
BUS_REAL=$(cd "$BUS" && pwd -P)
# The config dir as the git gate and the product's hooks find it.
CONFIG=${CLAUDE_CODE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}
case $CONFIG in
    /*) ;;
    *) CONFIG=$(pwd)/$CONFIG ;;
esac
CONFIG_REAL=$(cd "$CONFIG" 2>/dev/null && pwd -P) || CONFIG_REAL=$CONFIG
HOME_REAL=$(cd "$HOME" 2>/dev/null && pwd -P) || HOME_REAL=$HOME

# ------------------------------------------------------------ output

# The scrub works on $_x in this shell, with no subshell per line.
subst() {  # subst <from> <to>: make each <from> in $_x a <to>
    [ -n "$1" ] || return 0
    _s=$_x
    _o=
    while :; do
        case $_s in
            *"$1"*)
                _o=$_o${_s%%"$1"*}$2
                _s=${_s#*"$1"}
                ;;
            *) break ;;
        esac
    done
    _x=$_o$_s
}

subst2() {  # subst2 <path> <its other form> <to>: the longer form first
    if [ ${#1} -ge ${#2} ]; then
        subst "$1" "$3"
        subst "$2" "$3"
    else
        subst "$2" "$3"
        subst "$1" "$3"
    fi
}

N_MISSING=0
emit() {  # emit <line>: print it, bus, config and home paths hidden
    _x=$1
    subst2 "$BUS_REAL" "$BUS" '<bus>'
    subst2 "$CONFIG_REAL" "$CONFIG" '<config>'
    [ ${#HOME} -gt 1 ] && subst2 "$HOME_REAL" "$HOME" '~'
    printf '%s\n' "$_x"
    case $_x in
        "MISSING "*) N_MISSING=$((N_MISSING + 1)) ;;
    esac
}
ok() { emit "OK $CLASS $1"; }
missing() { emit "MISSING $CLASS $1"; }
info() { emit "INFO $CLASS $1"; }

finish() {
    if [ "$N_MISSING" -eq 0 ]; then
        emit "READY $CLASS"
        exit 0
    fi
    emit "NOT READY $CLASS: $N_MISSING missing"
    exit 1
}

short() { printf '%s\n' "$1" | cut -c1-7; }

show_url() {  # show_url <url>: the URL without its user:password@ part
    printf '%s\n' "$1" | sed 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/@]*@#\1#'
}

repo_name() {  # repo_name <url>: the repo's name, the URL's last part less .git
    _r=${1%/}
    _r=${_r##*/}
    _r=${_r##*:}
    printf '%s\n' "${_r%.git}"
}

# ------------------------------------------------------------ probes

if ! GIT_VERSION=$(git --version 2>/dev/null); then
    missing "git git --version does not run: install git"
    finish
fi
_top=$(git -C "$BUS" rev-parse --show-toplevel 2>/dev/null) &&
    [ "$(cd "$_top" 2>/dev/null && pwd -P)" = "$BUS_REAL" ] ||
    die "--bus is not the top folder of a git clone"

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/check-ready.XXXXXX") ||
    die "cannot make a temp folder"
cleanup() {
    cd / && rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$TMPD" || exit 2

# Prompts off, and no lock or index refresh in the bus or its submodules. No
# Python run here, the hooks' included, writes an interpreter cache.
GIT_TERMINAL_PROMPT=0
GIT_OPTIONAL_LOCKS=0
PYTHONDONTWRITEBYTECODE=1
export GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS PYTHONDONTWRITEBYTECODE
if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "${GIT_SSH:-}" ] &&
    [ -z "$(git config --get core.sshCommand 2>/dev/null)" ]; then
    GIT_SSH_COMMAND="ssh -o BatchMode=yes"
    export GIT_SSH_COMMAND
fi

run_capped() {  # run_capped <s> <command>...: run it, killed after <s> s
    _cap=$1
    shift
    "$@" &
    _job=$!
    (
        _nap=
        trap '[ -n "$_nap" ] && kill "$_nap" 2>/dev/null; exit 0' TERM
        sleep "$_cap" &
        _nap=$!
        wait "$_nap"
        kill "$_job" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    _dog=$!
    wait "$_job" 2>/dev/null
    _rc=$?
    kill "$_dog" 2>/dev/null
    wait "$_dog" 2>/dev/null
    return "$_rc"
}

PY_OK=no
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 6))' >/dev/null 2>&1 &&
    PY_OK=yes

# The Python part: hook interpreters, the git gate, LFS pointers, the overlay
# chain and the lore catalog. It must run under any Python 3.6 or later.
cat >"$TMPD/helper.py" <<'PY'
"""check-ready.sh helper: prints report lines for one item.

argv: <item> <class> <bus> <config> <home> [<path>...]. Python 3.6 or later:
no newer syntax or library call.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

MIN_PY = (3, 9)
HOPS = 5
CAP_S = 20
SHELLS = ("sh", "bash", "dash", "ksh", "zsh")
KEYWORDS = ("if", "then", "else", "elif", "do", "while", "until", "!", "{",
            "(")
PYTHON = re.compile(r"^python[0-9.]*$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
VAR = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
OPS = re.compile(r"\|\||&&|[;|&]")
IMPORT = re.compile(r"^@(\S+)$")
MEMORY = re.compile(r"(^|/)memory/")
VERSION_CODE = "import sys; print('.'.join(str(n) for n in sys.version_info[:3]))"
OVERLAY = "spaces/core/best-practices.user.md"
LORE = "spaces/lore/lore"
POINTER = b"version https://git-lfs.github.com/spec/v1\n"
STEP_PY = "install Python 3.9 or later at that path"
STEP_GATE = "add the bus clone's path to the gate's allowlist"

ITEM, CLS, BUS, CONFIG, HOME = sys.argv[1:6]
SETTINGS = os.path.join(CONFIG, "settings.json")


def _roots():
    """(root, prefix) pairs for show(), the longest root first."""
    out = []
    for path, prefix in ((BUS, ""), (CONFIG, ""), (HOME, "~/")):
        for form in (path, os.path.realpath(path)):
            if len(form) > 1:
                out.append((form, prefix))
    out.sort(key=lambda r: -len(r[0]))
    return out


ROOTS = _roots()


def show(path):
    """A path as a report line shows it: relative to the bus or the config,
    else under ~, never a home path."""
    for root, prefix in ROOTS:
        if path == root:
            return prefix[:-1] or "."
        if path.startswith(root + "/"):
            return prefix + path[len(root) + 1:]
    return path


def say(kind, item, detail, step=None):
    line = "%s %s %s" % (kind, CLS, item)
    if detail:
        line += " " + detail
    if step:
        line += ": " + step
    sys.stdout.buffer.write((line + "\n").encode("utf-8", "replace"))


def expand(word, env):
    """$NAME and ${NAME} from env, as the shell would; a leading ~."""
    word = VAR.sub(lambda m: env.get(m.group(1) or m.group(2), ""), word)
    if word == "~" or word.startswith("~/"):
        word = HOME + word[1:]
    return word


def split_words(text, env):
    try:
        words = shlex.split(text, comments=True)
    except ValueError:
        return None
    return [expand(w, env) for w in words]


def strip_prefix(words):
    """Drop leading assignments, exec, env and its options."""
    words = list(words)
    while words:
        word = words[0]
        if ASSIGN.match(word) or word in KEYWORDS:
            words.pop(0)
        elif word == "exec":
            words.pop(0)
            while words and words[0].startswith("-"):
                if words.pop(0) == "-a" and words:
                    words.pop(0)
        elif os.path.basename(word) == "env":
            words.pop(0)
            while words and (words[0].startswith("-") or ASSIGN.match(words[0])):
                opt = words.pop(0)
                if opt in ("-u", "-C", "-P") and words:
                    words.pop(0)
                elif opt == "-S" and words:
                    words = words[0].split() + words[1:]
                elif opt.startswith("-S") and len(opt) > 2:
                    words = opt[2:].split() + words
        else:
            break
    return words


def find_exe(word):
    if "/" in word:
        return word if os.path.exists(word) else None
    return shutil.which(word)


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, ValueError):
        return None


def first_line(path):
    try:
        with open(path, "rb") as f:
            return f.readline(256).decode("utf-8", "replace").rstrip("\r\n")
    except OSError:
        return None


def resolve(words, env, via, hops):
    """Follow a command to the interpreter it runs under, through env, a
    shebang or a shell wrapper's exec. Returns (kind, interpreter, via):
    kind is python, absent, other or unknown; via lists the shells passed."""
    words = strip_prefix(words)
    if not words:
        return ("unknown", "", via)
    if hops > HOPS:
        return ("unknown", words[0], via)
    word = words[0]
    if not word or "$" in word or "`" in word:
        return ("unknown", word, via)  # computed at run time, not readable
    base = os.path.basename(word)
    exe = find_exe(word)
    if exe is None:
        return ("absent", word, via)
    if PYTHON.match(base):
        return ("python", exe, via)
    if base in SHELLS:
        rest = words[1:]
        body = None
        while rest and rest[0].startswith("-"):
            if rest[0] == "-c" and len(rest) > 1:
                body = rest[1]
                break
            rest = rest[1:]
        if body is None:
            if not rest:
                return ("other", exe, via)
            if not os.path.isfile(rest[0]):
                return ("absent", rest[0], via + [exe])
            body = read_text(rest[0]) or ""
        return follow(body, env, via + [exe], hops + 1)
    line = first_line(exe)
    if line and line.startswith("#!"):
        return resolve(line[2:].split() + [exe] + words[1:], env, via,
                       hops + 1)
    return ("other", exe, via)


def follow(body, env, via, hops):
    """The interpreter a shell wrapper hands over to: its first exec, else
    its first command that runs a Python."""
    env = dict(env)
    execs = []
    pythons = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        for part in OPS.split(line):
            words = split_words(part, env)
            while words and words[0] in KEYWORDS:
                words.pop(0)
            if words and words[0] == "export":
                words = words[1:]
            if not words:
                continue
            if all(ASSIGN.match(w) for w in words):
                for w in words:
                    key, value = w.split("=", 1)
                    env[key] = value
            elif words[0] == "exec":
                execs.append(words)
            else:
                core = strip_prefix(words)
                if core and PYTHON.match(os.path.basename(core[0])):
                    pythons.append(words)
    for words in execs + pythons:
        return resolve(words, env, via, hops)
    return ("other", via[-1] if via else "", via[:-1])


def py_version(interp):
    try:
        p = subprocess.run([interp, "-c", VERSION_CODE],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=CAP_S)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", p.stdout.decode("utf-8", "replace"))
    if p.returncode != 0 or not m:
        return None
    return tuple(int(n) for n in m.groups())


def hook_commands():
    """(event, matcher, command) for each command hook in settings.json."""
    with open(SETTINGS, encoding="utf-8") as f:
        data = json.load(f)
    hooks = data.get("hooks") if isinstance(data, dict) else None
    out = []
    if not isinstance(hooks, dict):
        return out
    for event in hooks:
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            matcher = group.get("matcher") or ""
            for hook in group.get("hooks") or []:
                if not isinstance(hook, dict):
                    continue
                command = hook.get("command")
                if hook.get("type", "command") == "command" and \
                        isinstance(command, str) and command.strip():
                    out.append((event, matcher, command))
    return out


def load_hooks(item):
    """hook_commands(); [] without settings.json; None, after a MISSING
    line, when it does not parse."""
    try:
        return hook_commands()
    except FileNotFoundError:
        return []
    except (OSError, ValueError):
        say("MISSING", item, "settings.json does not parse",
            "fix the JSON of settings.json")
        return None


def hook_env():
    env = dict(os.environ)
    env.setdefault("CLAUDE_PROJECT_DIR", BUS)
    env["CLAUDE_CONFIG_DIR"] = CONFIG
    return env


def label(words):
    """The hook a command runs, as a report shows it."""
    for word in strip_prefix(words):
        base = os.path.basename(word)
        if word.startswith("-") or PYTHON.match(base) or base in SHELLS \
                or re.search(r"\s", word):
            continue
        return show(word)
    return show(words[0]) if words else "?"


def hook_python():
    cmds = load_hooks("hook-python")
    if cmds is None:
        return
    if not cmds:
        say("INFO", "hook-python", "no hook command in settings.json")
        return
    env = hook_env()
    seen = set()
    for event, _, command in cmds:
        if command in seen:
            continue
        seen.add(command)
        words = split_words(command, env)
        if not words:
            say("MISSING", "hook-python", "a %s hook command does not parse"
                % event, "fix that command in settings.json")
            continue
        name = label(words)
        kind, interp, via = resolve(words, env, [], 0)
        through = (" via " + " ".join(show(v) for v in via)) if via else ""
        shown = show(interp)
        if kind == "python":
            ver = py_version(interp)
            if ver is None:
                say("MISSING", "hook-python", "%s %s does not run%s"
                    % (name, shown, through), STEP_PY)
                continue
            detail = "%s %s %s%s" % (name, shown, ".".join(map(str, ver)),
                                     through)
            if ver < MIN_PY:
                say("MISSING", "hook-python", detail, STEP_PY)
            else:
                say("OK", "hook-python", detail)
        elif kind == "absent":
            what = name if shown == name else "%s %s" % (name, shown)
            say("MISSING", "hook-python", "%s not found%s" % (what, through),
                STEP_PY + ", or fix the hook command in settings.json")
        elif kind == "unknown":
            say("MISSING", "hook-python", "%s interpreter not determined%s"
                % (name, through),
                "make the hook name its interpreter by a literal path")
        else:
            say("INFO", "hook-python", "%s runs under %s%s, not Python"
                % (name, shown, through))


def matches(matcher, tool):
    if matcher in ("", "*"):
        return True
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return matcher == tool


def run_hook(command, stdin_text, env):
    """Run a hook command as Claude Code does: (exit code, stdout), or
    (None, why) when it did not run to its end."""
    try:
        p = subprocess.run(["/bin/sh", "-c", command],
                           input=stdin_text.encode("utf-8"),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=CAP_S, env=env, cwd=BUS)
    except subprocess.TimeoutExpired:
        return None, "timed out after %d s" % CAP_S
    except (OSError, subprocess.SubprocessError):
        return None, "did not run"
    return p.returncode, p.stdout.decode("utf-8", "replace")


def decision(out):
    try:
        data = json.loads(out) if out.strip() else {}
    except ValueError:
        return ""
    if not isinstance(data, dict):
        return ""
    spec = data.get("hookSpecificOutput")
    if isinstance(spec, dict) and spec.get("permissionDecision"):
        return str(spec["permissionDecision"])
    return str(data.get("decision") or "")


def gate(paths):
    cmds = load_hooks("gate")
    if cmds is None:
        return
    gates = [c for e, m, c in cmds if e == "PreToolUse" and matches(m, "Bash")]
    env = hook_env()
    for rel in paths:
        item = "gate %s push" % rel
        if not gates:
            say("MISSING", item, "no PreToolUse Bash hook in settings.json",
                "install the git gate (INSTALL.md step 2), then " + STEP_GATE)
            continue
        command = "git -C %s push origin HEAD:main" % shlex.quote(
            os.path.join(BUS, rel))
        payload = json.dumps({
            "session_id": "check-ready", "hook_event_name": "PreToolUse",
            "cwd": BUS, "tool_name": "Bash",
            "tool_input": {"command": command,
                           "description": "readiness probe"}})
        why = ""
        for hook in gates:
            code, out = run_hook(hook, payload, env)
            if code is None:
                why = out
            elif code == 2:
                why = "denied"
            elif code != 0:
                why = "failed with exit %d" % code
            elif decision(out) in ("deny", "block"):
                why = "denied"
            elif decision(out) == "ask":
                why = "asks for approval"
            if why:
                break
        if why:
            say("MISSING", item, why, STEP_GATE)
        else:
            say("OK", item, "allowed")


def walk(start):
    """The files an @-import chain reaches from start, at most HOPS hops,
    and the paths its import lines name, as written and resolved."""
    reached = []
    named = []
    todo = [(start, 0)]
    while todo:
        path, hops = todo.pop(0)
        real = os.path.realpath(path)
        if real in reached:
            continue
        reached.append(real)
        text = read_text(real) if hops < HOPS else None
        fence = False
        for raw in (text or "").splitlines():
            line = raw.strip()
            if line.startswith("```") or line.startswith("~~~"):
                fence = not fence
                continue
            m = None if fence else IMPORT.match(line)
            if not m:
                continue
            ref = m.group(1)
            if ref == "~" or ref.startswith("~/"):
                target = HOME + ref[1:]
            elif os.path.isabs(ref):
                target = ref
            else:
                target = os.path.join(os.path.dirname(real), ref)
            named.append((ref, os.path.normpath(target)))
            if os.path.isfile(target):
                todo.append((target, hops + 1))
    return reached, named


def overlay():
    target = os.path.join(BUS, OVERLAY)
    goal = os.path.realpath(target) if os.path.isfile(target) else None
    chains = [("bus", os.path.join(BUS, "guidance", "CLAUDE.md"),
               "import the overlay as @../" + OVERLAY + " in "
               "guidance/CLAUDE.md, with no memory/ import")]
    config_md = os.path.join(CONFIG, "CLAUDE.md")
    if os.path.isfile(config_md):
        chains.append(("config", config_md,
                       "make the chain import " + OVERLAY + " and name no "
                       "memory/ path"))
    for where, start, step in chains:
        name = "%s %s" % (where, show(start))
        if not os.path.isfile(start):
            say("MISSING", "overlay", name + " absent", "pull the migrated bus")
            continue
        reached, named = walk(start)
        problems = []
        if goal is None or goal not in reached:
            problems.append("does not reach " + OVERLAY)
        old = [t for ref, t in named if MEMORY.search(ref)]
        if old:
            problems.append("names " + show(old[0]))
        if problems:
            say("MISSING", "overlay", name + " " + ", ".join(problems), step)
        else:
            say("OK", "overlay", "%s reaches %s" % (name, OVERLAY))


def lore_catalog():
    cmds = load_hooks("lore-catalog")
    if cmds is None:
        return
    starts = [c for e, m, c in cmds if e == "SessionStart"]
    if not starts:
        say("MISSING", "lore-catalog", "no SessionStart hook in settings.json",
            "register the product's hooks/lore-recall.py as a SessionStart "
            "hook")
        return
    env = hook_env()
    for command in starts:
        code, out = run_hook(command, "{}", env)
        if code != 0:
            continue
        text = out
        try:
            text += str(json.loads(out)["hookSpecificOutput"]
                        ["additionalContext"])
        except (ValueError, KeyError, TypeError):
            pass
        if LORE in text:
            say("OK", "lore-catalog", "%s names %s"
                % (label(split_words(command, env) or [command]), LORE))
            return
    say("MISSING", "lore-catalog", "no SessionStart hook prints a catalog "
        "naming " + LORE, "bring product to the bus's pin, whose "
        "hooks/lore-recall.py reads " + LORE)


def git_out(args, cwd, stdin_bytes=None):
    """stdout of a read-only git command, or None when it fails."""
    try:
        p = subprocess.run(["git"] + args, cwd=cwd, input=stdin_bytes,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=CAP_S)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout if p.returncode == 0 else None


def is_pointer(path):
    """True when the work tree file is still a Git LFS pointer."""
    try:
        if os.path.getsize(path) > 1024:
            return False
        with open(path, "rb") as f:
            return f.read(len(POINTER)) == POINTER
    except OSError:
        return False


def lfs(paths):
    """The LFS files at a space's tip, by attribute, and how many of them are
    still pointers in its work tree. Plumbing only: git-lfs itself writes
    under .git/lfs/tmp even to list files."""
    for rel in paths:
        top = os.path.join(BUS, rel)
        listed = git_out(["ls-files", "-z"], top)
        attrs = None
        if listed is not None:
            attrs = git_out(["check-attr", "-z", "--stdin", "filter"], top,
                            listed)
        if attrs is None:
            say("MISSING", "lfs " + rel, "git ls-files does not run",
                "run git submodule update --init %s in the bus" % rel)
            continue
        fields = attrs.split(b"\0")
        files = [fields[i].decode("utf-8", "replace")
                 for i in range(0, len(fields) - 2, 3)
                 if fields[i + 2] == b"lfs"]
        left = [f for f in files if is_pointer(os.path.join(top, f))]
        detail = "%d LFS files, %d %s" % (len(files), len(left),
                                          "still pointers" if left
                                          else "pointers")
        if left:
            say("MISSING", "lfs " + rel, detail, "run git lfs pull in " + rel)
        else:
            say("OK", "lfs " + rel, detail)


def main():
    if ITEM == "hook-python":
        hook_python()
    elif ITEM == "gate":
        gate(sys.argv[6:])
    elif ITEM == "lfs":
        lfs(sys.argv[6:])
    elif ITEM == "overlay":
        overlay()
    elif ITEM == "lore-catalog":
        lore_catalog()
    else:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

helper() {  # helper <item> [<path>...]: the Python part's lines for <item>
    _item=$1
    if [ "$PY_OK" != yes ]; then
        missing "$_item not checked, $PY does not run Python 3.6 or later: \
install Python 3.9 or later at that path"
        return
    fi
    shift
    "$PY" -I -B "$TMPD/helper.py" "$_item" "$CLASS" "$BUS" "$CONFIG" "$HOME" \
        "$@" >"$TMPD/helper.out" 2>/dev/null
    _hrc=$?
    while IFS= read -r _hl; do
        emit "$_hl"
    done <"$TMPD/helper.out"
    [ "$_hrc" -eq 0 ] ||
        missing "$_item not checked, the check failed with exit $_hrc: \
rerun it, then report the failure"
}

# ------------------------------------------------------------ the bus

gm_paths() {  # the bus's submodules, one "<name><TAB><path>" line each
    [ -f "$BUS/.gitmodules" ] || return 0
    git config -f "$BUS/.gitmodules" --get-regexp '^submodule\..*\.path$' \
        2>/dev/null | while read -r _k _p; do
        _k=${_k#submodule.}
        printf '%s\t%s\n' "${_k%.path}" "$_p"
    done
}

gm_url() {  # gm_url <name>: its URL; a relative one as the clone resolved it
    _u=$(git config -f "$BUS/.gitmodules" --get "submodule.$1.url" 2>/dev/null)
    case $_u in
        ./* | ../*)
            _v=$(git -C "$BUS" config --get "submodule.$1.url" 2>/dev/null)
            [ -n "$_v" ] && _u=$_v
            ;;
    esac
    printf '%s\n' "$_u"
}

space_url() {  # space_url <x>: the URL given for core, lore or tmp, else mounted
    case $1 in
        core) _g=$CORE_URL ;;
        lore) _g=$LORE_URL ;;
        *) _g=$TMP_URL ;;
    esac
    if [ -z "$_g" ]; then
        _n=$(gm_paths | awk -F "$TAB" -v p="spaces/$1" '$2 == p { print $1 }' |
            sed -n 1p)
        [ -n "$_n" ] && _g=$(gm_url "$_n")
    fi
    printf '%s\n' "$_g"
}

is_repo_top() {  # is_repo_top <dir>: 0 when <dir> is the top of a work tree
    _dr=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    _dt=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$(cd "$_dt" 2>/dev/null && pwd -P)" = "$_dr" ]
}

has_role() {  # has_role <role>: 0 when AGENT_ROLES holds <role>
    case ",$(printf '%s' "$ROLES" | tr -d ' ')," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

# ------------------------------------------------------------ before items

item_git_lfs() {
    _step="install Git LFS, then git lfs install"
    if ! _v=$(git lfs version 2>/dev/null) || [ -z "$_v" ]; then
        missing "git-lfs git lfs version does not run: $_step"
        return
    fi
    _v=${_v#git-lfs/}
    _v=${_v%% *}
    _unset=
    for _k in clean smudge process; do
        [ -n "$(git config --get "filter.lfs.$_k" 2>/dev/null)" ] ||
            _unset="$_unset $_k"
    done
    [ "$(git config --bool --get filter.lfs.required 2>/dev/null)" = true ] ||
        _unset="$_unset required"
    if [ -n "$_unset" ]; then
        missing "git-lfs $_v, filter.lfs unset ($_unset ): $_step"
    else
        ok "git-lfs $_v"
    fi
}

item_filter_repo() {
    if _v=$(git filter-repo --version 2>/dev/null) && [ -n "$_v" ]; then
        ok "filter-repo $(printf '%s\n' "$_v" | sed -n 1p)"
    else
        missing "filter-repo git filter-repo --version does not run: \
install git-filter-repo"
    fi
}

READ_SEEN=$NL
READ_FAILED=$NL
probe_read() {  # probe_read <url>: 0 when git ls-remote reads it; refs in REFS
    run_capped "$CAP_S" git ls-remote "$1" >"$TMPD/ls.out" 2>/dev/null
    _prc=$?
    REFS=$(wc -l <"$TMPD/ls.out" | tr -d ' ')
    return "$_prc"
}

item_read() {  # item_read <url>: the counted read item, once per URL
    case $READ_SEEN in
        *"$NL$1$NL"*) return ;;
    esac
    READ_SEEN=$READ_SEEN$1$NL
    _shown=$(show_url "$1")
    _repo=$(repo_name "$_shown")
    if probe_read "$1"; then
        ok "read $_shown $REFS refs"
    else
        READ_FAILED=$READ_FAILED$1$NL
        missing "read $_shown: grant this node's git credential read access \
to $_repo; a token limited to named repos needs $_repo added"
    fi
}

PROBE=
probe_write() {  # probe_write <url>: 0 when a dry-run push to <url> is accepted
    if [ -z "$PROBE" ]; then
        mkdir -p "$TMPD/nohooks" &&
            git init -q --template= "$TMPD/probe" >/dev/null 2>&1 &&
            git -C "$TMPD/probe" -c core.hooksPath="$TMPD/nohooks" \
                -c commit.gpgsign=false -c user.name=check-ready \
                -c user.email=check-ready@example.invalid \
                commit -q --allow-empty -m "Readiness write probe" \
                >/dev/null 2>&1 || return 1
        PROBE=$TMPD/probe
    fi
    # The probe's commit goes to a ref the remote does not hold, never to
    # main: a non-empty remote would refuse an unrelated commit on main as
    # not a fast-forward before write access is tested.
    run_capped "$CAP_S" git -C "$PROBE" -c core.hooksPath="$TMPD/nohooks" \
        push --dry-run --porcelain "$1" "HEAD:$PROBE_REF" \
        >"$TMPD/push.out" 2>/dev/null
    _wrc=$?
    WROTE="dry-run push accepted"
    [ "$_wrc" -eq 0 ] && return 0
    # Should the remote hold the probe ref after all, the same refusal comes
    # only after the remote has taken the push request, so it shows write
    # access too.
    WROTE="dry-run push request accepted, the probe ref not a fast-forward"
    [ "$_wrc" -eq 1 ] && grep -Eq "^!${TAB}HEAD:$PROBE_REF${TAB}\
\[rejected\] \((fetch first|non-fast-forward)\)" "$TMPD/push.out"
}

item_write() {  # item_write <url>
    _shown=$(show_url "$1")
    _repo=$(repo_name "$_shown")
    case $READ_FAILED in
        *"$NL$1$NL"*)
            info "write $_shown not probed, the read failed"
            return
            ;;
    esac
    if probe_write "$1"; then
        ok "write $_shown $WROTE"
    else
        missing "write $_shown: grant this node's git credential write access \
to $_repo"
    fi
}

item_submodule() {  # item_submodule <name> <path>
    _p=$2
    _step="discard or move the change in $_p, then update the submodule"
    _pin=$(git -C "$BUS" rev-parse -q --verify "HEAD:$_p" 2>/dev/null)
    if [ -z "$_pin" ]; then
        missing "submodule $_p no pin at the bus's HEAD: $_step"
        return
    fi
    if ! is_repo_top "$BUS/$_p"; then
        missing "submodule $_p not initialized: $_step"
        return
    fi
    _head=$(git -C "$BUS/$_p" rev-parse -q --verify HEAD 2>/dev/null)
    _where=
    if [ "$_head" = "$_pin" ]; then
        _where="at the pin $(short "$_pin")"
    elif [ "$TRACK" = tip ]; then
        _br=$(git config -f "$BUS/.gitmodules" --get "submodule.$1.branch" \
            2>/dev/null)
        [ "$_br" = . ] && _br=$(git -C "$BUS" symbolic-ref -q --short HEAD)
        _br=${_br:-main}
        _tip=$(git -C "$BUS/$_p" rev-parse -q --verify \
            "refs/remotes/origin/$_br" 2>/dev/null)
        if [ "$(git -C "$BUS/$_p" symbolic-ref -q HEAD)" = "refs/heads/$_br" ] ||
            { [ -n "$_tip" ] && [ "$_head" = "$_tip" ]; }; then
            _where="on $_br at $(short "$_head")"
        fi
    fi
    if [ -z "$_where" ]; then
        missing "submodule $_p at $(short "$_head"), the pin is \
$(short "$_pin"): $_step"
        return
    fi
    if ! git -C "$BUS/$_p" status --porcelain --untracked-files=no \
        >"$TMPD/st.out" 2>/dev/null; then
        missing "submodule $_p status does not run: $_step"
        return
    fi
    _dirty=$(wc -l <"$TMPD/st.out" | tr -d ' ')
    if [ "$_dirty" -gt 0 ]; then
        missing "submodule $_p $_where, $_dirty changed paths: $_step"
    else
        ok "submodule $_p $_where, clean"
    fi
}

item_leftovers() {
    if ! git -C "$BUS" ls-files --others --exclude-standard -- memory \
        agent-tmp >"$TMPD/u.out" 2>/dev/null ||
        ! git -C "$BUS" ls-files --others --ignored --exclude-standard -- \
            memory agent-tmp >"$TMPD/i.out" 2>/dev/null; then
        missing "leftovers git ls-files does not run in the bus: move them \
out of the bus, or into scratch once it is mounted"
        return
    fi
    _u=$(wc -l <"$TMPD/u.out" | tr -d ' ')
    _i=$(wc -l <"$TMPD/i.out" | tr -d ' ')
    _d="$_u untracked and $_i ignored files under memory/ and agent-tmp/"
    if [ "$_u" -eq 0 ] && [ "$_i" -eq 0 ]; then
        ok "leftovers $_d"
    elif [ "$MIGRATING" = yes ]; then
        info "leftovers $_d"
    else
        missing "leftovers $_d: move them out of the bus, or into scratch once \
it is mounted"
    fi
}

item_agents() {
    for _r in $POD_ROLES; do
        _f=agents/swe-$_r.md
        if [ ! -f "$CONFIG/$_f" ]; then
            missing "agent swe-$_r $_f does not resolve: link the swe-pod role \
definitions"
            continue
        fi
        _n=$(sed -n 's/^name:[[:space:]]*//p' "$CONFIG/$_f" | sed -n 1p |
            sed "s/[[:space:]]*\$//; s/^[\"']//; s/[\"']\$//")
        if [ "$_n" = "swe-$_r" ]; then
            ok "agent swe-$_r $_f"
        else
            missing "agent swe-$_r $_f names ${_n:-no agent}: link the swe-pod \
role definitions"
        fi
    done
}

item_skills() {
    _want=$POD_SKILLS
    _scratch=no
    if [ -f "$BUS/product/skills/mesh-scratch/SKILL.md" ]; then
        _want="$_want mesh-scratch"
        _scratch=yes
    fi
    for _s in $_want; do
        if [ -f "$CONFIG/skills/$_s/SKILL.md" ]; then
            ok "skill $_s skills/$_s/SKILL.md"
        else
            missing "skill $_s skills/$_s/SKILL.md does not resolve: rerun the \
skill link loop of INSTALL.md step 3"
        fi
    done
    [ "$_scratch" = yes ] ||
        info "skill mesh-scratch not in the bus's product, not required"
    for _d in "$BUS"/product/skills/*/; do
        [ -f "${_d}SKILL.md" ] || continue
        _s=${_d%/}
        _s=${_s##*/}
        case " $_want " in
            *" $_s "*) continue ;;
        esac
        if [ -f "$CONFIG/skills/$_s/SKILL.md" ]; then
            info "skill $_s ok"
        else
            info "skill $_s absent"
        fi
    done
}

run_before() {
    ok "git ${GIT_VERSION#git version }"
    item_git_lfs
    [ "$MIGRATING" = yes ] && item_filter_repo
    helper hook-python

    gm_paths >"$TMPD/gm"
    ORIGIN=$(git -C "$BUS" remote get-url origin 2>/dev/null)
    if [ -n "$ORIGIN" ]; then
        item_read "$ORIGIN"
    else
        missing "read origin the bus clone has no origin remote: set it to \
the bus repo's URL"
    fi
    while IFS="$TAB" read -r l_name l_path; do
        case $l_path in spaces/*) continue ;; esac
        l_url=$(gm_url "$l_name")
        [ -n "$l_url" ] && item_read "$l_url"
    done <"$TMPD/gm"
    for l_x in $SPACES; do
        l_url=$(space_url "$l_x")
        if [ -n "$l_url" ]; then
            item_read "$l_url"
        else
            missing "read $l_x no URL given: pass --$l_x-url <url>"
        fi
    done
    while IFS="$TAB" read -r l_name l_path; do
        case $l_path in
            spaces/core | spaces/lore | spaces/tmp) continue ;;
            spaces/*) ;;
            *) continue ;;
        esac
        l_url=$(gm_url "$l_name")
        [ -n "$l_url" ] || continue
        if probe_read "$l_url"; then
            info "read $(show_url "$l_url") ok"
        else
            info "read $(show_url "$l_url") unreachable"
        fi
    done <"$TMPD/gm"

    [ -n "$ORIGIN" ] && item_write "$ORIGIN"
    l_url=$(space_url tmp)
    [ -n "$l_url" ] && item_write "$l_url"
    if has_role librarian; then
        for l_x in core lore; do
            l_url=$(space_url "$l_x")
            [ -n "$l_url" ] && item_write "$l_url"
        done
    fi

    helper gate spaces/core spaces/lore spaces/tmp

    while IFS="$TAB" read -r l_name l_path; do
        case $l_path in spaces/*) continue ;; esac
        item_submodule "$l_name" "$l_path"
    done <"$TMPD/gm"
    item_leftovers
    item_agents
    item_skills
}

# ------------------------------------------------------------ after items

item_bus() {  # HEAD against the fetched origin/main, not the remote's live one
    _head=$(git -C "$BUS" rev-parse -q --verify HEAD 2>/dev/null)
    _tip=$(git -C "$BUS" rev-parse -q --verify \
        'refs/remotes/origin/main^{commit}' 2>/dev/null)
    _lacks=
    for _x in $SPACES; do
        grep -Eq "(^|[{[:space:],])id:[[:space:]]*$_x[[:space:]]*([,}]|\$)" \
            "$BUS/spaces.yaml" 2>/dev/null || _lacks="$_lacks $_x"
    done
    _bad=
    if [ -z "$_tip" ]; then
        _bad="no fetched origin/main"
    elif [ "$_head" != "$_tip" ]; then
        _bad="at $(short "$_head"), origin/main at $(short "$_tip")"
    fi
    if [ -n "$_lacks" ]; then
        _bad="${_bad:+$_bad, }spaces.yaml lacks$_lacks"
    fi
    if [ -n "$_bad" ]; then
        missing "bus $_bad: pull the migrated bus"
    else
        ok "bus at origin/main $(short "$_tip"), spaces.yaml lists core, lore \
and tmp"
    fi
}

item_cloned() {  # item_cloned <x>
    _p=spaces/$1
    if ! is_repo_top "$BUS/$_p"; then
        missing "cloned $_p not initialized: run git submodule update --init \
$_p in the bus, then check out main in $_p"
        return
    fi
    _br=$(git -C "$BUS/$_p" symbolic-ref -q --short HEAD 2>/dev/null)
    _head=$(git -C "$BUS/$_p" rev-parse -q --verify HEAD 2>/dev/null)
    if [ "$_br" = main ]; then
        ok "cloned $_p on main at $(short "$_head")"
    elif [ -n "$_br" ]; then
        missing "cloned $_p on $_br: check out main in $_p"
    else
        missing "cloned $_p detached at $(short "$_head"): check out main \
in $_p"
    fi
}

item_lfs() {  # item_lfs <x>
    if is_repo_top "$BUS/spaces/$1"; then
        helper lfs "spaces/$1"
    else
        info "lfs spaces/$1 not checked, the space is not cloned"
    fi
}

run_after() {
    item_bus
    for l_x in $SPACES; do
        item_cloned "$l_x"
    done
    for l_x in $SPACES; do
        item_lfs "$l_x"
    done
    helper overlay
    helper lore-catalog
    item_agents
    item_skills
}

if [ "$MODE" = before ]; then
    run_before
else
    run_after
fi
finish
