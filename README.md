# AgentOS

Your own agent, 24/7 — a Telegram bot + task tracker + scheduled routines +
Mini App, running as a single process over a git repo.

**Own your files, own your repo.** Everything your agent knows and does lives
as plain files in a git repository on your machine: tasks, routines, notes,
working context. Read it with any editor, version it with git, back it up like
any repo, move it to another box whenever you want. No vendor database, nothing
to export — wipe the container and your data is still yours.

## What you get

- **A Telegram-native agent** — message it like a person; it answers, does the
  work, and reports back in the chat.
- **Tasks** — hand off long-running work; it runs in the background and comes
  back with results.
- **Routines** — scheduled jobs on cron: morning digests, monitors, recurring
  chores.
- **Mini App** — manage tasks and routines from your phone, right inside
  Telegram.
- **One process on your box** — a single Docker container or a single systemd
  service. Your server, your keys, your data.

## Install

One command on a clean Linux x64 box (Ubuntu 24.04 / Debian 12). You'll need a
bot token from [@BotFather](https://t.me/BotFather) and your Telegram user id.

Docker (default), with HTTPS for the Mini App:

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh | bash -s -- --domain agent.example.com
```

No domain? Use `--no-https` — the bot long-polls Telegram, so it is fully
functional behind NAT with no open ports; HTTPS is only needed for the Mini App
button. Other HTTPS options: `--tunnel-token` (named Cloudflare tunnel,
no open ports) or `--quick` (throwaway trycloudflare hostname, demo only).

Bare metal without Docker (hardened systemd unit, Node runtime vendored):

```bash
curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh | bash -s -- --no-docker --domain agent.example.com
```

Nothing is built on your machine: Docker mode pulls a release image pinned by
digest; `--no-docker` downloads a checksum-verified release tarball. Re-running
the installer is safe, and every answer has a flag for non-interactive installs
— see `install.sh --help` (`--token`, `--admin`, `--dir`, `--channel`,
`--image`, `-y`).

## Manage

Both modes put the `agentos` CLI on PATH:

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
