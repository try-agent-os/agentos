---
id: state-claims-need-a-command
title: Report a state only from a command run in the same turn
min_core: 4.0.0
source: field practice of the aos contour (owner reports on rights, usage and CI, autumn 2026)
---
"The CI is green", "the node has root on this host", "we used 40% of the
week" -- each of these sounds like a fact, and each has been wrong on a live
node when it came from memory, from a document or from an earlier turn. Rights
change, usage moves every minute, a check that was green an hour ago is red on
the new head.

The habit: a claim about the current state goes into a reply only together
with a command run in this same turn that shows it.

- Rights: ask the system (for example `sudo -l`, or the node's own boundary
  file), not the canon or a note.
- Usage and limits: the node's usage tool or command, with the time of the
  reading.
- CI and pull requests: the GitHub API or `gh` on the current head sha.
- Anything else: the shortest read-only command that returns the value.

If the command cannot be run, say "not checked" and list what was tried. "I
cannot" without the list of checked options is an unchecked answer: go
through the node's tools first (the `gh` scopes, `sudo -l`, the MCP tools,
the neighbour APIs) and name what was checked.
