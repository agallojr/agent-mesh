#!/usr/bin/env python3
"""Unit test of the email monitor's bus commits (R4).

git_sync stages and commits only the paths it is given, so a stale
submodule checkout, a staged gitlink and another modified file in the bus
stay out of the commit; run_once names exactly the files it wrote. Builds
throwaway repos under a temporary folder with HOME pointed into it.
Standard library only: the third-party truststore import is stubbed.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest

# Write no __pycache__ beside the monitor's source (each test removes what it
# makes, plan section 2.7).
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
MONITOR = os.path.join(HERE, "..", "..", "services", "librarian-email-monitor",
                       "email_monitor.py")
CACHE = os.path.join(os.path.dirname(MONITOR), "__pycache__")


def cache_listing() -> list[tuple[str, int]] | None:
    """What __pycache__ beside the monitor holds now (None if absent)."""
    if not os.path.isdir(CACHE):
        return None
    return sorted((n, os.stat(os.path.join(CACHE, n)).st_mtime_ns)
                  for n in os.listdir(CACHE))


# Taken before any test loads the monitor, to compare with afterwards.
CACHE_BEFORE = cache_listing()


def git(*args: str, cwd: str | None = None) -> str:
    """Run git and return its stdout, failing loudly."""
    r = subprocess.run(["git", *args], cwd=cwd, check=True,
                       capture_output=True, text=True)
    return r.stdout.strip()


def load_monitor() -> types.ModuleType:
    """Import email_monitor.py with a stand-in for truststore."""
    sys.modules["truststore"] = types.SimpleNamespace(
        inject_into_ssl=lambda: None)
    spec = importlib.util.spec_from_file_location("email_monitor", MONITOR)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class EmailMonitorStaging(unittest.TestCase):
    """The monitor's commits hold only the files it wrote."""

    def setUp(self) -> None:
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="mesh-unit-em."))
        home = os.path.join(self.tmp, "home")
        os.makedirs(home)
        self.env = dict(os.environ)
        os.environ.update({
            "HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "unit", "GIT_AUTHOR_EMAIL": "unit@example.invalid",
            "GIT_COMMITTER_NAME": "unit",
            "GIT_COMMITTER_EMAIL": "unit@example.invalid",
        })
        t = self.tmp
        git("init", "-q", "--bare", f"{t}/prod.git")
        git("-C", f"{t}/prod.git", "symbolic-ref", "HEAD", "refs/heads/main")
        git("clone", "-q", f"{t}/prod.git", f"{t}/prodw")
        git("-C", f"{t}/prodw", "symbolic-ref", "HEAD", "refs/heads/main")
        for name in ("a", "b"):
            with open(f"{t}/prodw/{name}", "w", encoding="utf-8") as fh:
                fh.write(name + "\n")
            git("-C", f"{t}/prodw", "add", name)
            git("-C", f"{t}/prodw", "commit", "-q", "-m", name)
        self.old = git("-C", f"{t}/prodw", "rev-parse", "HEAD~1")
        git("-C", f"{t}/prodw", "push", "-q", "origin", "main")
        git("init", "-q", "--bare", f"{t}/bus.git")
        git("-C", f"{t}/bus.git", "symbolic-ref", "HEAD", "refs/heads/main")
        git("clone", "-q", f"{t}/bus.git", f"{t}/bus")
        self.bus = f"{t}/bus"
        git("-C", self.bus, "symbolic-ref", "HEAD", "refs/heads/main")
        with open(f"{self.bus}/README.md", "w", encoding="utf-8") as fh:
            fh.write("bus\n")
        git("-C", self.bus, "add", "README.md")
        git("-C", self.bus, "commit", "-q", "-m", "init")
        git("-C", self.bus, "-c", "protocol.file.allow=always", "submodule",
            "add", "-q", f"file://{t}/prod.git", "product")
        git("-C", self.bus, "config", "-f", ".gitmodules",
            "submodule.product.ignore", "all")
        git("-C", self.bus, "add", ".gitmodules", "product")
        git("-C", self.bus, "commit", "-q", "-m", "pin")
        git("-C", self.bus, "push", "-q", "-u", "origin", "main")
        self.pin = git("-C", self.bus, "rev-parse", "HEAD:product")
        # The R4 scene: stale checkout, stray staged change inside it, the
        # stale gitlink staged in the bus index, another file modified.
        git("-C", f"{self.bus}/product", "checkout", "-q", self.old)
        git("-C", f"{self.bus}/product", "rm", "-q", "--cached", "a")
        git("-C", self.bus, "update-index", "--cacheinfo",
            f"160000,{self.old},product")
        with open(f"{self.bus}/README.md", "a", encoding="utf-8") as fh:
            fh.write("operator edit\n")
        self.em = load_monitor()

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.env)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def changed(self, rev: str) -> list[str]:
        out = git("-C", self.bus, "diff-tree", "-r", "--root", "--no-commit-id",
                  "--name-only", "--ignore-submodules=none", rev)
        return sorted(out.splitlines())

    def write(self, rel: str, text: str) -> None:
        full = os.path.join(self.bus, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)

    def test_git_sync_commits_only_named_paths(self) -> None:
        sub = "tasks/roles/librarian/20261029T1500-0001-x.md"
        idx = "outbox/em1/.ingested-emails"
        self.write(sub, "---\ntype: library.submit\n---\nbody\n")
        self.write(idx, "<id@example>\n")
        self.em.git_sync(self.bus, "post library.submit from email x",
                         [sub, idx])
        self.assertEqual(self.changed("HEAD"), sorted([sub, idx]))
        self.assertEqual(git("-C", self.bus, "rev-parse", "HEAD:product"),
                         self.pin)
        staged = git("-C", self.bus, "ls-files", "-s", "product").split()[1]
        self.assertEqual(staged, self.old, "the stale gitlink stays staged")
        self.assertEqual(git("-C", self.bus, "diff", "--name-only", "--",
                             "README.md"), "README.md")
        self.assertEqual(git("-C", f"{self.tmp}/bus.git", "rev-parse", "main"),
                         git("-C", self.bus, "rev-parse", "HEAD"))

    def test_loading_writes_nothing_into_the_source_tree(self) -> None:
        self.assertEqual(cache_listing(), CACHE_BEFORE,
                         "loading the monitor changed __pycache__ beside it")

    def test_run_once_names_exactly_the_files_it_wrote(self) -> None:
        em = self.em
        calls: list[tuple[str, list[str]]] = []
        em.git_sync = lambda repo, msg, paths: calls.append((msg, list(paths)))
        em.labels_map = lambda token: {"mesh-ingress": "L1"}
        em._mark = lambda *a, **k: None
        msgs = [{"id": "m1"}, {"id": "m2"}]
        em.api = lambda token, path, *a, **k: (
            {"messages": msgs} if path.startswith("messages?") else {})
        parsed = {
            "m1": types.SimpleNamespace(
                title="A note", sender="alice@lab.org", dkim="pass",
                dmarc="pass", secret_line_ok=True, intent="submit",
                message_id="<m1@lab.org>", category="lore", contexts=[],
                tags=[], body="text", auth_header_present=True),
            "m2": types.SimpleNamespace(
                title="Bad", sender="eve@evil.org", dkim="fail", dmarc="fail",
                secret_line_ok=False, intent="submit",
                message_id="<m2@evil.org>", category="lore", contexts=[],
                tags=[], body="x", auth_header_present=True),
        }
        order = iter(["m1", "m2"])
        em.parse_message = lambda cfg, msg: parsed[next(order)]
        em.decide = lambda cfg, p: ((True, "accepted") if p.sender.startswith(
            "alice") else (False, "dkim-fail"))
        cfg = types.SimpleNamespace(repo=self.bus, agent_id="em1",
                                    agent_context="", label="mesh-ingress")
        em.run_once(cfg, "token", dry=False)
        self.assertEqual(len(calls), 2)
        accept_paths, reject_paths = calls[0][1], calls[1][1]
        self.assertEqual(len(accept_paths), 2)
        self.assertTrue(accept_paths[0].startswith("tasks/roles/librarian/"))
        self.assertEqual(accept_paths[1], "outbox/em1/.ingested-emails")
        self.assertEqual(len(reject_paths), 1)
        self.assertTrue(reject_paths[0].startswith("outbox/em1/"))
        self.assertTrue(reject_paths[0].endswith("-m2-reject.json"))
        for rel in accept_paths + reject_paths:
            self.assertFalse(os.path.isabs(rel))
            self.assertTrue(os.path.isfile(os.path.join(self.bus, rel)), rel)


if __name__ == "__main__":
    unittest.main()
