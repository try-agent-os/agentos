#!/usr/bin/env python3
"""Negative and positive runs for .github/check-english.py.

A gate is only worth its job if every way of smuggling Russian in actually
fails it, so each surface it claims to guard gets a run that MUST exit 1:
Russian commit subject, Russian commit body on a commit that is not the head
one, Russian PR title, Russian PR body, Russian branch name, Russian comment in
an added line, Russian file name. Plus the runs that must stay green: a clean
English pull request, a diff that only REMOVES Cyrillic, and each bypass used
as designed.

Every Cyrillic fixture below is written with \\u escapes so this file is 7-bit
ASCII and passes the very check it is testing. That is not a trick to dodge the
gate -- it is the same discipline the gate asks of everybody else, and it keeps
the one file allowed to talk about Cyrillic from being the one file that has to
be excluded from the scan.

Run from the repository root:  python3 .github/test-check-english.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parent / "check-english.py"

# "russian", "Russian comment", "a Russian reason"
RU_WORD = "\u0440\u0443\u0441\u0441\u043a\u0438\u0439"
RU_SENTENCE = "\u041f\u043e\u0447\u0435\u043c\u0443 \u0441\u0435\u0439\u0447\u0430\u0441"
RU_SUPPLEMENT = "\u0500\u0511"  # Cyrillic Supplement, also out of bounds


def clean_env(**overrides: str) -> dict[str, str]:
    """The ambient environment minus everything GitHub Actions injects.

    Without this the self-test would inherit the real GITHUB_EVENT_PATH of the
    job running it and every sandbox would be scoped to this repository's own
    pull request instead of the fixture.
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
    env.update(
        GIT_AUTHOR_NAME="Gate Test",
        GIT_AUTHOR_EMAIL="gate@example.com",
        GIT_COMMITTER_NAME="Gate Test",
        GIT_COMMITTER_EMAIL="gate@example.com",
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_SYSTEM=os.devnull,
    )
    env.update(overrides)
    return env


