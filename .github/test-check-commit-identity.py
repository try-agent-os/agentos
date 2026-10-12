#!/usr/bin/env python3
"""Negative and positive runs for .github/check-commit-identity.py.

Every identity surface the gate claims to guard gets a run that MUST exit 1:
a foreign author, a foreign committer, a foreign `Co-authored-by:` trailer
(in any letter case, and on a commit that is not the head one), a trailer
without an address, a merge commit made by a foreign committer, and a pull
request that adds its own address to the allowlist. Plus the runs that must
stay green: a clean pull request, an allowlisted address in another letter
case, an allowed identity adding a NEW address to the allowlist, the bootstrap
pull request, and a push that created a branch.

Run from the repository root:  python3 .github/test-check-commit-identity.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parent / "check-commit-identity.py"
ALLOWLIST = ".github/commit-identities.txt"

OWNER = ("Owner", "owner@example.com")
BOT = ("Release Bot", "release@example.com")
STRANGER = ("Axion", "agent@stranger.example")


def env_for(author: tuple[str, str], committer: tuple[str, str] | None = None) -> dict[str, str]:
    committer = committer or author
    env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
    env.update(
        GIT_AUTHOR_NAME=author[0],
        GIT_AUTHOR_EMAIL=author[1],
        GIT_COMMITTER_NAME=committer[0],
        GIT_COMMITTER_EMAIL=committer[1],
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_SYSTEM=os.devnull,
    )
    return env


class Sandbox:
    def __init__(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="identity-gate-"))
        self.git("init", "-q", "-b", "main")

    def cleanup(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)

    def git(self, *args: str, who: tuple[str, str] = OWNER,
            committer: tuple[str, str] | None = None) -> str:
        proc = subprocess.run(
            ["git", *args], cwd=self.dir, env=env_for(who, committer),
            capture_output=True, text=True, check=True,
        )
        return proc.stdout.strip()

    def write(self, path: str, text: str) -> None:
        target = self.dir / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def commit(self, path: str, text: str, message: str = "Change a file",
               who: tuple[str, str] = OWNER, committer: tuple[str, str] | None = None) -> str:
        self.write(path, text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message, who=who, committer=committer)
        return self.git("rev-parse", "HEAD")

    def allowlist(self, *addresses: str) -> str:
        return "# test allowlist\n" + "".join(f"{a}\n" for a in addresses)

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(GATE), *args], cwd=self.dir,
            env=env_for(OWNER), capture_output=True, text=True,
        )


class IdentityGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.box = Sandbox()
        self.base = self.box.commit(ALLOWLIST, self.box.allowlist(OWNER[1], BOT[1]), "Add allowlist")
        self.box.git("checkout", "-q", "-b", "feature")

    def tearDown(self) -> None:
        self.box.cleanup()

    def gate(self, *extra: str) -> subprocess.CompletedProcess[str]:
        head = self.box.git("rev-parse", "HEAD")
        return self.box.run("--base", self.base, "--head", head, *extra)

    def assert_fails(self, *needles: str) -> str:
        proc = self.gate()
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        for needle in needles:
            self.assertIn(needle, proc.stdout)
        return proc.stdout

    def assert_passes(self) -> str:
        proc = self.gate()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("commit identities ok", proc.stdout)
        return proc.stdout

    # --- must stay green -------------------------------------------------

    def test_clean_pull_request_passes(self) -> None:
        self.box.commit("a.txt", "a\n")
        self.box.commit("b.txt", "b\n", who=BOT)
        self.assertIn("2 commit(s) checked", self.assert_passes())

    def test_address_case_does_not_matter(self) -> None:
        self.box.commit("a.txt", "a\n", who=("Owner", "Owner@EXAMPLE.com"))
        self.assert_passes()

    def test_allowlisted_coauthor_passes(self) -> None:
        self.box.commit("a.txt", "a\n", f"Change\n\nCo-authored-by: Bot <{BOT[1]}>\n")
        self.assert_passes()

    def test_allowed_identity_may_add_a_new_address(self) -> None:
        # Adding an address is fine; using it in the same pull request is not.
        self.box.commit(ALLOWLIST, self.box.allowlist(OWNER[1], BOT[1], STRANGER[1]))
        self.assert_passes()

    def test_bootstrap_uses_head_copy_when_base_has_none(self) -> None:
        box = Sandbox()
        try:
            base = box.commit("README", "x\n")
            box.commit(ALLOWLIST, box.allowlist(OWNER[1]))
            head = box.git("rev-parse", "HEAD")
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 0, proc.stdout)
            self.assertIn("BOOTSTRAP", proc.stdout)
        finally:
            box.cleanup()

    def test_push_that_created_a_branch_checks_the_head(self) -> None:
        head = self.box.commit("a.txt", "a\n", who=STRANGER)
        proc = self.box.run("--base", "0" * 40, "--head", head)
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("first parent", proc.stdout)
        self.assertIn(STRANGER[1], proc.stdout)

    # --- must fail -------------------------------------------------------

    def test_foreign_author_fails(self) -> None:
        sha = self.box.commit("a.txt", "a\n", who=STRANGER, committer=OWNER)
        self.assert_fails(f"{sha[:12]} author: {STRANGER[1]}")

    def test_foreign_committer_fails(self) -> None:
        sha = self.box.commit("a.txt", "a\n", who=OWNER, committer=STRANGER)
        self.assert_fails(f"{sha[:12]} committer: {STRANGER[1]}")

    def test_foreign_coauthor_fails_on_a_non_head_commit(self) -> None:
        sha = self.box.commit("a.txt", "a\n", f"Change\n\nCo-authored-by: Axion <{STRANGER[1]}>\n")
        self.box.commit("b.txt", "b\n")
        self.assert_fails(f"{sha[:12]} Co-authored-by: {STRANGER[1]}")

    def test_coauthor_key_is_case_insensitive(self) -> None:
        self.box.commit("a.txt", "a\n", f"Change\n\nco-AUTHORED-by:Axion <{STRANGER[1]}>\n")
        self.assert_fails(f"Co-authored-by: {STRANGER[1]}")

    def test_coauthor_without_address_fails(self) -> None:
        self.box.commit("a.txt", "a\n", "Change\n\nCo-authored-by: Axion\n")
        self.assert_fails("without an <address>")

    def test_self_add_to_allowlist_fails(self) -> None:
        # The pull request lists the stranger AND commits as the stranger: it
        # is judged by the allowlist of its base, which does not list it.
        self.box.commit(
            ALLOWLIST, self.box.allowlist(OWNER[1], BOT[1], STRANGER[1]), who=STRANGER,
        )
        self.assert_fails(f"author: {STRANGER[1]}", f"committer: {STRANGER[1]}")

    def test_self_add_is_judged_by_the_base_copy(self) -> None:
        # Sanity of the default: without --allowlist-rev the base copy rules.
        self.box.commit(ALLOWLIST, self.box.allowlist(STRANGER[1]), who=STRANGER)
        out = self.assert_fails(STRANGER[1])
        self.assertIn(f"as of {self.base[:12]}", out)

    def test_foreign_merge_commit_fails(self) -> None:
        self.box.commit("a.txt", "a\n")
        self.box.git("checkout", "-q", "-b", "side", self.base)
        self.box.commit("b.txt", "b\n")
        self.box.git("checkout", "-q", "feature")
        self.box.git("merge", "-q", "--no-ff", "-m", "Merge side", "side", who=STRANGER)
        merge = self.box.git("rev-parse", "HEAD")
        self.assert_fails(f"{merge[:12]} author: {STRANGER[1]}")

    def test_wildcard_allowlist_entry_fails(self) -> None:
        box = Sandbox()
        try:
            base = box.commit(ALLOWLIST, box.allowlist("*@example.com"))
            head = box.commit("a.txt", "a\n")
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 1, proc.stdout)
            self.assertIn("no wildcards", proc.stdout)
        finally:
            box.cleanup()

    def test_missing_allowlist_everywhere_fails(self) -> None:
        box = Sandbox()
        try:
            base = box.commit("README", "x\n")
            head = box.commit("a.txt", "a\n")
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 1, proc.stdout)
            self.assertIn("exists neither", proc.stdout)
        finally:
            box.cleanup()

    def test_unknown_base_fails(self) -> None:
        proc = self.box.run("--base", "f" * 40, "--head", "HEAD")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("is not a commit", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
