#!/usr/bin/env bash
# AgentOS Core on-prem profile — clean VM → working bot + Mini App.
#
#   curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh | bash -s -- --domain agent.example.com
#
# Non-interactive (a client install, CI, or a re-run) — every answer has a flag:
#
#   --token <bot-token>        @BotFather token           (else: prompt, or $TELEGRAM_BOT_TOKEN)
#   --admin <id|username>      Auto-approved admin: a numeric Telegram id (123510069) or a Telegram
#                              username (vasily, or @vasily — the @ is optional). Comma-separate to
#                              name several, in any mix. Omit it entirely and the node is UNCLAIMED:
#                              the first person who DMs the bot becomes its admin — once, no time
#                              limit. (Else: prompt, or $TELEGRAM_ADMIN_USER_IDS.)
#   --domain <host>            HTTPS via Caddy + real certs. Needs an A record → this host, 80+443 open.
#   --tunnel-token <token>     HTTPS via a named Cloudflare tunnel. No open ports needed. (Docker mode.)
#   --quick                    HTTPS via a throwaway trycloudflare hostname. Demo only. (Docker mode.)
#   --no-https                 Bot only. No Mini App button (the bot itself is fully functional).
#   --docker                   Run the node as a Docker container instead of the default systemd
#                              service. Required for --tunnel-token/--quick/--channel/--image, and for
#                              any host that is not x86_64 + apt. Implied by those flags.
#   --no-docker                The DEFAULT (bare-metal systemd unit, no Docker daemon) — still accepted
#                              so existing command lines keep working. Needs x86_64 + apt (Debian 12 /
#                              Ubuntu 24.04); --tunnel-token/--quick are not supported in this mode yet
#                              — use --domain or --no-https.
#   --dir <path>               Install root. Default /opt/<user>.
#   --user <name>              Unix service account to run the node as. Default agentos. Everything
#                              else keys off it, so a second instance on the same host is just a
#                              second --user: install root /opt/<user>, unit agentos-<user>.service,
#                              CLI /usr/local/bin/agentos-<user>. Pair it with --port. (systemd mode.)
#   --port <n>                 Loopback port for the node + Mini App origin. Default 8787. Two
#                              instances on one host need two ports. (systemd mode.)
#   --channel <name>           Release channel to resolve. Default stable. (Docker mode.)
#   --image <ref>              Pin an exact image (repo@sha256:...). Skips the channel. (Docker mode.)
#   -y, --yes                  Never prompt; fail instead of asking.
#
# TWO NODES ON ONE HOST: same install, twice, with a different --user/--port and
# its own .env — that is the whole story. Nothing is shared between instances
# except the machine: separate service account, separate install root (its $HOME,
# so separate ~/.ssh deploy key and ~/.claude state), separate data dir, separate
# unit, separate auto-update timer, separate CLI entry point. The default install
# is unchanged down to the last path — `agentos`, /opt/agentos, agentos.service —
# so an existing single-node box sees no rename.
#
# WHO IS ADMIN: an id is the durable form. A username is resolved to its numeric
# id on that person's first private message and the id is canonical from then on,
# because usernames are mutable and can be re-registered by someone else — so a
# username is a first-contact convenience, not an identity. With no admin
# configured at all the node is unclaimed and the first DM claims it, one shot
# and no time window: message the bot yourself as soon as this finishes.
#
# WHAT NEEDS HTTPS AND WHAT DOES NOT: the bot long-polls Telegram, so it works
# behind NAT with no domain, no certificate and no inbound port — that path is
# --no-https and it is a legitimate install. HTTPS buys exactly one thing:
# Telegram will only open a Mini App on a public https origin (grabla #7).
#
# NOTHING IS BUILT HERE. The default (bare metal) path resolves the release
# channel's stable.json, downloads the matching release tarball straight onto
# disk, and runs it under a systemd unit — there is no docker daemon to install
# first, which is also one less thing to race with a cloud VM's own first boot.
# --docker instead resolves the channel to an image digest, pulls it, and
# extracts the compose run profile the image carries. Either way: no git clone,
# no compiler, no toolchain on the target machine.
#
# Re-running is safe: in docker mode the .env is preserved (flags override
# individual keys); bare metal rewrites .env from the current flags, EXCEPT the
# admin pair, which is inherited in both modes when no --admin is passed (a
# forgotten flag must not strip the operator of their own admin rights). The data
# volume is untouched either way. To upgrade an existing install use `agentos upgrade`
# (both modes install this CLI onto PATH) — it backs up the data first.

set -euo pipefail

IMAGE_REPO="${AGENTOS_IMAGE_REPO:-ghcr.io/try-agent-os/agentos-core}"
SERVICE_USER="${AGENTOS_USER:-agentos}"
# Empty → resolved from SERVICE_USER after args (/opt/<user>), so --user alone is
# enough to move the whole install. An explicit --dir/$AGENTOS_DIR still wins.
INSTALL_DIR="${AGENTOS_DIR:-}"
SERVICE_NAME=""                  # resolved after args: agentos | agentos-<user>
PORT="${AGENTOS_PORT:-8787}"
CHANNEL="${AGENTOS_CHANNEL:-stable}"
IMAGE_REF="${AGENTOS_IMAGE:-}"   # set → skip channel resolution, pin exactly this
COMPOSE_FILE="docker-compose.node.yml"
INSTALL_MODE=""                  # docker | systemd; empty → resolved after args (default: systemd)

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
# --admin's raw value: one comma list mixing numeric ids and usernames, split by
# parse_admin (below) into the two keys the core reads. Both env vars keep
# working as the defaults they are today; --admin replaces them wholesale.
ADMIN_INPUT="${TELEGRAM_ADMIN_USER_IDS:-}"
if [ -n "${TELEGRAM_ADMIN_USERNAMES:-}" ]; then
  ADMIN_INPUT="${ADMIN_INPUT:+${ADMIN_INPUT},}${TELEGRAM_ADMIN_USERNAMES}"
fi
ADMIN_IDS=""         # → TELEGRAM_ADMIN_USER_IDS  (all-digit values)
ADMIN_USERNAMES=""   # → TELEGRAM_ADMIN_USERNAMES (no leading @)
DOMAIN=""
TUNNEL_TOKEN=""
HTTPS_MODE=""        # caddy | cloudflared | quick | none
ASSUME_YES=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}▸${NC} ${BOLD}$*${NC}"; }
info()  { echo -e "  ${DIM}$*${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; }
die()   { echo -e "\n${RED}✗ $*${NC}\n" >&2; exit 1; }

# ─── args ───────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --token)        BOT_TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --admin)        ADMIN_INPUT="${2:?--admin needs a value}"; shift 2 ;;
    --domain)       DOMAIN="${2:?--domain needs a value}"; HTTPS_MODE="caddy"; shift 2 ;;
    --tunnel-token) TUNNEL_TOKEN="${2:?--tunnel-token needs a value}"; HTTPS_MODE="cloudflared"; shift 2 ;;
    --quick)        HTTPS_MODE="quick"; shift ;;
    --no-https)     HTTPS_MODE="none"; shift ;;
    --docker)       INSTALL_MODE="docker"; shift ;;
    --no-docker)    INSTALL_MODE="systemd"; shift ;;
    --dir)          INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --user)         SERVICE_USER="${2:?--user needs a value}"; shift 2 ;;
    --port)         PORT="${2:?--port needs a value}"; shift 2 ;;
    --channel)      CHANNEL="${2:?--channel needs a value}"; shift 2 ;;
    --image)        IMAGE_REF="${2:?--image needs a value}"; shift 2 ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    # Line range = the whole header block above (ends one line before
    # `set -euo pipefail`). Grow the header, grow this range, or --help truncates.
    -h|--help)      sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
