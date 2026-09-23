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
   Exit 3 is not done: the node runs, but without the root it was promised
   (Phase 4).
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
validates its sudoers drop-in with `visudo -cf`, checks the directories it
creates against planted symlinks, and declines to move the version of an
existing install. (It does not yet close every link: the step that writes the
merged secrets into `.env` still writes through a name the service account can
reach — the script says so in its own comments, and it is filed as a bug. That
is one more reason to let the script own the box, not a reason to trust a
hand-rolled copy more.) Hand-rolling
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
echo a secret back, never write one into a file you are about to commit.

**The default is that a secret never enters your context at all.** Do not ask
the owner to paste a token into this conversation. Have it piped from their
clipboard or a file straight into the secrets file (Phase 2 shows how), and
read it from that file only inside the command that needs it. If the owner
pastes one into the chat anyway, use it, but treat your own transcript as
secret-bearing from then on and tell them the token should be rotated once the
node works.

**7. One bot token, one live node.** Telegram hands each update to exactly one
poller. Two processes on the same token — a rehearsal install and the real one,
an old box and a new one, a node and a script on the owner's laptop — fight over
`getUpdates`, and the visible symptom is a bot that answers sometimes or never.
Do not "rehearse, then install for real" with the owner's token: rehearse with a
second throwaway bot from @BotFather, or not at all. Before you install, ask
whether this token already runs anywhere, and if it does, have that process
stopped first.

**5. Never move an existing node's version.** If this box already has an
install, a re-run refreshes configuration and deliberately keeps the installed
version. Do not pass `--upgrade` to "get it current". The reason is not that
`--upgrade` is unsafe everywhere: on the default (bare-metal systemd) profile it
hands the version change to `agentos upgrade`, with the same pre-upgrade
snapshot and health-gated auto-rollback. On the `--docker` profile it does not —
there it moves the image under a live database whose migrations only run
forward, and `agentos upgrade` is the path that backs the data up first. Either
way, changing the owner's version is their decision, asked for in words, never
your tidiness.

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
command -v visudo                         # empty → install.sh must install sudo
systemctl list-units 'agentos*'           # an install already here? (any instance)
ls -d /opt/agentos* 2>/dev/null
free -m | awk '/Mem:/{print $2" MB RAM"}'
df -h / | tail -1
findmnt -no SOURCE,FSTYPE,OPTIONS /       # will the root filesystem survive a reboot?
hostname
```

Read it like this:

- **The root filesystem must be persistent.** Everything can install and every
  check can go green on a rescue or live system, and none of it survives a power
  cycle. Stop and tell the owner if `findmnt` shows `tmpfs`, `ramfs` or
  `squashfs`, if its source is not a real block device (`/dev/…`, an LVM or
  RAID volume), or if it shows `overlay` — and read the options, not only the
  type: a rescue system can report `overlay` with the writable layer in RAM
  (`upperdir=/ramfs/root` or anything under `/run`, `/tmp` or a `ramfs`). A
  hostname like `rescue` is the same warning. Ask the owner to boot the
  installed OS first; do not install into RAM.
- **x86_64 + apt-get + systemd** → the default bare-metal profile. This is what
  you want: no Docker daemon, a vendored Node runtime, one systemd unit.
- **Anything else** (arm64, no apt) → the container profile, `--docker`. Say so
  to the owner, and note that `--repo` does not work there — the container has
  no service account to check out under.
- **An existing install** → you are refreshing a node, not creating one. Re-read
  rule 5, and ask the owner what they actually want before you run anything.
- **Less than ~1 GB RAM or a nearly full disk** → say it now. It will fail later
  and less clearly.
- **No `visudo`** → the node's root comes from a sudoers drop-in that
  `install.sh` validates with `visudo -cf`, so without it there is no root.
  Warn the owner now: on an apt host the installer installs the `sudo` package
  itself and carries on; without apt it cannot, the install ends with exit 3,
  and you must not report this node as having root. One trap: `visudo` lives in
  `/usr/sbin`, which a non-root shell on Debian often leaves off `PATH`, and the
  installer looks for it on the `PATH` of the shell you run it from. If
  `command -v visudo` is empty but `ls /usr/sbin/visudo` finds it, run
  `export PATH="$PATH:/usr/sbin:/sbin"` in the shell that will run Phase 4.

Then dry-run your intended command line. These two probes read your flags, print
a decision and exit without touching the machine:

```bash
AGENTOS_PRINT_MODE=1 bash /tmp/agentos-install.sh <your flags>      # docker | systemd
AGENTOS_PRINT_IDENTITY=1 bash /tmp/agentos-install.sh <your flags>  # user|dir|unit|port
```

Drop `--secrets` from the flags you probe with. Argument validation runs before
these probes print anything, and a `--secrets` file that does not exist yet
(you write it in Phase 2) ends the probe with `✗ --secrets: no such file`. The
flags that decide profile and identity are the other ones anyway.

If `AGENTOS_PRINT_MODE` says `docker` when you expected `systemd`, either you
passed a container-only flag (`--tunnel-token`, `--quick`, `--image`, or a
`--channel` other than `stable`) — they switch profiles silently — or this box
already carries a Docker install, which pins the profile on its own and says so
(`existing Docker install in <install-dir>`). To go from that Docker install
back to bare metal, pass `--no-docker` explicitly — it is the only thing that
migrates the profile; without it a re-run stays on the container.

**Capture the identity once, and use only these values from here on.** The
install root defaults to `/opt/<user>`, not to `/opt/agentos`; the unit, the
port and the CLI name all follow `--user`, `--dir` and `--port`. Read them from
the probe instead of assuming the defaults:

```bash
IFS='|' read -r AOS_USER AOS_DIR AOS_UNIT AOS_PORT \
  < <(AGENTOS_PRINT_IDENTITY=1 bash /tmp/agentos-install.sh <your flags>)
