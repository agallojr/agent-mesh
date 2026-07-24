"""Email-monitor listener: drain the ingress mailbox into library.submit.

Runnable form of the email-monitor role duty (spec/librarian-email-ingress.md).
Per cycle: list unread mail under the ingress label, validate each (DKIM/DMARC +
sender allowlist + shared secret, constant-time), strip the secret, and either
post a sanitized `library.submit` onto the bus (accept) or a metadata-only reject
audit (reject) — then label + mark the mail read. It NEVER writes memory/; the
librarian drains what it posts.

Config comes from ~/.agent-identity.env (non-secret) and ~/.agent-credentials.env
(GMAIL_LIBRARIAN_OAUTH bundle + LIBRARIAN_EMAIL_SECRET). TLS verification goes
through the OS trust store via truststore, so it works behind a TLS-inspecting
proxy (e.g. Zscaler) without disabling verification.

Modes:
    --dry-run   validate + print decisions and the library.submit that WOULD be
                posted; write nothing, mutate no mail. Safe.
    --once      one pass then exit (default).
    --loop      repeat every LIBRARIAN_EMAIL_POLL_SEC seconds.
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import truststore

truststore.inject_into_ssl()

IDENTITY = os.path.expanduser("~/.agent-identity.env")
CREDENTIALS = os.path.expanduser("~/.agent-credentials.env")
GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me/"
BLOB_EXTS = {
    ".nc", ".h5", ".hdf5", ".ckpt", ".npy", ".npz", ".png", ".jpg", ".jpeg",
    ".mp4", ".tar", ".zip", ".gz", ".tgz", ".bin", ".pt", ".pth",
    ".safetensors",
}


def load_env(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            # strip a trailing inline comment ( ...  # note), but not a '#'
            # that is part of the value with no leading space (none of ours are)
            v = re.split(r"\s+#", v, maxsplit=1)[0]
            out[k.strip()] = v.strip()
    return out


class Config:
    def __init__(self) -> None:
        ident = load_env(IDENTITY)
        cred = load_env(CREDENTIALS)
        self.repo = ident["REPO_PATH"]
        self.agent_id = ident["AGENT_ID"]
        self.agent_context = ident.get("AGENT_CONTEXT", "")
        self.label = ident.get("LIBRARIAN_EMAIL_LABEL", "mesh-ingress")
        self.default_category = ident.get(
            "LIBRARIAN_EMAIL_DEFAULT_CATEGORY", "lore"
        )
        self.allowed = {
            a.strip().lower()
            for a in ident.get("LIBRARIAN_EMAIL_ALLOWED_SENDERS", "").split(",")
            if a.strip()
        }
        self.poll_sec = int(ident.get("LIBRARIAN_EMAIL_POLL_SEC", "300"))
        self.enabled = ident.get("LIBRARIAN_EMAIL_ENABLED", "false") == "true"
        self.secret = cred.get("LIBRARIAN_EMAIL_SECRET", "")
        self.oauth = json.loads(cred["GMAIL_LIBRARIAN_OAUTH"])


def access_token(oauth: dict) -> str:
    data = urllib.parse.urlencode({
        "client_id": oauth["client_id"],
        "client_secret": oauth["client_secret"],
        "refresh_token": oauth["refresh_token"],
        "grant_type": "refresh_token",
    }).encode()
    resp = urllib.request.urlopen(oauth["token_uri"], data=data, timeout=30)
    return json.load(resp)["access_token"]


def api(token: str, path: str, method: str = "GET",
        body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(GMAIL + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    return json.load(urllib.request.urlopen(req, timeout=30))


def labels_map(token: str) -> dict[str, str]:
    return {l["name"]: l["id"] for l in api(token, "labels")["labels"]}


def ensure_label(token: str, lmap: dict[str, str], name: str) -> str:
    if name in lmap:
        return lmap[name]
    created = api(token, "labels", "POST", {
        "name": name, "labelListVisibility": "labelShow",
        "messageListVisibility": "show",
    })
    lmap[name] = created["id"]
    return created["id"]


def first_text_body(payload: dict) -> str:
    if payload.get("mimeType", "").startswith("text/plain"):
        data = payload.get("body", {}).get("data")
        if data:
            return base64.urlsafe_b64decode(data).decode("utf-8", "replace")
    for part in payload.get("parts", []) or []:
        got = first_text_body(part)
        if got:
            return got
    return ""


class Parsed:
    def __init__(self) -> None:
        self.title = ""
        self.sender = ""
        self.dkim = False
        self.dmarc = False
        self.secret_line_ok = False
        self.intent = "learning"
        self.category = ""
        self.tags: list[str] = []
        self.contexts: list[str] = []
        self.body = ""
        self.message_id = ""
        self.date = ""


def parse_message(cfg: Config, msg: dict) -> Parsed:
    p = Parsed()
    hdrs = {h["name"].lower(): h["value"]
            for h in msg["payload"].get("headers", [])}
    p.title = hdrs.get("subject", "").strip()
    m = re.search(r"[\w.+-]+@[\w.-]+", hdrs.get("from", ""))
    p.sender = m.group(0).lower() if m else ""
    ar = hdrs.get("authentication-results", "").lower()
    p.dkim = "dkim=pass" in ar
    p.dmarc = "dmarc=pass" in ar
    p.message_id = hdrs.get("message-id", "").strip()
    p.date = hdrs.get("date", "").strip()

    raw = first_text_body(msg["payload"])
    lines = raw.splitlines()
    # first non-blank line must be the secret
    idx = 0
    while idx < len(lines) and not lines[idx].strip():
        idx += 1
    if idx < len(lines):
        key = re.match(r"X-Mesh-Key:\s*(.*)$", lines[idx].strip())
        if key and cfg.secret and hmac.compare_digest(
                key.group(1), cfg.secret):
            p.secret_line_ok = True
        idx += 1
    # consume X-Mesh-* directive lines
    p.category = cfg.default_category
    p.contexts = [cfg.agent_context] if cfg.agent_context else []
    while idx < len(lines):
        d = re.match(r"X-Mesh-(\w+):\s*(.*)$", lines[idx].strip())
        if not d:
            break
        field, val = d.group(1).lower(), d.group(2).strip()
        if field == "intent":
            p.intent = val.lower()
        elif field == "category":
            p.category = val
        elif field == "tags":
            p.tags = [t.strip() for t in val.split(",") if t.strip()]
        elif field == "contexts":
            p.contexts = [c.strip() for c in val.split(",") if c.strip()]
        idx += 1
    p.body = "\n".join(lines[idx:]).strip()
    return p


def decide(cfg: Config, p: Parsed) -> tuple[bool, str]:
    if not (p.dkim and p.dmarc):
        return False, "auth-failed"
    if p.sender not in cfg.allowed:
        return False, "sender-not-allowlisted"
    if not p.secret_line_ok:
        return False, "bad-secret"
    if p.intent != "learning":
        return False, "intent-unsupported"
    return True, "accepted"


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return (s or "untitled")[:60]


def now_stamp() -> tuple[str, str]:
    n = datetime.now(timezone.utc)
    return n.strftime("%Y%m%dT%H%M"), n.strftime("%Y-%m-%d")


def compose_submit(cfg: Config, p: Parsed, msg_id: str) -> str:
    fm = [
        "---",
        "schema_version: 1",
        f"id: {msg_id}",
        f"from: {cfg.agent_id}",
        "to: role:librarian",
        "type: library.submit",
        f"created: {datetime.now(timezone.utc).isoformat()}",
        f"category: {p.category}",
        f"title: {json.dumps(p.title)}",
        "provenance: human",
        f"contexts: [{', '.join(p.contexts)}]",
        f"discovered_by: {p.sender}",
        f"discovered_on: {now_stamp()[1]}",
        "retention: permanent-until-superseded",
        f"email_message_id: {p.message_id}",
    ]
    if p.tags:
        fm.append(f"tags: [{', '.join(json.dumps(t) for t in p.tags)}]")
    fm.append(f'source: "email:{p.sender}"')
    fm.append("---")
    return "\n".join(fm) + "\n\n" + p.body + "\n"


def git_sync(repo: str, message: str) -> None:
    for args in (["add", "-A"], ["commit", "-m", message],
                 ["push", "origin", "HEAD"]):
        subprocess.run(["git", "-C", repo, *args], check=True,
                       capture_output=True, text=True)


def ingested_index_path(cfg: Config) -> str:
    return os.path.join(
        cfg.repo, "outbox", cfg.agent_id, ".ingested-emails"
    )


def already_ingested(cfg: Config, message_id: str) -> bool:
    path = ingested_index_path(cfg)
    if not message_id or not os.path.exists(path):
        return False
    with open(path, encoding="utf-8") as fh:
        return any(line.strip() == message_id for line in fh)


def run_once(cfg: Config, token: str, dry: bool) -> None:
    lmap = labels_map(token)
    if cfg.label not in lmap:
        print(f"label {cfg.label!r} does not exist yet; nothing to do")
        return
    q = urllib.parse.quote(f"label:{cfg.label} is:unread")
    res = api(token, f"messages?q={q}&maxResults=20")
    refs = res.get("messages", [])
    print(f"unread under {cfg.label!r}: {len(refs)}")
    if not refs:
        return

    ts, _ = now_stamp()
    seq = 0
    for ref in refs:
        msg = api(token, f"messages/{ref['id']}?format=full")
        p = parse_message(cfg, msg)
        accept, reason = decide(cfg, p)
        tag = "ACCEPT" if accept else f"REJECT/{reason}"
        print(f"\n[{tag}] {p.title!r}  from={p.sender}  "
              f"dkim={p.dkim} dmarc={p.dmarc} secret={p.secret_line_ok} "
              f"intent={p.intent}")

        if accept and already_ingested(cfg, p.message_id):
            print("  already ingested (Message-ID seen); marking processed only")
            if not dry:
                _mark(token, lmap, ref["id"], "mesh-processed", dry)
            continue

        if accept:
            seq += 1
            msg_id = f"{ts}-{seq:04d}"
            submit = compose_submit(cfg, p, msg_id)
            rel = f"tasks/roles/librarian/{msg_id}-{slugify(p.title)}.md"
            if dry:
                print(f"  WOULD write {rel}:")
                print("  " + submit.replace("\n", "\n  "))
                continue
            _write(cfg, rel, submit)
            _append_index(cfg, p.message_id)
            git_sync(cfg.repo, f"post library.submit from email {msg_id}")
            _mark(token, lmap, ref["id"], "mesh-processed", dry)
            print(f"  posted {rel} and marked processed")
        else:
            audit = {
                "email_message_id": p.message_id, "from": p.sender,
                "dkim": p.dkim, "dmarc": p.dmarc, "decision": reason,
                "ts": datetime.now(timezone.utc).isoformat(),
            }
            rel = f"outbox/{cfg.agent_id}/{ts}-{ref['id']}-reject.json"
            if dry:
                print(f"  WOULD write reject audit {rel}: {json.dumps(audit)}")
                continue
            _write(cfg, rel, json.dumps(audit, indent=2) + "\n")
            git_sync(cfg.repo, f"reject email ingress {reason} {ref['id']}")
            _mark(token, lmap, ref["id"], "mesh-rejected", dry)
            print(f"  wrote reject audit {rel} and marked rejected")


def _write(cfg: Config, rel: str, content: str) -> None:
    full = os.path.join(cfg.repo, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as fh:
        fh.write(content)


def _append_index(cfg: Config, message_id: str) -> None:
    if not message_id:
        return
    path = ingested_index_path(cfg)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(message_id + "\n")


def _mark(token: str, lmap: dict[str, str], msg_id: str,
          label: str, dry: bool) -> None:
    if dry:
        return
    lid = ensure_label(token, lmap, label)
    api(token, f"messages/{msg_id}/modify", "POST",
        {"addLabelIds": [lid], "removeLabelIds": ["UNREAD"]})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    cfg = Config()
    if not cfg.enabled and not args.dry_run:
        print("LIBRARIAN_EMAIL_ENABLED is not true; refusing to run live. "
              "Use --dry-run to test, or enable it in ~/.agent-identity.env.")
        return 1
    if not cfg.secret or not cfg.oauth:
        print("missing LIBRARIAN_EMAIL_SECRET or GMAIL_LIBRARIAN_OAUTH")
        return 1

    while True:
        token = access_token(cfg.oauth)
        run_once(cfg, token, dry=args.dry_run)
        if not args.loop:
            return 0
        time.sleep(cfg.poll_sec)


if __name__ == "__main__":
    raise SystemExit(main())