done

# ─── instance identity: user → install root, unit name, CLI name ────────────
#
# One knob. A second node on the same host is the same install run again with a
# different --user (and --port), each with its own .env — there is no instance
# registry, no templating, nothing to keep in sync. Everything derives here so
# no later step has to re-decide it.
#
# The default user reproduces the historical layout EXACTLY (/opt/agentos,
# agentos.service, /usr/local/bin/agentos): a box installed before this flag
# existed must not see a rename on its next re-run.
case "$SERVICE_USER" in
  ''|*[!a-z0-9_-]*|[!a-z_]*)
    die "--user: expected a lowercase unix account name ([a-z_][a-z0-9_-]*), got '${SERVICE_USER}'" ;;
esac
case "$PORT" in
  ''|*[!0-9]*) die "--port: expected a number, got '${PORT}'" ;;
esac

[ -n "$INSTALL_DIR" ] || INSTALL_DIR="/opt/${SERVICE_USER}"
if [ "$SERVICE_USER" = "agentos" ]; then
  SERVICE_NAME="agentos"
else
  # Always prefixed, never doubled: --user symoditi and --user agentos-symoditi
  # both land on agentos-symoditi.service, so the unit is findable by `systemctl
  # list-units 'agentos*'` no matter which spelling the operator picked.
  SERVICE_NAME="agentos-${SERVICE_USER#agentos-}"
fi

# ─── install mode ───────────────────────────────────────────────────────────
#
# Bare metal is the DEFAULT channel. Not a preference: on a box created a
# minute ago the provider's own first boot still holds the dpkg lock, and
# get.docker.com's internal apt-get does not wait for it — installing a docker
# daemon first is a race the user did not sign up for. The systemd path needs
# nothing but apt (which does wait, see install_systemd) plus a tarball.
#
# Docker remains a first-class channel: opt-in with --docker, and selected
# automatically by the flags only the compose run profile can honour, so an
# existing command line asking for a tunnel or a pinned image keeps working.
#
# A RE-RUN NEVER CHANGES CHANNEL BY ITSELF. Re-running the installer is
# advertised as safe, and this flip must not turn that into "systemd unit
# raised next to your running container": same port, same bot token, two
# getUpdates consumers, one 409 loop. An existing docker install therefore
# keeps docker unless --no-docker is passed explicitly.
if [ -z "$INSTALL_MODE" ]; then
  if [ -n "$TUNNEL_TOKEN" ] || [ "$HTTPS_MODE" = "quick" ] || \
     [ -n "$IMAGE_REF" ] || [ "$CHANNEL" != "stable" ]; then
    INSTALL_MODE="docker"
    info "docker mode: --tunnel-token/--quick/--channel/--image are container-profile only"
  elif [ -f "$INSTALL_DIR/$COMPOSE_FILE" ] || \
       grep -qs '^AGENTOS_IMAGE=' "$INSTALL_DIR/.env"; then
    INSTALL_MODE="docker"
    info "existing Docker install in $INSTALL_DIR — staying on the container profile (--no-docker migrates)"
  else
    INSTALL_MODE="systemd"
  fi
fi

# Answer "which channel would this command pick?" without touching the machine.
# scripts/tests/install-mode.test.sh drives the whole matrix through it, and it
# is a straight answer to give a user who is about to re-run the installer on a
# node they inherited.
if [ -n "${AGENTOS_PRINT_MODE:-}" ]; then
  echo "$INSTALL_MODE"
  exit 0
fi

# Multi-instance is a bare-metal capability today. Docker mode keys everything —
# project name, volume, published port — off one compose file per host, so
# honouring --user there would need a second compose project, not a second flag.
# Fail loudly instead of installing something that quietly collides.
if [ "$INSTALL_MODE" = "docker" ] && { [ "$SERVICE_USER" != "agentos" ] || [ "$PORT" != "8787" ]; }; then
  die "--user/--port are systemd-mode only today — drop --docker, or run the second instance bare metal"
fi

# "Where would this command line install to?" — answered without touching the
# machine, same contract as AGENTOS_PRINT_MODE above.
# scripts/tests/install-identity.test.sh drives the matrix through it.
if [ -n "${AGENTOS_PRINT_IDENTITY:-}" ]; then
  echo "${SERVICE_USER}|${INSTALL_DIR}|${SERVICE_NAME}|${PORT}"
  exit 0
fi

# ─── admin identity ─────────────────────────────────────────────────────────
#
# --admin takes numeric ids AND usernames, in any mix, comma separated:
#
#   --admin 123510069          → TELEGRAM_ADMIN_USER_IDS=123510069
#   --admin @vasily            → TELEGRAM_ADMIN_USERNAMES=vasily
#   --admin 123510069,vasily   → one value in each key
#
# Classification needs no network lookup and is never ambiguous: a Telegram
# username is 5–32 characters, starts with a letter and then holds only letters,
# digits and underscores ([A-Za-z][A-Za-z0-9_]{4,31}), so it can NEVER be all
# digits. All digits ⇒ an id; anything else ⇒ a username, with one leading @
# stripped because the core stores usernames without it. A value that is neither
# stops the install right here: writing it through would produce a .env the core
# silently ignores — i.e. a node with no admin, quietly claimable by whoever
# messages the bot first.
parse_admin() { # parse_admin <comma-list> — fills ADMIN_IDS + ADMIN_USERNAMES
  local rest="$1" item given
  ADMIN_IDS=""
  ADMIN_USERNAMES=""
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    if [ "$item" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    # "--admin '123510069, vasily'" is a command line a human writes by hand —
    # the spaces they typed around a comma must not make a value invalid.
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "$item" ] || continue
    given="$item"
    case "$item" in
      *[!0-9]*)
        item="${item#@}"   # exactly one leading @, and only in that position
        printf '%s' "$item" | grep -qE '^[A-Za-z][A-Za-z0-9_]{4,31}$' || die \
"--admin: \"${given}\" is neither of the two accepted forms.
    numeric Telegram id    123510069         (DM @userinfobot to get yours)
    Telegram username      vasily, @vasily   (5-32 chars, starts with a letter,
                                              then letters/digits/underscore)"
        case ",${ADMIN_USERNAMES}," in
          *",${item},"*) ;;   # named twice (e.g. vasily and @vasily) — keep one
          *) ADMIN_USERNAMES="${ADMIN_USERNAMES:+${ADMIN_USERNAMES},}${item}" ;;
        esac
        ;;
      *)
        case ",${ADMIN_IDS}," in
          *",${item},"*) ;;
          *) ADMIN_IDS="${ADMIN_IDS:+${ADMIN_IDS},}${item}" ;;
        esac
        ;;
    esac
  done
}

parse_admin "$ADMIN_INPUT"