echo "user=$AOS_USER dir=$AOS_DIR unit=$AOS_UNIT port=$AOS_PORT"
```

The rest of this file calls them `<install-dir>` (`$AOS_DIR`), `<unit>`
(`$AOS_UNIT`) and `<port>` (`$AOS_PORT`). The CLI is `agentos` for the default
account and `agentos-<user>` for a named one; every `agentos …` command below
means whichever of the two this install has. For a plain install they come out
as `/opt/agentos`, `agentos` and `8787` — that is a result of the probe, not
something to write down in advance. Shell variables do not survive between your
tool calls in every agent, so write the four values into your notes, not only
into the shell.

**Whether a node is already installed is a question about the box, not about
your flags.** Ask the box, using the directory the identity probe just printed:

```bash
sudo readlink <install-dir>/current   # prints the installed version tag, or nothing
```

Anything printed means there is already a node here: rule 5 applies, you are
refreshing and not creating, and the version stays where it is.

There is a third probe, `AGENTOS_PRINT_VERSION_DECISION`, and it is easy to
misread. It evaluates the keep-or-move rule as a pure function of
(channel tag, installed tag, `--upgrade`) — fed by `AGENTOS_TEST_CHANNEL_TAG`
and `AGENTOS_TEST_INSTALLED_TAG`, not by looking at this machine. Run it with
neither set and it prints `install` on a box that already runs a node. Use it
only to confirm what the rule does with tags you have already read yourself:

```bash
AGENTOS_TEST_INSTALLED_TAG="$(sudo readlink <install-dir>/current | xargs -r basename)" \
AGENTOS_TEST_CHANNEL_TAG="<the tag the channel offers>" \
AGENTOS_PRINT_VERSION_DECISION=1 bash /tmp/agentos-install.sh <your flags>
# install <tag> | keep <installed> | upgrade <installed> <tag>
```

The authoritative answer on a real run is the installer's own banner in Phase 4
(`installed <old>; channel has <new> — keeping <old>`), which it prints from the
same function after resolving both tags for itself.

## Phase 1 — Ask the owner

Ask in one pass, grouped, with the reason attached — not as a twenty-question
interrogation. Everything you do not ask here you either derive or do without;
do not invent an answer to a question in group A.

**A. What the install cannot proceed without**

| Ask | Why it cannot be derived |
|---|---|
| That they have a bot token from [@BotFather](https://t.me/BotFather) (`/newbot`), and that it runs nowhere else | It is created by a human in Telegram. The installer never validates it against Telegram — a wrong but well-formed token installs "fine" and the bot stays silent. Ask them to *have* it, not to paste it here: it goes into the secrets file by the path in Phase 2 (rule 4). A token already live on another box or script is two pollers (rule 7). |
| Their numeric Telegram id from [@userinfobot](https://t.me/userinfobot), or their username | It becomes `--admin`. **Always pass it.** With no admin the node is UNCLAIMED and the first stranger who DMs it becomes its owner, once, with no time limit. |
| Mini App, or bot only? | `--domain <host>` needs an A record already pointing at this box and ports 80+443 open; Caddy then gets a Let's Encrypt certificate. `--no-https` is a complete install — the bot long-polls Telegram and works behind NAT — it only costs the Mini App, which Telegram opens on a public `https` origin or not at all. Ask which they have, do not guess, and pass exactly one of the two. The script does not reject both, and the result is not clean either way round: `--no-https` switches Caddy off but leaves the domain set, so `MINIAPP_URL=https://<domain>/app` still lands in `.env` — no certificate, and a Mini App button that points nowhere. |
| May the node have passwordless root on this box? | The default install grants the service account exactly that, because administering the box is the job. It is the one consent in this flow that cannot be taken back quietly. If the box hosts anything else, offer `--scoped-sudo`, which narrows the grant to restart/status/journal on its own unit. |

