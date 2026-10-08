#!/usr/bin/env python3
"""Positive and negative runs for .github/node-notes.py.

Every rule the checker claims gets a fixture that MUST fail it: an oversized
note, a yaml block, a routine field key, a missing min_core, a min_core above
the latest release, a stale bundle, a missing routine-fields.json asset, a
Cyrillic line, a bundle over 64 KB, and an author outside the base AUTHORS --
including the author who adds themselves in the same pull request. Plus the
runs that must stay green: the empty catalog (offline, no asset), a valid
note, and the bootstrap pull request that introduces node-notes/.

Cyrillic fixtures are written with \\u escapes so this file stays 7-bit ASCII.

Run from the repository root:  python3 .github/test-node-notes.py
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "node-notes.py"
REPO = HERE.parent

FIELDS = ["name", "schedule", "steps", "steps.run", "timeout_s"]

GOOD_NOTE = """---
id: promise-after-turn
title: Do not promise to write later without a watcher
min_core: 4.49.0
requires_tools: [watch_start]
source: context#123
---
A turn that ends with "I will write when it is done" writes nothing: nothing
wakes the session up. Start a watcher first, then promise.
"""


def run(*args: str, cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-I", str(TOOL), *args], cwd=cwd, capture_output=True, text=True
    )


class Tree:
    """A scratch copy of node-notes/ with the real README and AUTHORS."""

    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="node-notes-test-"))
        (self.root / "node-notes").mkdir()
        for name in ("README.md", "AUTHORS"):
            shutil.copy(REPO / "node-notes" / name, self.root / "node-notes" / name)
        self.fields = self.root / "routine-fields.json"
        self.fields.write_text(json.dumps({"fields": FIELDS}))

    def note(self, name: str, text: str) -> None:
        (self.root / "node-notes" / name).write_text(text, encoding="utf-8")

    def build(self) -> subprocess.CompletedProcess:
        return run("build", cwd=self.root)

    def check(self, fields: Path | None = None, latest: str = "4.72.0") -> subprocess.CompletedProcess:
        return run(
            "check", "--latest-core", latest, "--routine-fields", str(fields or self.fields),
            cwd=self.root,
        )

    def close(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.t = Tree()

    def tearDown(self) -> None:
        self.t.close()

    def assertGreen(self, r: subprocess.CompletedProcess) -> None:
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def assertRed(self, r: subprocess.CompletedProcess, needle: str) -> None:
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(needle, r.stderr)

    def build_ok(self) -> None:
        self.assertGreen(self.t.build())

    # green

    def test_repository_tree_is_green(self) -> None:
        r = subprocess.run(
            [sys.executable, "-I", str(TOOL), "check"], cwd=REPO, capture_output=True, text=True
        )
        self.assertGreen(r)

    def test_empty_catalog_is_green_without_the_asset(self) -> None:
        self.build_ok()
        self.assertGreen(self.t.check(fields=self.t.root / "absent.json"))
        bundle = json.loads((self.t.root / "node-notes" / "node-notes.json").read_text())
        self.assertEqual(bundle, {"format": 1, "notes": []})

    def test_valid_note_is_green_and_bundled(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE)
        self.build_ok()
        self.assertGreen(self.t.check())
        bundle = json.loads((self.t.root / "node-notes" / "node-notes.json").read_text())
        self.assertEqual(
            list(bundle["notes"][0]),
            ["id", "title", "min_core", "requires_tools", "source", "body"],
        )
        self.assertNotIn("source_commit", bundle)
        self.assertNotIn("built_at", bundle)

    def test_build_is_deterministic(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE)
        self.build_ok()
        first = (self.t.root / "node-notes" / "node-notes.json").read_bytes()
        self.build_ok()
        self.assertEqual(first, (self.t.root / "node-notes" / "node-notes.json").read_bytes())

    # red

    def test_oversized_note(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE + "x" * 4096 + "\n")
        self.assertRed(self.t.check(), "the limit is 4096 per note")

    def test_yaml_block(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE + "```yaml\nfoo: 1\n```\n")
        self.assertRed(self.t.check(), "yaml code blocks are not allowed")

    def test_yml_tilde_block(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE + "~~~ YML\nfoo: 1\n~~~\n")
        self.assertRed(self.t.check(), "yaml code blocks are not allowed")

    def test_routine_field_key_line(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE + "\n  schedule: '*/5 * * * *'\n")
        self.assertRed(self.t.check(), "routine schema field key 'schedule:'")

    def test_routine_field_key_inline(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE + "Set `timeout_s: 600` there.\n")
        self.assertRed(self.t.check(), "routine schema field key 'timeout_s:'")

    def test_missing_min_core(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE.replace("min_core: 4.49.0\n", ""))
        self.assertRed(self.t.check(), "'min_core' is missing")

    def test_min_core_above_latest_release(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE.replace("4.49.0", "9.0.0"))
        self.build_ok()
        self.assertRed(self.t.check(), "above the latest core release 4.72.0")

    def test_min_core_not_semver(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE.replace("4.49.0", "latest"))
        self.assertRed(self.t.check(), "is not a semver")

    def test_max_core_below_min_core(self) -> None:
        self.t.note(
            "promise-after-turn.md", GOOD_NOTE.replace("min_core: 4.49.0", "min_core: 4.49.0\nmax_core: 4.1.0")
        )
        self.assertRed(self.t.check(), "below min_core")

    def test_unknown_key(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE.replace("source:", "author: me\nsource:"))
        self.assertRed(self.t.check(), "unknown front matter key 'author'")

    def test_id_must_match_file_name(self) -> None:
        self.t.note("other-name.md", GOOD_NOTE)
        self.assertRed(self.t.check(), "file name must be 'promise-after-turn.md'")

    def test_stale_bundle(self) -> None:
        self.build_ok()
        self.t.note("promise-after-turn.md", GOOD_NOTE)
        self.assertRed(self.t.check(), "is stale")

    def test_missing_bundle(self) -> None:
        self.assertRed(self.t.check(), "node-notes.json is missing")

    def test_missing_routine_fields_asset_with_a_note(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE)
        self.build_ok()
        self.assertRed(self.t.check(fields=self.t.root / "absent.json"), "routine-fields.json is unavailable")

    def test_empty_routine_fields_asset(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE)
        self.build_ok()
        empty = self.t.root / "empty.json"
        empty.write_text("[]")
        self.assertRed(self.t.check(fields=empty), "not a non-empty list")

    def test_cyrillic_in_a_note(self) -> None:
        self.t.note("promise-after-turn.md", GOOD_NOTE + "\u043f\u0440\u0438\u0432\u0435\u0442\n")
        self.assertRed(self.t.check(), "notes are English only")

    def test_bundle_over_64_kb(self) -> None:
        filler = ("word " * 15 + "\n") * 48
        for i in range(20):
            nid = f"note-number-{i:02d}"
            text = GOOD_NOTE.replace("promise-after-turn", nid) + filler
            self.assertLessEqual(len(text.encode()), 4096)
            self.t.note(f"{nid}.md", text)
        self.build_ok()
        self.assertRed(self.t.check(), "the limit is 65536")

    def test_unexpected_file(self) -> None:
        self.build_ok()
        self.t.note("notes.txt", "x")
        self.assertRed(self.t.check(), "unexpected file")

    def test_bad_authors_line(self) -> None:
        self.build_ok()
        (self.t.root / "node-notes" / "AUTHORS").write_text("not a login!\n")
        self.assertRed(self.t.check(), "is not a GitHub login")


class AuthorsTest(unittest.TestCase):
    """The pull-request gate, against a real scratch git repository."""

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="node-notes-authors-"))
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "test")
        self.write("README.md", "repo\n")
        self.base0 = self.commit("empty repository")

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=self.root, check=True, capture_output=True, text=True
        ).stdout.strip()

    def write(self, path: str, text: str) -> None:
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def commit(self, msg: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def gate(self, base: str, head: str, author: str) -> subprocess.CompletedProcess:
        return run("authors", "--base", base, "--head", head, "--author", author, cwd=self.root)

    def with_authors(self) -> str:
        self.write("node-notes/AUTHORS", "# allowed\nalice\n")
        self.write("node-notes/README.md", "format\n")
        return self.commit("add node-notes")

    def test_listed_author_is_green(self) -> None:
        base = self.with_authors()
        self.write("node-notes/a-note.md", "x\n")
        head = self.commit("note")
        r = self.gate(base, head, "Alice")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_author_outside_authors_is_red(self) -> None:
        base = self.with_authors()
        self.write("node-notes/a-note.md", "x\n")
        head = self.commit("note")
        r = self.gate(base, head, "mallory")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("is not listed", r.stderr)

    def test_author_adding_themselves_is_red(self) -> None:
        base = self.with_authors()
        self.write("node-notes/AUTHORS", "alice\nmallory\n")
        self.write("node-notes/a-note.md", "x\n")
        head = self.commit("add myself")
        r = self.gate(base, head, "mallory")
        self.assertEqual(r.returncode, 1, r.stdout)

    def test_checker_change_is_gated(self) -> None:
        base = self.with_authors()
        self.write(".github/node-notes.py", "print('green')\n")
        head = self.commit("weaken the checker")
        self.assertEqual(self.gate(base, head, "mallory").returncode, 1)

    def test_deleting_a_note_is_gated(self) -> None:
        self.with_authors()
        self.write("node-notes/a-note.md", "x\n")
        base = self.commit("note")
        (self.root / "node-notes" / "a-note.md").unlink()
        head = self.commit("drop note")
        self.assertEqual(self.gate(base, head, "mallory").returncode, 1)

    def test_unrelated_change_is_green_for_anybody(self) -> None:
        base = self.with_authors()
        self.write("README.md", "changed\n")
        head = self.commit("docs")
        self.assertEqual(self.gate(base, head, "mallory").returncode, 0)

    def test_bootstrap_without_notes_is_green(self) -> None:
        self.write("node-notes/AUTHORS", "alice\n")
        self.write("node-notes/README.md", "format\n")
        self.write("node-notes/node-notes.json", "{}\n")
        head = self.commit("introduce node-notes")
        r = self.gate(self.base0, head, "anybody")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("bootstrap", r.stdout)

    def test_bootstrap_with_a_note_is_red(self) -> None:
        self.write("node-notes/AUTHORS", "mallory\n")
        self.write("node-notes/a-note.md", "x\n")
        head = self.commit("introduce node-notes with a note")
        self.assertEqual(self.gate(self.base0, head, "mallory").returncode, 1)

    def test_base_without_authors_but_with_notes_dir_is_red(self) -> None:
        self.write("node-notes/README.md", "format\n")
        base = self.commit("dir without AUTHORS")
        self.write("node-notes/README.md", "changed\n")
        head = self.commit("change")
        self.assertEqual(self.gate(base, head, "anybody").returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
