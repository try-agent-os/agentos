#!/usr/bin/env python3
"""Self-test of .github/ruleset.py: the lint must fail on every way the
protection of main can be weakened, and the live comparison must catch drift
while ignoring the defaults GitHub adds on its own. A gate nobody tests is a
green check that means nothing.

Run from the repository root:  python3 .github/test-ruleset.py
"""

from __future__ import annotations

import copy
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ruleset as R  # noqa: E402

FAILS: list[str] = []


def expect(cond: bool, what: str) -> None:
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        FAILS.append(what)


def rule(rs: dict, t: str) -> dict:
    return next(r for r in rs["rules"] if r["type"] == t)


base = R.load_ruleset()
jobs = R.workflow_pr_jobs()

expect(R.lint(base, jobs) == [], "the committed ruleset passes lint")

for name, mutate in [
    ("an admin bypass", lambda rs: rs["bypass_actors"].append(
        {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"})),
    ("enforcement 'evaluate'", lambda rs: rs.__setitem__("enforcement", "evaluate")),
    ("a ruleset on another branch", lambda rs: rs["conditions"]["ref_name"].__setitem__("include", ["refs/heads/dev"])),
    ("no force-push rule", lambda rs: rs["rules"].remove(rule(rs, "non_fast_forward"))),
    ("no deletion rule", lambda rs: rs["rules"].remove(rule(rs, "deletion"))),
    ("no pull-request rule", lambda rs: rs["rules"].remove(rule(rs, "pull_request"))),
    ("a required approval", lambda rs: rule(rs, "pull_request")["parameters"].__setitem__(
        "required_approving_review_count", 1)),
    ("a check not pinned to Actions", lambda rs: rule(rs, "required_status_checks")["parameters"][
        "required_status_checks"][0].pop("integration_id")),
    ("a check no workflow runs", lambda rs: rule(rs, "required_status_checks")["parameters"][
        "required_status_checks"].append({"context": "CI / lint", "integration_id": R.GITHUB_ACTIONS_APP_ID})),
    ("node-notes not required", lambda rs: rule(rs, "required_status_checks")["parameters"].__setitem__(
        "required_status_checks", [c for c in rule(rs, "required_status_checks")["parameters"]["required_status_checks"]
                                   if c["context"] != "node-notes"])),
    ("strict status checks", lambda rs: rule(rs, "required_status_checks")["parameters"].__setitem__(
        "strict_required_status_checks_policy", True)),
]:
    rs = copy.deepcopy(base)
    mutate(rs)
    expect(R.lint(rs, jobs) != [], f"lint rejects {name}")

# A workflow with a paths filter does not run on every PR: its job is no check.
with tempfile.TemporaryDirectory() as d:
    Path(d, "a.yml").write_text(
        "name: a\non:\n  pull_request:\n    branches: [main]\n    paths: ['x/**']\njobs:\n  lint:\n    runs-on: x\n")
    Path(d, "b.yml").write_text(
        "name: b\non:\n  workflow_dispatch:\njobs:\n  node-notes:\n    runs-on: x\n")
    Path(d, "c.yml").write_text(
        "name: c\non:\n  pull_request:\n    branches: [main]\njobs:\n  x:\n    name: English only\n    runs-on: x\n")
    got = R.workflow_pr_jobs(Path(d))
    expect(got == {"English only": "c.yml"}, f"only unfiltered pull_request jobs count as checks: {got}")

# Live comparison: GitHub echoes the body back with ids and extra defaults.
live = copy.deepcopy(base)
live.update({"id": 1, "source_type": "Repository", "source": "try-agent-os/agentos"})
rule(live, "pull_request")["parameters"]["required_reviewers"] = []
live["rules"].reverse()
rule(live, "required_status_checks")["parameters"]["required_status_checks"].reverse()
ok_repo = {"allow_auto_merge": True}
expect(R.compare(base, live, ok_repo) == [], "live echo with defaults and reordering is no drift")

for name, mutate, repo in [
    ("a bypass actor added live", lambda l: l["bypass_actors"].append({"actor_id": 1}), ok_repo),
    ("bypass list unreadable", lambda l: l.pop("bypass_actors"), ok_repo),
    ("enforcement disabled live", lambda l: l.__setitem__("enforcement", "disabled"), ok_repo),
    ("a required check dropped live", lambda l: rule(l, "required_status_checks")["parameters"][
        "required_status_checks"].pop(), ok_repo),
    ("an extra rule live", lambda l: l["rules"].append({"type": "required_linear_history"}), ok_repo),
    ("auto-merge off", lambda l: None, {"allow_auto_merge": False}),
]:
    l = copy.deepcopy(live)
    mutate(l)
    expect(R.compare(base, l, repo) != [], f"compare reports {name}")

if FAILS:
    print(f"\n{len(FAILS)} self-test failure(s)")
    sys.exit(1)
print("\nruleset self-test: all passed")