# THE ADMIN PAIR IS STICKY ACROSS RE-RUNS, IN BOTH CHANNELS. An admin is an
# identity the operator established once — not a per-run switch — so a re-run
# that simply forgets the flag must not strip them of their own rights (and, on
# a node whose claim marker has not been set yet, hand the node to whoever DMs
# the bot next). Docker mode always merged its .env; bare metal used to rewrite
# it from flags, which silently emptied both keys. Now both inherit here.
#
# Only the admin pair is sticky. Every other key bare metal writes still comes
# from the current flags (write_env_systemd rewrites the file) — that is the
# documented behaviour and it stays.
#
# --admin (or its env default) remains an explicit, COMPLETE replacement of both
# keys: nothing is inherited when a value was passed, so switching from a
# username to an id cannot leave the username behind.
ADMIN_INHERITED=0
inherit_admin_from_dotenv() {
  local envfile="$INSTALL_DIR/.env" content=""
  [ -z "$ADMIN_INPUT" ] || return 0                       # flag/env wins outright
  [ -z "${ADMIN_IDS}${ADMIN_USERNAMES}" ] || return 0     # already inherited
  # The file is 0600 and owned by the service account: root reads it directly,
  # `sudo install.sh` only through $SUDO — which is still unset the first time
  # this runs (the hook below is deliberately reachable without root). Both
  # attempts are best effort: an unreadable .env must never fail a run, least of
  # all a --dir dry run by a normal user.
  if [ -r "$envfile" ]; then
    content="$(cat "$envfile" 2>/dev/null || true)"
  elif [ -n "${SUDO:-}" ]; then
    content="$($SUDO cat "$envfile" 2>/dev/null || true)"
  fi
  [ -n "$content" ] || return 0
  # tail -1 mirrors set_env's append-last upsert: the last assignment wins.
  ADMIN_IDS="$(printf '%s\n' "$content" | sed -n 's/^TELEGRAM_ADMIN_USER_IDS=//p' | tail -1)"
  ADMIN_USERNAMES="$(printf '%s\n' "$content" | sed -n 's/^TELEGRAM_ADMIN_USERNAMES=//p' | tail -1)"
  # Verbatim, deliberately: what is already in .env is the operator's, and a
  # re-run is no place to start re-validating a file they may have edited by hand.
  if [ -n "${ADMIN_IDS}${ADMIN_USERNAMES}" ]; then
    ADMIN_INHERITED=1
  fi
}

# First attempt, before the hook below, so what the hook prints is what the run
# would actually use. Silent: the info line belongs in each channel's
# Configuration step, which is where the second attempt (with $SUDO available)
# happens.
inherit_admin_from_dotenv

# "Which admins would this command line configure?", answered without touching
# the machine — the admin counterpart of AGENTOS_PRINT_MODE above, deliberately
# a SEPARATE hook: that one's output is asserted line-for-line by
# scripts/tests/install-mode.test.sh. Driven by scripts/tests/install-admin.test.sh.
if [ -n "${AGENTOS_PRINT_ADMIN:-}" ]; then
  echo "ids=${ADMIN_IDS}"
  echo "usernames=${ADMIN_USERNAMES}"
  exit 0
fi

ask() { # ask <prompt> <var-value> ; echoes the answer
  local prompt="$1" current="$2"
  if [ -n "$current" ]; then echo "$current"; return; fi
  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    die "$prompt is required and there is no terminal to ask on — pass the flag (--help)."
  fi
  local answer=""
  read -r -p "$(echo -e "  ${BOLD}${prompt}${NC}: ")" answer </dev/tty
  echo "$answer"
}

# The admin question, asked identically by both install channels. Sets
# ADMIN_IDS/ADMIN_USERNAMES through parse_admin (so an id, a username, or a
# mixed list all work), and says out loud what an empty answer now means —
# leaving it empty is a real choice, not a "fill this in later" placeholder.
ask_admin() {
  local answer=""
  info "Your numeric Telegram id (DM @userinfobot) or your username — vasily or @vasily."
  info "Empty = this node stays UNCLAIMED and the first person who DMs the bot becomes"
  info "its admin, once. Make that you: message the bot as soon as this finishes."
  read -r -p "$(echo -e "  ${BOLD}Admin Telegram id or username${NC} ${DIM}(optional)${NC}: ")" answer </dev/tty || true
  if [ -n "$answer" ]; then
    parse_admin "$answer"
  fi
}

