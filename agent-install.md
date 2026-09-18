# Install AgentOS with a coding agent

**If you are a human, this file is not for you to follow — it is for you to
hand over.** You need a Linux box you can reach and a coding agent that can run
shell commands on it (Claude Code, Codex CLI, or any agent with a terminal).
Give that agent this file — paste it whole, or point it at

```
https://raw.githubusercontent.com/try-agent-os/agentos/main/agent-install.md
```

and answer the questions it asks. It installs the node, connects it to you, and
gives your agent the memory it starts from. If you would rather run one command
yourself, the [README](README.md) has it — this is a second channel, not a
replacement.

Everything below is addressed to the agent.

---

## What you are doing

You are installing an AgentOS node on this machine for the person talking to
you, and you are its onboarding: what a wizard would have asked in chat, you ask
here, and what it would have written into the node, you write.

Done means all four of these, not three:

1. `install.sh` finished with exit 0 and the node answers its health check.
2. The owner can talk to the bot in Telegram and is its admin.
3. The node has a brain — a git checkout it treats as its context — with the
   owner's profile in it, not an empty skeleton.
4. The owner knows what they have: where it lives, how to see logs, how to
   upgrade, and what is still missing.

## Rules that do not bend

**1. `install.sh` is the installer. You are not.** Exactly one thing puts
AgentOS on this box: `install.sh` from this repository. Do not download release
tarballs, do not unpack anything by hand, do not write a systemd unit, do not
start the image yourself. It verifies a SHA256 over the release tarball,
validates its sudoers drop-in with `visudo -cf`, refuses to follow planted
symlinks, and declines to move the version of an existing install. Hand-rolling
any step throws all of that away. If the script cannot do something you need,
that is a bug worth reporting at `try-agent-os/agentos`, not a gap for you to
fill.

**2. Download it, then run it — do not pipe it into a shell.**

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh \
  -o /tmp/agentos-install.sh
