"""Lore record helpers shared by the lore hooks (lore-recall, lore-trigger).

Reads ~/.agent-identity.env and the front-matter of spaces/lore/lore/*.md
(PROTOCOL §7). Stdlib only, no YAML library: the header is parsed with
regexes that accept a flow list wrapped over several lines and a block list.
Python 3.6-safe, since the hooks run under /usr/bin/python3, which is 3.6 on
some nodes (lore-20261028-0002).
"""
import glob
import os
import re
from typing import Dict, List

TRIGGER_MODES = ("hint", "fail", "block")


def identity() -> Dict[str, str]:
    """Parse ~/.agent-identity.env ({} if absent). Inline # comments and
    surrounding quotes are stripped from values."""
    out = {}  # type: Dict[str, str]
    try:
        with open(os.path.expanduser("~/.agent-identity.env")) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                val = val.split("#", 1)[0].strip().strip("'\"")
                out[key.strip()] = val
    except Exception:
        pass
    return out


def lore_dir(repo: str) -> str:
    """The lore folder under a bus checkout, or '' if there is none. The
    memory/lore compatibility path is read only when the space is absent."""
    for sub in (("spaces", "lore", "lore"), ("memory", "lore")):
        path = os.path.join(repo, *sub)
        if os.path.isdir(path):
            return path
    return ""


def front_matter(text: str) -> str:
    """The YAML block between the first two --- fences."""
    m = re.search(r"^---\s*$(.*?)^---\s*$", text, re.M | re.S)
    return m.group(1) if m else ""


def field(block: str, name: str) -> str:
    """A scalar field, quotes stripped."""
    m = re.search(r"^%s:[ \t]*(.*)$" % re.escape(name), block, re.M)
    return m.group(1).strip().strip("'\"") if m else ""


def list_field(block: str, name: str) -> List[str]:
    """A list field, as a flow list (possibly wrapped over lines) or a block
    list of `- item` lines. Items may not contain commas or brackets."""
    key = re.escape(name)
    m = re.search(r"^%s:[ \t]*\[(.*?)\]" % key, block, re.M | re.S)
    if m:
        items = m.group(1).split(",")
    else:
        m = re.search(r"^%s:[ \t]*\n((?:[ \t]+-[^\n]*\n?)+)" % key, block,
                      re.M)
        if not m:
            return []
        items = [ln.strip()[1:] for ln in m.group(1).splitlines()]
    return [i.strip().strip("'\"") for i in items if i.strip()]


def section(text: str, heading: str) -> str:
    """Body of a `## <heading>` section, up to the next ## heading."""
    m = re.search(r"^##[ \t]+%s[ \t]*$(.*?)(?=^##[ \t]|\Z)" % heading,
                  text, re.M | re.S)
    return m.group(1).strip() if m else ""


def body(text: str) -> str:
    """Everything after the front-matter."""
    m = re.search(r"^---\s*$.*?^---\s*$", text, re.M | re.S)
    return text[m.end():].strip() if m else text.strip()


def holds(contexts: List[str], context: str) -> bool:
    """A record holds here if it is universal or names this context."""
    return not contexts or (bool(context) and context in contexts)


def records(ldir: str) -> List[Dict]:
    """Every lore record in ldir, sorted by file name (that is, by id)."""
    out = []  # type: List[Dict]
    for path in sorted(glob.glob(os.path.join(ldir, "*.md"))):
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except Exception:
            continue
        block = front_matter(text)
        mode = field(block, "trigger_mode") or "hint"
        out.append({
            "path": path,
            "text": text,
            "id": field(block, "id"),
            "title": field(block, "title"),
            "contexts": list_field(block, "contexts"),
            "tags": list_field(block, "tags"),
            "triggers": list_field(block, "triggers"),
            "trigger_mode": mode if mode in TRIGGER_MODES else "hint",
        })
    return out