# Shared by both install modes (scripts/agentos's own wait_healthz mirrors this
# exactly — keep the two in step). Docker mode still waits on `docker inspect`
# health status below (§8) instead of this: that inline check is unchanged by
# this addition, on purpose.
wait_healthz() {
  for _ in $(seq 1 45); do
    curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# A cloud VM handed over as "active" is usually STILL provisioning: cloud-init
# runs its own apt-get while the user is already pasting the install command
# (the DigitalOcean button gives them a shell within seconds). Any nested
# apt-get then dies with exit 100, "Could not get lock
# /var/lib/dpkg/lock-frontend ... held by process N (apt-get)" — the host is
# fine, we just lost a race. install_systemd passes -o DPkg::Lock::Timeout
# to the apt-get calls it owns; this drops the same timeout into apt's own
# config so apt-get calls we do NOT own (get.docker.com's, above all) wait too.
apt_wait_for_lock() {
  [ -d /etc/apt/apt.conf.d ] || return 0
  printf 'DPkg::Lock::Timeout "300";\n' \
    | $SUDO tee /etc/apt/apt.conf.d/99-agentos-lock-timeout >/dev/null 2>&1 || true
}

# Belt to that suspenders: wait out the provider's first boot before touching
# packages at all. Bounded, and a stuck cloud-init must not hang the install.
wait_for_first_boot() {
  command -v cloud-init >/dev/null 2>&1 || return 0
  cloud-init status >/dev/null 2>&1 || return 0
  case "$(cloud-init status 2>/dev/null)" in
    *running*)
      info "the machine is still on its first boot (cloud-init) — waiting for it"
      if command -v timeout >/dev/null 2>&1; then
        timeout 300 cloud-init status --wait >/dev/null 2>&1 || true
      else
        cloud-init status --wait >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

# ─── --no-docker (bare metal / systemd) ────────────────────────────────────
#
# No image, no compose profile: the unit of distribution here is a release
# tarball (scripts/release/pack-tarball.sh output) addressed by stable.json
# (Task 2), unpacked straight onto disk, with systemd — not the docker
# daemon — owning the process lifecycle. Task 6's upgrade swaps
# $INSTALL_DIR/current and restarts the agentos.service unit this installs.

write_env_systemd() {
  # 0600 from birth: the file carries the bot token, so no umask-default window.
  # ${tag} comes from the caller (install_systemd) via bash dynamic scoping.
  # Every key here is (re)written from the current flags — that is this channel's
  # documented re-run behaviour. The one exception is the admin pair: by the time
  # this runs, inherit_admin_from_dotenv may have refilled it from the .env this
  # call is about to overwrite, so a re-run without --admin keeps its admins.
  $SUDO install -m 600 /dev/null "$INSTALL_DIR/.env"
  $SUDO tee "$INSTALL_DIR/.env" >/dev/null <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_ADMIN_USER_IDS=${ADMIN_IDS}
TELEGRAM_ADMIN_USERNAMES=${ADMIN_USERNAMES}
PORT=${PORT}
MINIAPP_PORT=${PORT}
# Loopback bind: only Caddy (443) faces the network; the origin stays private.
HOST=127.0.0.1
AGENTOS_VERSION=${tag}
TELEGRAM_MCP_DB_PATH=${INSTALL_DIR}/data/messages.db
AGENTOS_SEARCH_DB_PATH=${INSTALL_DIR}/data/search.db
AOP_STATE_DIR=${INSTALL_DIR}/data/.aop
MINIAPP_DIST_DIR=${INSTALL_DIR}/current/miniapp-dist
EOF
  $SUDO chmod 600 "$INSTALL_DIR/.env"
  # Explicit if, NOT `[ -n ] && …`: as the function's last command, a false
  # test would become its exit status and `set -e` would kill the install at
  # the call site — exactly the --no-https path, before the unit even exists.
  if [ -n "$DOMAIN" ]; then
    echo "MINIAPP_URL=https://${DOMAIN}/app" | $SUDO tee -a "$INSTALL_DIR/.env" >/dev/null
  fi
}

install_systemd() {
  step "System packages"
  export DEBIAN_FRONTEND=noninteractive
  # DPkg::Lock::Timeout: on a fresh droplet's FIRST boot the provider agent
  # (cloud-init, unattended-upgrades) still holds the apt/dpkg lock — wait for
  # it (up to 300s) instead of dying on "could not get lock". wait_for_first_boot
  # gets us out of the busiest window first; the timeout covers the rest.
  wait_for_first_boot
  apt_wait_for_lock
  $SUDO apt-get -o DPkg::Lock::Timeout=300 update -qq
  $SUDO apt-get -o DPkg::Lock::Timeout=300 install -y -qq ffmpeg git tmux curl zstd jq ca-certificates

  step "Release"
  local manifest tag tarball sha node_ver url
  manifest="$(curl -fsSL --max-time 30 \
    "https://github.com/try-agent-os/agentos/releases/latest/download/stable.json")" \
    || die "cannot resolve the stable channel"
  tag="$(jq -r .version <<<"$manifest")"
  tarball="$(jq -r .tarball <<<"$manifest")"
  sha="$(jq -r .tarball_sha256 <<<"$manifest")"
  node_ver="$(jq -r .node_version <<<"$manifest")"
  url="https://github.com/try-agent-os/agentos/releases/download/${tag}/${tarball}"
  ok "channel stable → ${tag}"

  step "Service user + layout"
  # $HOME must live inside the writable install root (ProtectSystem=strict in
  # the unit): ~/.claude and ~/.ssh break under a custom --dir otherwise.
  id "$SERVICE_USER" >/dev/null 2>&1 || \
    $SUDO useradd -r -m -d "$INSTALL_DIR" -s /usr/sbin/nologin "$SERVICE_USER"
  $SUDO mkdir -p "$INSTALL_DIR"/{versions,data,backups}

  step "Node ${node_ver} (vendored)"
  if [ ! -x "$INSTALL_DIR/node/bin/node" ] || \
     [ "$("$INSTALL_DIR/node/bin/node" --version)" != "v${node_ver}" ]; then
    curl -fsSL "https://nodejs.org/dist/v${node_ver}/node-v${node_ver}-linux-x64.tar.xz" \
      -o /tmp/node.tar.xz
    $SUDO rm -rf "$INSTALL_DIR/node" && $SUDO mkdir -p "$INSTALL_DIR/node"
    $SUDO tar -xJf /tmp/node.tar.xz -C "$INSTALL_DIR/node" --strip-components=1
    rm /tmp/node.tar.xz
  fi
  ok "node $("$INSTALL_DIR/node/bin/node" --version)"

  step "Core ${tag}"
  if [ ! -d "$INSTALL_DIR/versions/$tag" ]; then
    curl -fsSL "$url" -o "/tmp/${tarball}"
    echo "${sha}  /tmp/${tarball}" | sha256sum -c - || die "tarball checksum mismatch"
    $SUDO mkdir -p "$INSTALL_DIR/versions/$tag"
    $SUDO tar --use-compress-program=unzstd -xf "/tmp/${tarball}" -C "$INSTALL_DIR/versions/$tag"
    rm "/tmp/${tarball}"
  fi
  $SUDO ln -sfn "$INSTALL_DIR/versions/$tag" "$INSTALL_DIR/current"

  step "Claude Code CLI"
  # Pinned to the version the image bakes; the manifest is authoritative later
  # (add claude_code_version to stable.json when it first diverges — YAGNI now).
  # npm's shebang is `#!/usr/bin/env node` and the vendored node is not on
  # sudo's secure_path, so run npm through the vendored node explicitly AND put
  # its bin dir on PATH for any child `node` processes npm spawns.
  $SUDO env PATH="$INSTALL_DIR/node/bin:$PATH" \
    "$INSTALL_DIR/node/bin/node" "$INSTALL_DIR/node/bin/npm" \
    install -g --prefix "$INSTALL_DIR/node" "@anthropic-ai/claude-code@2.1.205"

  step "Config + unit"
  write_env_systemd
  # scripts/release/agentos.service ships with every path spelled as the
  # literal default install root — that IS its placeholder convention (see the
  # comment at the top of that file). A plain cp only works for the default
  # --dir; retargeting every occurrence (EnvironmentFile, ExecStart*,
  # WorkingDirectory, and the ProtectSystem= hardening paths alike) is what
  # makes a custom --dir actually boot instead of pointing a hardened unit at
  # a root that does not exist.
  # $SUDO on the READ too, not just the tee: $INSTALL_DIR is the agentos
  # service account's $HOME (useradd -r -m), which can be 0700 — under sudo
  # (not already root), plain `sed` as the invoking user would fail to even
  # open the template before `tee` ever runs.
  # User=/Group= are substituted on their own anchored lines, AFTER the path
  # rewrite: the account name is a substring of every install path, so a global
  # s|agentos|<user>| would corrupt them. Anchored ^User= can only ever hit the
  # two lines it is meant to.
  $SUDO sed -e "s|/opt/agentos|${INSTALL_DIR}|g" \
            -e "s|^User=agentos$|User=${SERVICE_USER}|" \
            -e "s|^Group=agentos$|Group=${SERVICE_USER}|" \
            "$INSTALL_DIR/current/profiles/agentos.service" \
    | $SUDO tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null
  $SUDO chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "$SERVICE_NAME"

  if [ "$HTTPS_MODE" = "caddy" ]; then
    step "HTTPS (Caddy)"
    # Same Caddyfile the compose "caddy" profile mounts (docker/Caddyfile,
    # shipped in profiles/ — see docker/Dockerfile.node), with the compose
    # env-substitution placeholder and the docker-network upstream hostname
    # swapped for what a bare-metal box actually has: a known domain and the
    # node listening on loopback.
    # /etc/caddy/Caddyfile is one file per host: a second instance would
    # overwrite the first instance's vhost instead of adding to it. Until this
    # renders a per-instance snippet, only the default install may claim it.
    [ "$SERVICE_NAME" = "agentos" ] || \
      die "--domain writes the single /etc/caddy/Caddyfile — a second instance would clobber the first. Use --no-https here and put this instance behind your own vhost on 127.0.0.1:${PORT}"
    $SUDO apt-get -o DPkg::Lock::Timeout=120 install -y -qq caddy
    # Same $SUDO-on-the-read reasoning as the unit render above: this template
    # also lives under $INSTALL_DIR (the service account's $HOME).
    $SUDO sed -e "s/{\$AGENTOS_DOMAIN}/${DOMAIN}/" -e "s/node:8787/127.0.0.1:${PORT}/" \
      "$INSTALL_DIR/current/profiles/docker/Caddyfile" | $SUDO tee /etc/caddy/Caddyfile >/dev/null
    $SUDO systemctl reload caddy 2>/dev/null || $SUDO systemctl restart caddy
    ok "caddy → https://${DOMAIN} (127.0.0.1:${PORT})"
  fi

  step "Health"
  wait_healthz || { $SUDO journalctl -u "$SERVICE_NAME" -n 50 --no-pager; die "node did not become healthy"; }
  ok "node is healthy"

  # The CLI needs to know WHICH install it operates on. For the default node
  # that is its own built-in default, so it stays the plain symlink it has
  # always been; a named instance gets a two-line wrapper that pins the three
  # coordinates (root, unit, port) before exec'ing the very same script.
  if [ "$SERVICE_NAME" = "agentos" ]; then
    $SUDO ln -sfn "$INSTALL_DIR/current/profiles/agentos" /usr/local/bin/agentos
  else
    $SUDO tee "/usr/local/bin/${SERVICE_NAME}" >/dev/null <<EOF
#!/bin/sh
# AgentOS CLI for the '${SERVICE_USER}' instance — written by install.sh.
AGENTOS_DIR=${INSTALL_DIR} AGENTOS_SERVICE=${SERVICE_NAME} \\
AGENTOS_USER=${SERVICE_USER} AGENTOS_PORT=${PORT} \\
  exec ${INSTALL_DIR}/current/profiles/agentos "\$@"
EOF
    $SUDO chmod 755 "/usr/local/bin/${SERVICE_NAME}"
  fi
  ok "agentos CLI → /usr/local/bin/${SERVICE_NAME}"

  install_autoupdate_timer "$INSTALL_DIR/current/profiles"
}

# Install + arm the unattended update timer. Mode-agnostic: the poller and its
# systemd units ride the same profiles/ layer as the agentos CLI, so both the
# docker and bare-metal paths get the identical manifest-driven updater. Renders
# the oneshot's install-root placeholder exactly like agentos.service does, then
# enables the timer. On a host with no systemd it degrades to a printed hint, not
# a failure — the node still works, it just checks by hand.
install_autoupdate_timer() { # install_autoupdate_timer <profiles-dir>
  local pdir="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "no systemd on this host — unattended auto-update not armed."
    info "check for updates by hand any time with: agentos autoupdate --check"
    return 0
  fi
  [ -f "$pdir/agentos-autoupdate.service" ] || { warn "auto-update units missing from $pdir — skipping timer."; return 0; }
  # Per instance, like the service itself: its own poller unit, its own timer,
  # its own policy drop-in. ExecStart is retargeted at THIS instance's CLI entry
  # point, which is what carries the root/unit/port coordinates.
  local au="${SERVICE_NAME}-autoupdate"
  $SUDO sed -e "s|/opt/agentos|${INSTALL_DIR}|g" \
            -e "s|^ExecStart=/usr/local/bin/agentos |ExecStart=/usr/local/bin/${SERVICE_NAME} |" \
            "$pdir/agentos-autoupdate.service" \
    | $SUDO tee "/etc/systemd/system/${au}.service" >/dev/null
  # The timer names the unit it fires, so it is rendered too, never copied.
  $SUDO sed -e "s|^Unit=agentos-autoupdate.service$|Unit=${au}.service|" \
            "$pdir/agentos-autoupdate.timer" \
    | $SUDO tee "/etc/systemd/system/${au}.timer" >/dev/null
  # The operator's auto-apply appetite, when they set one. Default lives in the
  # unit (patch): patch/security land unattended, minor/major wait for a button.
  if [ -n "${AGENTOS_AUTOUPDATE_POLICY:-}" ]; then
    $SUDO mkdir -p "/etc/systemd/system/${au}.service.d"
    printf '[Service]\nEnvironment=AGENTOS_AUTOUPDATE_POLICY=%s\n' "${AGENTOS_AUTOUPDATE_POLICY}" \
      | $SUDO tee "/etc/systemd/system/${au}.service.d/policy.conf" >/dev/null
  fi
  $SUDO systemctl daemon-reload
  if $SUDO systemctl enable --now "${au}.timer" >/dev/null 2>&1; then
    ok "auto-update timer armed (policy=${AGENTOS_AUTOUPDATE_POLICY:-patch})"
  else
    warn "could not enable ${au}.timer — arm it with: systemctl enable --now ${au}.timer"
  fi
}

echo -e "\n${BOLD}AgentOS Node — install${NC}"

# ─── 0. privileges ──────────────────────────────────────────────────────────

SUDO=""
if [ "$(id -u)" != "0" ]; then
  command -v sudo >/dev/null 2>&1 || die "run as root, or install sudo."
  SUDO="sudo"
  $SUDO -v || die "sudo failed — run as root instead."
fi

# ─── 0b. --no-docker: split off before anything Docker-specific ────────────
#
# Everything below this block (image resolution, pull, compose profile
# extraction, compose up, the docker-inspect health wait) is the Docker path
# and is left untouched — this branch takes its own, much shorter road to the
# same three answers (bot token, admin id, HTTPS mode) and then hands off to
# install_systemd (defined above), which does the rest: packages, release
# tarball, vendored Node, the systemd unit, and its own health wait.
if [ "$INSTALL_MODE" = "systemd" ]; then
  step "Bare-metal preflight"
  [ "$(uname -m)" = "x86_64" ] \
    || die "the bare-metal node needs x86_64 (glibc floor: Debian 12 / Ubuntu 24.04) — this host reports $(uname -m). Re-run with --docker to use the container profile instead."
  command -v apt-get >/dev/null 2>&1 \
    || die "the bare-metal node needs an apt-based distro (Debian 12 / Ubuntu 24.04) — apt-get was not found. Re-run with --docker to use the container profile instead."
  ok "x86_64, apt-get present"

  step "Configuration"
  if [ -z "$BOT_TOKEN" ]; then
    info "Get one from @BotFather → /newbot. Looks like 123456:ABC-..."
    BOT_TOKEN="$(ask 'Telegram bot token' '')"
  fi
  [ -n "$BOT_TOKEN" ] || die "a bot token is required."
  echo "$BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$' \
    || warn "that token does not look like a @BotFather token — continuing, but check it if the bot stays silent."

  # Second attempt, now that $SUDO exists: on a re-run the install dir's .env is
  # 0600 root/agentos, so under `sudo install.sh` the pre-hook attempt above read
  # nothing. Whichever attempt won, the operator hears about it exactly once.
  inherit_admin_from_dotenv
  if [ "$ADMIN_INHERITED" = "1" ]; then
    info "reusing the admin(s) from the existing .env — pass --admin to replace them"
  fi
  if [ -z "${ADMIN_IDS}${ADMIN_USERNAMES}" ] && [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
    ask_admin
  fi

  # --tunnel-token / --quick need cloudflared, which this task does not wire
  # up on bare metal (YAGNI — see task brief). Fail fast rather than silently
  # downgrading to --no-https, whatever HTTPS_MODE the flags already picked.
  case "$HTTPS_MODE" in
    cloudflared|quick)
      die "--tunnel-token/--quick: not yet supported in --no-docker mode, use --domain or --no-https" ;;
  esac
  if [ -z "$HTTPS_MODE" ]; then
    if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
      HTTPS_MODE="none"
      info "no HTTPS flag given in non-interactive mode → bot only (--no-https)"
    else
      echo
      info "The bot works with no HTTPS at all. --no-docker wires up HTTPS via a real"
      info "domain (Caddy) or not at all — Cloudflare tunnels need --domain or --no-https for now."
      echo -e "    ${BOLD}1${NC}) I have a domain pointing here     ${DIM}(Caddy, real certs)${NC}"
      echo -e "    ${BOLD}2${NC}) Skip — bot only                   ${DIM}(add a domain later, re-run this script)${NC}"
      choice="$(read -r -p "$(echo -e "  ${BOLD}Choice${NC} ${DIM}(1-2)${NC}: ")" c </dev/tty; echo "${c:-2}")"
      case "$choice" in
        1) HTTPS_MODE="caddy"; DOMAIN="$(ask 'Domain (e.g. agent.example.com)' '')" ;;
        *) HTTPS_MODE="none" ;;
      esac
    fi
  fi
  [ "$HTTPS_MODE" = "caddy" ] && [ -z "$DOMAIN" ] && die "--domain needs a hostname."

  install_systemd

  cat <<EOF

