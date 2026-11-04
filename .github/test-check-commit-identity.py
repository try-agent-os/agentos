#!/usr/bin/env python3
"""Negative and positive runs for .github/check-commit-identity.py.

Every identity surface the gate claims to guard gets a run that MUST exit 1: a
foreign agent as author, as committer, as a `Co-authored-by:` trailer (in any
letter case, and on a commit that is not the head one), in another spelling of
the same account, inside a listed domain, as the committer of a merge commit,
plus a trailer without an address and a pull request that drops the entry judging
it. An unreadable or empty registry fails as well, and so does a plain address in
it. Plus the runs that must stay green: a clean pull request, a human nobody has
listed on each of those surfaces, a pull request adding a new entry, the bootstrap
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
REGISTRY = ".github/foreign-agent-identities.txt"

OWNER = ("Owner", "owner@example.com")
HUMAN = ("Passer-by", "someone@people.example")
HUMAN_NOREPLY = ("Passer-by", "1234+someone@users.noreply.github.com")
FOREIGN = ("Axion", "agent@stranger.example")
FOREIGN_LOGIN = "stranger-agent@users.noreply.github.com"
FOREIGN_DOMAIN = "@bots.stranger.example"
OTHER_FOREIGN = ("Other", "agent@other.example")


def hashes(*entries: str) -> list[str]:
    proc = subprocess.run(
        [sys.executable, "-I", str(GATE), "--hash"], input="".join(f"{e}\n" for e in entries),
        capture_output=True, text=True, check=True,
    )
    return proc.stdout.split()


# Hashing is deliberately slow: once per test run, not per test.
ENTRY = dict(zip(
    (FOREIGN[1], FOREIGN_LOGIN, FOREIGN_DOMAIN, OTHER_FOREIGN[1]),
    hashes(FOREIGN[1], FOREIGN_LOGIN, FOREIGN_DOMAIN, OTHER_FOREIGN[1]),
))


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

    def registry(self, *entries: str) -> str:
        return "# test registry\n" + "".join(f"{ENTRY.get(e, e)}\n" for e in entries)

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(GATE), *args], cwd=self.dir,
            env=env_for(OWNER), capture_output=True, text=True,
        )


class IdentityGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.box = Sandbox()
        self.base = self.box.commit(
            REGISTRY, self.box.registry(FOREIGN[1], FOREIGN_LOGIN, FOREIGN_DOMAIN), "Add registry",
        )
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
        self.assertIn("1 commit(s) checked", self.assert_passes())

    def test_unlisted_human_passes_as_author_and_committer(self) -> None:
        self.box.commit("a.txt", "a\n", who=HUMAN, committer=HUMAN_NOREPLY)
        self.assert_passes()

    def test_unlisted_human_passes_as_coauthor(self) -> None:
        self.box.commit("a.txt", "a\n", f"Change\n\nCo-authored-by: P <{HUMAN[1]}>\n")
        self.assert_passes()

    def test_unlisted_human_may_make_a_merge_commit(self) -> None:
        self.box.commit("a.txt", "a\n")
        self.box.git("checkout", "-q", "-b", "side", self.base)
        self.box.commit("b.txt", "b\n")
        self.box.git("checkout", "-q", "feature")
        self.box.git("merge", "-q", "--no-ff", "-m", "Merge side", "side", who=HUMAN)
        self.assert_passes()

    def test_same_login_on_another_domain_passes(self) -> None:
        # The noreply reduction applies to GitHub's domain only.
        self.box.commit("a.txt", "a\n", who=("X", "stranger-agent@people.example"))
        self.assert_passes()

    def test_subdomain_of_a_listed_domain_passes(self) -> None:
        self.box.commit("a.txt", "a\n", who=("X", "someone@sub.bots.stranger.example"))
        self.assert_passes()

    def test_pull_request_may_add_a_new_entry(self) -> None:
        self.box.commit(REGISTRY, self.box.registry(FOREIGN[1], OTHER_FOREIGN[1]))
        self.assert_passes()

    def test_new_entry_binds_only_once_it_is_in_the_base(self) -> None:
        # Listed by the head, not by the base: the base copy rules, in both directions.
        self.box.commit(REGISTRY, self.box.registry(FOREIGN[1], OTHER_FOREIGN[1]), who=OTHER_FOREIGN)
        self.assert_passes()

    def test_bootstrap_uses_head_copy_when_base_has_none(self) -> None:
        box = Sandbox()
        try:
            base = box.commit("README", "x\n")
            box.commit(REGISTRY, box.registry(FOREIGN[1]))
            head = box.git("rev-parse", "HEAD")
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 0, proc.stdout)
            self.assertIn("BOOTSTRAP", proc.stdout)
        finally:
            box.cleanup()

    def test_bootstrap_still_judges_by_the_head_copy(self) -> None:
        box = Sandbox()
        try:
            base = box.commit("README", "x\n")
            head = box.commit(REGISTRY, box.registry(FOREIGN[1]), who=FOREIGN)
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 1, proc.stdout)
            self.assertIn(f"author: {FOREIGN[1]}", proc.stdout)
        finally:
            box.cleanup()

    def test_shipped_registry_is_readable_and_has_entries(self) -> None:
        text = (GATE.parent / "foreign-agent-identities.txt").read_text(encoding="utf-8")
        box = Sandbox()
        try:
            base = box.commit(REGISTRY, text)
            head = box.commit("a.txt", "a\n")
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 0, proc.stdout)
        finally:
            box.cleanup()

    def test_push_that_created_a_branch_checks_the_head(self) -> None:
        head = self.box.commit("a.txt", "a\n", who=FOREIGN)
        proc = self.box.run("--base", "0" * 40, "--head", head)
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("first parent", proc.stdout)
        self.assertIn(FOREIGN[1], proc.stdout)

    # --- must fail -------------------------------------------------------

    def test_foreign_author_fails(self) -> None:
        sha = self.box.commit("a.txt", "a\n", who=FOREIGN, committer=OWNER)
        self.assert_fails(f"{sha[:12]} author: {FOREIGN[1]}")

    def test_foreign_committer_fails(self) -> None:
        sha = self.box.commit("a.txt", "a\n", who=OWNER, committer=FOREIGN)
        self.assert_fails(f"{sha[:12]} committer: {FOREIGN[1]}")

    def test_foreign_coauthor_fails_on_a_non_head_commit(self) -> None:
        sha = self.box.commit("a.txt", "a\n", f"Change\n\nCo-authored-by: Axion <{FOREIGN[1]}>\n")
        self.box.commit("b.txt", "b\n")
        self.assert_fails(f"{sha[:12]} Co-authored-by: {FOREIGN[1]}")

    def test_coauthor_key_is_case_insensitive(self) -> None:
        self.box.commit("a.txt", "a\n", f"Change\n\nco-AUTHORED-by:Axion <{FOREIGN[1]}>\n")
        self.assert_fails(f"Co-authored-by: {FOREIGN[1]}")

    def test_coauthor_without_address_fails(self) -> None:
        self.box.commit("a.txt", "a\n", "Change\n\nCo-authored-by: Axion\n")
        self.assert_fails("no address")

    def test_foreign_address_in_another_case_fails(self) -> None:
        self.box.commit("a.txt", "a\n", who=("X", FOREIGN[1].upper()))
        self.assert_fails(FOREIGN[1].upper())

    def test_foreign_address_with_a_tag_fails(self) -> None:
        self.box.commit("a.txt", "a\n", who=("X", "agent+ci@stranger.example"))
        self.assert_fails("agent+ci@stranger.example")

    def test_foreign_noreply_with_an_id_fails(self) -> None:
        self.box.commit("a.txt", "a\n", who=("X", f"306+{FOREIGN_LOGIN}"))
        self.assert_fails(f"306+{FOREIGN_LOGIN}")

    def test_listed_domain_fails(self) -> None:
        self.box.commit("a.txt", "a\n", who=("X", "anyone@bots.stranger.example"))
        self.assert_fails("anyone@bots.stranger.example")

    def test_foreign_merge_commit_fails(self) -> None:
        self.box.commit("a.txt", "a\n")
        self.box.git("checkout", "-q", "-b", "side", self.base)
        self.box.commit("b.txt", "b\n")
        self.box.git("checkout", "-q", "feature")
        self.box.git("merge", "-q", "--no-ff", "-m", "Merge side", "side", who=FOREIGN)
        merge = self.box.git("rev-parse", "HEAD")
        self.assert_fails(f"{merge[:12]} author: {FOREIGN[1]}")

    def test_pull_request_cannot_drop_the_entry_judging_it(self) -> None:
        self.box.commit(REGISTRY, self.box.registry(OTHER_FOREIGN[1]), who=FOREIGN)
        out = self.assert_fails(f"author: {FOREIGN[1]}", f"committer: {FOREIGN[1]}")
        self.assertIn(f"as of {self.base[:12]}", out)

    def test_pull_request_cannot_empty_or_delete_the_registry(self) -> None:
        self.box.commit(REGISTRY, "# nothing here\n", who=FOREIGN)
        self.assert_fails(f"author: {FOREIGN[1]}")
        self.box.git("rm", "-q", REGISTRY)
        self.box.git("commit", "-q", "-m", "Delete the registry", who=FOREIGN)
        self.assert_fails(f"author: {FOREIGN[1]}")

    def assert_base_registry_refused(self, text: str, *needles: str) -> str:
        box = Sandbox()
        try:
            base = box.commit(REGISTRY, text)
            head = box.commit("a.txt", "a\n", who=HUMAN)
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 1, proc.stdout)
            for needle in needles:
                self.assertIn(needle, proc.stdout)
            return proc.stdout
        finally:
            box.cleanup()

    def test_plain_address_in_the_registry_fails_and_is_not_echoed(self) -> None:
        out = self.assert_base_registry_refused(f"{FOREIGN[1]}\n", "line 1", "not a hash")
        self.assertNotIn(FOREIGN[1], out)

    def test_empty_registry_fails(self) -> None:
        self.assert_base_registry_refused("# no entries\n\n", "lists no hash")

    def test_missing_registry_everywhere_fails(self) -> None:
        box = Sandbox()
        try:
            base = box.commit("README", "x\n")
            head = box.commit("a.txt", "a\n")
            proc = box.run("--base", base, "--head", head)
            self.assertEqual(proc.returncode, 1, proc.stdout)
            self.assertIn("exists neither", proc.stdout)
        finally:
            box.cleanup()

    def test_registry_rev_overrides_the_base(self) -> None:
        self.box.commit("a.txt", "a\n", who=OTHER_FOREIGN)
        head = self.box.commit(REGISTRY, self.box.registry(OTHER_FOREIGN[1]))
        proc = self.box.run("--base", self.base, "--head", head, "--registry-rev", head)
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn(f"author: {OTHER_FOREIGN[1]}", proc.stdout)

    def test_unknown_base_fails(self) -> None:
        proc = self.box.run("--base", "f" * 40, "--head", "HEAD")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("is not a commit", proc.stdout)

    def test_hash_refuses_a_line_that_is_no_address(self) -> None:
        proc = subprocess.run(
            [sys.executable, "-I", str(GATE), "--hash"], input="not-an-address\n",
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
