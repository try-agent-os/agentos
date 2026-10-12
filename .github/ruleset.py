#!/usr/bin/env python3
"""The protection of `main`, kept as a file and applied with a read-back.

`main` of this repository is what strangers install from: install.sh and the
agentos CLI are fetched from it, and a merged node note (node-notes/) is
published to every node the moment it lands. So nothing reaches `main` except
through a pull request whose required checks are green, and NOBODY is exempt:
the bypass list is empty on purpose. A bypass for the admin role is a bypass for
whoever holds an admin token -- the owner's PAT, a leaked release token -- and
the whole point of the checks is that they also hold against those.

The rules live in .github/rulesets/main.json (the body of the GitHub rulesets
API) and are put in place by this script, never by clicking in the settings:

  python3 .github/ruleset.py lint     # offline: the file keeps its invariants
  python3 .github/ruleset.py check    # read-only: live settings == the file
  python3 .github/ruleset.py apply    # create/update, then read back

`apply` needs `gh` authenticated with admin on the repository. It creates the
ruleset (or updates the one with the same name), turns on `allow_auto_merge`
-- the release workflow of try-agent-os/agent-os syncs install.sh and the CLI
through a `release-sync/<tag>` pull request with `gh pr merge --auto` -- and
then reads both back. A read-back that does not match is exit 1: a protection
that was "applied" but is not in force is worse than none, because everyone
believes it.

`lint` runs in CI (job `lint`). It holds what must never change silently:
the bypass list is empty, the ruleset is active and targets main, force-push
and deletion are blocked, a pull request is required, and every required check
names a job that really runs on every pull request to main (a required check
that never runs leaves every pull request pending forever).

Exit 0 = clean, 1 = findings / drift on stdout, 2 = usage or gh failure.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULESET = ROOT / ".github" / "rulesets" / "main.json"
WORKFLOWS = ROOT / ".github" / "workflows"
REPO = "try-agent-os/agentos"

# The GitHub Actions app. A required check pinned to it can only be satisfied
# by a check run of a workflow in this repository, not by a commit status that
# any token with `statuses: write` could post under the same name.
GITHUB_ACTIONS_APP_ID = 15368

READBACK_TRIES = 4
READBACK_PAUSE_S = 3

REQUIRED_RULE_TYPES = {"deletion", "non_fast_forward", "pull_request", "required_status_checks"}


def load_ruleset(path: Path = RULESET) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


# --------------------------------------------------------------------- lint --

def workflow_pr_jobs(workflows_dir: Path = WORKFLOWS) -> dict[str, str]:
    """Map check name -> workflow file for every job that runs on each PR to main.

    A deliberately small reader of the workflow files (no YAML library in the
    lint job): it finds the top-level `on:` block, the `jobs:` block, each job
    key at two spaces and its `name:` at four. A workflow with a `paths` or
    `paths-ignore` filter, or without `pull_request`, contributes nothing --
    its jobs do not run on every pull request.
    """
    out: dict[str, str] = {}
    for wf in sorted(workflows_dir.glob("*.yml")) + sorted(workflows_dir.glob("*.yaml")):
        lines = wf.read_text(encoding="utf-8").splitlines()
        on_block: list[str] = []
        jobs: dict[str, str] = {}
        section = None
        job = None
        for line in lines:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            top = re.match(r"^([^\s#:][^:]*):", line)
            if top:
                section = top.group(1).strip("\"'")
                job = None
                continue
            if section == "on":
                on_block.append(line)
            elif section == "jobs":
                m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
                if m:
                    job = m.group(1)
                    jobs[job] = job
                    continue
                m = re.match(r"^    name:\s*(.+?)\s*$", line)
                if m and job:
                    jobs[job] = m.group(1).strip("\"'")
        on_text = "\n".join(on_block)
        if not re.search(r"^\s+pull_request:", on_text, re.M):
            continue
        if re.search(r"^\s+paths(-ignore)?:", on_text, re.M):
            continue
        branches = re.search(r"pull_request:\s*\n\s+branches:\s*\[([^\]]*)\]", on_text)
        if branches and "main" not in [b.strip().strip("\"'") for b in branches.group(1).split(",")]:
            continue
        for name in jobs.values():
            out[name] = wf.name
    return out


def lint(ruleset: dict, pr_jobs: dict[str, str]) -> list[str]:
    findings: list[str] = []
    if ruleset.get("bypass_actors") != []:
        findings.append("bypass_actors must be an empty list: no role, team, app or key is exempt")
    if ruleset.get("enforcement") != "active":
        findings.append("enforcement must be 'active' (evaluate/disabled protect nothing)")
    if ruleset.get("target") != "branch":
        findings.append("target must be 'branch'")
    ref = (ruleset.get("conditions") or {}).get("ref_name") or {}
    if "refs/heads/main" not in (ref.get("include") or []) and "~DEFAULT_BRANCH" not in (ref.get("include") or []):
        findings.append("conditions.ref_name.include must cover refs/heads/main")
    if ref.get("exclude"):
        findings.append("conditions.ref_name.exclude must be empty")

    rules = ruleset.get("rules") or []
    types = [r.get("type") for r in rules]
    for missing in sorted(REQUIRED_RULE_TYPES - set(types)):
        findings.append(f"rule '{missing}' is missing")
    for dup in sorted({t for t in types if types.count(t) > 1}):
        findings.append(f"rule '{dup}' appears more than once")

    by_type = {r.get("type"): r.get("parameters") or {} for r in rules}
    pr = by_type.get("pull_request")
    if pr is not None and pr.get("required_approving_review_count") != 0:
        findings.append("pull_request.required_approving_review_count must be 0: the factory merges, nobody approves")
    checks = (by_type.get("required_status_checks") or {}).get("required_status_checks") or []
    if "required_status_checks" in by_type and not checks:
        findings.append("required_status_checks lists no check")
    if (by_type.get("required_status_checks") or {}).get("strict_required_status_checks_policy"):
        findings.append("strict_required_status_checks_policy must be false: an auto-merge PR behind main would stall")
    contexts = []
    for c in checks:
        ctx = c.get("context")
        contexts.append(ctx)
        if c.get("integration_id") != GITHUB_ACTIONS_APP_ID:
            findings.append(f"required check '{ctx}' must be pinned to GitHub Actions (integration_id {GITHUB_ACTIONS_APP_ID})")
        if ctx not in pr_jobs:
            findings.append(f"required check '{ctx}' is not a job that runs on every pull request to main")
    for must in ("lint", "node-notes"):
        if must not in contexts:
            findings.append(f"required check '{must}' is missing")
    return findings


# --------------------------------------------------------- compare (live) --

def _subset(want, have) -> bool:
    """`have` carries every key/value of `want`; GitHub adds defaults we ignore."""
    if isinstance(want, dict):
        return isinstance(have, dict) and all(k in have and _subset(v, have[k]) for k, v in want.items())
    if isinstance(want, list):
        if not isinstance(have, list) or len(want) != len(have):
            return False
        if all(not isinstance(x, (dict, list)) for x in want + have):
            return sorted(want, key=repr) == sorted(have, key=repr)
        return _subset_unordered(want, have)
    return want == have


def _subset_unordered(want: list, have: list) -> bool:
    left = list(have)
    for w in want:
        for i, h in enumerate(left):
            if _subset(w, h):
                del left[i]
                break
        else:
            return False
    return True


def compare(want: dict, live: dict, repo: dict) -> list[str]:
    """Differences between the file and the live ruleset + repository settings."""
    drift: list[str] = []
    for key in ("name", "target", "enforcement"):
        if live.get(key) != want.get(key):
            drift.append(f"{key}: live {live.get(key)!r}, file {want.get(key)!r}")
    if not _subset(want.get("conditions"), live.get("conditions")):
        drift.append(f"conditions: live {json.dumps(live.get('conditions'), sort_keys=True)}")
    if (live.get("bypass_actors") or []) != []:
        drift.append(f"bypass_actors is not empty live: {json.dumps(live.get('bypass_actors'))}")
    if "bypass_actors" not in live:
        drift.append("bypass_actors is not readable live (token without admin?) -- cannot prove it empty")
    want_rules = {r["type"]: r.get("parameters") or {} for r in want.get("rules") or []}
    live_rules = {r.get("type"): r.get("parameters") or {} for r in live.get("rules") or []}
    for t in sorted(set(want_rules) - set(live_rules)):
        drift.append(f"rule '{t}' is missing live")
    for t in sorted(set(live_rules) - set(want_rules)):
        drift.append(f"rule '{t}' exists live but not in the file")
    for t in sorted(set(want_rules) & set(live_rules)):
        if not _subset(want_rules[t], live_rules[t]):
            drift.append(f"rule '{t}' parameters: live {json.dumps(live_rules[t], sort_keys=True)}")
    if repo.get("allow_auto_merge") is not True:
        drift.append(f"allow_auto_merge: live {repo.get('allow_auto_merge')!r}, want True")
    return drift


# ---------------------------------------------------------------- gh calls --

def gh(*args: str, body: dict | None = None) -> object:
    cmd = ["gh", "api", *args]
    if body is not None:
        cmd += ["--input", "-"]
    res = subprocess.run(cmd, input=json.dumps(body) if body is not None else None,
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(f"gh api {' '.join(args)} failed: {res.stderr.strip() or res.stdout.strip()}", file=sys.stderr)
        raise SystemExit(2)
    return json.loads(res.stdout) if res.stdout.strip() else None


def find_live(repo: str, name: str) -> dict | None:
    listed = gh(f"repos/{repo}/rulesets?includes_parents=false&per_page=100")
    same = [r for r in listed if r.get("name") == name and r.get("source_type", "Repository") == "Repository"]
    if len(same) > 1:
        print(f"{len(same)} rulesets named {name!r} on {repo}: resolve by hand, refusing to guess", file=sys.stderr)
        raise SystemExit(2)
    return gh(f"repos/{repo}/rulesets/{same[0]['id']}") if same else None


def live_state(repo: str, name: str) -> tuple[dict, dict]:
    return find_live(repo, name) or {}, gh(f"repos/{repo}")


def cmd_check(repo: str, want: dict) -> int:
    live, repo_info = live_state(repo, want["name"])
    if not live:
        print(f"ruleset {want['name']!r} does not exist on {repo}")
        return 1
    drift = compare(want, live, repo_info)
    for d in drift:
        print(f"drift: {d}")
    if not drift:
        print(f"{repo}: ruleset {want['name']!r} (id {live['id']}) and allow_auto_merge match {RULESET.relative_to(ROOT)}")
    return 1 if drift else 0


def cmd_apply(repo: str, want: dict) -> int:
    findings = lint(want, workflow_pr_jobs())
    if findings:
        for f in findings:
            print(f"lint: {f}")
        print("refusing to apply a ruleset that fails lint")
        return 1
    live = find_live(repo, want["name"])
    if live:
        gh("-X", "PUT", f"repos/{repo}/rulesets/{live['id']}", body=want)
        print(f"updated ruleset {want['name']!r} (id {live['id']}) on {repo}")
    else:
        made = gh("-X", "POST", f"repos/{repo}/rulesets", body=want)
        print(f"created ruleset {want['name']!r} (id {made['id']}) on {repo}")
    gh("-X", "PATCH", f"repos/{repo}", body={"allow_auto_merge": True})
    # Read back from scratch: what counts is what GitHub now holds. The REST
    # reads lag the writes by a moment (seen on 2026-10-12: the repository
    # answered allow_auto_merge=false seconds after the PATCH, true after), so
    # a mismatch is re-read a few times before it is believed.
    for attempt in range(READBACK_TRIES):
        if attempt:
            time.sleep(READBACK_PAUSE_S)
        rc = cmd_check(repo, want)
        if rc == 0:
            return 0
    return rc


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in ("lint", "check", "apply"):
        print(__doc__.split("\n\n")[3])
        return 2
    repo = REPO
    if "--repo" in argv:
        repo = argv[argv.index("--repo") + 1]
    want = load_ruleset()
    if argv[1] == "lint":
        findings = lint(want, workflow_pr_jobs())
        for f in findings:
            print(f"{RULESET.relative_to(ROOT)}: {f}")
        if not findings:
            print(f"{RULESET.relative_to(ROOT)}: ok")
        return 1 if findings else 0
    if argv[1] == "check":
        return cmd_check(repo, want)
    return cmd_apply(repo, want)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
