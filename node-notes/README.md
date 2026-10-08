# node-notes

Short **field practice** notes for AgentOS nodes: a habit or a trap that was
proven on live nodes and is worth telling an agent when it asks. A node fetches
these notes on its host auto-update tick and hands them out only on request
(the `notes` topic of `agentos_docs`). They are never mixed into skills or the
system context, and a node's own built-in docs win on any conflict: a note is
practice, not a contract.

The catalog is empty on purpose until `main` is protected; the format and the
checks come first.

## Publication

There is no release step. A merged `main` **is** the publication: a node reads
`node-notes/node-notes.json` at the commit sha of `main`. The bundle is
generated in the pull request and committed:

```sh
python3 .github/node-notes.py build    # regenerate node-notes/node-notes.json
python3 .github/node-notes.py check    # what CI runs (read-only)
```

A rollback is a revert pull request through the same checks.

## A note

One file per note: `node-notes/<id>.md`, where the file name is the id.

```markdown
---
id: promise-after-turn
title: Do not promise "I will write when it is done" without a watcher
min_core: 4.49.0
requires_tools: [watch_start]
source: context#123 / incident 2026-09-21
---
Plain English prose.
```

Front matter is flat `key: value` lines, nothing else:

| key | required | value |
|---|---|---|
| `id` | yes | 3-64 chars of `a-z`, `0-9`, `-`; equals the file name |
| `title` | yes | one line, at most 120 characters |
| `min_core` | yes | semver `X.Y.Z`, not above the latest core release tag `v*`; there is no default |
| `max_core` | no | semver `X.Y.Z`, not below `min_core`; for a note known to be tied to a version range |
| `requires_tools` | no | list `[a, b]` of tool names; a node hides the note when a tool is missing in the session |
| `source` | yes | where the practice was proven (a PR, an incident) |

The body:

- English only (no Cyrillic anywhere in the file);
- the whole file is at most 4 KB, the whole bundle at most 64 KB;
- no ` ```yaml ` (or `yml`) code blocks, and no routine schema field keys
  written as `key:` -- neither at the start of a line nor inside inline code.
  A note describes practice; a routine example is how a note turns into an
  instruction that outlives the schema. The list of keys is the
  `routine-fields.json` asset of the latest core release; when a note exists
  and the asset cannot be fetched, the check is red.

## The bundle

`node-notes/node-notes.json`, generated, never edited by hand:

```json
{
  "format": 1,
  "notes": [
    {
      "id": "...",
      "title": "...",
      "min_core": "4.49.0",
      "requires_tools": ["watch_start"],
      "source": "...",
      "body": "..."
    }
  ]
}
```

Notes are sorted by id; `max_core` appears only when set. There is no
`source_commit` or build time in the file: the node knows the sha it fetched.

## Who may change it

A pull request that touches `node-notes/**`, `.github/node-notes.py` or
`.github/workflows/node-notes.yml` is green only when its author is listed in
`node-notes/AUTHORS` **as read from the base of the pull request**, and the
gate itself runs the base commit's copy of the checker. A pull request cannot
add its own author: adding a login is a change of its own, made by somebody
already listed.

## CI

`.github/workflows/node-notes.yml` runs on every pull request and every push to
`main` (no path filter, so it can be a required check), with
`permissions: contents: read` and actions pinned by sha. It has no write token:
nothing in this layer can rewrite a release or the update manifest.