$(echo -e "${GREEN}${BOLD}AgentOS Node is running.${NC}")

  $(echo -e "${BOLD}Bot${NC}")        message it on Telegram — it is already polling.
$(if [ -z "${ADMIN_IDS:-}${ADMIN_USERNAMES:-}" ]; then
    echo "               No admin was configured, so this node is UNCLAIMED: the FIRST person"
    echo "               who sends it a private message becomes its admin — once, no time limit."
    echo "               Message it NOW, before anybody else does."
  fi)
  $(echo -e "${BOLD}Mini App${NC}")   $(case "$HTTPS_MODE" in
      none) echo "not published (bot-only install). Add it: re-run with --domain <host>." ;;
      *)    echo "https://${DOMAIN}/app — open it from the bot's menu button or /app." ;;
    esac)
  $(echo -e "${BOLD}Install${NC}")    $INSTALL_DIR ($SERVICE_USER, 127.0.0.1:$PORT)

  logs      journalctl -u $SERVICE_NAME -f
  status    systemctl status $SERVICE_NAME
  cli       $SERVICE_NAME status | logs [n] | version | upgrade [--to <tag>] | rollback | backup

EOF
  exit 0
fi

# ─── 1. docker ──────────────────────────────────────────────────────────────

step "Docker"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "already installed ($(docker --version | cut -d, -f1))"
else
  info "not found — installing from get.docker.com"
  command -v curl >/dev/null 2>&1 || $SUDO sh -c 'apt-get update -qq && apt-get install -y -qq curl' >/dev/null 2>&1 || true
  wait_for_first_boot
  apt_wait_for_lock
  # Three attempts, and the log is PRINTED on the last failure: swallowing it
  # into /dev/null is how "docker install failed" used to reach the user with
  # the actual line ("Could not get lock /var/lib/dpkg/lock-frontend") hidden.
  docker_log="$(mktemp)"
  docker_ok=0
  for attempt in 1 2 3; do
    if curl -fsSL https://get.docker.com | $SUDO sh >"$docker_log" 2>&1; then
      docker_ok=1
      break
    fi
    [ "$attempt" -lt 3 ] || break
    info "attempt ${attempt} failed (the machine is likely still busy) — retrying in 20s"
    sleep 20
  done
  if [ "$docker_ok" != "1" ]; then
    warn "get.docker.com failed three times; its last output:"
    tail -20 "$docker_log" >&2 || true
    rm -f "$docker_log"
    die "docker install failed — install Docker Engine + the compose plugin manually and re-run, or drop --docker to install the default bare-metal node (systemd, no daemon)."
  fi
  rm -f "$docker_log"
  docker compose version >/dev/null 2>&1 \
    || die "docker installed but 'docker compose' is missing — install the compose plugin, then re-run."
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  ok "installed"
fi
docker info >/dev/null 2>&1 || die "docker daemon is not reachable (try: $SUDO systemctl start docker)."