bash /tmp/agentos-install.sh --help
```

Two reasons. You get to read the same bytes you are about to run, and `--help`
only works this way: it prints its own header with `sed -n '2,97p' "$0"`, and in
a pipeline `$0` is the shell, not the script, so the help you most want is the
one thing the pipe cannot give you.

**3. That `--help` output outranks this file.** This prompt names flags and
describes behaviour as of writing. The script on `main` is the truth. Where they
disagree, the script wins, and say so to the owner rather than quietly doing
what this file said.

**4. Secrets do not travel through argv, chat, or a log.** The bot token, a
GitHub token and a Claude setup token are all secrets. Put them in a
`KEY=VALUE` env file with mode 0600 and hand that file to `--secrets`; the
script merges it into the node's `.env` without any value ever reaching `ps`, a
journal, or your own command line. The bot token may also come from
`$TELEGRAM_BOT_TOKEN` in your environment — the script reads it there. Never
echo a secret back, never write one into a file you are about to commit, and
treat your own transcript as secret-bearing once the owner has pasted one into
it.

**5. Never move an existing node's version.** If this box already has an
install, a re-run refreshes configuration and deliberately keeps the installed
version. Do not pass `--upgrade` to "get it current": moving versions runs
forward-only migrations against a live database, and `agentos upgrade` is the
path that snapshots it first and can roll back. Changing the owner's version is
their decision, asked for in words, never your tidiness.

**6. Ask before anything irreversible, act on everything else.** Creating a
GitHub repository, granting the service account root, opening a firewall port,
overwriting an existing `.env` — ask. Reading state, re-running the installer,
restarting the unit, fixing a file you wrote yourself — just do it and report.

---

## Phase 0 — Preflight

Gather facts before you ask the owner anything; several of the questions below
disappear once you know the box.

```bash
uname -m                                  # x86_64 or not
. /etc/os-release && echo "$PRETTY_NAME"  # Debian 12 / Ubuntu 24.04 wanted
id -u                                     # 0, or sudo must work
command -v apt-get systemctl curl
systemctl is-active agentos 2>/dev/null   # an install already here?
ls -d /opt/agentos 2>/dev/null
free -m | awk '/Mem:/{print $2" MB RAM"}'
df -h / | tail -1
```

Read it like this:

- **x86_64 + apt-get + systemd** → the default bare-metal profile. This is what
  you want: no Docker daemon, a vendored Node runtime, one systemd unit.
- **Anything else** (arm64, no apt) → the container profile, `--docker`. Say so
  to the owner, and note that `--repo` does not work there — the container has
  no service account to check out under.
- **An existing install** → you are refreshing a node, not creating one. Re-read
  rule 5, and ask the owner what they actually want before you run anything.
- **Less than ~1 GB RAM or a nearly full disk** → say it now. It will fail later
  and less clearly.

Then dry-run your intended command line. These three probes print a decision and
exit without touching the machine:

```bash
AGENTOS_PRINT_MODE=1 bash /tmp/agentos-install.sh <your flags>              # docker | systemd
AGENTOS_PRINT_IDENTITY=1 bash /tmp/agentos-install.sh <your flags>          # user|dir|unit|port
AGENTOS_PRINT_VERSION_DECISION=1 bash /tmp/agentos-install.sh <your flags>  # install | keep | upgrade
```

If `AGENTOS_PRINT_MODE` says `docker` when you expected `systemd`, you passed a
container-only flag (`--tunnel-token`, `--quick`, `--image`, or a `--channel`
other than `stable`) — they switch profiles silently. If
`AGENTOS_PRINT_VERSION_DECISION` says anything but `install`, there is already a
node here. Stop and go back to rule 5.

## Phase 1 — Ask the owner

Ask in one pass, grouped, with the reason attached — not as a twenty-question
interrogation. Everything you do not ask here you either derive or do without;
do not invent an answer to a question in group A.

**A. What the install cannot proceed without**

| Ask | Why it cannot be derived |
|---|---|
| The bot token from [@BotFather](https://t.me/BotFather) (`/newbot`) | It is created by a human in Telegram. The installer never validates it against Telegram — a wrong but well-formed token installs "fine" and the bot stays silent. |
| Their numeric Telegram id from [@userinfobot](https://t.me/userinfobot), or their username | It becomes `--admin`. **Always pass it.** With no admin the node is UNCLAIMED and the first stranger who DMs it becomes its owner, once, with no time limit. |
| Mini App, or bot only? | `--domain <host>` needs an A record already pointing at this box and ports 80+443 open; Caddy then gets a Let's Encrypt certificate. `--no-https` is a complete install — the bot long-polls Telegram and works behind NAT — it only costs the Mini App, which Telegram opens on a public `https` origin or not at all. Ask which they have, do not guess, and pass exactly one of the two: these flags are last-one-wins, not mutually exclusive, so passing both silently keeps only the last. |
| May the node have passwordless root on this box? | The default install grants the service account exactly that, because administering the box is the job. It is the one consent in this flow that cannot be taken back quietly. If the box hosts anything else, offer `--scoped-sudo`, which narrows the grant to restart/status/journal on its own unit. |

**B. The brain**

The node keeps its context in a git repository — charter, memory, skills,
routines. Offer three, in this order:

1. **A new repo from the template** —
   [`try-agent-os/claude-code-template`](https://github.com/try-agent-os/claude-code-template),
   private. The best default. Needs a GitHub token with `repo` scope (or a
   `gh auth status` that is already good).
2. **A repo they already have.** Take the clone URL.
3. **Local for now** — a checkout on this box only. It works; it just means the
   brain lives on one disk and dies with it.

**C. The owner — this is the onboarding, and it is the part with no flag**

Nothing below reaches the node unless you put it there. Ask it as a
conversation, not a form, and write down what you get:

- **Name, and what to call them.**
- **Timezone.** Everything scheduled keys off it. Ask; do not guess it from a
  language code.
- **Working language** — the language the agent should answer in.
- **What they want it doing first** — two or three concrete jobs. This is the
  difference between a node that is useful in a day and one that is a toy for a
  week.
- **When to speak and when not to** — quiet hours, what is worth interrupting
  for, what should wait for a digest.
- **What it may do without asking** — the standing consent. Default: reversible
  things yes, outward-facing or destructive things no.
- **Who and what it should recognise** — the two or three people, systems or
  repos that come up daily.

Two more, only if they already exist; never talk anyone into creating one now:

- A **Claude setup token** (`claude setup-token`, run on *their own* machine,
  never here) or an `ANTHROPIC_API_KEY`. Browser OAuth from a rented VPS does
  not work — Anthropic refuses the flow from datacenter IPs — so a token they
  generate locally is the path that actually completes. If they have one, it
  goes in the secrets file and the node is thinking from its first minute; if
  not, they connect it from Telegram in Phase 5.
- A **GitHub token** if you are creating or cloning a repo for them.

## Phase 2 — Write the secrets file

One file, mode 0600, outside any repository, deleted when you are done:

```bash
umask 077
cat > /root/agentos-secrets.env <<'EOF'
GH_TOKEN=<github token, if any>
CLAUDE_CODE_OAUTH_TOKEN=<claude setup token, if any>
AGENTOS_REPO_DIR=/opt/agentos/repos/<repo-name>
EOF
chmod 600 /root/agentos-secrets.env
```

Three things are going on here, and only the first is obvious.

`GH_TOKEN` is what the installer authenticates git with (`gh auth setup-git`)
before cloning anything you passed to `--repo`. `CLAUDE_CODE_OAUTH_TOKEN` is the
supported way to give a node its Claude credentials without a browser.
`AGENTOS_REPO_DIR` is how the node learns which checkout is its brain: on a boot
where its context registry is still empty, it adopts that directory — in place,
read-only, nothing scaffolded — as its active context. The installer preserves
the key across every re-run but never sets it, so this file is where it belongs.

Set `AGENTOS_REPO_DIR` to `<install-dir>/repos/<name>`, where `<name>` is the
repository name with no `.git` — that is exactly where `--repo` clones. For the
default install and a repo called `my-agent` that is
`/opt/agentos/repos/my-agent`.

For the **local-only** brain, create the checkout yourself before installing —
`git init`, the template's layout, a first commit — and point `AGENTOS_REPO_DIR`
at it. A directory without `.git` is not adopted; it is skipped with a line in
the log saying so.

## Phase 3 — Create the brain

Skip this if the owner brought their own repo; use their URL instead.

```bash
gh repo create <owner>/<name> --private --template try-agent-os/claude-code-template
gh repo clone <owner>/<name> /tmp/brain
```

Fill it in from Phase 1C, in the two files the template keeps for exactly this:

- **`memory/owner.md`** — copy `memory/owner._template.md` and write the real
  answers into it: name, preferred name, timezone, role, how they want updates
  delivered, what they are working on now, the people who matter. Short and
  true beats long and padded.
- **`CLAUDE.md`** — the charter. Set the working language, name the two or three
  jobs from Phase 1C, and write the standing consent as a rule the agent can
  actually apply ("act on reversible things and report; ask before anything
  outward-facing").

Then commit and push. Do not put a token, a key, or anything from the secrets
file in this repository.

That filled `memory/owner.md` is load-bearing beyond being useful: the node's
own chat onboarding treats a filled owner profile as proof that onboarding
already happened and stands down instead of re-asking. Leave the template's
placeholders in place and the owner gets greeted by a wizard for work you
already did.

## Phase 4 — Install

One command, all flags decided, nothing interactive:

```bash
bash /tmp/agentos-install.sh \
  --admin <telegram-id-or-username> \
  --no-https \
  --repo https://github.com/<owner>/<name>.git \
  --secrets /root/agentos-secrets.env \
  -y
