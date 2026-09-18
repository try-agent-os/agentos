# Installing by agent — the second channel

**Status:** design + the prepared prompt ([`agent-install.md`](../agent-install.md)).
Not a full implementation: nothing in the node changes because of this document.

## Why a second channel

The existing channel is one command a human runs, and it stays exactly as it is:
`install.sh` from this repository, a checksum-verified release tarball, a
systemd unit, a health gate. It ends with a running node and a person who now
has to find out what to do with it — which is what the node's own bot-led
onboarding wizard was supposed to answer, in chat, afterwards.

That split is the problem. The wizard runs after the install, in a different
place, with different information, and it can only ask what fits in a Telegram
keyboard. It is being retired.

The people we are addressing here already have the thing that does the asking
well: a coding agent with a terminal. For them the honest shape is not
"install, then get onboarded" but **one conversation that ends with a working
node** — the agent runs the installer, asks what the wizard would have asked,
and writes the answers where the node will read them. Onboarding stops being a
phase and becomes the install.

This does not replace the one-command channel and does not fork distribution.
It is a second entry point onto the same installer.

## What ships

| Artifact | What it is |
|---|---|
| [`agent-install.md`](../agent-install.md) | The prepared prompt. The human hands this file (or its raw URL) to their agent. It carries the rules, the flow, the questions and the failure policy. |
| This document | Why it is shaped that way, and the decisions behind it. |
| [`.github/check-agent-prompt.py`](../.github/check-agent-prompt.py) | The CI gate that keeps the prompt from drifting away from `install.sh`. |
| A README section | How a human finds the channel at all. |

Not in scope, deliberately: any change to `install.sh`, to the node, or to the
wizard. Turning the wizard off is its own task in the node's repository.

## The flow

Seven phases. Each one ends with a command that answers yes or no — the prompt
insists on that, because "it probably worked" is how an agent-run install
becomes a support ticket a week later.

| Phase | The agent | Gate |
|---|---|---|
| 0 Preflight | arch, distro, privileges, existing install, disk/RAM; dry-runs the intended command line through the installer's own no-op probes (`AGENTOS_PRINT_MODE`, `AGENTOS_PRINT_IDENTITY`, `AGENTOS_PRINT_VERSION_DECISION`) | profile decided; `install`, not `keep` |
| 1 Interview | group A: what the install cannot proceed without · group B: where the brain lives · group C: who the owner is | every group-A answer present |
| 2 Secrets file | one 0600 env file: `GH_TOKEN`, optional `CLAUDE_CODE_OAUTH_TOKEN`, `AGENTOS_REPO_DIR` | file exists, mode 0600 |
| 3 Brain | repo from the template, `memory/owner.md` and `CLAUDE.md` filled from group C, pushed | commit on the remote |
| 4 Install | one `install.sh` call with `--admin`, one HTTPS flag, `--repo`, `--secrets`, `-y` | exit 0 · `AgentOS Node is running.` · `systemctl is-active` · `/healthz` |
| 5 Connect | owner DMs the bot (`/start`), `/login` if no token was placed; brain adoption verified in the log | bot answers · context adopted |
| 6 Useful | harness if not Claude, first routine from the preset catalog, one real task in chat | routine present in the repo |
| 7 Handover | what/where/how, in the owner's words and as `memory/node.md`; secrets file destroyed | both written |

The ordering is not cosmetic. The brain is created **before** the install so
that `--repo` clones it and `AGENTOS_REPO_DIR` names it in the same run: the
checkout then exists before the node's first boot, which is when the node looks
for a context to adopt. Build the repo afterwards and you need a restart to make
it stick — which the prompt also tells the agent how to detect and fix, because
on a fresh box the race can still go the other way.

## Decisions

### D1. What agent we assume

Any agent that can run shell commands on the target box and read their output,
and that can talk to the human while doing it. Claude Code and Codex CLI are the
ones we have in mind; nothing in the prompt depends on either.