# ─── 2. release ─────────────────────────────────────────────────────────────
#
# No clone. No compiler. The unit of distribution is an OCI image addressed by
# sha256 digest; the compose file below is a thin RUN PROFILE that the image
# itself carries, extracted after the pull. A git ref does not identify a
# release — a digest does.
#
# resolve_image mirrors scripts/release/resolve-image.sh on purpose: this script
# is delivered standalone through `curl | bash`, so it cannot source a file from
# a repo the caller has not got. Keep the two in step when either changes.

resolve_image() { # resolve_image <channel> — echo repo@sha256:...
  local channel="$1"
  local registry="${IMAGE_REPO%%/*}" name="${IMAGE_REPO#*/}" token headers digest
  token="$(curl -fsSL --max-time 15 \
    "https://${registry}/token?service=${registry}&scope=repository:${name}:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)"
  # Every media type the image could be published as must be in Accept, or the
  # registry answers with a converted manifest whose digest is not the one
  # clients pull by.
  headers="$(curl -fsSI --max-time 20 \
    ${token:+-H "Authorization: Bearer ${token}"} \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://${registry}/v2/${name}/manifests/${channel}" 2>/dev/null || true)"
  digest="$(printf '%s' "$headers" | tr -d '\r' \
    | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | tail -1)"
  printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || return 1
  printf '%s@%s\n' "$IMAGE_REPO" "$digest"
}

step "Release"
if [ -n "$IMAGE_REF" ]; then
  info "using the image reference you pinned"
else
  IMAGE_REF="$(resolve_image "$CHANNEL")" \
    || die "could not resolve ${IMAGE_REPO}:${CHANNEL} to a digest — the registry did not answer with one.
    If the package is private, anonymous pull is refused. Check:
      curl -sI https://${IMAGE_REPO%%/*}/v2/${IMAGE_REPO#*/}/manifests/${CHANNEL}"
fi
ok "$IMAGE_REF"

$SUDO mkdir -p "$INSTALL_DIR"
# Everything below writes here (.env, compose state), so own it as the invoking
# user: an install that only root can operate is an install that gets sudo'd
# blindly forever after.
[ -n "$SUDO" ] && $SUDO chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
cd "$INSTALL_DIR"

step "Pulling the core image"
info "prebuilt — nothing is compiled on this machine"
docker pull "$IMAGE_REF" >/dev/null 2>&1 || {
  warn "quiet pull failed — re-running with full output so you can see why"
  docker pull "$IMAGE_REF"
  die "pull failed."
}
ok "image pulled"

# The compose file + Caddyfile ship inside the image (docker/Dockerfile.node),
# so a stranger needs no access to the source tree to run it. A repo checkout
# that already has them keeps its own — that is the dev/self-hosted-from-source
# path, and overwriting there would clobber local edits.
step "Run profile"
if [ -f "$INSTALL_DIR/$COMPOSE_FILE" ] && [ -d "$INSTALL_DIR/.git" ]; then
  info "existing source checkout — keeping its compose file"
else
  profile_container="$(docker create "$IMAGE_REF")"
  docker cp "${profile_container}:/app/profiles/." "$INSTALL_DIR/" >/dev/null
  docker rm "$profile_container" >/dev/null
  ok "extracted from the image"
fi
[ -f "$INSTALL_DIR/$COMPOSE_FILE" ] || die "no $COMPOSE_FILE after extraction — the image is missing /app/profiles."