class Sandbox:
    """A throwaway git repository carrying a copy of the gate."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        (root / ".github").mkdir(parents=True, exist_ok=True)
        shutil.copy2(GATE, root / ".github" / "check-english.py")
        self.write("README.md", "# sandbox\n")
        self.commit("chore: seed the sandbox")

    # -- git plumbing ----------------------------------------------------
    def git(self, *args: str) -> str:
        proc = subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=clean_env(),
        )
        if proc.returncode != 0:
            raise AssertionError(f"git {' '.join(args)}: {proc.stderr}")
        return proc.stdout.strip()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def commit(self, subject: str, body: str = "") -> str:
        self.git("add", "-A")
        message = f"{subject}\n\n{body}" if body else subject
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def branch(self, name: str) -> None:
        self.git("checkout", "-q", "-b", name)

    def sha(self, rev: str = "HEAD") -> str:
        return self.git("rev-parse", rev)

    # -- running the gate -------------------------------------------------
    def run(self, event_name: str = "", event: dict | None = None, **env: str):
        overrides = dict(env)
        if event_name:
            overrides["GITHUB_EVENT_NAME"] = event_name
        if event is not None:
            path = self.root / "event.json"
            path.write_text(json.dumps(event), encoding="utf-8")
            overrides["GITHUB_EVENT_PATH"] = str(path)
        return subprocess.run(
            [sys.executable, ".github/check-english.py"],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=clean_env(**overrides),
        )

    def pr(self, *, title="feat: a clean english change", body="Nothing to see here.",
           branch="feat/clean", base="main"):
        return self.run(
            "pull_request",
            {
                "number": 7,
                "pull_request": {
                    "number": 7,
                    "title": title,
                    "body": body,
                    "head": {"sha": self.sha(), "ref": branch},
                    "base": {"sha": self.sha(base)},
                },
            },
        )


class GateTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.box = Sandbox(Path(self._tmp.name))

    def assertFails(self, result, *expected: str):
        self.assertEqual(
            result.returncode, 1, f"expected a failure, got 0:\n{result.stdout}{result.stderr}"
        )
        for fragment in expected:
            self.assertIn(fragment, result.stdout, result.stdout + result.stderr)

    def assertPasses(self, result):
        self.assertEqual(
            result.returncode, 0, f"expected a pass, got 1:\n{result.stdout}{result.stderr}"
        )

    # -- the positive run --------------------------------------------------
    def test_clean_english_pull_request_passes(self):
        self.box.branch("feat/clean")
        self.box.write("install.sh", "#!/bin/sh\n# install the thing\necho hi\n")
        self.box.commit("feat: install the thing", "A body, in English, over\ntwo lines.")
        result = self.box.pr()
        self.assertPasses(result)
        self.assertIn("english ok", result.stdout)

    # -- the four mandatory negative runs ----------------------------------
    def test_russian_commit_subject_fails(self):
        self.box.branch("feat/clean")
        self.box.commit(f"feat: {RU_WORD}")
        self.assertFails(self.box.pr(), "commit subject", "U+0440")

    def test_russian_pr_body_fails(self):
        self.box.branch("feat/clean")
        self.box.commit("feat: english subject")
        self.assertFails(self.box.pr(body=f"## {RU_SENTENCE}\n\nmore text"), "PR body")

    def test_russian_branch_name_fails(self):
        self.box.branch("feat/clean")
        self.box.commit("feat: english subject")
        self.assertFails(self.box.pr(branch=f"feat/{RU_WORD}"), "branch name")

    def test_russian_comment_in_added_code_fails(self):
        self.box.branch("feat/clean")
        self.box.write("install.sh", f"#!/bin/sh\n# {RU_SENTENCE}\necho hi\n")
        self.box.commit("feat: english subject")
        self.assertFails(self.box.pr(), "added line", "install.sh:2")

    # -- the surfaces the four do not cover --------------------------------
    def test_russian_body_of_a_commit_that_is_not_the_head_fails(self):
        """The squash body is assembled from every commit, not just the last."""
        self.box.branch("feat/clean")
        self.box.commit("feat: first", f"{RU_SENTENCE}")
        self.box.commit("feat: second and clean")
        self.assertFails(self.box.pr(), "commit body")

    def test_russian_pr_title_fails(self):
        self.box.branch("feat/clean")
        self.box.commit("feat: english subject")
        self.assertFails(self.box.pr(title=f"feat: {RU_WORD}"), "PR title")

    def test_cyrillic_supplement_range_fails(self):
        self.box.branch("feat/clean")
        self.box.commit(f"feat: {RU_SUPPLEMENT}")
        self.assertFails(self.box.pr(), "U+0500")

    def test_russian_file_name_fails(self):
        self.box.branch("feat/clean")
        self.box.write(f"docs/{RU_WORD}.md", "# all english inside\n")
        self.box.commit("docs: english subject")
        self.assertFails(self.box.pr(), "added path")

    def test_removing_cyrillic_passes(self):
        """Only ADDED lines are scanned: a cleanup must not be punished."""
        self.box.write("legacy.md", f"# {RU_SENTENCE}\n")
        self.box.commit("docs: legacy file with cyrillic")
        self.box.branch("feat/clean")
        self.box.write("legacy.md", "# all english now\n")
        self.box.commit("docs: translate the legacy file")
        self.assertPasses(self.box.pr())

    def test_untouched_cyrillic_in_history_passes(self):
        """A file already in the tree is not rescanned on every PR."""
        self.box.write("legacy.md", f"# {RU_SENTENCE}\n")
        self.box.commit("docs: legacy file with cyrillic")
        self.box.branch("feat/clean")
        self.box.write("other.md", "# english\n")
        self.box.commit("docs: an unrelated english file")
        self.assertPasses(self.box.pr())

    # -- the bypasses ------------------------------------------------------
    def test_allow_cyrillic_marker_waives_added_lines(self):
        self.box.branch("feat/clean")
        self.box.write("docs/l10n.md", f"Quoted verbatim: {RU_SENTENCE}\n")
        self.box.commit("docs: quote a localization bug report")
        result = self.box.pr(body="Body.\n\nallow-cyrillic: quotes a localization bug report\n")
        self.assertPasses(result)
        self.assertIn("waived", result.stdout)

    def test_allow_cyrillic_marker_does_not_waive_a_commit_subject(self):
        self.box.branch("feat/clean")
        self.box.commit(f"feat: {RU_WORD}")
        self.assertFails(
            self.box.pr(body="allow-cyrillic: a reason that does not buy metadata\n"),
            "commit subject",
        )

    def test_allow_cyrillic_marker_does_not_waive_a_branch_name(self):
        self.box.branch("feat/clean")
        self.box.commit("feat: english subject")
        self.assertFails(
            self.box.pr(branch=f"feat/{RU_WORD}", body="allow-cyrillic: still no\n"),
            "branch name",
        )

    def test_allow_cyrillic_marker_without_a_reason_does_not_count(self):
        self.box.branch("feat/clean")
        self.box.write("docs/l10n.md", f"{RU_SENTENCE}\n")
        self.box.commit("docs: english subject")
        self.assertFails(self.box.pr(body="allow-cyrillic:   \n"), "added line")

    def test_allowlist_file_waives_the_listed_path_only(self):
        self.box.branch("feat/clean")
        self.box.write(".github/cyrillic-allowlist.txt", "# why:\ndocs/l10n.md\n")
        self.box.write("docs/l10n.md", f"{RU_SENTENCE}\n")
        self.box.commit("docs: english subject")
        self.assertPasses(self.box.pr())

        self.box.write("docs/other.md", f"{RU_SENTENCE}\n")
        self.box.commit("docs: another english subject")
        self.assertFails(self.box.pr(), "docs/other.md")

    def test_allowlist_entry_covering_the_repository_is_rejected(self):
        self.box.branch("feat/clean")
        self.box.write(".github/cyrillic-allowlist.txt", "*\n")
        self.box.write("docs/l10n.md", f"{RU_SENTENCE}\n")
        self.box.commit("docs: english subject")
        self.assertFails(self.box.pr(), "covers the whole repository")

    # -- push to main ------------------------------------------------------
    def test_push_to_main_with_a_russian_subject_fails(self):
        before = self.box.sha()
        self.box.write("install.sh", "echo hi\n")
        after = self.box.commit(f"release: {RU_WORD}")
        result = self.box.run(
            "push", {"before": before, "after": after}, GITHUB_REF_NAME="main"
        )
        self.assertFails(result, "commit subject")

    def test_push_to_main_with_a_russian_added_line_fails(self):
        before = self.box.sha()
        self.box.write("install.sh", f"# {RU_SENTENCE}\n")
        after = self.box.commit("release: sync the installer")
        result = self.box.run(
            "push", {"before": before, "after": after}, GITHUB_REF_NAME="main"
        )
        self.assertFails(result, "added line")

    def test_clean_push_to_main_passes(self):
        before = self.box.sha()
        self.box.write("install.sh", "echo hi\n")
        after = self.box.commit("release: sync the installer for v1.2.3")
        self.assertPasses(
            self.box.run("push", {"before": before, "after": after}, GITHUB_REF_NAME="main")
        )

    def test_push_of_a_new_branch_checks_the_head_commit(self):
        """No usable `before`: fall back to the head commit, do not pass blindly."""
        self.box.write("install.sh", "echo hi\n")
        after = self.box.commit(f"release: {RU_WORD}")
        result = self.box.run(
            "push", {"before": "0" * 40, "after": after}, GITHUB_REF_NAME="main"
        )
        self.assertFails(result, "commit subject")

    # -- local scope -------------------------------------------------------
    def test_local_run_checks_the_branch_and_the_commits(self):
        self.box.branch(f"feat/{RU_WORD}")
        self.box.commit("feat: english subject")
        self.assertFails(self.box.run(), "branch name")

    def test_local_run_on_a_clean_branch_passes(self):
        self.box.branch("feat/clean")
        self.box.write("install.sh", "echo hi\n")
        self.box.commit("feat: english subject")
        result = self.box.run()
        self.assertPasses(result)
        self.assertIn("no pull request locally", result.stdout)

    def test_local_run_finds_a_russian_added_line(self):
        self.box.branch("feat/clean")
        self.box.write("install.sh", f"# {RU_WORD}\n")
        self.box.commit("feat: english subject")
        self.assertFails(self.box.run(), "added line")

    # -- the gate must fail loudly, never quietly pass ---------------------
    def test_unreachable_base_sha_fails_instead_of_passing(self):
        self.box.branch("feat/clean")
        self.box.commit("feat: english subject")
        result = self.box.run(
            "pull_request",
            {
                "number": 7,
                "pull_request": {
                    "number": 7,
                    "title": "feat: english",
                    "body": "english",
                    "head": {"sha": self.box.sha(), "ref": "feat/clean"},
                    "base": {"sha": "0" * 39 + "1"},
                },
            },
        )
        self.assertFails(result, "fetch-depth: 0")

    def test_event_without_shas_fails(self):
        result = self.box.run("pull_request", {"number": 7, "pull_request": {"number": 7}})
        self.assertFails(result, "no base/head sha")

    def test_broken_event_file_fails(self):
        (self.box.root / "broken.json").write_text("{not json", encoding="utf-8")
        result = self.box.run(
            "pull_request", GITHUB_EVENT_PATH=str(self.box.root / "broken.json")
        )
        self.assertFails(result, "not valid JSON")

    # -- this repository itself -------------------------------------------
    def test_the_gate_source_files_are_seven_bit_ascii(self):
        """Otherwise the gate is the one thing in the repo that cannot pass it."""
        for name in ("check-english.py", "test-check-english.py"):
            data = (GATE.parent / name).read_bytes()
            offenders = [i for i, byte in enumerate(data) if byte > 127]
            self.assertEqual(offenders, [], f"{name}: non-ASCII byte at {offenders[:1]}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
