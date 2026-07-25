# AgentOS

Your own agent, 24/7 — a Telegram bot + task tracker + scheduled routines +
Mini App, running as a single process over a git repo.

**Own your files, own your repo.** Everything your agent knows and does lives
as plain files in a git repository on your machine: tasks, routines, notes,
working context. Read it with any editor, version it with git, back it up like
any repo, move it to another box whenever you want. No vendor database, nothing
to export — wipe the node and your data is still yours.

Start the agent's repo from the default template:
**[try-agent-os/claude-code-template](https://github.com/try-agent-os/claude-code-template)**
— charter, skills, memory, and manifests, pre-structured the way the node
expects them.

## What you get

- **A Telegram-native agent** — message it like a person; it answers, does the
  work, and reports back in the chat.
- **Tasks** — hand off long-running work; it runs in the background and comes
  back with results.
- **Routines** — scheduled jobs on cron: morning digests, monitors, recurring
  chores.
- **Mini App** — manage tasks and routines from your phone, right inside
  Telegram.
- **One process on your box** — a single systemd service (or a single Docker
  container, if you prefer). Your server, your keys, your data.

## Install

Two things to have ready: a bot token from
[@BotFather](https://t.me/BotFather) (`/newbot`), and your numeric Telegram id
from [@userinfobot](https://t.me/userinfobot) — the id auto-approves you as the
node's admin.

Then, on a clean Linux x64 box (Ubuntu 24.04 / Debian 12), one command:

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh \
  | bash -s -- --no-https --token <BOT_TOKEN> --admin <YOUR_TELEGRAM_ID>
```

That is the whole install, and it involves **no Docker daemon**: a
checksum-verified release tarball unpacked onto disk, its own vendored Node
runtime, and `agentos.service` owning the process under systemd. Nothing is
compiled here and nothing is cloned. When the script prints `AgentOS Node is
running`, the bot is already polling Telegram.

Then DM your bot `/login` (admin-only, private chat) to connect Claude — no SSH
needed for that step.

### No box yet? One click to create one

[![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/droplets/new?image=ubuntu-24-04-x64&size=s-2vcpu-4gb&region=fra1&refcode=6f9a0892dd0a)

The button opens DigitalOcean's Droplet page with a sensible node prefilled —
Ubuntu 24.04, 2 vCPU / 4 GB, Frankfurt. Pick your SSH key, create it, then `ssh
root@<droplet-ip>` and run the command above.

The button provisions the machine and nothing else, on purpose: DigitalOcean's
web form takes a startup script only from its own **Startup scripts** field (or
through the API — see [Other providers](#other-providers-cloud-init)), never
from a link in the URL, so a droplet created this way boots plain Ubuntu. Your
bot token stays on your own terminal either way — it never rides a URL through
your browser history.

No DigitalOcean account yet? Signing up through this badge supports the
project:

<a href="https://www.digitalocean.com/?refcode=6f9a0892dd0a&utm_campaign=Referral_Invite&utm_medium=Referral_Program&utm_source=badge"><img src="https://web-platforms.sfo2.cdn.digitaloceanspaces.com/WWW/Badge%201.svg" alt="DigitalOcean Referral Badge" /></a>

### Adding HTTPS, for the Mini App

The bot needs no domain at all — it long-polls Telegram, so `--no-https` is a
complete install behind NAT, with no inbound port and no certificate. HTTPS
buys exactly one thing: Telegram opens a Mini App only on a public `https`
origin.

Point an A record at the box, open ports 80 and 443, and use `--domain` instead
of `--no-https` — Caddy gets a Let's Encrypt certificate and renews it:

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh \
  | bash -s -- --domain agent.example.com --token <BOT_TOKEN> --admin <YOUR_TELEGRAM_ID>
```

You can add it later: re-run the installer with `--domain` and your data and
config are preserved.

### As a Docker container instead

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh \
  | bash -s -- --docker --domain agent.example.com
```

`--docker` pulls a release image pinned by `sha256` digest and runs it under
compose. Reach for it when the host is not x86_64 + apt, or when you want an
option only the container profile carries: `--tunnel-token` (named Cloudflare
tunnel, no open ports), `--quick` (throwaway trycloudflare hostname, demo
only), or a pinned `--channel` / `--image`. Those flags select Docker on their
own, so an existing command line keeps working unchanged.

Re-running the installer is safe, and it never moves a node between profiles on
its own — an existing Docker install stays Docker. Every prompt has a flag; see
`install.sh --help` (`--token`, `--admin`, `--dir`, `-y`).

### Other providers: cloud-init

[`cloud-init.yaml`](cloud-init.yaml) does the same thing on first boot, minus
the secrets: it stages the installer at `/opt/agentos-bootstrap/install.sh` and
puts the finishing command in the login banner. Use it wherever user data
actually reaches the machine — a provider whose console has a user-data /
cloud-init field (Hetzner, Vultr, Linode), or DigitalOcean through its API:

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/cloud-init.yaml -o cloud-init.yaml
doctl compute droplet create agentos --image ubuntu-24-04-x64 --size s-2vcpu-4gb \
  --region fra1 --ssh-keys <your-ssh-key-id> --user-data-file cloud-init.yaml
```

## Manage

Both profiles put the `agentos` CLI on PATH:

```
agentos status | logs | upgrade | rollback | backup | version
```

`agentos upgrade` backs up your data before switching versions;
`agentos rollback` undoes the last upgrade.

## Releases

[Releases](https://github.com/try-agent-os/agentos/releases) carry the
bare-metal tarball, `SHA256SUMS`, and the `stable.json` channel manifest that
`install.sh` and `agentos` resolve against.

## License

The scripts in this repository (`install.sh`, `agentos`) are MIT-licensed; the
release artifacts (container images, tarballs) are proprietary © Novo Studio
and free to download and run for self-hosting — see [LICENSE](LICENSE).