# profiles/agentos (Task 4's CLI) rides inside the same profiles/ layer the
# compose file above came from, so a fresh extraction already dropped it at
# $INSTALL_DIR/agentos — symlink it onto PATH so a docker-mode install gets
# the same `agentos upgrade|rollback|status|logs` operator surface --no-docker
# gets (the finish banner below points at it instead of a script a curl|bash
# install never had). Known limitation: `agentos upgrade` swaps the running
# node's image but does not re-fetch this CLI file itself — a materially
# changed CLI needs a re-run of this installer to pick up.
if [ -f "$INSTALL_DIR/agentos" ]; then
  chmod +x "$INSTALL_DIR/agentos"
  $SUDO ln -sfn "$INSTALL_DIR/agentos" /usr/local/bin/agentos
  ok "agentos CLI → /usr/local/bin/agentos"
fi
[ -f "$INSTALL_DIR/agentos-autoupdate.sh" ] && chmod +x "$INSTALL_DIR/agentos-autoupdate.sh"
install_autoupdate_timer "$INSTALL_DIR"

# ─── 3. answers ─────────────────────────────────────────────────────────────

step "Configuration"
if [ -z "$BOT_TOKEN" ] && [ -f .env ]; then
  BOT_TOKEN="$(grep -E '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2- || true)"
  [ -n "$BOT_TOKEN" ] && info "reusing the bot token from the existing .env"
fi
if [ -z "$BOT_TOKEN" ]; then
  info "Get one from @BotFather → /newbot. Looks like 123456:ABC-..."
  BOT_TOKEN="$(ask 'Telegram bot token' '')"
fi
[ -n "$BOT_TOKEN" ] || die "a bot token is required."
echo "$BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$' \
  || warn "that token does not look like a @BotFather token — continuing, but check it if the bot stays silent."

# Admin, on a re-run: inherited from $INSTALL_DIR/.env unless --admin (or its env
# default) named one — see inherit_admin_from_dotenv above, which both channels
# share. Second attempt for the same reason bare metal makes one: $SUDO only
# exists from §0 onward, and this .env is 0600.
inherit_admin_from_dotenv
if [ "$ADMIN_INHERITED" = "1" ]; then
  info "reusing the admin(s) from the existing .env — pass --admin to replace them"
fi
if [ -z "${ADMIN_IDS}${ADMIN_USERNAMES}" ] && [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
  ask_admin
fi

# HTTPS mode: ask only if no flag decided it.
if [ -z "$HTTPS_MODE" ]; then
  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    HTTPS_MODE="none"
    info "no HTTPS flag given in non-interactive mode → bot only (--no-https)"
  else
    echo
    info "The bot works with no HTTPS at all. HTTPS is only needed for the Mini App,"
    info "because Telegram opens a Mini App only on a public https origin."
    echo -e "    ${BOLD}1${NC}) I have a domain pointing here     ${DIM}(real certs, recommended)${NC}"
    echo -e "    ${BOLD}2${NC}) Cloudflare named tunnel token     ${DIM}(no open ports needed)${NC}"
    echo -e "    ${BOLD}3${NC}) Throwaway quick tunnel            ${DIM}(demo only — new URL each restart)${NC}"
    echo -e "    ${BOLD}4${NC}) Skip — bot only                   ${DIM}(add a domain later, re-run this script)${NC}"
    choice="$(read -r -p "$(echo -e "  ${BOLD}Choice${NC} ${DIM}(1-4)${NC}: ")" c </dev/tty; echo "${c:-4}")"
    case "$choice" in
      1) HTTPS_MODE="caddy";       DOMAIN="$(ask 'Domain (e.g. agent.example.com)' '')" ;;
      2) HTTPS_MODE="cloudflared"; TUNNEL_TOKEN="$(ask 'Cloudflare tunnel token' '')" ;;
      3) HTTPS_MODE="quick" ;;
      *) HTTPS_MODE="none" ;;
    esac
  fi
fi

# ─── 4. domain preflight (grabla #7: fail here, not after boot) ─────────────

MINIAPP_URL=""
case "$HTTPS_MODE" in
  caddy)
    [ -n "$DOMAIN" ] || die "--domain needs a hostname."
    MINIAPP_URL="https://${DOMAIN}/app"
    step "Domain preflight — $DOMAIN"
    # Caddy will ask Let's Encrypt for a cert and LE will come back to :80. If DNS
    # or the port is wrong, that fails minutes later inside a container log nobody
    # reads. Check it now, while there is still a human here to fix it.
    resolved="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    public_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$resolved" ]; then
      warn "$DOMAIN does not resolve yet. Add an A record → ${public_ip:-this host} and re-run."
      warn "Continuing: certificate issuance will retry until DNS propagates."
    elif [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
      warn "$DOMAIN resolves to $resolved but this host looks like $public_ip."
      warn "If that is a proxy (Cloudflare orange-cloud), set the record to DNS-only or use --tunnel-token."
    else
      ok "$DOMAIN → $resolved (this host)"
    fi
    for p in 80 443; do
      if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :$p )" 2>/dev/null | grep -q ":$p"; then
        die "port $p is already in use — free it (another web server?) or use --tunnel-token instead."
      fi
    done
    ok "ports 80/443 are free"
    ;;
  cloudflared)
    [ -n "$TUNNEL_TOKEN" ] || die "--tunnel-token needs a value."
    step "Cloudflare named tunnel"
    info "Route the tunnel's public hostname at http://node:8787 in the Cloudflare dashboard."
    MINIAPP_URL="$(ask 'Public hostname of the tunnel (e.g. https://agent.example.com)' "${AGENTOS_MINIAPP_URL:-}")"
    case "$MINIAPP_URL" in
      https://*) : ;;
      *) die "the tunnel hostname must be an https:// URL (Telegram accepts nothing else)." ;;
    esac
    # Accept both "https://host" and "https://host/app" and land on exactly one /app.
    MINIAPP_URL="${MINIAPP_URL%/}"
    MINIAPP_URL="${MINIAPP_URL%/app}/app"
    ;;
  quick)
    step "Quick tunnel"
    warn "trycloudflare gives a NEW random hostname on every restart, and the Mini App"
    warn "button is registered with Telegram at boot — after a restart it points at a dead"
    warn "URL until you re-run this script. Fine to evaluate; use --domain for a real install."
    ;;
  none)
    step "HTTPS — skipped"
    info "Bot only. It long-polls Telegram, so it works behind NAT right now."
    info "Add the Mini App later: re-run with --domain <host>."
    ;;
esac

# ─── 5. .env ────────────────────────────────────────────────────────────────