**B. The brain**

The node keeps its context in a git repository — charter, memory, skills,
routines. Offer three, in this order:

1. **A new repo from the template** —
   [`try-agent-os/claude-code-template`](https://github.com/try-agent-os/claude-code-template),
   private. The best default. Needs a GitHub token with `repo` scope (or a
   `gh auth status` that is already good), and two names Phase 3 cannot
   derive: the **owner** — their GitHub username or the organisation the repo
   belongs in — and the **repository name** (suggest something like
   `my-agent`, and let them change it). Ask for both now; `gh repo create
   <owner>/<name>` needs them, and the name also fixes the checkout path in
   Phase 2.
2. **A repo they already have.** Take the clone URL. Phase 3 still writes the
   charter and the owner profile into it if they are missing, so the GitHub
   token needs write access to it too.
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
  never here) or an `ANTHROPIC_API_KEY`. Neither is required, and neither is
  the better path: `/login` from Telegram in Phase 5 works from a rented VPS
  too (the node runs the login in a terminal of its own and hands the owner the
  URL), and it gives the node full `claude.ai` credentials. A setup token can
  only make model requests — no Remote Control sessions, no `claude.ai`
  connectors. If they already have a token and want the node thinking from its
  first minute, it goes in the secrets file; otherwise leave it out and use
  `/login`.
- A **GitHub token** if you are creating or cloning a repo for them.

## Phase 2 — Write the secrets file

One file, mode 0600, outside any repository, deleted when you are done. Put it
in the home directory of the account you are running as — `/root` only if that
account is root; Phase 0 accepts a non-root operator with sudo, and that
operator cannot write to `/root`:

```bash
SECRETS="$HOME/agentos-secrets.env"
umask 077
printf 'AGENTOS_REPO_DIR=%s\n' "<install-dir>/repos/<repo-name>" > "$SECRETS"
chmod 600 "$SECRETS"
```

The secrets go in next, **without passing through your context**. Each value
is piped from where the owner already has it — their clipboard or a file —
straight onto the end of that file, so it never appears in this conversation,
in argv or in `ps`. If you are working on the owner's own machine and reach
the box over ssh, run this there (`pbpaste` on macOS; `wl-paste` or
`xclip -o -selection clipboard` on Linux), once per secret, after the owner has
copied it:

```bash
{ printf 'TELEGRAM_BOT_TOKEN='; pbpaste; echo; } \
  | ssh <box> 'umask 077; cat >> ~/agentos-secrets.env'
```

On the box itself, the same shape reads from a file the owner dropped there:
`{ printf 'GH_TOKEN='; cat <file>; echo; } >> "$SECRETS"`. Only if neither
works do you fall back to the owner pasting into chat — rule 4 says what that
costs. The keys that belong in this file:

| Key | When |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Always. Phase 4 reads it from here into the installer's environment. |
| `GH_TOKEN` | If you are creating or cloning a repo. |
| `CLAUDE_CODE_OAUTH_TOKEN` | If the owner has a Claude setup token. |
| `AGENTOS_REPO_DIR` | Always, unless there is no brain yet (written above). |