What we may assume: a terminal, `curl`, `git`, and the ability to follow a long
document without losing the thread. What we may **not** assume: network access
to anything but the box and the public internet, a GitHub CLI already
authenticated, any prior knowledge of AgentOS, or that the agent will ask before
doing something silly. Hence the rules block at the top of the prompt: the
hard constraints are stated before any step, in the imperative, with the reason
attached — an agent that understands *why* it must not hand-unpack a tarball
will not invent a variant we did not think of.

We also assume the agent is running with the owner watching. Anything only a
human can do — creating the bot, generating a Claude setup token, clicking
`/login` — is explicitly handed back, never faked.

### D2. Where the prompt lives, and how it is versioned

It lives in this repository, at the root, next to `install.sh`, and it is
fetched from `main` — the same discipline as the installer, which the README
also fetches from `main` rather than from a tag.

It is deliberately **not** versioned per release, because it deliberately
contains nothing that a release can invalidate: no version numbers, no channel
names, no copy of the installer's internals. What it contains is the *shape* of
the work — which questions to ask, which flags to decide between, what to assert
— and that changes when the flow changes, not when the node ships a patch.

Two consequences we accept: an old copy pasted into an agent six months from now
may name a flag that has since been renamed (the prompt tells the agent that
`install.sh --help` outranks it, precisely for this), and the prompt cannot
describe behaviour that differs between installed versions.

### D3. One installer, one source of truth

`install.sh` is the only mechanism. The prompt is a shell around it, never a
copy of it. In practice that means the prompt may:

- tell the agent to download and run `install.sh`, and how to choose its flags;
- assert on its observable output (`AgentOS Node is running.`, `/healthz`,
  `systemctl is-active`);
- explain what the installer deliberately does not do, so the agent does not
  wait for it.

And may not: re-implement a step it performs, download a release artifact
directly, write a unit file, or work around one of its guards. The checksum
gate, the `visudo -cf` validation, the symlink refusals and the
keep-the-installed-version rule exist only there.

This is enforced, not just asserted. [`.github/check-agent-prompt.py`](../.github/check-agent-prompt.py)
runs in CI and fails the build when the prompt names a flag that `install.sh`'s
parser does not have, when it points a download at anything other than this
repository's own files, or when it pins a version. A prompt that drifts from the
installer is the failure mode that would quietly break this channel; it now
breaks the build instead.

### D4. What the agent decides, and what it asks

The line is: **ask for what only the owner knows or only the owner may consent
to; decide everything that follows from the box.**

