#!/usr/bin/env bash
# AgentOS Core on-prem profile — clean VM → working bot + Mini App.
#
#   curl -fsSL https://raw.githubusercontent.com/try-agent-os/agentos/main/install.sh | bash -s -- --domain agent.example.com
#
# Non-interactive (a client install, CI, or a re-run) — every answer has a flag:
#
#   --token <bot-token>        @BotFather token           (else: prompt, or $TELEGRAM_BOT_TOKEN)
#   --admin <telegram-id>      auto-approved admin id     (else: prompt, or $TELEGRAM_ADMIN_USER_IDS)
#   --domain <host>            HTTPS via Caddy + real certs. Needs an A record → this host, 80+443 open.
#   --tunnel-token <token>     HTTPS via a named Cloudflare tunnel. No open ports needed. (Docker mode.)
#   --quick                    HTTPS via a throwaway trycloudflare hostname. Demo only. (Docker mode.)
#   --no-https                 Bot only. No Mini App button (the bot itself is fully functional).
#   --no-docker                Bare-metal systemd install, no Docker. Needs x86_64 + apt (Debian 12 /
#                              Ubuntu 24.04). --tunnel-token/--quick are not supported in this mode yet
#                              — use --domain or --no-https.
#   --dir <path>               Install root. Default /opt/agentos.
#   --channel <name>           Release channel to resolve. Default stable. (Docker mode.)
#   --image <ref>              Pin an exact image (repo@sha256:...). Skips the channel. (Docker mode.)
#   -y, --yes                  Never prompt; fail instead of asking.
#
# WHAT NEEDS HTTPS AND WHAT DOES NOT: the bot long-polls Telegram, so it works
# behind NAT with no domain, no certificate and no inbound port — that path is
# --no-https and it is a legitimate install. HTTPS buys exactly one thing:
# Telegram will only open a Mini App on a public https origin (grabla #7).
#
# NOTHING IS BUILT HERE. The default (Docker) path resolves the release channel
# to an image digest, pulls it, and extracts the compose run profile the image
# carries. --no-docker instead resolves the channel's stable.json, downloads the
# matching release tarball straight onto disk, and runs it under a systemd unit.
# Either way: no git clone, no compiler, no toolchain on the target machine.
#
# Re-running is safe: in docker mode the .env is preserved (flags override
# individual keys); --no-docker rewrites .env from the current flags. The data
# volume is untouched either way. To upgrade an existing install use `agentos upgrade`
# (both modes install this CLI onto PATH) — it backs up the data first.

set -euo pipefail

IMAGE_REPO="${AGENTOS_IMAGE_REPO:-ghcr.io/try-agent-os/agentos-core}"
INSTALL_DIR="${AGENTOS_DIR:-/opt/agentos}"
CHANNEL="${AGENTOS_CHANNEL:-stable}"
IMAGE_REF="${AGENTOS_IMAGE:-}"   # set → skip channel resolution, pin exactly this
COMPOSE_FILE="docker-compose.node.yml"
INSTALL_MODE="docker"            # docker | systemd (--no-docker: bare metal)

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
ADMIN_IDS="${TELEGRAM_ADMIN_USER_IDS:-}"
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
    --admin)        ADMIN_IDS="${2:?--admin needs a value}"; shift 2 ;;
    --domain)       DOMAIN="${2:?--domain needs a value}"; HTTPS_MODE="caddy"; shift 2 ;;
    --tunnel-token) TUNNEL_TOKEN="${2:?--tunnel-token needs a value}"; HTTPS_MODE="cloudflared"; shift 2 ;;
    --quick)        HTTPS_MODE="quick"; shift ;;
    --no-https)     HTTPS_MODE="none"; shift ;;
    --no-docker)    INSTALL_MODE="systemd"; shift ;;
    --dir)          INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --channel)      CHANNEL="${2:?--channel needs a value}"; shift 2 ;;
    --image)        IMAGE_REF="${2:?--image needs a value}"; shift 2 ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
done

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