```

with `TELEGRAM_BOT_TOKEN` exported in the environment of that command (or
`--token <token>` if you must, accepting that it lands in `ps`). Swap
`--no-https` for `--domain <host>` if the owner has DNS ready. Add `--docker`
only if Phase 0 said the bare-metal profile cannot run here, and drop `--repo`
when you do — it is a systemd-mode flag and the container profile only warns.
`-y` turns a missing answer into an error instead of a hang.

It takes a few minutes: apt packages, the release tarball and its checksum, a
vendored Node runtime, the Claude Code CLI, the unit, then a health gate that
polls `http://127.0.0.1:<port>/healthz` for up to 90 seconds.

**Assert the finish, do not eyeball it.** All four:

```bash
echo "exit=$?"                                   # 0
# stdout contained the literal: AgentOS Node is running.
systemctl is-active agentos                      # active
curl -fsS http://127.0.0.1:8787/healthz          # 200
```

Also read what the banner says about your own flags. If it printed
`installed <old>; channel has <new> — keeping <old>`, you were refreshing an
existing node and rule 5 applies. If it printed the UNCLAIMED warning, `--admin`
did not take — tell the owner to DM the bot *now*, before anyone else does.

## Phase 5 — Connect the owner

Two steps only the human can do. Do not fake progress here; ask, then verify.