Asked — bot token, admin id, Mini App or bot-only, root or `--scoped-sudo`,
where the brain lives, and all of group C. Four of those are unknowable
(`--token`, `--admin`, DNS readiness, the owner's own facts) and one is consent:
the default install gives the service account passwordless root on the host, and
an agent must not accept that on its owner's behalf without saying it out loud.

Decided — profile (bare metal unless the host cannot take it), install root,
service account, port, `-y`, how many times to retry, when to restart, what to
assert. The prompt does not ask "shall I use the default port": nobody wants to
be consulted about that, and an agent that consults about everything is worse
than one that decides.

Never decided: the version of an existing node. That is a separate, backed-up
operation (`agentos upgrade`) with its own rollback, and the prompt forbids
`--upgrade` as a tidiness reflex.

### D5. What happens when a step fails

Three classes, each with one rule:

1. **The agent's own error** (bad argv, a missing file) — fix it and re-run.
   Never push it back to the owner as a question they already answered.
2. **The environment** (wrong arch, no apt, no root, a port in use, DNS not
   ready) — name it, name the remedy the installer itself names (usually
   `--docker`, or a flag change), and ask before doing anything that changes the
   host beyond the install.
3. **Integrity** — checksum mismatch, certificate failure, any suggestion to
   skip verification: stop, report, do not route around. This is the one class
   where "the agent fixed it" is a worse outcome than "the agent stopped".

Everything else is a retry-once-then-report. The installer has no rollback and
no cleanup trap on purpose: whatever completed stays completed, `.env` and data
survive, and re-running is the supported repair — so the prompt's default
recovery is *run the installer again*, not *repair the box by hand*. The one
documented exception is a checksum failure, which leaves an empty version
directory that a naive re-run would adopt; the prompt says exactly which two
paths to delete first.

### D6. What onboarding must extract

This is the list the wizard was reaching for. The wizard, as built, asked the
owner exactly one question (connect GitHub storage, or stay local) and guessed
the rest: the name came from the Telegram profile, the timezone from a language
code, and the "focus" was a hardcoded string. That is why it did not feel like
being met.

What the agent asks instead, and where each answer lands:

| Fact | Where it goes | Why it matters on day one |
|---|---|---|
| Name, preferred address | `memory/owner.md` | the agent addresses a person, not a chat id |
| Timezone | `memory/owner.md`, and the routine it schedules | everything on a cron is wrong without it |
| Working language | `CLAUDE.md` | the node answers in the owner's language from the first message |
| The two or three jobs wanted first | `CLAUDE.md`, and a first task in chat | the difference between useful in a day and a toy for a week |
| Quiet hours, what is worth interrupting for | `memory/owner.md` | an assistant that pings at 02:00 gets muted once and never unmuted |
| Standing consent (what it may do unasked) | `CLAUDE.md` | otherwise every action becomes a question, or none does |
| People, systems and repos that come up daily | `memory/owner.md` | recognition without re-explanation |
| The node's own body: paths, unit, port, profile, what is still open | `memory/node.md` | the next session knows where it lives |

All of it is repository state, not node settings, and that is the point: the
repository is the brain, it travels, and it survives the node being rebuilt. The
node's settings surface (`agentos ctl settings`) carries five operational keys
and is the wrong home for any of this.

### D7. How this sits next to the bot-led wizard

The wizard is being removed by a separate task in the node's repository. This
channel does not depend on that happening, and does not break if it is delayed —
the node's own gates take care of it:

- a filled `memory/owner.md` in the active context makes the wizard reply "done"
  and stop, instead of opening (`apps/api/src/core/onboarding/wizard.ts`,
  `isProfileFilled`). **This is the gate this channel relies on**, and Phase 3
  of the prompt exists partly to arm it;
- a context binding that is not the node's own local one makes the wizard skip
  permanently (`detectEstablishedNode`, `core/onboarding/local-context.ts`).
  That second gate does **not** fire on a fresh install through this channel:
  `AGENTOS_REPO_DIR` adoption registers the brain under the local-context owner
  (`core/db/bootstrap-contexts.ts`), so the node counts as established only once
  the owner connects GitHub. Which is why the first gate has to be armed and is
  not a belt-and-braces nicety.

So a node installed through this channel greets its owner as an already-known
person, wizard or no wizard. When the wizard is deleted, nothing here changes.

## Known gaps

Stated rather than hidden; none of them blocks the channel.

- **The brain is bound as a `local` context.** `AGENTOS_REPO_DIR` adoption
  creates a binding with `source_kind = 'local'`, and the node's repo-sync only
  pushes for `github` bindings. So the owner's repository receives the agent's
  accumulated changes only after a GitHub connect through the Mini App — until
  then the brain is read-forward, not written back. The fix belongs to the
  node (ClickUp 12418agf087), not here.
- **Adoption happens at boot**, and on a very first install the clone can land
  after the context registry has already been read. The prompt handles it with a
  verify-and-restart-once step; a node-side fix would make that unnecessary.
- **`--repo` is systemd-only.** On the container profile the installer warns and
  continues, so an agent installing with `--docker` has to place the brain
  another way. The prompt says so; it does not invent a workaround.
- **No exit code distinguishes the installer's failure classes.** Every curated
  failure is exit 1, so the prompt classifies by message text. Stable enough in
  practice, and the alternative — the agent guessing — is worse.
- **The prompt is not tested end to end.** CI checks that it cannot contradict
  `install.sh`; it does not prove that an agent following it reaches a healthy
  node. The first real run against a clean box is the acceptance, and it needs a
  human.