Check the result by key names only — never print the file:
`sed -n 's/=.*//p' "$SECRETS"`.

Four things are going on here, and only the first is obvious.

`TELEGRAM_BOT_TOKEN` in this file is not enough on its own for a first install:
the installer asks for the bot token before it merges `--secrets`, so with `-y`
and no token in its environment it stops with `a bot token is required.` That
is why Phase 4 lifts it from this file into the installer's environment.

`GH_TOKEN` is what the installer authenticates git with (`gh auth setup-git`)
before cloning anything you passed to `--repo`. If the token has to live under
another key, `--gh-token-key <KEY>` names it (default: `GH_TOKEN`, then
`GITHUB_TOKEN`). `CLAUDE_CODE_OAUTH_TOKEN` is the
supported way to give a node its Claude credentials without a browser.
`AGENTOS_REPO_DIR` is how the node learns which checkout is its brain: on a boot
where its context registry is still empty, it adopts that directory — in place,
read-only, nothing scaffolded — as its active context. The installer preserves
the key across every re-run but never sets it, so this file is where it belongs.

Set `AGENTOS_REPO_DIR` to `<install-dir>/repos/<name>`, where `<name>` is the
repository name from Phase 1B with no `.git` — that is exactly where `--repo`
clones. For a plain install and a repo called `my-agent` that comes out as
`/opt/agentos/repos/my-agent`, but take `<install-dir>` from the probe.

For the **local-only** brain, create the checkout yourself before installing —
`git init`, the template's layout, a first commit — and point `AGENTOS_REPO_DIR`
at it. Phase 3B then fills its required files in place. A directory without
`.git` is not adopted; it is skipped with a line in the log saying so.

## Phase 3 — The brain

Two parts, and only the first one is optional. **3A creates the repository**;
skip it when the owner brought their own. **3B fills the files that make a
repository a brain**, and it is never skipped — whichever of the three Phase 1B
options the owner picked. An existing repository is the case that needs 3B the
most: it arrives with whatever its owner happened to put in it, which is usually
no charter and no owner profile at all.

### 3A. Create the repository (skip if they brought their own)

`<owner>` and `<name>` are the two names you asked for in Phase 1B; do not
guess the owner from `gh api user` when the owner said an organisation.

- **A new repo from the template:**

  ```bash
  gh repo create <owner>/<name> --private --template try-agent-os/claude-code-template
  gh repo clone <owner>/<name> /tmp/brain
  ```

- **A repo they already have:** no creation, only a working copy for 3B —
  `gh repo clone <their-url> /tmp/brain`. Their URL is what `--repo` gets in
  Phase 4.
- **Local for now:** the checkout you created in Phase 2 *is* the brain. Work in
  it directly wherever 3B says `/tmp/brain`.

### 3B. Fill the required files (never skip)

First look at what is there — do not assume the template's layout, and do not
assume it is missing either:

```bash
cd /tmp/brain
for f in CLAUDE.md memory/owner.md memory/owner._template.md; do
  [ -f "$f" ] && echo "HAVE $f" || echo "NO   $f"
done
```

Two files are required, and what you do with each depends on that listing. An
existing file is the owner's: complete it, never replace it.

- **`memory/owner.md`** — missing: copy `memory/owner._template.md` if the repo
  has one, or create `memory/` and the file yourself with the frontmatter shown
  below. Present: keep its body and fill only what is empty. Either way, write
  the real answers from Phase 1C into it: name, preferred name, timezone, role,
  how they want updates delivered, what they are working on now, the people who
  matter. Short and true beats long and padded.

  **Fill the YAML frontmatter, not only the prose below it.** The template opens
  with a fence of empty strings, and the node reads exactly three keys out of
  it — `name`, `preferred_name`, `timezone` — to decide whether this owner has
  been onboarded. Prose in the body, however good, does not count:

  ```
  ---
  name: "Vasily Krylov"
  role: "founder"
  timezone: "Europe/Amsterdam"
  preferred_name: "Vasily"
  ---
  ```

  Keep the fence as the very first thing in the file (a stray blank line above
  it and the file parses as having no frontmatter at all), and leave no required
  value empty or whitespace. Everything else you learned in Phase 1C goes in the
  body sections, where it is for the agent to read rather than for a predicate
  to check.