# Shared by both install modes (scripts/agentos's own wait_healthz mirrors this
# exactly — keep the two in step). Docker mode still waits on `docker inspect`
# health status below (§8) instead of this: that inline check is unchanged by
# this addition, on purpose.
wait_healthz() {
  for _ in $(seq 1 45); do
    curl -fsS --max-time 3 "http://127.0.0.1:8787/healthz" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
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
  $SUDO install -m 600 /dev/null "$INSTALL_DIR/.env"
  $SUDO tee "$INSTALL_DIR/.env" >/dev/null <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_ADMIN_USER_IDS=${ADMIN_IDS}
PORT=8787
MINIAPP_PORT=8787
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
  # it (up to 120s) instead of dying on "could not get lock".
  $SUDO apt-get -o DPkg::Lock::Timeout=120 update -qq
  $SUDO apt-get -o DPkg::Lock::Timeout=120 install -y -qq ffmpeg git tmux curl zstd jq ca-certificates

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
  id agentos >/dev/null 2>&1 || $SUDO useradd -r -m -d "$INSTALL_DIR" -s /usr/sbin/nologin agentos
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
  $SUDO sed "s|/opt/agentos|${INSTALL_DIR}|g" "$INSTALL_DIR/current/profiles/agentos.service" \
    | $SUDO tee /etc/systemd/system/agentos.service >/dev/null
  $SUDO chown -R agentos:agentos "$INSTALL_DIR"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now agentos

  if [ "$HTTPS_MODE" = "caddy" ]; then
    step "HTTPS (Caddy)"
    # Same Caddyfile the compose "caddy" profile mounts (docker/Caddyfile,
    # shipped in profiles/ — see docker/Dockerfile.node), with the compose
    # env-substitution placeholder and the docker-network upstream hostname
    # swapped for what a bare-metal box actually has: a known domain and the
    # node listening on loopback.
    $SUDO apt-get -o DPkg::Lock::Timeout=120 install -y -qq caddy
    # Same $SUDO-on-the-read reasoning as the unit render above: this template
    # also lives under $INSTALL_DIR (the agentos account's $HOME).
    $SUDO sed -e "s/{\$AGENTOS_DOMAIN}/${DOMAIN}/" -e "s/node:8787/127.0.0.1:8787/" \
      "$INSTALL_DIR/current/profiles/docker/Caddyfile" | $SUDO tee /etc/caddy/Caddyfile >/dev/null
    $SUDO systemctl reload caddy 2>/dev/null || $SUDO systemctl restart caddy
    ok "caddy → https://${DOMAIN} (127.0.0.1:8787)"
  fi

  step "Health"
  wait_healthz || { $SUDO journalctl -u agentos -n 50 --no-pager; die "node did not become healthy"; }
  ok "node is healthy"

  $SUDO ln -sfn "$INSTALL_DIR/current/profiles/agentos" /usr/local/bin/agentos
  ok "agentos CLI → /usr/local/bin/agentos"
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
    || die "--no-docker needs x86_64 (glibc floor: Debian 12 / Ubuntu 24.04) — this host reports $(uname -m). Use the Docker path instead (drop --no-docker)."
  command -v apt-get >/dev/null 2>&1 \
    || die "--no-docker needs an apt-based distro (Debian 12 / Ubuntu 24.04) — apt-get was not found. Use the Docker path instead (drop --no-docker)."
  ok "x86_64, apt-get present"

  step "Configuration"
  if [ -z "$BOT_TOKEN" ]; then
    info "Get one from @BotFather → /newbot. Looks like 123456:ABC-..."
    BOT_TOKEN="$(ask 'Telegram bot token' '')"
  fi
  [ -n "$BOT_TOKEN" ] || die "a bot token is required."
  echo "$BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$' \
    || warn "that token does not look like a @BotFather token — continuing, but check it if the bot stays silent."

  if [ -z "$ADMIN_IDS" ] && [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
    info "Your numeric Telegram id — DM @userinfobot to get it. Empty = approve yourself later with /start."
    ADMIN_IDS="$(read -r -p "$(echo -e "  ${BOLD}Admin Telegram id${NC} ${DIM}(optional)${NC}: ")" a </dev/tty; echo "${a:-}")" || true
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
$(if [ -z "${ADMIN_IDS:-}" ]; then echo "               No admin id was set: send /start, then approve yourself."; fi)
  $(echo -e "${BOLD}Mini App${NC}")   $(case "$HTTPS_MODE" in
      none) echo "not published (bot-only install). Add it: re-run with --domain <host>." ;;
      *)    echo "https://${DOMAIN}/app — open it from the bot's menu button or /app." ;;
    esac)
  $(echo -e "${BOLD}Install${NC}")    $INSTALL_DIR

  logs      journalctl -u agentos -f
  status    systemctl status agentos
  cli       agentos status | logs [n] | version | upgrade [--to <tag>] | rollback | backup

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
  curl -fsSL https://get.docker.com | $SUDO sh >/dev/null 2>&1 \
    || die "docker install failed — install Docker Engine + the compose plugin manually, then re-run."
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

if [ -z "$ADMIN_IDS" ] && [ -f .env ]; then
  ADMIN_IDS="$(grep -E '^TELEGRAM_ADMIN_USER_IDS=' .env | cut -d= -f2- || true)"
fi
if [ -z "$ADMIN_IDS" ] && [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
  info "Your numeric Telegram id — DM @userinfobot to get it. Empty = approve yourself later with /start."
  ADMIN_IDS="$(read -r -p "$(echo -e "  ${BOLD}Admin Telegram id${NC} ${DIM}(optional)${NC}: ")" a </dev/tty; echo "${a:-}")" || true
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
$(if [ -z "${ADMIN_IDS:-}" ]; then echo "               No admin id was set: send /start, then approve yourself."; fi)
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
