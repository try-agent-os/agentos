#!/usr/bin/env python3
"""Keep the agent-install prompt from drifting away from install.sh.

The second install channel (docs/agent-install-design.md) is a prepared prompt,
agent-install.md, that tells a coding agent how to install AgentOS BY CALLING
install.sh. Its whole value rests on one property: the prompt is a shell around
the installer, never a second copy of it. A prompt that quietly grows its own
flags, its own download URL or its own pinned version stops being a shell and
becomes a second source of truth about how AgentOS is installed — and the way
that failure shows up in the field is an agent confidently running a command
that has not existed for three releases.

Nothing about that is catchable by reading a diff, so it is checked here:

  1. every `--flag` the documents name is either one install.sh actually parses,
     or one of the foreign flags declared below with a reason;
  2. nothing is fetched from anywhere but this repository's own files on main;
  3. the prompt pins no version;
  4. relative links resolve;
  5. the README still points at the prompt — a channel nobody can find is not a
     channel.

Run it from the repository root:  python3 .github/check-agent-prompt.py
Exit 0 = clean, 1 = findings on stdout.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPT = ROOT / "agent-install.md"
DESIGN = ROOT / "docs" / "agent-install-design.md"
README = ROOT / "README.md"
INSTALLER = ROOT / "install.sh"

# Flags that belong to another tool the prompt tells the agent to run. Each one
# is listed WITH its owner on purpose: adding a command to the prompt should
# cost one deliberate line here, not pass unnoticed.
FOREIGN_FLAGS = {
    "--json": "agentos ctl, every command",
    "--reason": "agentos ctl restart --reason <why>",
    "--private": "gh repo create",
    "--template": "gh repo create",
    "--no-pager": "journalctl",
    "--to": "agentos upgrade --to <tag>",
}

# The only remote files an agent following this prompt may download. Anything
# else is a second distribution channel, which is exactly what this design
# refuses to grow.
ALLOWED_FETCH = {
    "https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh",
    "https://raw.githubusercontent.com/try-agent-os/agentos/main/agent-install.md",
    "https://raw.githubusercontent.com/try-agent-os/agentos/main/cloud-init.yaml",
}

FLAG_RE = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
URL_RE = re.compile(r"https://[^\s`)<>\"']+")
VERSION_PIN_RE = re.compile(r"\bv\d+\.\d+\.\d+\b")


def installer_flags() -> set[str]:
    """The flags install.sh's argument parser actually answers to.

    Read from the parser block itself rather than from the header comment: the
    comment is documentation and can lag, the `case` arms are what runs. If the
    block cannot be found the check FAILS rather than returning an empty set —
    an install.sh refactor must surface here, not silently switch the gate off.
    """
    lines = INSTALLER.read_text(encoding="utf-8").splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("while [ $# -gt 0 ]"))
    except StopIteration:
        raise SystemExit("check-agent-prompt: install.sh has no `while [ $# -gt 0 ]` parser block")
    flags: set[str] = set()
    for line in lines[start + 1 :]:
        if re.match(r"^\s*esac\s*$", line):
            break
        match = re.match(r"^\s*((?:-{1,2}[A-Za-z0-9-]+\|?)+)\)", line)
        if match:
            flags.update(tok for tok in match.group(1).split("|") if tok.startswith("-"))
    if "--token" not in flags or "--domain" not in flags:
        raise SystemExit("check-agent-prompt: parsed no plausible flag set from install.sh")
    return flags


def fetch_urls(text: str) -> set[str]:
    """URLs on a line that downloads something. A link in prose is not a fetch."""
    found: set[str] = set()
    for line in text.splitlines():
        if "curl" not in line and "wget" not in line:
            continue
        found.update(URL_RE.findall(line))
    return found


def main() -> int:
    problems: list[str] = []
    known = installer_flags() | set(FOREIGN_FLAGS)

    for doc in (PROMPT, DESIGN):
        text = doc.read_text(encoding="utf-8")
        rel = doc.relative_to(ROOT)

        for flag in sorted(set(FLAG_RE.findall(text))):
            if flag not in known:
                problems.append(
                    f"{rel}: names `{flag}`, which install.sh does not parse. "
                    f"Either it is a typo, or it belongs to another tool and must be "
                    f"declared in FOREIGN_FLAGS in {Path(__file__).name}."
                )

        for url in sorted(fetch_urls(text)):
            if url.rstrip(".,") not in ALLOWED_FETCH:
                problems.append(
                    f"{rel}: downloads {url}. The prompt may fetch this repository's own "
                    f"files on main and nothing else — a second download path is a second "
                    f"distribution channel."
                )

        for pin in sorted(set(VERSION_PIN_RE.findall(text))):
            problems.append(
                f"{rel}: pins version {pin}. The prompt is versioned with main and must "
                f"carry nothing a release can invalidate."
            )

        for target in sorted(set(LINK_RE.findall(text))):
            if target.startswith(("http://", "https://", "#", "mailto:")):
                continue
            path = (doc.parent / target.split("#", 1)[0]).resolve()
            if not path.exists():
                problems.append(f"{rel}: link target does not exist: {target}")

    if PROMPT.name not in README.read_text(encoding="utf-8"):
        problems.append(
            f"README.md does not mention {PROMPT.name} — a human who does not know the "
            f"file exists cannot use the channel."
        )

    for problem in problems:
        print(f"✗ {problem}")
    if problems:
        print(f"\n{len(problems)} problem(s).")
        return 1
    print(f"agent prompt ok ({len(known)} known flags, {len(ALLOWED_FETCH)} allowed fetch URLs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