- **`CLAUDE.md`** — the charter. Set the working language, name the two or three
  jobs from Phase 1C, and write the standing consent as a rule the agent can
  actually apply ("act on reversible things and report; ask before anything
  outward-facing"). Missing: write it. Present — the owner's own repo often has
  one written for other work: leave what is there, add what is not (language,
  jobs, consent) as a section of its own, and tell the owner what you added.

Check the result before you commit, not after the node has greeted anyone:

```bash
head -n 1 memory/owner.md                       # exactly: ---
awk 'NR>1 && /^---$/ {exit} NR>1' memory/owner.md \
  | grep -E '^(name|preferred_name|timezone):'  # three lines, none of them ""
test -s CLAUDE.md && echo "charter ok"
```

Then commit and push — before Phase 4, because `--repo` clones whatever is on
the remote at that moment, and a brain that reaches the node without these two
files is exactly the adoption this part exists to prevent. For a local-only
brain, commit; there is nothing to push. If the push to the owner's own repo is
refused (a token without write access, a protected default branch), do not
install around it: tell the owner which of the two they need to change, or
offer the template path instead. Do not put a token, a key, or anything from
the secrets file in this repository.

That filled `memory/owner.md` is load-bearing beyond being useful: the node's
own chat onboarding treats a filled owner profile as proof that onboarding
already happened and stands down instead of re-asking. Leave those three
frontmatter values empty and the owner gets greeted by a wizard for work you
already did.

## Phase 4 — Install

One command, all flags decided, nothing interactive:

```bash
TELEGRAM_BOT_TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$SECRETS" | tail -1)" \
bash /tmp/agentos-install.sh \
  --admin <telegram-id-or-username> \
  --no-https \
  --repo https://github.com/<owner>/<name>.git \
  --secrets "$SECRETS" \
  -y 2>&1 | tee /tmp/agentos-install.log
echo "exit=${PIPESTATUS[0]}"
```

The `tee` keeps the installer's output in `/tmp/agentos-install.log`, and
`PIPESTATUS[0]` is the installer's own exit status, not `tee`'s — a plain `$?`
after the pipe reports `tee`. Read it in the same tool call as the install:
it is gone by the next one. Both are what Phase 4 asserts below.

The first line puts the bot token into the installer's environment straight
from the secrets file: it never reaches argv, `ps` or your transcript. Run it
as yourself, not under `sudo` — the installer escalates on its own, and `sudo`
would strip that variable. (`--token <token>` also works, accepting that the
token then lands in `ps` and in your context.) Keep every flag you probed with
in Phase 0 — a `--user`, `--dir` or `--port` dropped here installs somewhere
other than `<install-dir>`. Swap
`--no-https` for `--domain <host>` if the owner has DNS ready. Add `--docker`
only if Phase 0 said the bare-metal profile cannot run here, and drop `--repo`
when you do — it is a systemd-mode flag and the container profile only warns.
`-y` turns a missing answer into an error instead of a hang.

Flags this command does not need by default, but you should know exist
(`--help` has the full wording):

- `--user <name>` and `--port <n>` — a second node on the same box: its own
  service account, install root, unit and port. Pass both, or neither.
- `--dir <path>` — the install root, when `/opt/<user>` is wrong for this box
  (a separate data disk, say). It moves `<install-dir>`; re-probe after adding it.
- `--no-docker` — the bare-metal profile. It is the default on a clean box, so
  you pass it only for one reason: this box already carries a Docker install,
  and the owner wants it moved back to bare metal. Without the flag a re-run
  stays on Docker.
- `--gh-token-key <KEY>` — which key in the merged `.env` holds the GitHub token
  for `gh auth setup-git` and the `--repo` clones, when it is not `GH_TOKEN` or
  `GITHUB_TOKEN`.
- `--secret-reader <user>` — a host account (a backup job, a monitor) that must
  keep read access to `<install-dir>/secrets` across updates. Repeatable,
  bare-metal only, needs `acl`. Pass it only if the owner names such an account.

It takes a few minutes: apt packages, the release tarball and its checksum, a
vendored Node runtime, the Claude Code CLI, the unit, then a health gate that
polls `http://127.0.0.1:<port>/healthz` — 45 attempts two seconds apart, so up
to roughly two minutes before it gives up.

**Assert the finish, do not eyeball it.** Five things must hold, and the first
two are gone if you do not capture them: the installer's **exit status is 0**,
and its stdout contained the literal `AgentOS Node is running.` — ANSI colour
wraps that line, so match the substring, not the whole line. Then, independently
of what it printed:

```bash
systemctl is-active <unit>                       # active
curl -fsS http://127.0.0.1:<port>/healthz        # exits 0
! grep -q 'sudoers drop-in was NOT installed' /tmp/agentos-install.log  # exits 0
```

Both values come from the identity probe in Phase 0; a named instance's unit is
`agentos-<user>`, not `agentos`. The fifth check is the node's root: the
installer writes that line whenever its sudoers drop-in did not land, and the
node then has no root however green the other four look.

**Exit 3 means "the node runs, but it has no root".** Only the bare-metal
(systemd) profile returns it: the unit is up and `/healthz` answers, but the
sudoers drop-in could not be installed — no `visudo`, a render `visudo -cf`
rejected, or an unwritable `/etc/sudoers.d`. The closing headline then reads
`AgentOS Node is up, but WITHOUT HOST AUTHORITY` instead of `AgentOS Node is
running.`, and a `!! NO HOST AUTHORITY` banner below it names the reason on its
`Why:` line. That is exactly what you report to the owner: the node is running,
it does not have root, and why, in the banner's words. Never report it as
installed with root. The banner's fix is to install the `sudo` package and
re-run the installer with the same flags; a re-run that ends with exit 0 and
all five checks green is done. Any exit status other than 0 or 3 is a failed
install — see "When a step fails".

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
   `/login` (admin only, private chat). The proof it took is a real answer to a
   real message, not the absence of an error: ask them to send the bot something
   that needs thinking and confirm what came back. The node's own view of itself
   is one command away, and costs no model tokens:

```bash
agentos ctl status --json    # version, uptime, harness, live runs
```

Do not judge the login by `~/.claude/.credentials.json`. The node does not keep
its Claude state there, and `CLAUDE_CONFIG_DIR` is unset in your shell, so the
familiar path reads as "not logged in" on a node that is logged in. After
`/login` the credentials live at
`<install-dir>/data/.aop/claude-config/.credentials.json`; with a
`CLAUDE_CODE_OAUTH_TOKEN` in `.env` there may be no such file at all. The check
that does not lie is the node's own log, after the owner has sent a message:

```bash
sudo grep -ci 'not logged in' <install-dir>/logs/node.log            # must stop growing
sudo grep -c '\[session\] Result: subtype=success' <install-dir>/logs/node.log  # must be > 0
```

The first count is cumulative, so compare it before and after the owner's test
message rather than expecting zero; the second is the proof that a real turn
completed.

If they have no credential at all and no way to make one right now, say plainly
what that means: the node runs, routines tick, and every agent reply comes back
as the Claude CLI's `Not logged in` banner with the node's own hint to run
`/login` — until `/login` happens.

Then verify the brain actually got adopted — it is the step with the quietest
failure:

```bash
agentos logs 500 | grep -i 'contexts'
sudo ls -la <install-dir>/repos/<name>
```

You are looking for a line saying `AGENTOS_REPO_DIR` was adopted as the local
context. If instead you see that it was skipped as "not a git checkout", the
clone did not happen — check the `--repo` warning in the install output, the
token's scope (`repo`, `read:org`) and the URL, fix it, and re-run the
installer. If the directory is a good checkout and the log says nothing at all,
restart the node once and look again:

```bash
systemctl restart agentos
```

This is not a race, and it is expected after a re-run: adoption happens only at
boot, and re-running the installer to add `--repo` clones the checkout without
restarting a node that is already running. (On a named instance the unit is
`agentos-<user>`.)

## Phase 6 — Make it useful today

The node is running and knows who it belongs to. Give it one thing to do and
one way you know it works.

- **Harness**, if the owner is on Codex rather than Claude:
  `agentos ctl harness set codex-acp` (`claude-sdk`, `claude-acp`, `codex-acp`,
  `opencode` are the values; `agentos ctl harness get` shows the current one).
- **A first routine**, from the shipped catalog rather than hand-written YAML:

```bash
agentos preset ls
agentos preset add daily-brief hour=8 minute=0 --repo <install-dir>/repos/<name>
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

Then delete the secrets file (`shred -u "$SECRETS"`, or `rm`) and
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
| Exit 3, `AgentOS Node is up, but WITHOUT HOST AUTHORITY`, `!! NO HOST AUTHORITY` | The node is installed and running, but its sudoers drop-in was NOT installed, so it has no root. The `Why:` line of the banner names the cause. | Tell the owner exactly that, with the cause. Fix it (usually `apt-get install sudo`; on Debian as non-root, also `/usr/sbin` on `PATH` — see Phase 0) and re-run with the same flags. |
| `the bare-metal node needs x86_64…` / `needs an apt-based distro…` | Wrong host for this profile. Nothing was touched. | Re-run with `--docker`, and tell the owner what that changes. |
| `cannot resolve the stable channel`, a curl failure on the tarball or the Node runtime | Network or GitHub. Packages may be installed; nothing else is. | Retry once. Still failing: report it as an outage, do not hand-download anything. |
| `tarball checksum mismatch` | **Stop.** A release tarball that does not match its SHA256 is not a thing to work around. | Nothing was unpacked: the version directory is created only after the check passes, so the box is untouched apart from a partial download in `/tmp` that the next attempt overwrites. Retry once in case the download was truncated. If it repeats, report it and stop; never disable the check. |
| A `tar`/`unzstd` failure right after the checksum passed | The download was good, the extraction was not. **This one does leave a trap**: `<install-dir>/versions/<tag>` now exists but is empty or partial, and the installer skips the whole download-and-unpack block when that directory is present — so a naive re-run points `current` at an empty tree and the node never starts. | Delete `<install-dir>/versions/<tag>` (and the tarball in `/tmp`) before retrying. Then re-run the installer. |
| `node did not become healthy` (the last 50 journal lines were printed above it) | The unit is installed and enabled; the node did not answer `/healthz` in 45 attempts (~1.5-2 min). | Read that dump first. Then `journalctl -u <unit> -n 200 --no-pager` and `sudo tail -200 <install-dir>/logs/node.log` — note that `/usr/local/bin/agentos` is not created until after the health gate, so the CLI is not there yet (and on a named instance it is `/usr/local/bin/agentos-<user>`, a wrapper, not a symlink). A wrong value in `.env` and a port already taken are the common causes. Fix the cause and re-run the installer; it is cheap the second time. |
| `docker install failed`, `docker daemon is not reachable` | Docker, not AgentOS. | Follow the message, or drop `--docker` if the box can take the bare-metal profile. |
| `install did not finish cleanly… your .env and data are kept` (container profile) | Same class as the health timeout. | Read the container's last log lines, fix, re-run. |
| `! git clone <name> failed`, `! gh auth setup-git failed` | **Warnings, not failures.** The install succeeded; the brain did not arrive. | Check the token scope (`repo`, `read:org`) and the URL, then re-run the installer — `--repo` is re-run safe and fetches when the checkout is already there. |
| `! that token does not look like a @BotFather token` | Shape check only; the installer never asks Telegram. | Let it finish, then verify by having the owner DM the bot. Silence means the token. |
| The bot is silent, everything else is green | Wrong token, or another process is polling the same bot. | Ask whether this bot is running anywhere else — including a rehearsal install you made yourself. Two pollers is the usual answer; rule 7 is how you avoid it. |

Three habits that decide whether this goes well:

- **Re-run the installer rather than repairing by hand.** It is idempotent,
  keeps data, skips work already done, and never moves the version. Know what
  it does to `.env`: the `--docker` profile keeps it and overrides only the keys
  your flags name, but the default bare-metal profile **rewrites `.env` from the
  flags of this run** — only the admin pair, the update policy and a fixed list
  of context keys (`AGENTOS_REPO_DIR` among them) carry over. Anything else in
  it — a token merged by an earlier `--secrets`, a key added by hand — is gone
  unless this run brings it again. So re-run with the full set of flags and the
  same secrets file the box was installed with, not just the one you are
  changing.
  Hand-repair is how a box ends up in a state nobody can reproduce.
- **Stop on anything that smells like integrity.** A checksum mismatch, a
  certificate error, a suggestion to skip verification: report and stop. That is
  not a step you are authorised to route around.
- **Never say a phase passed because it probably did.** Every phase here has a
  command that answers yes or no. Run it.