1. **Claim the node.** Ask them to DM the bot and send `/start`. Confirm they
   got an answer. A silent bot after a successful install is almost always a
   wrong token or another process polling the same bot.
2. **Connect the thinking** — unless you placed a token in Phase 2. In the DM:
   `/login` (admin only, private chat). Check it landed:

```bash
agentos ctl status --json    # version, uptime, harness, live runs
```

If they have no credential at all and no way to make one right now, say plainly
what that means: the node runs, routines tick, and every agent reply fails with
"Not logged in" until `/login` happens.

Then verify the brain actually got adopted — it is the step with the quietest
failure:

```bash
agentos logs 500 | grep -i 'contexts'
ls -la /opt/agentos/repos/<name>
```

You are looking for a line saying `AGENTOS_REPO_DIR` was adopted as the local
context. If instead you see that it was skipped as "not a git checkout", the
clone did not happen — check the `--repo` warning in the install output, the
token's scope (`repo`, `read:org`) and the URL, fix it, and re-run the
installer. If the directory is a good checkout and the log says nothing at all,
restart once (`agentos ctl restart --reason "adopt context"`) and look again:
adoption happens at boot, and on a very first install the checkout can arrive
after the registry has already been read.

## Phase 6 — Make it useful today

The node is running and knows who it belongs to. Give it one thing to do and
one way you know it works.

- **Harness**, if the owner is on Codex rather than Claude:
  `agentos ctl harness set codex-acp` (`claude-sdk`, `claude-acp`, `codex-acp`,
  `opencode` are the values; `agentos ctl harness get` shows the current one).
- **A first routine**, from the shipped catalog rather than hand-written YAML:

```bash
agentos preset ls
agentos preset add daily-brief hour=8 minute=0 --repo /opt/agentos/repos/<name>
```

  It writes the routine into the brain repo, where the owner can read and edit
  it like any other file. Use their timezone and their hour from Phase 1C.
- **One real task, in the chat**, chosen from what they said they wanted first.
  A first success in Telegram is worth more than any explanation you could give.

## Phase 7 — Hand it over

Write the handover twice: once to the owner in their own words, once into the
brain repo — as `memory/node.md` — so the node knows its own body on the next
session. Both say the same things:

- Install root, service account, unit name, port, profile (bare metal or
  container), version installed, and whether HTTPS is on.
- `agentos status` · `agentos logs` · `agentos ctl status` · `agentos backup` ·
  `agentos upgrade` · `agentos rollback` — and that `agentos status` is "is the
  unit up" while `agentos ctl status` is "what is the node doing".
