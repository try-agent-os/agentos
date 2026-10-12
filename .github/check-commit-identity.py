#!/usr/bin/env python3
"""Only allowlisted identities may appear in the commits of this repository.

try-agent-os/agentos is public. Every e-mail address in a commit -- the author,
the committer and each `Co-authored-by:` trailer of the message -- is published
in the history forever, and GitHub turns each of them into an entry of the
Contributors list. On 2026-09-20 a squash commit (73160fff, PR #6) carried the
trailer `Co-authored-by: Axion <agent@symoditi.com>` and an unrelated agent
became a public contributor of the repository. Nothing checked it: who a commit
names was decided by the configuration of whatever machine made it.

This script is the mechanical rule: a commit that names an address which is not
in .github/commit-identities.txt cannot be merged.

WHAT IS CHECKED

  every commit in base..head, merge commits included:
    * the author e-mail
    * the committer e-mail
    * every `Co-authored-by:` line of the message (case-insensitive key,
      anywhere in the message, not only in the final trailer block -- a
      stricter reading than GitHub's costs nothing and leaves no hiding place)

A `Co-authored-by:` line without an `<address>` is a finding as well: it cannot
be checked, so it cannot pass.

THE ALLOWLIST IS READ FROM THE BASE

The allowlist is read from `--allowlist-rev` (default: the base commit), never
from the working tree or the head. A pull request that adds its own address to
the allowlist is still judged by the list it started from, so it fails; the new
address becomes valid only after a separate, already-allowed change has landed.
The workflow also runs the base commit's copy of this script, so a pull request
cannot rewrite the rule that judges it either.

The single exception is the bootstrap: when the allowlist revision has no
allowlist file at all (the pull request that introduces this gate), the head's
copy is used and the run says so. Once the file is on main, the exception can
never fire again for a pull request into main.

RUNNING IT

  python3 .github/check-commit-identity.py --base SHA --head SHA
  python3 .github/check-commit-identity.py            # origin/main..HEAD

`--base` may be empty or the all-zero SHA (a push that created a branch); the
first parent of the head is used instead, or only the head commit itself when
it is a root commit.

Exit 0 = every identity is allowed. Exit 1 = findings, one line per commit,
field and address. A range or an allowlist the gate cannot read is also exit 1:
a gate that cannot see its input must fail, never quietly pass.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

ALLOWLIST_FILE = ".github/commit-identities.txt"
NULL_SHA = "0" * 40

# `Co-authored-by: Name <address>`; the key is case-insensitive, as in git.
COAUTHOR_RE = re.compile(r"^\s*co-authored-by\s*:(?P<value>.*)$", re.IGNORECASE)
ADDRESS_RE = re.compile(r"<(?P<address>[^<>]*)>")

# Unit separator: cannot occur in a name or an e-mail address.
SEP = "\x1f"


class GateError(Exception):
    """The gate cannot determine what to check. Never a silent pass."""


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        ["git", "-c", "core.quotePath=false", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and proc.returncode != 0:
        raise GateError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc


def resolve(rev: str, what: str) -> str:
    proc = git("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}", check=False)
    sha = proc.stdout.strip()
    if proc.returncode != 0 or not sha:
        raise GateError(
            f"{what} {rev!r} is not a commit in this checkout "
            f"(the workflow needs `fetch-depth: 0` on actions/checkout)"
        )
    return sha


def parse_allowlist(text: str, where: str) -> set[str]:
    allowed: set[str] = set()
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if any(c in line for c in "*?[]") or " " in line or line.count("@") != 1:
            raise GateError(
                f"{where} line {number}: {line!r} is not one exact e-mail address "
                f"(one address per line, no wildcards)"
            )
        local, domain = line.split("@")
        if not local or not domain:
            raise GateError(f"{where} line {number}: {line!r} is not an e-mail address")
        allowed.add(line.lower())
    if not allowed:
        raise GateError(f"{where} lists no address; an empty allowlist rejects every commit")
    return allowed


def load_allowlist(rev: str, head: str, notes: list[str]) -> set[str]:
    shown = git("show", f"{rev}:{ALLOWLIST_FILE}", check=False)
    if shown.returncode == 0:
        notes.append(f"allowlist: {ALLOWLIST_FILE} as of {rev[:12]}")
        return parse_allowlist(shown.stdout, f"{rev[:12]}:{ALLOWLIST_FILE}")
    in_tree = git("ls-tree", "--name-only", rev, ALLOWLIST_FILE, check=False)
    if in_tree.returncode != 0:
        raise GateError(f"cannot read the tree of {rev}: {in_tree.stderr.strip()}")
    head_copy = git("show", f"{head}:{ALLOWLIST_FILE}", check=False)
    if head_copy.returncode != 0:
        raise GateError(
            f"{ALLOWLIST_FILE} exists neither in the base {rev[:12]} nor in the head "
            f"{head[:12]}; there is nothing to check identities against"
        )
    notes.append(
        f"allowlist: BOOTSTRAP -- the base {rev[:12]} has no {ALLOWLIST_FILE}, so the "
        f"head's copy is used; every later change is judged by the base copy"
    )
    return parse_allowlist(head_copy.stdout, f"{head[:12]}:{ALLOWLIST_FILE}")


def commit_range(base: str, head: str, notes: list[str]) -> tuple[str | None, list[str]]:
    """The base actually used and the commits of base..head, oldest first."""
    if base and base != NULL_SHA:
        base_sha = resolve(base, "base")
    else:
        parents = git("rev-list", "--parents", "-1", head).stdout.split()[1:]
        if parents:
            base_sha = parents[0]
            notes.append(f"no base given; comparing the head with its first parent {base_sha[:12]}")
        else:
            base_sha = None
            notes.append("no base given and the head is a root commit; only the head is checked")
    rev = f"{base_sha}..{head}" if base_sha else head
    return base_sha, git("rev-list", "--reverse", rev).stdout.split()


def identities(sha: str) -> list[tuple[str, str]]:
    """(field, address) for every identity a commit names; address '' = malformed."""
    fmt = SEP.join(["%ae", "%ce", "%B"])
    out = git("log", "-1", f"--format={fmt}", sha).stdout
    author, committer, message = out.split(SEP, 2)
    found = [("author", author.strip()), ("committer", committer.strip())]
    for line in message.splitlines():
        match = COAUTHOR_RE.match(line)
        if not match:
            continue
        address = ADDRESS_RE.search(match.group("value"))
        found.append(("Co-authored-by", address.group("address").strip() if address else ""))
    return found


def check(base: str, head: str, allowlist_rev: str | None) -> int:
    notes: list[str] = []
    head_sha = resolve(head, "head")
    base_sha, shas = commit_range(base, head_sha, notes)
    rev = resolve(allowlist_rev, "allowlist revision") if allowlist_rev else (base_sha or head_sha)
    allowed = load_allowlist(rev, head_sha, notes)

    problems: list[str] = []
    for sha in shas:
        for field, address in identities(sha):
            if not address:
                problems.append(
                    f"{sha[:12]} {field}: a trailer without an <address> cannot be checked"
                )
            elif address.lower() not in allowed:
                problems.append(f"{sha[:12]} {field}: {address} is not in {ALLOWLIST_FILE}")

    for note in notes:
        print(f"- {note}")
    print(f"- {len(shas)} commit(s) checked: author, committer, Co-authored-by")
    if not problems:
        print("commit identities ok: every address is in the allowlist")
        return 0
    print()
    for problem in problems:
        print(f"x {problem}")
    print(
        f"\n{len(problems)} problem(s). This repository is public: every address in a "
        f"commit is published forever and listed among its contributors.\n"
        f"Rewrite the offending commits with an allowed identity (`git commit --amend "
        f"--reset-author`, `git rebase` and drop the foreign `Co-authored-by:` lines), "
        f"or add the address to {ALLOWLIST_FILE} in a SEPARATE pull request first -- "
        f"this one is judged by the allowlist of its base."
    )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default=None, help="exclusive start of the range")
    parser.add_argument("--head", default="HEAD", help="last commit of the range")
    parser.add_argument(
        "--allowlist-rev", default=None, help="revision to read the allowlist from (default: base)"
    )
    args = parser.parse_args()
    try:
        base = args.base
        if base is None:
            base = git("merge-base", "origin/main", args.head).stdout.strip()
        return check(base, args.head, args.allowlist_rev)
    except GateError as exc:
        print(f"x commit identity gate: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
