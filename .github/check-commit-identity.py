#!/usr/bin/env python3
"""Agent identities of other deployments may not appear in this repository.

try-agent-os/agentos is public. Every e-mail address in a commit -- the author,
the committer and each `Co-authored-by:` trailer of the message -- is published
in the history forever, and GitHub turns each of them into an entry of the
Contributors list. On 2026-09-20 a squash commit (PR #6) carried the
trailer of an agent that serves another deployment, and that agent became a
public contributor of the repository. Nothing checked it: who a commit names was
decided by the configuration of whatever machine made it.

This script is the mechanical rule: a commit that names the agent identity of
another deployment cannot be merged. People are not limited: any human
contributor, with any address, passes without being listed anywhere. This
project's own agent and release bot are simply not in the registry.

WHAT IS CHECKED

  every commit in base..head, merge commits included:
    * the author e-mail
    * the committer e-mail
    * every `Co-authored-by:` line of the message (case-insensitive key,
      anywhere in the message, not only in the final trailer block -- a
      stricter reading than GitHub's costs nothing and leaves no hiding place)

An identity with no address -- such as a `Co-authored-by:` line without an
`<address>` -- is a finding as well: it cannot be checked, so it cannot pass.

Spellings of one account are one identity (`canonical`): letter case, a `+tag`,
and GitHub's `<id>+<login>@users.noreply.github.com` form, which reduces to
`<login>@users.noreply.github.com`.

THE REGISTRY HOLDS HASHES, NOT ADDRESSES

A plain list of those addresses in a public repository would itself publish who
the other deployments are. So .github/foreign-agent-identities.txt holds only
salted scrypt hashes, and the gate hashes each address it meets and compares. A
pull request from a fork needs no secret or repository variable to be judged,
which matters because forks are exactly where human contributors come from. An
entry is an address, or `@domain` for a whole domain. To make one, without
leaving the address in the shell history:

  python3 .github/check-commit-identity.py --hash   # one per line on stdin

The hash hides a list from a reader, not one address from someone who already
guesses it: scrypt makes guessing slow, not impossible. Nor is this a defence
against someone forging commits, who can use an unlisted address anyway. It
stops an agent's configured identity from landing by accident.

THE REGISTRY IS READ FROM THE BASE

The registry is read from `--registry-rev` (default: the base commit), never
from the working tree or the head. A pull request that removes an entry to get
its own commits through is still judged by the list it started from, so it
fails. The workflow also runs the base commit's copy of this script, so a pull
request cannot rewrite the rule that judges it either.

The single exception is the bootstrap: when the registry revision has no
registry file at all (the pull request that introduces it), the head's copy is
used and the run says so. Once the file is on main, the exception can never fire
again for a pull request into main.

RUNNING IT

  python3 .github/check-commit-identity.py --base SHA --head SHA
  python3 .github/check-commit-identity.py            # origin/main..HEAD

`--base` may be empty or the all-zero SHA (a push that created a branch); the
first parent of the head is used instead, or only the head commit itself when
it is a root commit.

Exit 0 = no foreign agent identity. Exit 1 = findings, one line per commit, field
and address. A range or a registry the gate cannot read is also exit 1, and so
is an empty one: a deny list that cannot see its input, or has none, would let
everything through, and a gate must fail rather than quietly pass.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys

REGISTRY_FILE = ".github/foreign-agent-identities.txt"
NULL_SHA = "0" * 40
GITHUB_NOREPLY_DOMAIN = "users.noreply.github.com"

# A fixed salt: it rules out lookup in ready-made tables of hashed e-mail
# addresses. The scrypt cost (about 16 MiB and 50 ms per guess) is what slows
# down testing guesses against the registry. Changing either invalidates it.
HASH_SALT = b"try-agent-os/agentos foreign agent identity v1"
HASH_N, HASH_R, HASH_P = 2**14, 8, 1
ENTRY_RE = re.compile(r"[0-9a-f]{64}")

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


def canonical(address: str) -> str:
    """One account behind the spellings of its address; `@domain` stays a domain."""
    local, _, domain = address.strip().lower().rpartition("@")
    if domain == GITHUB_NOREPLY_DOMAIN:
        local = local.rpartition("+")[2]
    else:
        local = local.partition("+")[0]
    return f"{local}@{domain}"


def entry_hash(entry: str) -> str:
    return hashlib.scrypt(
        entry.encode("utf-8"), salt=HASH_SALT, n=HASH_N, r=HASH_R, p=HASH_P, dklen=32
    ).hex()


def parse_registry(text: str, where: str) -> set[str]:
    entries: set[str] = set()
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if not ENTRY_RE.fullmatch(line):
            # Never echo the line: it may be the address that must not be published.
            raise GateError(
                f"{where} line {number} is not a hash from `--hash` (a plain address "
                f"here would publish it; the bad line is not repeated in this log)"
            )
        entries.add(line)
    if not entries:
        raise GateError(f"{where} lists no hash; an empty deny list would let everything through")
    return entries


def load_registry(rev: str, head: str, notes: list[str]) -> set[str]:
    shown = git("show", f"{rev}:{REGISTRY_FILE}", check=False)
    if shown.returncode == 0:
        notes.append(f"registry: {REGISTRY_FILE} as of {rev[:12]}")
        return parse_registry(shown.stdout, f"{rev[:12]}:{REGISTRY_FILE}")
    in_tree = git("ls-tree", "--name-only", rev, REGISTRY_FILE, check=False)
    if in_tree.returncode != 0:
        raise GateError(f"cannot read the tree of {rev}: {in_tree.stderr.strip()}")
    head_copy = git("show", f"{head}:{REGISTRY_FILE}", check=False)
    if head_copy.returncode != 0:
        raise GateError(
            f"{REGISTRY_FILE} exists neither in the base {rev[:12]} nor in the head "
            f"{head[:12]}; there is nothing to check identities against"
        )
    notes.append(
        f"registry: BOOTSTRAP -- the base {rev[:12]} has no {REGISTRY_FILE}, so the "
        f"head's copy is used; every later change is judged by the base copy"
    )
    return parse_registry(head_copy.stdout, f"{head[:12]}:{REGISTRY_FILE}")


def is_foreign(address: str, registry: set[str], memo: dict[str, bool]) -> bool:
    """Is it a listed address, or an address in a listed domain?"""
    key = canonical(address)
    if key not in memo:
        domain = "@" + key.rpartition("@")[2]
        memo[key] = entry_hash(key) in registry or entry_hash(domain) in registry
    return memo[key]


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


def check(base: str, head: str, registry_rev: str | None) -> int:
    notes: list[str] = []
    head_sha = resolve(head, "head")
    base_sha, shas = commit_range(base, head_sha, notes)
    rev = resolve(registry_rev, "registry revision") if registry_rev else (base_sha or head_sha)
    registry = load_registry(rev, head_sha, notes)

    problems: list[str] = []
    memo: dict[str, bool] = {}
    for sha in shas:
        for field, address in identities(sha):
            if not address:
                problems.append(f"{sha[:12]} {field}: no address, so it cannot be checked")
            elif is_foreign(address, registry, memo):
                problems.append(
                    f"{sha[:12]} {field}: {address} is an agent identity of another deployment"
                )

    for note in notes:
        print(f"- {note}")
    print(f"- {len(shas)} commit(s) checked: author, committer, Co-authored-by")
    if not problems:
        print("commit identities ok: no agent identity of another deployment")
        return 0
    print()
    for problem in problems:
        print(f"x {problem}")
    print(
        f"\n{len(problems)} problem(s). This repository is public: every address in a "
        f"commit is published forever and listed among its contributors.\n"
        f"Rewrite the offending commits with your own identity (`git commit --amend "
        f"--reset-author`, `git rebase` and drop the foreign `Co-authored-by:` lines). "
        f"If an address here is a person's and not an agent's, remove its hash from "
        f"{REGISTRY_FILE} in a SEPARATE pull request first -- this one is judged by "
        f"the registry of its base."
    )
    return 1


def print_hashes() -> int:
    """stdin: one address or `@domain` per line. stdout: one registry entry per line."""
    for raw in sys.stdin:
        entry = raw.strip()
        if not entry:
            continue
        if "@" not in entry:
            print("x an entry is an address or @domain; a line without @ is neither")
            return 1
        print(entry_hash(canonical(entry)))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default=None, help="exclusive start of the range")
    parser.add_argument("--head", default="HEAD", help="last commit of the range")
    parser.add_argument(
        "--registry-rev", default=None, help="revision to read the registry from (default: base)"
    )
    parser.add_argument(
        "--hash", action="store_true", help="print registry entries for the addresses on stdin"
    )
    args = parser.parse_args()
    if args.hash:
        return print_hashes()
    try:
        base = args.base
        if base is None:
            base = git("merge-base", "origin/main", args.head).stdout.strip()
        return check(base, args.head, args.registry_rev)
    except GateError as exc:
        print(f"x commit identity gate: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