- Where their data lives and that nothing backs it up off this box. `agentos
  upgrade` snapshots before it moves; `agentos backup` is the manual one. An
  off-host copy is theirs to arrange.
- What is still open: DNS or the Mini App if they chose `--no-https`, `/login`
  if it did not happen, a repo still local-only.
- That the service account has passwordless root, if it does, in one plain
  sentence.

Then delete the secrets file (`shred -u /root/agentos-secrets.env`, or `rm`) and
`/tmp/agentos-install.sh`, and say that you did. Note that the node's `.env`
keeps its own copy at mode 0600 — that is where they live now.

---

## When a step fails

The installer has no rollback and no cleanup trap, by design: whatever
completed stays completed, and re-running is the normal repair. Curated failures
exit 1 with a red `✗ ` line on stderr; everything else fails with the underlying
command's own status and message. Read the message — it usually names the fix.

| What you see | What it is | What you do |
|---|---|---|
| `unknown option`, `--user: expected…`, `--port: expected…`, `--secrets: no such file`, `--admin: … is neither of the two accepted forms` | Your own argv. Nothing was touched. | Fix and re-run. Never ask the owner to re-answer something you mangled. |
| `run as root, or install sudo.` / `sudo failed` | No privileges. Nothing was touched. | Get root, or say you cannot. |
| `the bare-metal node needs x86_64…` / `needs an apt-based distro…` | Wrong host for this profile. Nothing was touched. | Re-run with `--docker`, and tell the owner what that changes. |
| `cannot resolve the stable channel`, a curl failure on the tarball or the Node runtime | Network or GitHub. Packages may be installed; nothing else is. | Retry once. Still failing: report it as an outage, do not hand-download anything. |
| `tarball checksum mismatch` | **Stop.** A release tarball that does not match its SHA256 is not a thing to work around. | Delete `<install-dir>/versions/<tag>` and the tarball left in `/tmp` before any retry — the version directory was already created, and a naive re-run skips the download and points `current` at an empty tree. Then retry once. If it repeats, report it and stop; never disable the check. |
| `node did not become healthy` (the last 50 journal lines were printed above it) | The unit is installed and enabled; the node did not answer `/healthz` in ~90 s. | Read that dump first. Then `journalctl -u agentos -n 200 --no-pager` and `tail -200 /opt/agentos/logs/node.log` — note that `/usr/local/bin/agentos` is not created until after the health gate, so the CLI is not there yet. A wrong value in `.env` and a port already taken are the common causes. Fix the cause and re-run the installer; it is cheap the second time. |
| `docker install failed`, `docker daemon is not reachable` | Docker, not AgentOS. | Follow the message, or drop `--docker` if the box can take the bare-metal profile. |
| `install did not finish cleanly… your .env and data are kept` (container profile) | Same class as the health timeout. | Read the container's last log lines, fix, re-run. |
| `! git clone <name> failed`, `! gh auth setup-git failed` | **Warnings, not failures.** The install succeeded; the brain did not arrive. | Check the token scope (`repo`, `read:org`) and the URL, then re-run the installer — `--repo` is re-run safe and fetches when the checkout is already there. |
| `! that token does not look like a @BotFather token` | Shape check only; the installer never asks Telegram. | Let it finish, then verify by having the owner DM the bot. Silence means the token. |
| The bot is silent, everything else is green | Wrong token, or another process is polling the same bot. | Ask whether this bot is running anywhere else. Two pollers is the usual answer. |

Three habits that decide whether this goes well:

- **Re-run the installer rather than repairing by hand.** It is idempotent,
  keeps `.env` and data, skips work already done, and never moves the version.
  Hand-repair is how a box ends up in a state nobody can reproduce.
- **Stop on anything that smells like integrity.** A checksum mismatch, a
  certificate error, a suggestion to skip verification: report and stop. That is
  not a step you are authorised to route around.
- **Never say a phase passed because it probably did.** Every phase here has a
  command that answers yes or no. Run it.
