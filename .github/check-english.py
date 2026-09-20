#!/usr/bin/env python3
"""Everything this repository publishes is written in English.

try-agent-os/agentos is public: its branch names, commit subjects and bodies,
pull-request titles and bodies, code, comments and docs are read by people who
do not speak Russian, and by search engines, and forever. The rule "public =
English" was already written down twice as an instruction to the agent writing
the change -- and on 2026-09-20 the history of public main had to be rewritten
(three merged commits) plus three PR bodies, because an instruction in a prompt
is not reproducible. This script is the mechanical version of that rule: it is
not possible to merge Russian in, rather than not allowed to.

WHAT IS CHECKED

  * branch name                -- PR head ref / pushed ref / local branch
  * every commit in the change -- subject AND body, not only the head commit:
                                  a squash body is assembled from all of them
  * PR title and PR body       -- read from the event payload, not from the
                                  last commit, because that is what a reviewer
                                  and the merge dialog actually show
  * added diff lines           -- code, comments, docs, YAML; added paths too.
                                  Only ADDED lines: history and files already
                                  in the tree are not rescanned on every PR
  * direct pushes to main      -- a push bypasses the PR surfaces entirely,
                                  and that is how release sync travels

THE CRITERION

Not one Cyrillic character: U+0400-U+04FF (Cyrillic) plus U+0500-U+052F
(Cyrillic Supplement). Deliberately mechanical. No probabilistic language
detection: Latin text carrying Russian meaning is not caught and does not need
to be -- the rule being enforced is "you cannot write in Russian", not "you
must write well". The historic Cyrillic Extended blocks are out of scope for
the same reason: they cannot spell Russian, and every range added to the
criterion is a range somebody has to reason about later.

THE BYPASS

There is none by default. Two exist for the day a document genuinely has to
quote Cyrillic (a localization note, a bug report about an encoding):

  1. `allow-cyrillic: <reason>` on its own line in the PR BODY. The reason is
     mandatory and must be non-empty. It waives the two surfaces that can
     legitimately carry a quote -- the added diff lines and the PR body -- and
     NOTHING else. A branch name and a commit subject are pure metadata: there
     is no quote that has to live there, so no reason can buy them.
  2. `.github/cyrillic-allowlist.txt`, one path glob per line, `#` comments.
     Path-scoped, so it only ever waives added lines. An entry broad enough to
     cover the whole repository is rejected: an allowlist that matches
     everything is this gate switched off, and switching it off should cost a
     conversation, not a wildcard.

Both bypasses are reported on stdout when they fire, so a green run still says
out loud what it let through.

RUNNING IT

From the repository root, no arguments:  python3 .github/check-english.py

In GitHub Actions it reads GITHUB_EVENT_NAME / GITHUB_EVENT_PATH and scopes
itself to the pull request or the push. Outside Actions it falls back to the
local branch: the commits and the diff between origin/main and HEAD, plus the
branch name. PR title and body do not exist locally and are reported skipped.

Exit 0 = clean, 1 = findings on stdout. A scope it cannot determine is also
exit 1: a gate that cannot see its input must fail, never quietly pass.
"""

from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# The criterion, and the only place the ranges are written down.
# Written as escapes on purpose: this file has to pass its own check, and a
# literal class here would be the one Cyrillic in the repository.
CYRILLIC_RE = re.compile("[\\u0400-\\u04FF\\u0500-\\u052F]")

ALLOWLIST_FILE = ".github/cyrillic-allowlist.txt"

# An allowlist entry matching every one of these covers the whole repository.
ALLOWLIST_CANARIES = (
    "install.sh",
    "README.md",
    "docs/agent-install-design.md",
    ".github/workflows/ci.yml",
)

BYPASS_RE = re.compile(r"^[ \t>*-]*allow-cyrillic:[ \t]*(?P<reason>.*)$", re.MULTILINE)

NULL_SHA = "0" * 40