step "Writing .env"
set_env() { # set_env KEY VALUE — idempotent upsert, no duplicate keys on re-run
  local key="$1" val="${2:-}"
  [ -f .env ] || : > .env
  if grep -qE "^${key}=" .env; then
    # value can contain / and & — use a python-free, sed-delimiter-safe rewrite
    grep -vE "^${key}=" .env > .env.tmp && mv .env.tmp .env
  fi
  printf '%s=%s\n' "$key" "$val" >> .env
}
unset_env() { # unset_env KEY — drop a key so a re-run in a leaner mode can't inherit it
  local key="$1"
  [ -f .env ] || return 0
  if grep -qE "^${key}=" .env; then
    grep -vE "^${key}=" .env > .env.tmp && mv .env.tmp .env
  fi
}
umask 077   # the bot token is in here
# Pin the exact digest the stack runs. compose reads AGENTOS_IMAGE from here, so
# a later `docker compose up` — or a reboot — brings back the SAME bits, not
# whatever the channel tag has moved on to since.
set_env AGENTOS_IMAGE "$IMAGE_REF"
set_env TELEGRAM_BOT_TOKEN "$BOT_TOKEN"
set_env TELEGRAM_ADMIN_USER_IDS "${ADMIN_IDS:-}"
# Written even when empty, exactly like the ids key above: an operator who moves
# from a username to an id (or the other way) needs the key they abandoned to end
# up empty, not to keep a stale value the core would still honour.
set_env TELEGRAM_ADMIN_USERNAMES "${ADMIN_USERNAMES:-}"
[ -n "$DOMAIN" ]       && set_env AGENTOS_DOMAIN "$DOMAIN"
[ -n "$TUNNEL_TOKEN" ] && set_env CLOUDFLARE_TUNNEL_TOKEN "$TUNNEL_TOKEN"
# --no-https (and quick before the tunnel resolves) leaves MINIAPP_URL empty. A
# guarded set would keep a stale value from an earlier --quick run — a dead
# trycloudflare URL that still publishes the Mini App button, contradicting the
# "--no-https ⇒ no button" contract. So actively drop it when there is no URL.
if [ -n "$MINIAPP_URL" ]; then
  set_env MINIAPP_URL "$MINIAPP_URL"
else
  unset_env MINIAPP_URL
fi
chmod 600 .env
ok ".env written (mode 600 — it holds the bot token)"

# ─── 6. up ──────────────────────────────────────────────────────────────────

PROFILE_ARGS=()
case "$HTTPS_MODE" in
  caddy)       PROFILE_ARGS=(--profile caddy) ;;
  cloudflared) PROFILE_ARGS=(--profile cloudflared) ;;
  quick)       PROFILE_ARGS=(--profile quick) ;;
esac

step "Starting"
docker compose -f "$COMPOSE_FILE" "${PROFILE_ARGS[@]}" up -d

# ─── 7. quick tunnel: resolve the URL, then re-boot the node with it ─────────
#
# The chicken-and-egg this script exists to solve: the hostname does not exist
# until cloudflared has connected, but the node bakes MINIAPP_URL into Telegram's
# menu button at boot. So: bring the tunnel up, read the hostname it was given,
# write it to .env, restart the node. Manually this is the step everyone gets
# wrong (grabla #7).
if [ "$HTTPS_MODE" = "quick" ]; then
  step "Resolving the quick-tunnel hostname"
  QUICK_URL=""
  for _ in $(seq 1 30); do
    QUICK_URL="$(docker compose -f "$COMPOSE_FILE" --profile quick logs quick-tunnel 2>/dev/null \
      | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
    [ -n "$QUICK_URL" ] && break
    sleep 2
  done
  if [ -n "$QUICK_URL" ]; then
    set_env MINIAPP_URL "${QUICK_URL}/app"
    MINIAPP_URL="${QUICK_URL}/app"
    ok "$QUICK_URL"
    info "restarting the node so it registers the button with this URL"
    docker compose -f "$COMPOSE_FILE" --profile quick up -d --force-recreate node >/dev/null
  else
    warn "the tunnel did not report a hostname in 60s — the bot still works; the Mini App button is skipped."
    warn "check: docker compose -f $COMPOSE_FILE --profile quick logs quick-tunnel"
  fi
fi

# ─── 8. verify ──────────────────────────────────────────────────────────────

step "Waiting for the node to come up"
HEALTHY=0
for _ in $(seq 1 60); do
  state="$(docker inspect --format '{{.State.Health.Status}}' agentos-node 2>/dev/null || echo starting)"
  case "$state" in
    healthy)   HEALTHY=1; break ;;
    unhealthy) break ;;
  esac
  # A crash-loop will never become healthy — stop waiting out the full minute.
  running="$(docker inspect --format '{{.State.Running}}' agentos-node 2>/dev/null || echo false)"
  [ "$running" = "false" ] && break
  sleep 2
done

if [ "$HEALTHY" != "1" ]; then
  echo
  warn "the node did not report healthy. Last 30 log lines:"
  docker compose -f "$COMPOSE_FILE" logs --tail 30 node || true
  die "install did not finish cleanly. Fix the error above and re-run — your .env and data are kept."
fi
ok "node is healthy (migrations applied, store open, Mini App listening)"

# /healthz proves the API listener is up, not that the SPA shipped: an image
# built without the miniapp stage still reports healthy while /app serves a
# 503 "build not found" stub. Ask /app itself before claiming a Mini App —
# and keep "docker exec failed" apart from the stub: only a real 503 proves a
# bad image; a dead exec (container restarting, daemon hiccup) proves nothing.
if APP_CODE="$(docker exec agentos-node node -e "require('http').get('http://127.0.0.1:'+(process.env.MINIAPP_PORT||8787)+'/app',r=>{console.log(r.statusCode);r.resume()}).on('error',()=>console.log('conn_error'))" 2>/dev/null)"; then
  APP_CODE="$(printf '%s' "$APP_CODE" | tail -n1 | tr -d '[:space:]')"
else
  APP_CODE=""
fi
if [ "$APP_CODE" = "200" ]; then
  ok "Mini App SPA serves at /app"
elif [ "$APP_CODE" = "503" ]; then
  if [ "$HTTPS_MODE" = "none" ]; then
    warn "GET /app answered 503 — this release image is missing the Mini App build."
    warn "The bot works. Before adding a domain, install a release that has it: re-run with --channel stable."
  else
    warn "GET /app answered 503 — this release image is missing the Mini App build, so the"
    warn "published Telegram button would open an error page instead of the Mini App."
    warn "That is a broken release, not a broken install — the image should never ship without /app."
    die "re-run with a good release (--channel stable, or --image <repo@sha256:...>) — your .env and data are kept."
  fi
else
  warn "could not confirm the Mini App: GET /app answered ${APP_CODE:-nothing — docker exec failed}."
  warn "The node reports healthy; verify once it settles: docker compose -f $COMPOSE_FILE logs node"
fi

# ─── done ───────────────────────────────────────────────────────────────────

cat <<EOF

$(echo -e "${GREEN}${BOLD}AgentOS Node is running.${NC}")

  $(echo -e "${BOLD}Bot${NC}")        message it on Telegram — it is already polling.
$(if [ -z "${ADMIN_IDS:-}${ADMIN_USERNAMES:-}" ]; then
    echo "               No admin was configured, so this node is UNCLAIMED: the FIRST person"
    echo "               who sends it a private message becomes its admin — once, no time limit."
    echo "               Message it NOW, before anybody else does."
  fi)
  $(echo -e "${BOLD}Mini App${NC}")   $(case "$HTTPS_MODE" in
      none) echo "not published (bot-only install). Add it: re-run with --domain <host>." ;;
      *)    echo "${MINIAPP_URL:-<pending>} — open it from the bot's menu button or /app." ;;
    esac)
  $(echo -e "${BOLD}Install${NC}")    $INSTALL_DIR

  logs      docker compose -f $INSTALL_DIR/$COMPOSE_FILE logs -f node
  stop      docker compose -f $INSTALL_DIR/$COMPOSE_FILE down        $(echo -e "${DIM}(keeps your data volume)${NC}")
  upgrade   agentos upgrade                                          $(echo -e "${DIM}(backs the DB up first)${NC}")
  rollback  agentos rollback                                         $(echo -e "${DIM}(undo the last upgrade)${NC}")

EOF