# Surfaces the PR-body bypass may waive. Everything else is unbuyable.
WAIVABLE = frozenset({"added line", "added path", "PR body"})


class GateError(Exception):
    """The gate cannot determine what to check. Never a silent pass."""


# --------------------------------------------------------------------------
# git


def git(*args: str, check: bool = True) -> str:
    proc = subprocess.run(
        ["git", "-c", "core.quotePath=false", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and proc.returncode != 0:
        raise GateError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def repo_root() -> Path:
    try:
        return Path(git("rev-parse", "--show-toplevel").strip())
    except GateError as exc:
        raise GateError(f"not a git repository (run from the repository root): {exc}") from exc


def have_commit(sha: str) -> bool:
    return (
        subprocess.run(
            ["git", "cat-file", "-e", f"{sha}^{{commit}}"],
            capture_output=True,
        ).returncode
        == 0
    )


def ensure_commit(sha: str, what: str) -> None:
    """Make `sha` readable, or fail loudly.

    On a `pull_request` run actions/checkout gives us the merge commit, whose
    parents are base and head, so with fetch-depth: 0 both SHAs are already
    here. A shallow checkout is the case this exists for: one deliberate fetch,
    and if that still cannot produce the object the gate fails. Scanning "the
    commits I happen to be able to see" is the failure mode this whole script
    exists to prevent.
    """
    if have_commit(sha):
        return
    subprocess.run(
        ["git", "fetch", "--no-tags", "--depth=2147483647", "origin", sha],
        capture_output=True,
    )
    if have_commit(sha):
        return
    raise GateError(
        f"{what} {sha} is not in this checkout and could not be fetched. "
        f"The workflow needs `fetch-depth: 0` on actions/checkout."
    )


def commits_in(base: str | None, head: str) -> list[str]:
    rev = f"{base}..{head}" if base else head
    return git("rev-list", "--no-merges", rev).split()


def merge_base(a: str, b: str) -> str:
    out = git("merge-base", a, b, check=False).strip()
    if not out:
        raise GateError(f"no merge base between {a} and {b}")
    return out


# --------------------------------------------------------------------------
# findings


class Findings:
    def __init__(self) -> None:
        self.problems: list[str] = []
        self.waived: list[str] = []
        self.notes: list[str] = []

    def note(self, message: str) -> None:
        self.notes.append(message)

    def scan(self, surface: str, where: str, text: str, waiver: str | None = None) -> None:
        """Report every line of `text` that carries Cyrillic."""
        for offset, line in enumerate(text.splitlines() or [text]):
            hits = CYRILLIC_RE.findall(line)
            if not hits:
                continue
            chars = "".join(sorted(set(hits), key=hits.index))[:12]
            codes = " ".join(f"U+{ord(c):04X}" for c in chars[:4])
            place = where if len(text.splitlines()) <= 1 else f"{where} (line {offset + 1})"
            detail = f"{surface}: {place}: Cyrillic {codes} in {line.strip()[:120]!r}"
            if waiver and surface in WAIVABLE:
                self.waived.append(f"{detail}  [waived: {waiver}]")
            else:
                self.problems.append(detail)


# --------------------------------------------------------------------------
# surfaces


def scan_branch(findings: Findings, branch: str | None) -> None:
    if not branch:
        findings.note("branch name: not determinable in this context, skipped")
        return
    findings.scan("branch name", branch, branch)


def scan_commits(findings: Findings, shas: list[str], label: str) -> None:
    if not shas:
        findings.note(f"{label}: no commits in range, nothing to check")
        return
    for sha in shas:
        subject = git("log", "-1", "--format=%s", sha).strip("\n")
        body = git("log", "-1", "--format=%b", sha).strip("\n")
        findings.scan("commit subject", f"{sha[:12]}", subject)
        if body.strip():
            findings.scan("commit body", f"{sha[:12]}", body)
    findings.note(f"{label}: {len(shas)} commit(s) checked (subject and body)")


def added_lines(base: str, head: str) -> list[tuple[str, int, str]]:
    """(path, line number in the new file, text) for every added line."""
    out = git(
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--find-renames",
        "-U0",
        base,
        head,
    )
    hunk_re = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@")
    results: list[tuple[str, int, str]] = []
    path: str | None = None
    lineno = 0
    for line in out.splitlines():
        if line.startswith("diff --git "):
            path, lineno = None, 0
        elif line.startswith("+++ "):
            target = line[4:].strip()
            path = None if target == "/dev/null" else re.sub(r"^b/", "", target)
        elif line.startswith("@@"):
            match = hunk_re.match(line)
            if match:
                lineno = int(match.group(1))
        elif line.startswith("+") and not line.startswith("+++"):
            results.append((path or "<unknown>", lineno, line[1:]))
            lineno += 1
    return results


def added_paths(base: str, head: str) -> list[str]:
    out = git("diff", "--name-only", "--find-renames", "--diff-filter=AR", base, head)
    return [p for p in out.splitlines() if p.strip()]


def load_allowlist(root: Path, findings: Findings) -> list[str]:
    """Path globs where added lines may carry Cyrillic. Absent file = none."""
    path = root / ALLOWLIST_FILE
    if not path.exists():
        return []
    patterns: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        entry = raw.split("#", 1)[0].strip()
        if not entry:
            continue
        if all(fnmatch.fnmatch(canary, entry) for canary in ALLOWLIST_CANARIES):
            findings.problems.append(
                f"allowlist: {ALLOWLIST_FILE} entry {entry!r} covers the whole repository. "
                f"An allowlist that matches everything is this gate switched off; "
                f"name the file or the directory that actually has to quote Cyrillic."
            )
            continue
        patterns.append(entry)
    if patterns:
        findings.note(
            f"{ALLOWLIST_FILE}: {len(patterns)} path pattern(s) may carry Cyrillic: "
            + ", ".join(patterns)
        )
    return patterns


def scan_diff(findings: Findings, root: Path, base: str, head: str, waiver: str | None) -> None:
    allowlist = load_allowlist(root, findings)

    def allowed(path: str) -> bool:
        return any(fnmatch.fnmatch(path, pattern) for pattern in allowlist)

    lines = added_lines(base, head)
    for path, lineno, text in lines:
        if allowed(path):
            continue
        findings.scan("added line", f"{path}:{lineno}", text, waiver=waiver)
    for path in added_paths(base, head):
        if allowed(path):
            continue
        findings.scan("added path", path, path, waiver=waiver)
    findings.note(f"diff {base[:12]}..{head[:12]}: {len(lines)} added line(s) checked")


def bypass_reason(pr_body: str | None) -> str | None:
    """`allow-cyrillic: <reason>` in the PR body. Empty reason does not count."""
    if not pr_body:
        return None
    for match in BYPASS_RE.finditer(pr_body):
        reason = match.group("reason").strip()
        if reason:
            return reason
    return None


# --------------------------------------------------------------------------
# scopes


def load_event() -> tuple[str, dict]:
    name = os.environ.get("GITHUB_EVENT_NAME", "")
    raw = os.environ.get("GITHUB_EVENT_PATH", "")
    if not name or not raw:
        return "", {}
    path = Path(raw)
    if not path.exists():
        raise GateError(f"GITHUB_EVENT_PATH points at {raw}, which does not exist")
    try:
        return name, json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise GateError(f"GITHUB_EVENT_PATH {raw} is not valid JSON: {exc}") from exc


def run_pull_request(findings: Findings, root: Path, event: dict) -> None:
    pr = event.get("pull_request") or {}
    number = event.get("number") or pr.get("number")
    title = pr.get("title") or ""
    body = pr.get("body") or ""
    head_sha = ((pr.get("head") or {}).get("sha")) or ""
    base_sha = ((pr.get("base") or {}).get("sha")) or ""
    branch = (pr.get("head") or {}).get("ref") or ""
    if not head_sha or not base_sha:
        raise GateError("pull_request event carries no base/head sha")

    waiver = bypass_reason(body)
    findings.note(f"scope: pull request #{number} ({branch})")

    scan_branch(findings, branch)
    findings.scan("PR title", f"#{number}", title)
    findings.scan("PR body", f"#{number}", body, waiver=waiver)

    ensure_commit(base_sha, "PR base commit")
    ensure_commit(head_sha, "PR head commit")
    base = merge_base(base_sha, head_sha)
    scan_commits(findings, commits_in(base, head_sha), "commits in the PR")
    scan_diff(findings, root, base, head_sha, waiver)

    if waiver:
        findings.note(f"bypass active: allow-cyrillic: {waiver}")


def run_push(findings: Findings, root: Path, event: dict) -> None:
    before = event.get("before") or ""
    after = event.get("after") or git("rev-parse", "HEAD").strip()
    branch = os.environ.get("GITHUB_REF_NAME") or ""
    findings.note(f"scope: push to {branch or '<unknown ref>'}")

    scan_branch(findings, branch)
    ensure_commit(after, "pushed head commit")

    base: str | None = None
    if before and before != NULL_SHA and have_commit(before):
        base = before
    else:
        parents = git("rev-list", "--parents", "-1", after).split()[1:]
        if parents:
            base = parents[0]
        findings.note(
            "push: the previous head is not available (new branch or force push); "
            "checking the pushed head commit only"
        )

    scan_commits(findings, commits_in(base, after), "commits in the push")
    if base:
        # No PR body exists on a push, so there is no waiver to pass: a direct
        # push to main gets the strict rule and nothing else.
        scan_diff(findings, root, base, after, None)


def run_local(findings: Findings, root: Path) -> None:
    branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()
    findings.note(f"scope: local checkout on {branch} (no GitHub event)")
    scan_branch(findings, branch if branch != "HEAD" else None)
    findings.note("PR title and PR body: no pull request locally, skipped")

    head = git("rev-parse", "HEAD").strip()
    base = None
    for candidate in ("origin/main", "main"):
        if git("rev-parse", "--verify", "--quiet", candidate, check=False).strip():
            resolved = git("rev-parse", candidate).strip()
            if resolved != head:
                base = merge_base(resolved, head)
                findings.note(f"comparing against {candidate}")
            break
    if base is None:
        findings.note(
            "no base branch to compare against (HEAD is main, or main is missing); "
            "commits and diff not checked"
        )
        return
    scan_commits(findings, commits_in(base, head), "commits ahead of the base")
    scan_diff(findings, root, base, head, None)


# --------------------------------------------------------------------------


def main() -> int:
    findings = Findings()
    try:
        root = repo_root()
        name, event = load_event()
        if name in ("pull_request", "pull_request_target") and event:
            run_pull_request(findings, root, event)
        elif name == "push" and event:
            run_push(findings, root, event)
        else:
            if name:
                findings.note(f"event {name!r} has no dedicated scope; using the local scope")
            run_local(findings, root)
    except GateError as exc:
        print(f"x english gate: {exc}")
        return 1

    for note in findings.notes:
        print(f"- {note}")
    for waived in findings.waived:
        print(f"~ {waived}")
    if not findings.problems:
        print("english ok: no Cyrillic in branch, commits, PR text or added lines")
        return 0

    print()
    for problem in findings.problems:
        print(f"x {problem}")
    print(
        f"\n{len(findings.problems)} problem(s). This repository is public and everything "
        f"it publishes is written in English: branch names, commit subjects and bodies, "
        f"PR title and body, code, comments and docs.\n"
        f"Rewrite the offending text in English (`git commit --amend` / `git rebase -i` for "
        f"commit messages, rename the branch, edit the PR on GitHub).\n"
        f"If a document genuinely has to QUOTE Cyrillic, add a line "
        f"`allow-cyrillic: <reason>` to the PR body, or list the path in "
        f"{ALLOWLIST_FILE} -- neither one waives a branch name or a commit subject."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
