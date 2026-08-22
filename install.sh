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
#   --upgrade                  Re-running over an existing install? By default the installed version
#                              is KEPT (config is refreshed, the version is not moved) — moving it
#                              belongs to `agentos upgrade`, which backs up the database first and
#                              can roll back. Pass --upgrade to follow the channel; the version
#                              change is then performed BY that CLI, backup and all.
#   --scoped-sudo              Do NOT grant the service account root. By default the install gives it
#                              passwordless sudo over the whole host, because administering the box is
#                              the job; this narrows the grant to restart/status/journal on its own
#                              unit. Pick it when the node shares a host with something off-limits.
#   -y, --yes                  Never prompt; fail instead of asking.
#
# CONTOUR ACCESS — an instance gets ALL of its contour's access at install time,
# so nothing has to be handed to it by hand afterwards (secrets, gh/git to its
# repos, checkouts). Three flags declare it; all are systemd-mode and re-run safe:
#   --secrets <file>           Env-file (KEY=VALUE per line) of the contour's secrets. Its keys are merged
#                              into /opt/<user>/.env (0600) on install AND every re-run. Values are read
#                              from the FILE, never from argv — nothing lands in `ps`, a journal or a log.
#   --repo <url>               A contour repo to check out under the instance ($INSTALL_DIR/repos/<name>),
#                              cloned as the service account with the token below. Repeatable — pass the
#                              context-repo and every working repo (e.g. platform).
#   --gh-token-key <KEY>       Which key in the merged .env holds the GitHub token used for `gh auth
#                              setup-git` and the clones above. Default: GH_TOKEN, then GITHUB_TOKEN.
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
# How much of the host the service account may reach through sudo. `full` is the
# default (see the sudoers section below); `--scoped-sudo` selects `selfmgmt`.
SUDO_SCOPE="${AGENTOS_SUDO_SCOPE:-full}"
# Empty → resolved from SERVICE_USER after args (/opt/<user>), so --user alone is
# enough to move the whole install. An explicit --dir/$AGENTOS_DIR still wins.
INSTALL_DIR="${AGENTOS_DIR:-}"
SERVICE_NAME=""                  # resolved after args: agentos | agentos-<user>
PORT="${AGENTOS_PORT:-8787}"
CHANNEL="${AGENTOS_CHANNEL:-stable}"
IMAGE_REF="${AGENTOS_IMAGE:-}"   # set → skip channel resolution, pin exactly this
# Did the OPERATOR name the image (env now, --image below)? A named version is a
# deliberate choice and outranks the "keep what is installed" rule; the channel
# moving on its own does not.
IMAGE_PINNED_BY_USER=0
[ -n "$IMAGE_REF" ] && IMAGE_PINNED_BY_USER=1
ALLOW_UPGRADE=0                  # re-run over an existing install: follow the channel? (#106)
# ─── contour access (secrets + repos) ───────────────────────────────────────
# An instance's contour — its secrets and its repos — is DECLARED here and laid
# down at install time, so a fresh node can gh/git to its own repos and read its
# own secrets with nothing added by hand afterwards. All read from files/env,
# never argv (secret hygiene): $SECRETS_FILE is a path, tokens live in .env.
SECRETS_FILE="${AGENTOS_SECRETS_FILE:-}"   # env-file whose keys merge into .env
CONTOUR_REPOS=()                            # --repo, repeatable: checkouts under the instance
if [ -n "${AGENTOS_CONTOUR_REPOS:-}" ]; then # space/comma list also accepted via env
  IFS=', ' read -r -a CONTOUR_REPOS <<< "${AGENTOS_CONTOUR_REPOS}"
fi
GH_TOKEN_KEY="${AGENTOS_GH_TOKEN_KEY:-}"    # which .env key holds the gh token (else GH_TOKEN/GITHUB_TOKEN)
COMPOSE_FILE="docker-compose.node.yml"
INSTALL_MODE=""                  # docker | systemd; empty → resolved after args (default: systemd)
# Prefix for the absolute HOST paths the auto-update channel writes OUTSIDE the
# install root — /etc/systemd/system (its units) and /var/lib/<service> (the
# root-owned outbox). Empty in production, and there is no flag or env var that
# fills it: the dry-run hook below sets it so the unit render, the policy
# migration and the signal-directory ownership are testable without root
# (scripts/tests/agentos-signals.test.sh).
HOST_PREFIX=""

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

# ─── is this name safe for root to create and chown? ────────────────────────
#
# Every directory this script hands to the service account lives under
# $INSTALL_DIR, and $INSTALL_DIR belongs to that account — install_systemd
# chowns the whole tree to it on every re-run, and the core runs unconfined
# (agentos.service ships no systemd sandbox), so it can write anywhere its POSIX
# permissions reach. So for any such name the core may have got there
# first and left a symlink, and root's `mkdir -p`/`chmod`/`chown` all FOLLOW
# symlinks: aimed at /etc/systemd/system, the chown hands the service account
# every unit root runs.
#
# No string check reaches this. The paths are the product's own legitimate
# defaults; the attack is on what the name points AT.
#
# Three call sites share this rule (the two signal directories and the contour
# repos checkout), and the CLI carries the same function under the same name for
# its own copy of the signal directories. It is ONE function per file rather
# than one per caller because hand-copied parity between these two files has
# already produced two wrong comments and one unreachable helper.
#
# Returns 0 when <path> is free (the caller's mkdir is what creates it) or is a
# real directory. Never for a symlink, and never for anything else that exists.
plain_dir_ok() { # plain_dir_ok <path> <label> -> 0 when it is safe to create/chmod/chown
  # -L FIRST. A dangling symlink is -L true, -e false and -d false, so every
  # other test reads it as "not there yet" and goes on to mkdir — which fails
  # EEXIST over a link, and under `set -e` that took the whole install down
  # before this guard could say a word about it.
  if [ -L "$1" ]; then
    warn "refusing to touch the $2 ($1): it is a symlink, not a directory — nothing was created, chmod'ed or chowned. Move it aside and re-run"
    return 1
  fi
  [ ! -e "$1" ] && return 0        # free: the caller's mkdir is what creates it
  [ -d "$1" ] && return 0
  warn "refusing to touch the $2 ($1): it exists but is not a directory — nothing was created, chmod'ed or chowned"
  return 1
}

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
    --upgrade)      ALLOW_UPGRADE=1; shift ;;
    --secrets)      SECRETS_FILE="${2:?--secrets needs a value}"; shift 2 ;;
    --repo)         CONTOUR_REPOS+=("${2:?--repo needs a value}"); shift 2 ;;
    --gh-token-key) GH_TOKEN_KEY="${2:?--gh-token-key needs a value}"; shift 2 ;;
    --image)        IMAGE_REF="${2:?--image needs a value}"; IMAGE_PINNED_BY_USER=1; shift 2 ;;
    --scoped-sudo)  SUDO_SCOPE="selfmgmt"; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    # Line range = the whole header block above (ends one line before
    # `set -euo pipefail`). Grow the header, grow this range, or --help truncates.
    -h|--help)      sed -n '2,90p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Contour declarations are validated for SHAPE here (existence, url form) — never
# for content, and the secrets file is never read into a variable at this stage:
# a value must not enter the process just to be shape-checked. Real ingestion is
# merge_contour_secrets, which streams the file straight into .env.
if [ -n "$SECRETS_FILE" ] && [ ! -e "$SECRETS_FILE" ]; then
  die "--secrets: no such file: ${SECRETS_FILE}"
fi
for _repo in ${CONTOUR_REPOS+"${CONTOUR_REPOS[@]}"}; do
  case "$_repo" in
    https://*|git@*|ssh://*) : ;;
    *) die "--repo: expected an https://, git@ or ssh:// git URL, got '${_repo}'" ;;
  esac
done

[ -n "$INSTALL_DIR" ] || INSTALL_DIR="/opt/${SERVICE_USER}"
if [ "$SERVICE_USER" = "agentos" ]; then
  SERVICE_NAME="agentos"
else
  # Always prefixed, never doubled: --user symoditi and --user agentos-symoditi
  # both land on agentos-symoditi.service, so the unit is findable by `systemctl
  # list-units 'agentos*'` no matter which spelling the operator picked.
  SERVICE_NAME="agentos-${SERVICE_USER#agentos-}"
fi

# ─── contour access: secrets + repo checkouts ───────────────────────────────
#
# The whole point of these helpers is that an instance leaves install.sh with
# EVERYTHING its contour needs — its secrets in .env, gh authenticated to its
# repos, its checkouts on disk — so a human never has to hand-carry a token or
# clone a repo into a running node afterwards (the failure this task fixes).
#
# Secret hygiene is load-bearing here, not decoration: a token value never
# appears on a command line (world-readable /proc/<pid>/cmdline), never in a log
# or an `ok`/`info` line, and never in a variable that outlives the write. Files
# are streamed; the gh token rides the ENVIRONMENT into a child, not its argv.

# Read a file we may not own as the invoking user, falling back to $SUDO. Used
# for the operator's --secrets file and for the 0600 .env root writes.
read_maybe_sudo() { # read_maybe_sudo <path> — echoes contents, or fails
  local f="$1"
  if [ -r "$f" ]; then cat "$f"; return 0; fi
  [ -n "${SUDO:-}" ] && $SUDO cat "$f" 2>/dev/null && return 0
  return 1
}

# Merge the contour secrets env-file into $INSTALL_DIR/.env, idempotently: any
# key the file declares REPLACES that key in .env (last write wins), every other
# line in .env is left exactly as it was. The result is rewritten 0600 in one
# shot. Values move file→file only; the log prints key NAMES, never values.
merge_contour_secrets() {
  [ -n "$SECRETS_FILE" ] || return 0
  local envfile="$INSTALL_DIR/.env" secrets declared keypat current filtered lines new n
  # Docker mode owns .env as the INVOKING user (docker compose reads it as them),
  # so writing it through sudo would lock them out; systemd mode's .env is
  # root/service-owned and needs sudo. $su selects the right hand for the write.
  local su="${SUDO:-}"
  [ "${INSTALL_MODE:-}" = "docker" ] && su=""
  secrets="$(read_maybe_sudo "$SECRETS_FILE")" || die "cannot read --secrets file: ${SECRETS_FILE}"
  # Only well-formed KEY=VALUE lines count; comments/blanks in the source are fine
  # and simply ignored. The captured names are safe to print — they are keys.
  declared="$(printf '%s\n' "$secrets" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p')"
  if [ -z "$declared" ]; then
    warn "--secrets file has no KEY=VALUE lines — nothing merged (${SECRETS_FILE})"
    return 0
  fi
  keypat="$(printf '%s\n' "$declared" | paste -sd'|' -)"
  current="$(read_maybe_sudo "$envfile" 2>/dev/null || true)"
  # Drop the keys we are about to redeclare, and any pre-existing blank lines, so
  # a re-run cannot pile up duplicates or grow a gap on every pass.
  filtered="$(printf '%s\n' "$current" | grep -Ev "^(${keypat})=" | grep -v '^[[:space:]]*$' || true)"
  lines="$(printf '%s\n' "$secrets" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=')"
  new="$(printf '%s\n%s' "$filtered" "$lines")"
  # 0600 from birth (install /dev/null first), then stream the content in — the
  # values reach the file through a pipe, never an argument.
  $su install -m 600 /dev/null "$envfile"
  printf '%s\n' "$new" | $su tee "$envfile" >/dev/null
  $su chmod 600 "$envfile"
  # Hand it to the service account only in systemd mode (docker leaves it with the
  # invoking user). Guarded: the account may not exist yet in a dry run.
  #
  # -h, because $envfile sits in a directory the core owns and this is root. It
  # cannot follow a link, so a link planted at that name takes the ownership
  # change on itself instead of passing it to whatever it points at. Costs
  # nothing: the line already ends in `|| true`, so it cannot abort either way.
  #
  # What -h does NOT close, stated because it is the more valuable half: the
  # `tee` three lines up writes the merged secrets to that same name, so a link
  # planted before it puts the contents — a bot token, a GitHub token — into a
  # path of the core's choosing. Nothing available in bash closes that: the file
  # is written by redirecting into a name, and naming a path is the whole of the
  # exposure. A guard here would only narrow the window, not remove it, and the
  # honest fix is that the core should not be able to reach this directory at
  # all. Filed, not attempted here.
  [ "${INSTALL_MODE:-}" = "systemd" ] && [ -n "${SUDO:-}" ] \
    && $SUDO chown -h "${SERVICE_USER}:${SERVICE_USER}" "$envfile" 2>/dev/null || true
  n="$(printf '%s\n' "$declared" | grep -c . || true)"
  ok "merged ${n} contour secret key(s) into .env: $(printf '%s ' $declared)"
}

# Resolve the GitHub token from the merged .env, by the operator's chosen key if
# any, else the two gh honours natively. Echoes the value on stdout for a caller
# to capture into a local and pass by environment — it is never logged.
resolve_gh_token() { # resolve_gh_token — echoes the token, or empty
  local key val
  for key in ${GH_TOKEN_KEY:+"$GH_TOKEN_KEY"} GH_TOKEN GITHUB_TOKEN; do
    val="$(read_maybe_sudo "$INSTALL_DIR/.env" 2>/dev/null | sed -n "s/^${key}=//p" | tail -1)"
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  done
  return 0
}

# Run a command AS the service account, with its install root as $HOME (so gh
# and git read that account's ~/.config/gh and ~/.gitconfig) and GH_TOKEN carried
# in from the caller's ENVIRONMENT — never placed on argv.
run_as_service() { # run_as_service <cmd> [args...]
  if [ "$(id -u)" = 0 ]; then
    HOME="$INSTALL_DIR" runuser -u "$SERVICE_USER" -- "$@"
  else
    $SUDO -u "$SERVICE_USER" --preserve-env=GH_TOKEN env HOME="$INSTALL_DIR" "$@"
  fi
}

# Ensure the GitHub CLI is present — the acceptance is `gh pr view/checks`, which
# needs the binary, not just a token. Try the distro first (Ubuntu 24.04 ships
# it), then GitHub's own apt repo; degrade to a warning rather than failing the
# install (git-over-https still works through the credential helper).
ensure_gh() {
  command -v gh >/dev/null 2>&1 && return 0
  $SUDO apt-get -o DPkg::Lock::Timeout=120 install -y -qq gh >/dev/null 2>&1 \
    && command -v gh >/dev/null 2>&1 && { ok "gh installed (apt)"; return 0; }
  info "adding the GitHub CLI apt repo"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null \
    | $SUDO tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1 || true
  $SUDO chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null 2>&1 || true
  $SUDO apt-get -o DPkg::Lock::Timeout=120 update -qq >/dev/null 2>&1 || true
  $SUDO apt-get -o DPkg::Lock::Timeout=120 install -y -qq gh >/dev/null 2>&1 \
    && command -v gh >/dev/null 2>&1 && { ok "gh installed (github apt repo)"; return 0; }
  warn "could not install gh — 'gh pr view/checks' stays unavailable until it is; git over https still works"
  return 0
}

# Lay down the contour's checkouts under the instance and authenticate gh/git to
# them, all as the service account. Clones/fetches are best-effort per repo: one
# unreachable repo must not abort the install or the others.
setup_contour_repos() {
  [ "${#CONTOUR_REPOS[@]}" -gt 0 ] || return 0
  step "Contour repos"
  ensure_gh
  local token reposdir="$INSTALL_DIR/repos" url name
  token="$(resolve_gh_token)"
  if [ -z "$token" ]; then
    warn "no GitHub token in .env (looked for ${GH_TOKEN_KEY:+${GH_TOKEN_KEY}, }GH_TOKEN, GITHUB_TOKEN)"
    warn "repos will be attempted unauthenticated — declare the token in --secrets for private repos"
  fi
  # Same guard as the signal directories, and this site needs it MORE. There is
  # no race to win here: the installer has just blocked in wait_healthz until the
  # core answered, and there is no `systemctl stop` anywhere in the install path,
  # so on a re-run the core is live and running while root does this. It owns
  # $INSTALL_DIR; it can point `repos` wherever it likes and be certain root will
  # arrive.
  #
  # `return 0`, not a skipped chown: the clone loop below writes into
  # $reposdir/$name, so continuing would clone THROUGH the link — root creating
  # trees wherever it points. `return`, never `die`: a refusal must not abort an
  # otherwise healthy install, exactly as in create_signal_dirs.
  plain_dir_ok "$reposdir" "contour repos directory" || return 0
  $SUDO mkdir -p "$reposdir"
  # -h for the same reason it is on the signal directories: it cannot follow a
  # link, so if one is planted between the guard and here, the ownership change
  # lands on the link and not on what it names.
  $SUDO chown -h "${SERVICE_USER}:${SERVICE_USER}" "$reposdir"
  # Authenticate git to GitHub via gh's credential helper, once, for the account.
  # GH_TOKEN is exported into run_as_service's environment — never onto its argv.
  if [ -n "$token" ] && command -v gh >/dev/null 2>&1; then
    if GH_TOKEN="$token" run_as_service gh auth setup-git >/dev/null 2>&1; then
      ok "gh auth setup-git configured for ${SERVICE_USER}"
    else
      warn "gh auth setup-git failed — check the token's scope (repo, read:org)"
    fi
  fi
  for url in "${CONTOUR_REPOS[@]}"; do
    name="$(basename "${url%.git}")"
    if [ -d "$reposdir/$name/.git" ]; then
      if GH_TOKEN="$token" run_as_service git -C "$reposdir/$name" fetch --all --prune >/dev/null 2>&1; then
        ok "fetched ${name}"
      else
        warn "git fetch ${name} failed — check the token or the URL"
      fi
    else
      if GH_TOKEN="$token" run_as_service git clone "$url" "$reposdir/$name" >/dev/null 2>&1; then
        ok "cloned ${name} → ${reposdir}/${name}"
      else
        warn "git clone ${name} failed — check the token or the URL (${url})"
      fi
    fi
  done
}

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

# What a run should do about VERSIONS, as a pure function of (channel, what is
# already installed, --upgrade). Kept separate from the install path so the rule
# is testable without root, network or a box: see scripts/tests/install-upgrade.test.sh.
#
# The rule (#106): a re-run over an existing install refreshes config but never
# moves the version on its own. Moving versions belongs to `agentos upgrade`,
# which snapshots the database first and leaves a rollback pointer; this script
# does neither, so following the channel silently would run new migrations on
# live data with no way back.
version_decision() { # version_decision <channel-tag> <installed-tag> <allow-upgrade> → install|keep|upgrade
  local channel="$1" installed="$2" allow="$3"
  if [ -z "$installed" ]; then printf 'install %s\n' "$channel"; return 0; fi
  if [ "$installed" = "$channel" ]; then printf 'install %s\n' "$channel"; return 0; fi
  if [ "$allow" = "1" ]; then printf 'upgrade %s %s\n' "$installed" "$channel"; return 0; fi
  printf 'keep %s\n' "$installed"
}

if [ -n "${AGENTOS_PRINT_VERSION_DECISION:-}" ]; then
  version_decision "${AGENTOS_TEST_CHANNEL_TAG:-}" "${AGENTOS_TEST_INSTALLED_TAG:-}" "$ALLOW_UPGRADE"
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

# ─── host authority: the sudoers drop-in ─────────────────────────────────────
#
# install_selfmgmt_sudoers (systemd path) drops a file at
# /etc/sudoers.d/<user>-selfmgmt. What it grants is one knob, and the DEFAULT is
# full: `<user> ALL=(ALL) NOPASSWD: ALL`.
#
# Why full by default. AgentOS is an operator — the thing people install it to do
# is administer the box it runs on: edit a config under /etc, restart a
# neighbouring service, read a journal, install a package. A scoped grant does
# not make that safe, it makes it fail HALFWAY: the agent gets far enough to be
# trusted with the task and then dead-ends on a permission it was never given,
# and the human is back in the loop for the last step. The node also runs its
# sessions with the harness's bypass-equivalent permission mode (see
# apps/api/src/core/harness/acp-harnesses.ts) — an agent that may run any command
# but may not become root is not a security boundary, it is a limp.
#
# This is a REAL grant of the whole host to a software agent, and it is opt-out,
# not opt-in. `--scoped-sudo` selects the old narrow drop-in instead: NOPASSWD on
# exactly three commands against its OWN unit (restart, status, journal) and
# nothing else on the box. Pick it when the node shares a host with something it
# must not be able to touch. On a machine installed FOR AgentOS, the default is
# the honest setting.
#
# Either body carries absolute binary paths (a sudoers requirement — a bare name
# would let $PATH decide which `systemctl` runs) and, in the scoped form, matches
# the unit token exactly, so a neighbour instance's unit (agentos-<other>) can
# never satisfy the rules. render_selfmgmt_sudoers is a pure function of
# (user, unit, scope) so the exact drop-in body is testable without root — see
# AGENTOS_PRINT_SUDOERS below and scripts/tests/install-sudoers.test.sh.
render_selfmgmt_sudoers() { # render_selfmgmt_sudoers <user> <unit> [scope] → drop-in body on stdout
  local user="$1" unit="$2" scope="${3:-full}"
  if [ "$scope" = "selfmgmt" ]; then
    cat <<EOF
# AgentOS per-instance self-management for the '${user}' instance (--scoped-sudo).
# Written by install.sh — do NOT edit by hand; a re-run or upgrade rewrites it,
# an uninstall removes it. Grants ${user} NOPASSWD sudo for EXACTLY three
# commands against its own unit (${unit}.service) and nothing else on this host:
# restart it, read its status, and read its journal. No bare systemctl, no other
# unit's journal.
${user} ALL=(root) NOPASSWD: /usr/bin/systemctl restart ${unit}, /usr/bin/systemctl status ${unit}, /usr/bin/journalctl -u ${unit} *
EOF
  else
    cat <<EOF
# AgentOS host authority for the '${user}' instance (${unit}.service).
# Written by install.sh — do NOT edit by hand; a re-run or upgrade rewrites it,
# an uninstall removes it.
#
# This grants ${user} passwordless root on this host — the whole box, not just
# its own unit. That is the default because AgentOS is installed to ADMINISTER
# the machine, and an operator that cannot become root dead-ends mid-task.
# Re-run install.sh with --scoped-sudo to replace this with a drop-in limited to
# restart/status/journal on ${unit}.service alone.
${user} ALL=(ALL) NOPASSWD: ALL
EOF
  fi
}

# "What sudoers drop-in would this command line write?" — answered without root
# or a box, same dry-run contract as AGENTOS_PRINT_IDENTITY above.
if [ -n "${AGENTOS_PRINT_SUDOERS:-}" ]; then
  render_selfmgmt_sudoers "$SERVICE_USER" "$SERVICE_NAME" "$SUDO_SCOPE"
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

# "What would this contour declaration DO to .env, and which repos would it check
# out?" — answered against a real (temp, --dir) install root, without touching a
# machine, network, or root. Same early-exit contract as the print hooks above;
# it actually RUNS merge_contour_secrets so the test asserts the real merge (upsert,
# idempotency, 0600, no value ever printed), then prints only key names + repos.
# Driven by scripts/tests/install-contour.test.sh.
if [ -n "${AGENTOS_PRINT_CONTOUR:-}" ]; then
  SUDO="${SUDO:-}"                       # not yet resolved this early; merge tolerates empty
  $SUDO mkdir -p "$INSTALL_DIR"
  merge_contour_secrets >/dev/null 2>&1 || true
  if [ -f "$INSTALL_DIR/.env" ]; then
    # Print KEYS only — a value must never reach stdout, even in a dry run.
    echo "env_keys=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$INSTALL_DIR/.env" | paste -sd, -)"
    echo "env_mode=$(stat -c '%a' "$INSTALL_DIR/.env" 2>/dev/null || echo '?')"
  else
    echo "env_keys="
    echo "env_mode=none"
  fi
  _rnames=""
  for _r in ${CONTOUR_REPOS+"${CONTOUR_REPOS[@]}"}; do
    _n="$(basename "${_r%.git}")"; _rnames="${_rnames:+${_rnames},}${_n}"
  done
  echo "repos=${_rnames}"
  echo "gh_token_key=${GH_TOKEN_KEY}"
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

# Idempotent key upsert into an EXISTING .env, usable from both install modes.
# Deliberately not the docker section's set_env(): that one is defined below both
# call sites of install_autoupdate_timer, so calling it from there would be
# `command not found` under `set -euo pipefail` — in exactly the branch that
# repairs an old node.
#
# `cp` onto the original file rather than `install`/`mv`: the destination keeps
# its own owner and mode that way. On bare metal .env belongs to the service
# account (install_systemd chowns the tree), and handing it back as a root-owned
# copy would take the instance's own config away from it.
env_upsert() { # env_upsert <file> <key> <value>
  local file="$1" key="$2" value="$3" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp)"
  { $SUDO grep -v "^${key}=" "$file" 2>/dev/null || true; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  $SUDO cp "$tmp" "$file"
  rm -f "$tmp"
}

# The node's auto-apply appetite is STICKY across re-runs — the same exception
# the admin pair gets (inherit_admin_from_dotenv above), for the same reason.
# write_env_systemd rewrites .env wholesale from the current flags, and the
# policy migration below rescues the operator's value only while policy.conf
# still exists, which the very run that migrates it deletes. Without this, any
# LATER run of the installer — a contour backfill, --upgrade, a repair run —
# would hand the node back to policy=all and it would silently resume taking
# every eligible release unattended, breaking and major included. The drop-in
# used to give this for free (it was written only when the var was set, and
# never deleted otherwise, so a re-run preserved it); .env has to carry it now.
#
# The precedence this establishes, in full:
#
#   explicit flag/env  >  policy.conf drop-in  >  inherited .env  >  default all
#
# POLICY_INHERITED is what keeps the middle pair the right way round, and it is
# the same device ADMIN_INHERITED is for the admin pair. Inheriting is not the
# same act as being TOLD: every node installed from this release onward has a
# non-empty policy in .env (write_env_systemd writes the default
# unconditionally), so a plain "is it set?" test would let that inherited value
# outrank a drop-in the operator wrote afterwards — and migrate_policy_dropin's
# `rm -f` would then delete their only record of it. Only a flag/env on THIS run
# outranks a drop-in.
#
# An .env written before this key existed yields empty, which is what leaves the
# first run's policy.conf migration free to fire.
#
# What comes back from .env is VALIDATED, because .env is a file the unprivileged
# core owns and can rewrite, and this value is copied into the root poller's unit
# as `Environment=AGENTOS_AUTOUPDATE_POLICY=<value>`. systemd reads one
# Environment= line as SEVERAL assignments when the value contains whitespace, so
# `all AGENTOS_AUTOUPDATE_NOTIFY_CMD=/bin/sh -c …` would hand that root oneshot a
# command to run — the escalation the missing EnvironmentFile= closes, walked back
# in through the value. The enum is the whole defence, and it is also what the
# core's own env schema accepts (apps/api/src/app/config/env.ts), so a value that
# fails here would have refused to let the node boot anyway.
valid_policy() { # valid_policy <value> — the five words the enum admits
  case "${1:-}" in off|security|patch|minor|all) return 0 ;; *) return 1 ;; esac
}
POLICY_INHERITED=0
inherit_policy_from_dotenv() {
  [ -z "${AGENTOS_AUTOUPDATE_POLICY:-}" ] || return 0
  local found
  found="$(read_maybe_sudo "$INSTALL_DIR/.env" 2>/dev/null \
    | sed -n 's/^AGENTOS_AUTOUPDATE_POLICY=//p' | tail -1 || true)"
  [ -n "$found" ] || return 0
  if ! valid_policy "$found"; then
    # Not adopted, so this run falls through to the flag/default — and
    # write_env_systemd then rewrites the key with that value, which is how a
    # node whose .env was scribbled on heals itself instead of staying broken.
    warn "ignoring AGENTOS_AUTOUPDATE_POLICY='${found}' in ${INSTALL_DIR}/.env — not one of off|security|patch|minor|all"
    return 0
  fi
  AGENTOS_AUTOUPDATE_POLICY="$found"
  POLICY_INHERITED=1
}

# ─── --no-docker (bare metal / systemd) ────────────────────────────────────
#
# No image, no compose profile: the unit of distribution here is a release
# tarball (scripts/release/pack-tarball.sh output) addressed by stable.json
# (Task 2), unpacked straight onto disk, with systemd — not the docker
# daemon — owning the process lifecycle. Task 6's upgrade swaps
# $INSTALL_DIR/current and restarts the agentos.service unit this installs.

write_env_systemd() {
  local preserved="" pair suffix canonical legacy value
  for pair in \
    REPO_DIR:AGENTOS_REPO_DIR REPO_URL:AGENTOS_CONTEXT_IMPORT_URL \
    REPO_REF:AGENTOS_CONTEXT_IMPORT_REF SYNC_BRANCH:AGENTOS_CONTEXT_IMPORT_REF \
    SYNC_PUSH:AGENTOS_SYNC_PUSH SYNC_IDLE_MS:AGENTOS_SYNC_IDLE_MS \
    SYNC_MAX_MS:AGENTOS_SYNC_MAX_MS SYNC_POLL_MS:AGENTOS_SYNC_POLL_MS \
    SYNC_SUBMODULES:AGENTOS_SYNC_SUBMODULES \
    SYNC_SUBMODULE_DEPTH:AGENTOS_SYNC_SUBMODULE_DEPTH \
    SYNC_SUBMODULE_TIMEOUT_MS:AGENTOS_SYNC_SUBMODULE_TIMEOUT_MS \
    DEPS_ENABLED:AGENTOS_DEPS_ENABLED GITHUB_TOKEN:AGENTOS_GITHUB_TOKEN \
    AUTH_PTY:AGENTOS_AUTH_PTY STATE_MARKER:AGENTOS_STATE_MARKER; do
    suffix="${pair%%:*}"; canonical="${pair#*:}"; legacy="RECE$(printf %s IVER_)${suffix}"
    value="$(read_maybe_sudo "$INSTALL_DIR/.env" 2>/dev/null | sed -n "s/^${canonical}=//p" | tail -1 || true)"
    [ -n "$value" ] || value="$(read_maybe_sudo "$INSTALL_DIR/.env" 2>/dev/null | sed -n "s/^${legacy}=//p" | tail -1 || true)"
    [ -n "$value" ] && preserved="${preserved}${canonical}=${value}
"
  done
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
AGENTOS_DATA_DIR=${INSTALL_DIR}/data
AOP_STATE_DIR=${INSTALL_DIR}/data/.aop
MINIAPP_DIST_DIR=${INSTALL_DIR}/current/miniapp-dist
# The update channel, in the one place both halves of it read: the in-core
# detector (which pokes) and the root poller (which decides and applies) load
# this same file, so they can never disagree about the channel, the node's
# appetite, or where the signal files are. The paths are written out rather than
# derived per consumer — a named instance has install root /opt/<user> but unit
# name agentos-<user>, so two derivations would land in two directories.
AGENTOS_CHANNEL=${CHANNEL}
AGENTOS_AUTOUPDATE_POLICY=${AGENTOS_AUTOUPDATE_POLICY:-all}
AGENTOS_SIGNAL_INBOX=${INSTALL_DIR}/signals
AGENTOS_SIGNAL_OUTBOX=${HOST_PREFIX}/var/lib/${SERVICE_NAME}/outbox
EOF
  [ -n "$preserved" ] && printf '%s' "$preserved" | $SUDO tee -a "$INSTALL_DIR/.env" >/dev/null
  $SUDO chmod 600 "$INSTALL_DIR/.env"
  # Explicit if, NOT `[ -n ] && …`: as the function's last command, a false
  # test would become its exit status and `set -e` would kill the install at
  # the call site — exactly the --no-https path, before the unit even exists.
  if [ -n "$DOMAIN" ]; then
    echo "MINIAPP_URL=https://${DOMAIN}/app" | $SUDO tee -a "$INSTALL_DIR/.env" >/dev/null
  fi
}

# The two signal directories, and why they are TWO. The core writes pokes, root
# writes results; one shared writable directory would let a compromised core
# replace result.json with a symlink and have root write through it. Separate
# ownership removes that without a single check in either program.
#
#   inbox  — $INSTALL_DIR/signals, owned by the service account so the core can
#            write. Inside the install root because that is the tree the
#            service account owns.
#   outbox — /var/lib/<unit>/outbox, root-owned, group = the service account so
#            the core can READ result.json without being able to create
#            anything there. Deliberately OUTSIDE the install root: install.sh
#            chowns that whole tree to the service account on every re-run.
#
# Keyed off SERVICE_NAME, not the install root's basename: `--user hub` gives
# /opt/hub but the unit is agentos-hub, and the poller's own fallback would
# derive /var/lib/hub. write_env_systemd writes the resulting path into .env,
# which is what keeps every consumer on this one directory.
#
# WHO the core is differs by install mode, and only that differs — same split,
# same modes, two spellings of one identity:
#
#   systemd — the unix service account this script creates.
#   docker  — uid 1001 inside the image, and NO host account at all (`--user` is
#             refused in docker mode, and useradd only ever runs on the systemd
#             path). `chown agentos:agentos` there would fail outright on a
#             docker-only host, and would still be wrong if some unrelated
#             `agentos` account happened to exist: the container writes as 1001
#             whatever the host calls it.
CORE_CONTAINER_UID=1001   # docker/Dockerfile.node: useradd -u 1001 -g nodejs
CORE_CONTAINER_GID=1001   # docker/Dockerfile.node: groupadd -g 1001 nodejs
create_signal_dirs() {
  local outbox="${HOST_PREFIX}/var/lib/${SERVICE_NAME}/outbox"
  local inbox_owner="${SERVICE_USER}:${SERVICE_USER}" outbox_group="${SERVICE_USER}"
  if [ "$INSTALL_MODE" = "docker" ]; then
    inbox_owner="${CORE_CONTAINER_UID}:${CORE_CONTAINER_GID}"
    outbox_group="${CORE_CONTAINER_GID}"
  fi
  # Same guard, same reason, and the same PER-DIRECTORY order as the CLI's
  # ensure_signal_dirs — guard, mkdir, chmod, chown, one directory at a time, so
  # that in both files exactly one process stands between a guard and the chmod it
  # protects. Kept in step BY HAND; the two differ only where the message does
  # (this one has no six-hourly timer to reassure anyone about yet). The ordering
  # claim is checked, not merely checkable: scripts/tests/agentos-signals.test.sh
  # traces BOTH functions — this one through its AGENTOS_PRINT_SIGNAL_DIRS
  # dry-run — and reads the commands that run between each `plain_dir_ok` and the
  # `chmod` it guards. Anything but the one mkdir fails. That test was blind to
  # this file until it was made to trace it, and blind to guards altogether
  # before that, so the claim stood while the code drifted. $INSTALL_DIR belongs to the
  # service account (the chown -R below runs on every re-run) and the core runs
  # unconfined, so it can swap `signals` for a symlink
  # and have the chown/chmod land on its target; /etc/systemd/system would hand it
  # every unit root runs. Refuse rather than `chown -h`-retarget: retargeting as a
  # SUBSTITUTE for refusing would leave the attacker's link in place and the node
  # quietly unable to poke, trading a loud failure for a silent one. (`-h` still
  # goes on the chown below — as a belt on top of the refusal, never instead of
  # it; see the ordering note there.) Skipping one directory is never fatal here
  # either — the timer still covers the node.
  # Guard FIRST, create SECOND, and one mkdir per directory: `mkdir -p` over a
  # symlink to a directory succeeds silently (so its exit status says nothing
  # about what is there), over a dangling one it fails — and a single
  # `mkdir -p a b` would let either name take the other down with it.
  #
  # chmod, then `chown -h` — and the residual stated as what THIS CODE does and
  # what a winner gets. This block asserts nothing about what any tool offers on
  # any platform: three such claims were written here and two were wrong, and the
  # versions that decide them belong to the operator's host, not to us.
  #
  # `chown -h` does not close the race and is not the response to a planted
  # symlink: refusing is, above. It runs on a directory just verified, where it
  # is a no-op except in the one case that matters. Nothing here makes
  # check-and-act atomic; what `-h` changes is what LOSING costs. Lost with it,
  # the ownership change lands on the link itself and the target keeps its own
  # uid/gid. Lost without it, root hands the service account whatever the link
  # named, and /etc/systemd/system is every unit root runs.
  #
  # The chmod is a plain chmod on that same just-verified path, so a link
  # swapped in before it runs IS followed. What that wins an attacker: a target
  # that was tighter, widened to 0750 or 0755 — a confidentiality loss, and a
  # denial of service against anything relying on the old mode. What it does not
  # win: ownership, which does not move; or privilege, because the modes this
  # code passes carry no special digit and so cannot ADD setuid or setgid to
  # anything. (Only that half is claimed. Whether such a bit already on the
  # target survives is a question about the host's chmod, and this block does not
  # answer those.) Which is why the chmod goes first, while the guard's answer is
  # newest, and why that ordering is pinned by a test — of BOTH files' windows —
  # rather than left to prose.
  if plain_dir_ok "$INSTALL_DIR/signals" "update-signal inbox"; then
    $SUDO mkdir -p "$INSTALL_DIR/signals"
    $SUDO chmod 0750 "$INSTALL_DIR/signals"
    $SUDO chown -h "$inbox_owner" "$INSTALL_DIR/signals"
  fi
  if plain_dir_ok "$outbox" "update-signal outbox"; then
    $SUDO mkdir -p "$outbox"
    $SUDO chmod 0750 "$outbox"
    $SUDO chown -h "root:${outbox_group}" "$outbox"
  fi
  # The outbox's PARENT, 0755 so the core can traverse into a directory it is not
  # allowed to list. Guarded like the other two rather than argued about: it is
  # root's, under a root-owned /var/lib, so no unprivileged process can plant a
  # link here today — and "today" is not a property a root chmod should rest on.
  # The mkdir is idempotent and is NOT here to cover a reachable case: refusing
  # the outbox above requires something to exist at $STATE/outbox, which requires
  # $STATE itself to exist, so by the time this runs it always does. It is here
  # so that this block does not silently depend on the block above having created
  # it for us — which is the kind of coupling that becomes false later, and a
  # `chmod` on a path that does not exist fails under `set -e`.
  #
  # NOT handled, and stated because the benign case beside it IS an asserted
  # property: a DANGLING symlink at this path still kills the install at rc 1,
  # with a bare `mkdir` error, before the guard below is ever consulted — the
  # outbox above is created first, and its `mkdir -p` walks this component. The
  # guard is leaf-only: it covers the name it is handed, never that name's
  # parents. Both need /var/lib to be writable by the core, which it is not.
  if plain_dir_ok "${HOST_PREFIX}/var/lib/${SERVICE_NAME}" "update-signal state directory"; then
    $SUDO mkdir -p "${HOST_PREFIX}/var/lib/${SERVICE_NAME}"
    $SUDO chmod 0755 "${HOST_PREFIX}/var/lib/${SERVICE_NAME}"
  fi
}

# The docker channel's .env keys for the same two directories. Three readers
# share that file on a docker host, and two of them need DIFFERENT values for
# the same idea, so the mount sources get keys of their own:
#
#   AGENTOS_SIGNAL_INBOX / _OUTBOX       host paths. What the ROOT POLLER is
#       given — not by reading this file (its unit has no EnvironmentFile=: the
#       core owns .env and a root unit must not take an environment from it) but
#       because install_autoupdate_timer and the CLI's reconcile_units copy these
#       values into the unit as Environment= lines. The poller runs on the host in
#       docker mode exactly as it does on bare metal, and its own fallback would
#       derive /var/lib/<basename of --dir>/outbox, so these are what keep it on
#       the directory this script actually created.
#       They also ride into the container through compose's `env_file:`, where
#       the compose `environment:` block overrides them with /signals and
#       /signals-out (environment: outranks env_file for one key).
#   AGENTOS_SIGNAL_INBOX_HOST / _OUTBOX_HOST   the same host paths, read by
#       COMPOSE's ${…} interpolation for the two bind-mount sources, and by
#       nothing else. Separate names rather than reusing the pair above because
#       that pair already means "the container's path" everywhere inside the
#       container: one key with two meanings three lines apart in one file is
#       how someone later deletes the "redundant" override. Compose interpolation
#       also prefers an exported shell variable over .env, so reusing the plain
#       key would let a stray AGENTOS_SIGNAL_INBOX=/signals in the operator's
#       shell silently turn the MOUNT SOURCE into the host's /signals.
#
# env_upsert, not the docker section's set_env(): same reason install_autoupdate_timer
# gives above — set_env is defined 750 lines below this, so only env_upsert can
# also be exercised by the AGENTOS_PRINT_SIGNAL_DIRS dry-run.
write_signal_env_docker() {
  local envfile="$INSTALL_DIR/.env" outbox="${HOST_PREFIX}/var/lib/${SERVICE_NAME}/outbox"
  # In §5 .env already exists (set_env AGENTOS_IMAGE made it); env_upsert is a
  # no-op on a missing file, so create it here rather than silently write nothing.
  [ -f "$envfile" ] || install -m 600 /dev/null "$envfile"
  env_upsert "$envfile" AGENTOS_SIGNAL_INBOX       "${INSTALL_DIR}/signals"
  env_upsert "$envfile" AGENTOS_SIGNAL_OUTBOX      "$outbox"
  env_upsert "$envfile" AGENTOS_SIGNAL_INBOX_HOST  "${INSTALL_DIR}/signals"
  env_upsert "$envfile" AGENTOS_SIGNAL_OUTBOX_HOST "$outbox"
}

# "What would this command line lay down for the signal channel, and for whom?"
# The docker path cannot be dry-run as a whole — it wants a daemon, a registry
# and a compose up — so the two functions above are exercised here directly,
# against a temp install root (--dir) and a temp stand-in for the host's /
# ($AGENTOS_PRINT_SIGNAL_DIRS), the same early-exit contract as
# AGENTOS_PRINT_AUTOUPDATE below. The MODE is not passed in: it is resolved from
# the real flags, so what the test observes is the real branch.
# Driven by scripts/tests/agentos-signals.test.sh.
if [ -n "${AGENTOS_PRINT_SIGNAL_DIRS:-}" ]; then
  SUDO="${SUDO:-}"                       # not yet resolved this early
  HOST_PREFIX="$AGENTOS_PRINT_SIGNAL_DIRS"
  $SUDO mkdir -p "$INSTALL_DIR"
  create_signal_dirs
  if [ "$INSTALL_MODE" = "docker" ]; then write_signal_env_docker; fi
  echo "mode=${INSTALL_MODE}"
  exit 0
fi

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

  # A re-run over an EXISTING install must not move versions behind the
  # operator's back. `agentos upgrade` snapshots the database first and records
  # a rollback pointer; this script does neither, so silently following the
  # channel here would run new migrations on live data with no way back
  # (issue #106 — observed on a live node: a config-only re-run took it from
  # v2.3.0 to v2.4.0 with no backup). Config is still refreshed either way;
  # only the version is pinned.
  local installed="" deferred_upgrade="" decision=""
  if [ -L "$INSTALL_DIR/current" ]; then
    installed="$(basename "$($SUDO readlink "$INSTALL_DIR/current")")"
  fi
  decision="$(version_decision "$tag" "$installed" "$ALLOW_UPGRADE")"
  local keep_version=0
  case "$decision" in
    keep\ *)
      keep_version=1
      warn "installed ${installed}; channel has ${tag} — keeping ${installed}"
      info "this re-run refreshes config only. To move versions:"
      info "  agentos upgrade          — snapshots the database first, health-gated"
      info "  or re-run with --upgrade"
      tag="$installed"; url="" ;;
    upgrade\ *)
      deferred_upgrade="$tag"
      info "will upgrade ${installed} → ${tag} through the CLI (it takes the backup)"
      tag="$installed"; url="" ;;
  esac

  step "Service user + layout"
  # $HOME IS the install root (useradd -d): ~/.claude (CLI state) and ~/.ssh (the
  # deploy key core-entrypoint.sh writes) then follow a custom --dir instead of
  # landing in a home the install knows nothing about.
  id "$SERVICE_USER" >/dev/null 2>&1 || \
    $SUDO useradd -r -m -d "$INSTALL_DIR" -s /usr/sbin/nologin "$SERVICE_USER"
  # logs/: the node's own log file lives here (the unit appends stdout+stderr to
  # logs/node.log — see agentos.service), so the operator can self-diagnose from
  # inside the instance without journalctl or root. Owned by the service
  # account (chown -R below), world-readable once systemd
  # creates the file.
  $SUDO mkdir -p "$INSTALL_DIR"/{versions,data,backups,logs}
  create_signal_dirs

  step "Node ${node_ver} (vendored)"
  # A kept version keeps the runtime it has: node_ver comes from the CHANNEL's
  # manifest, so swapping it here would run an older release under a newer Node
  # than it shipped with — the same "don't move things behind the operator" rule
  # as the version itself. A missing runtime is still installed (repair path).
  if [ "$keep_version" = 1 ] && [ -x "$INSTALL_DIR/node/bin/node" ]; then
    info "keeping the runtime this release was installed with"
  elif [ ! -x "$INSTALL_DIR/node/bin/node" ] || \
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
  # Before the wholesale rewrite, never after: .env is the only place a narrowed
  # auto-update policy still lives once the drop-in is gone.
  inherit_policy_from_dotenv
  write_env_systemd
  # Contour secrets land in .env right after the base keys, so the systemd unit's
  # EnvironmentFile=.env carries them into the running node from its very first
  # boot — GH_TOKEN and the rest are present with nothing added by hand later.
  merge_contour_secrets
  # scripts/release/agentos.service ships with every path spelled as the
  # literal default install root — that IS its placeholder convention (see the
  # comment at the top of that file). A plain cp only works for the default
  # --dir; retargeting every occurrence (EnvironmentFile, ExecStart*,
  # WorkingDirectory, StandardOutput/StandardError alike) is what
  # makes a custom --dir actually boot instead of pointing the unit at
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

  # Check out the contour's repos and authenticate gh/git — as the service
  # account, using the token now in .env. Best-effort per repo: a repo that will
  # not clone must not fail an otherwise-healthy install.
  setup_contour_repos

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
#
# The CLI this execs lives in the RELEASE TREE, so its behaviour depends on
# which release is currently installed. A tree older than per-instance support
# IGNORES the four variables below and operates on the default instance
# instead: it stops \`agentos.service\`, chowns this install to \`agentos\`, waits
# on a health check that the still-running old process answers — and reports
# success while leaving THIS node one restart away from not starting at all.
# That is not hypothetical; it is what an upgrade from such a tree did.
#
# So probe the CLI for the concept before handing it the instance. A source
# probe, not a --flag: the whole point is that the old CLI does not know the
# question, so it cannot answer it truthfully either.
CLI=${INSTALL_DIR}/current/profiles/agentos
if ! grep -q AGENTOS_SERVICE "\$CLI" 2>/dev/null; then
  echo "agentos: the CLI in ${INSTALL_DIR}/current predates per-instance support," >&2
  echo "         so it would manage the DEFAULT instance instead of '${SERVICE_USER}'." >&2
  echo "         Refresh this install first, then retry:" >&2
  echo "         install.sh --user ${SERVICE_USER} --port ${PORT} …" >&2
  exit 3
fi
AGENTOS_DIR=${INSTALL_DIR} AGENTOS_SERVICE=${SERVICE_NAME} \\
AGENTOS_USER=${SERVICE_USER} AGENTOS_PORT=${PORT} \\
  exec "\$CLI" "\$@"
EOF
    $SUDO chmod 755 "/usr/local/bin/${SERVICE_NAME}"
  fi
  ok "agentos CLI → /usr/local/bin/${SERVICE_NAME}"

  # Explicit --upgrade: hand the version change to the CLI rather than swapping
  # the symlink here, so the pre-upgrade snapshot, the .last-upgrade pointer and
  # the health-gated auto-rollback all apply exactly as they do for a normal
  # `agentos upgrade`.
  if [ -n "$deferred_upgrade" ]; then
    step "Upgrade ${tag} → ${deferred_upgrade}"
    "/usr/local/bin/${SERVICE_NAME}" upgrade --to "$deferred_upgrade" \
      || die "upgrade to ${deferred_upgrade} failed; the node is still on ${tag}"
  fi

  install_selfmgmt_sudoers
  install_autoupdate_timer "$INSTALL_DIR/current/profiles"
}

# Drop the instance's sudoers file (systemd path). Idempotent: a re-run/upgrade
# re-renders and overwrites it, so it always tracks the current user/unit AND the
# current scope — re-running with --scoped-sudo narrows an existing full grant,
# re-running without it widens a scoped one back. Validated with `visudo -cf`
# BEFORE it is moved into place — a malformed file in /etc/sudoers.d can lock
# sudo out of the whole host, so a render that fails validation is discarded,
# never installed. Degrades to a warning (never a failed install) on a host with
# no sudo/visudo.
install_selfmgmt_sudoers() {
  step "Host authority (sudoers)"
  if ! command -v visudo >/dev/null 2>&1; then
    warn "visudo not found — the instance's sudoers drop-in was NOT installed."
    info "install the sudo package, then re-run to grant it."
    return 0
  fi
  local dropin="/etc/sudoers.d/${SERVICE_USER}-selfmgmt"
  local tmp; tmp="$(mktemp)"
  render_selfmgmt_sudoers "$SERVICE_USER" "$SERVICE_NAME" "$SUDO_SCOPE" > "$tmp"
  # visudo -cf checks THIS file's syntax in isolation; -f names the file.
  if $SUDO visudo -cf "$tmp" >/dev/null 2>&1; then
    # 0440 root:root is the required mode for a sudoers.d drop-in; `install`
    # sets owner+mode atomically as it copies.
    $SUDO install -m 0440 -o root -g root "$tmp" "$dropin"
    if [ "$SUDO_SCOPE" = "selfmgmt" ]; then
      ok "self-management → ${dropin} (restart/status/journal on ${SERVICE_NAME} only)"
    else
      ok "host authority → ${dropin} (${SERVICE_USER} has passwordless root; --scoped-sudo narrows it)"
    fi
  else
    warn "generated sudoers failed visudo -cf — NOT installed (the node cannot sudo)."
  fi
  rm -f "$tmp"
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
  # its own .path watcher. ExecStart is retargeted at THIS instance's CLI entry
  # point, which is what carries the root/unit/port coordinates.
  local au="${SERVICE_NAME}-autoupdate"
  local units="${HOST_PREFIX}/etc/systemd/system"
  # BEFORE the oneshot is rendered, not after: the migration is what settles the
  # policy for this run, and the unit now CARRIES that policy. Rendering first
  # would arm the poller with `all` while .env said `minor`, until some later
  # upgrade happened to re-render it — the two-source ambiguity this migration
  # exists to remove, one layer down.
  migrate_policy_dropin "${units}/${au}.service.d" "$INSTALL_DIR/.env"
  # The oneshot runs as root and deliberately has no EnvironmentFile= (see the
  # long comment in the template): the core owns .env, so the two values both
  # halves must agree on are copied into the unit BY ROOT instead. They are
  # written from this script's own variables — the same expressions
  # write_env_systemd / write_signal_env_docker put into .env and
  # create_signal_dirs creates on disk — so the unit, the file and the
  # directories cannot drift apart. The policy is the one value that can have
  # come from .env (inherit_policy_from_dotenv); it is enum-checked there and
  # again here, since an explicit AGENTOS_AUTOUPDATE_POLICY=<nonsense> on this
  # run reaches this point too.
  local policy="${AGENTOS_AUTOUPDATE_POLICY:-all}"
  if ! valid_policy "$policy"; then
    # 'off' rather than 'all': the poller's own unknown-policy branch already
    # treats a value it cannot read as 'off', and a typo must not be the thing
    # that widens what a node installs unattended.
    warn "auto-update policy '${policy}' is not one of off|security|patch|minor|all — arming the poller with 'off'"
    policy=off
  fi
  { $SUDO sed -e "s|/opt/agentos|${INSTALL_DIR}|g" \
              -e "s|^ExecStart=/usr/local/bin/agentos |ExecStart=/usr/local/bin/${SERVICE_NAME} |" \
              "$pdir/agentos-autoupdate.service"
    printf 'Environment=AGENTOS_AUTOUPDATE_POLICY=%s\n' "$policy"
    printf 'Environment=AGENTOS_SIGNAL_INBOX=%s\n'  "${INSTALL_DIR}/signals"
    printf 'Environment=AGENTOS_SIGNAL_OUTBOX=%s\n' "${HOST_PREFIX}/var/lib/${SERVICE_NAME}/outbox"
    # The activity-gate thresholds the poller must share with the in-core
    # detector (scripts/agentos-autoupdate.sh). Both halves default identically,
    # so these are carried only when the operator set them for this run; a
    # non-integer value is dropped so the poller keeps the shared default rather
    # than being armed with a word.
    for _gk in AGENTOS_UPDATE_MAX_DEFERRAL AGENTOS_UPDATE_RESTART_INTERVAL; do
      _gv="$(printf '%s' "${!_gk-}")"
      case "$_gv" in
        ''|*[!0-9]*) : ;;
        *) printf 'Environment=%s=%s\n' "$_gk" "$_gv" ;;
      esac
    done
  } | $SUDO tee "${units}/${au}.service" >/dev/null
  # The timer names the unit it fires, so it is rendered too, never copied.
  $SUDO sed -e "s|^Unit=agentos-autoupdate.service$|Unit=${au}.service|" \
            "$pdir/agentos-autoupdate.timer" \
    | $SUDO tee "${units}/${au}.timer" >/dev/null
  # The .path unit — what turns the in-core detector's poke into a root run in
  # seconds instead of at the next backstop tick. It watches this instance's
  # inbox and fires this instance's oneshot: the SAME unit the timer fires, so
  # systemd's per-unit start serialization is what stops a poke and a periodic
  # tick from running two upgrades at once.
  #
  # Optional on purpose: a node upgrading from a release that predates this file
  # has no template, and a bare sed on a missing file would kill the installer
  # under `set -euo pipefail` — after a successful healthz, the worst possible
  # moment. Such a node keeps updating on the timer until Task 11's unit
  # reconciliation gives it the watcher.
  local have_path=0
  if [ -f "$pdir/agentos-autoupdate.path" ]; then
    have_path=1
    $SUDO sed -e "s|/opt/agentos|${INSTALL_DIR}|g" \
              -e "s|^Unit=agentos-autoupdate.service$|Unit=${au}.service|" \
              "$pdir/agentos-autoupdate.path" \
      | $SUDO tee "${units}/${au}.path" >/dev/null
  fi
  $SUDO systemctl daemon-reload
  if $SUDO systemctl enable --now "${au}.timer" >/dev/null 2>&1; then
    # $policy, not the raw variable: this is the value the unit was actually
    # armed with, which is the whole question an operator asks here.
    ok "auto-update backstop timer armed (policy=${policy})"
  else
    warn "could not enable ${au}.timer — arm it with: systemctl enable --now ${au}.timer"
  fi
  if [ "$have_path" = 1 ]; then
    if $SUDO systemctl enable --now "${au}.path" >/dev/null 2>&1; then
      ok "update pokes armed (${au}.path → ${au}.service)"
    else
      warn "could not arm ${au}.path — updates will still arrive on the timer"
    fi
  fi
}

# The node's auto-apply appetite used to live in a systemd drop-in that only the
# root poller could see. The in-core detector reads it too now, so it moved into
# .env — and the drop-in is ABOLISHED, not kept as an override: EnvironmentFile=
# overrides Environment= in systemd, so leaving the drop-in in place would
# silently stop it working, the exact opposite of what an operator who narrowed
# their policy expects. One source, and the old value is carried across before
# the file is deleted.
#
# An explicit policy on THIS run still wins: that is the operator speaking now,
# and honouring a value they set months ago over the flag they just passed would
# be its own silent surprise. Either way the drop-in goes.
migrate_policy_dropin() { # migrate_policy_dropin <dropin-dir> <env-file>
  local dir="$1" env_file="$2" conf="$1/policy.conf" migrated
  [ -f "$conf" ] || return 0
  # Read the value the way SYSTEMD would, not the way install.sh happened to
  # write it. docs/self-host.md tells operators to set the policy "in the
  # drop-in", so this file is hand-edited in the field, and systemd accepts
  # several spellings of one assignment: Environment="K=v", Environment=K="v",
  # a leading indent, spaces around the first =, several assignments on a line,
  # and a CRLF file. The strict `^Environment=K=` pattern matched only the bare
  # form: anything else came back empty, nothing reached .env, and the `rm -f`
  # below then deleted the operator's only record of their choice — the node
  # silently back on `all`. A quoted VALUE was worse than dropped, it arrived in
  # .env with its quotes still on.
  #
  # So: take everything after `Environment=`, drop the quotes whichever spelling
  # used them, split on whitespace (which puts each assignment — and a trailing
  # CR — on its own line), and only then match the key. tail -1 keeps systemd's
  # last-wins rule.
  migrated="$($SUDO sed -n 's/^[[:space:]]*Environment[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null \
    | sed "s/[\"']//g" \
    | tr ' \t\r' '\n\n\n' \
    | sed -n 's/^AGENTOS_AUTOUPDATE_POLICY=//p' | tail -1 || true)"
  # A drop-in is root-owned, so this is the operator's own typo rather than the
  # core's doing — but it ends up in .env and in the poller's unit all the same,
  # so it gets the same enum check. Treated as no value at all: the run keeps the
  # policy it already had instead of adopting a word nothing downstream accepts.
  if [ -n "$migrated" ] && ! valid_policy "$migrated"; then
    warn "the policy drop-in says '${migrated}', which is not one of off|security|patch|minor|all — leaving this node's policy as it is"
    migrated=""
  fi
  # The drop-in loses only to an EXPLICIT policy on this run, never to one that
  # was merely inherited from .env a moment ago — see the ladder above
  # inherit_policy_from_dotenv. Getting this backwards is silent in the worst
  # way: the `rm -f` below then destroys a choice nothing recorded.
  if [ -n "$migrated" ] && \
     { [ -z "${AGENTOS_AUTOUPDATE_POLICY:-}" ] || [ "${POLICY_INHERITED:-0}" = 1 ]; }; then
    # Into the VARIABLE as well as the file: the docker channel writes its .env
    # after this runs (install.sh §5), so a file-only migration would be
    # overwritten by the default a few steps later.
    AGENTOS_AUTOUPDATE_POLICY="$migrated"
    # The value no longer comes from .env, so the flag must stop claiming it does.
    POLICY_INHERITED=0
    env_upsert "$env_file" AGENTOS_AUTOUPDATE_POLICY "$migrated"
    info "auto-update policy '${migrated}' moved from the systemd drop-in into ${env_file}"
  fi
  $SUDO rm -f "$conf"
  # Only when it is now empty — an operator may have their own drop-ins here.
  $SUDO rmdir "$dir" 2>/dev/null || true
}

# "What would this command line arm the update channel with?" — the units it
# renders, the policy it migrates, the signal directories it creates and the
# .env keys every consumer reads them from. It RUNS the real functions, in the
# real order install_systemd runs them, against a temp install root (--dir) and
# a temp stand-in for the host's / ($AGENTOS_PRINT_AUTOUPDATE) — the same
# early-exit contract as AGENTOS_PRINT_CONTOUR above, extended to functions
# whose whole job is writing files. Driven by scripts/tests/agentos-signals.test.sh.
if [ -n "${AGENTOS_PRINT_AUTOUPDATE:-}" ]; then
  SUDO="${SUDO:-}"                       # not yet resolved this early
  HOST_PREFIX="$AGENTOS_PRINT_AUTOUPDATE"
  tag="${AGENTOS_TEST_TAG:-v0.0.0-dryrun}"   # write_env_systemd reads it by dynamic scoping
  $SUDO mkdir -p "$INSTALL_DIR" "${HOST_PREFIX}/etc/systemd/system"
  create_signal_dirs
  inherit_policy_from_dotenv
  write_env_systemd
  # An old release's profiles/ has no .path template — AGENTOS_TEST_PROFILES_DIR
  # is how that node is reproduced here.
  install_autoupdate_timer "${AGENTOS_TEST_PROFILES_DIR:-$(dirname "$0")/scripts/release}"
  # Keys only, never a value: .env holds the bot token. The policy is the one
  # value printed, because "which policy did this run end up with?" is the
  # question the migration exists to answer.
  echo "policy=${AGENTOS_AUTOUPDATE_POLICY:-}"
  exit 0
fi

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
  # Re-run inherits the bot token from the existing 0600 .env, exactly like docker
  # mode does (§3). Without this a hands-off re-run — the contour BACKFILL path,
  # `install.sh --user X --secrets f --repo r -y` — would die for want of --token
  # even though the token is right there in .env. $SUDO exists from §0, so the
  # 0600 root/service-owned file is readable here.
  if [ -z "$BOT_TOKEN" ] && [ -e "$INSTALL_DIR/.env" ]; then
    BOT_TOKEN="$(read_maybe_sudo "$INSTALL_DIR/.env" 2>/dev/null | sed -n 's/^TELEGRAM_BOT_TOKEN=//p' | tail -1 || true)"
    [ -n "$BOT_TOKEN" ] && info "reusing the bot token from the existing .env"
  fi
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

# Same rule as the bare-metal path (#106): a re-run over an existing install
# keeps the image it is already pinned to. Following :stable here would pull a
# newer image and run its migrations on the existing volume WITHOUT the
# pre-upgrade backup `agentos upgrade` takes. An explicit --image is the
# operator naming a version, so it wins; --upgrade opts into following the
# channel.
if [ "$IMAGE_PINNED_BY_USER" != "1" ] && [ "${ALLOW_UPGRADE:-0}" != "1" ] && \
   [ -f "$INSTALL_DIR/.env" ] && grep -qs '^AGENTOS_IMAGE=' "$INSTALL_DIR/.env"; then
  pinned="$(grep '^AGENTOS_IMAGE=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
  if [ -n "$pinned" ] && [ "$pinned" != "$IMAGE_REF" ]; then
    warn "installed image is already pinned; channel has a newer one — keeping the pin"
    info "this re-run refreshes config only. To move versions:"
    info "  agentos upgrade          — backs up first, health-gated"
    info "  or re-run with --upgrade"
    IMAGE_REF="$pinned"
  fi
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
# install never had). `agentos upgrade` re-extracts this CLI (plus the
# auto-update poller and, when unedited, the compose file/Caddyfile) from every
# new image it installs — docker_refresh_profiles() in scripts/agentos — so a
# materially changed CLI lands on the next upgrade without re-running install.
if [ -f "$INSTALL_DIR/agentos" ]; then
  chmod +x "$INSTALL_DIR/agentos"
  $SUDO ln -sfn "$INSTALL_DIR/agentos" /usr/local/bin/agentos
  ok "agentos CLI → /usr/local/bin/agentos"
fi
[ -f "$INSTALL_DIR/agentos-autoupdate.sh" ] && chmod +x "$INSTALL_DIR/agentos-autoupdate.sh"
# The policy this node already has, BEFORE the unit that now carries it is
# rendered. §5 below does the same inherit for .env's sake, and on the bare-metal
# path write_env_systemd has already run by the time the timer is installed — but
# here the units go in two hundred lines EARLIER than .env is written, so without
# this the oneshot would be armed with `all` while §5 wrote the operator's
# narrowed policy into .env: the file and the unit disagreeing on a re-run, which
# is precisely the failure the drop-in migration was meant to end. Idempotent, so
# the second call in §5 is a no-op.
inherit_policy_from_dotenv
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
adopt_legacy_agentos_key() { # suffix canonical — one-release in-place VPS migration
  local legacy="RECE$(printf %s IVER_)$1" canonical="$2" value
  [ -f .env ] || return 0
  value="$(sed -n "s/^${legacy}=//p" .env | tail -1)"
  if [ -n "$value" ] && ! grep -qE "^${canonical}=" .env; then
    set_env "$canonical" "$value"
    info "migrated deprecated config key to ${canonical}"
  fi
  unset_env "$legacy"
}
umask 077   # the bot token is in here
adopt_legacy_agentos_key REPO_DIR AGENTOS_REPO_DIR
adopt_legacy_agentos_key REPO_URL AGENTOS_CONTEXT_IMPORT_URL
adopt_legacy_agentos_key REPO_REF AGENTOS_CONTEXT_IMPORT_REF
adopt_legacy_agentos_key SYNC_BRANCH AGENTOS_CONTEXT_IMPORT_REF
adopt_legacy_agentos_key SYNC_PUSH AGENTOS_SYNC_PUSH
adopt_legacy_agentos_key SYNC_IDLE_MS AGENTOS_SYNC_IDLE_MS
adopt_legacy_agentos_key SYNC_MAX_MS AGENTOS_SYNC_MAX_MS
adopt_legacy_agentos_key SYNC_POLL_MS AGENTOS_SYNC_POLL_MS
adopt_legacy_agentos_key SYNC_SUBMODULES AGENTOS_SYNC_SUBMODULES
adopt_legacy_agentos_key SYNC_SUBMODULE_DEPTH AGENTOS_SYNC_SUBMODULE_DEPTH
adopt_legacy_agentos_key SYNC_SUBMODULE_TIMEOUT_MS AGENTOS_SYNC_SUBMODULE_TIMEOUT_MS
adopt_legacy_agentos_key DEPS_ENABLED AGENTOS_DEPS_ENABLED
adopt_legacy_agentos_key GITHUB_TOKEN AGENTOS_GITHUB_TOKEN
adopt_legacy_agentos_key AUTH_PTY AGENTOS_AUTH_PTY
adopt_legacy_agentos_key STATE_MARKER AGENTOS_STATE_MARKER
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
# The update channel's own keys, exactly as write_env_systemd writes them on
# bare metal — the container's core, the host's root poller and compose itself
# all read this file, so the signal paths are stated once here rather than
# derived three times. The mounts that make those paths reachable from inside
# the container are the compose file's half of this; a node whose compose file
# was edited locally keeps its own and simply never gets them, at which point the
# detector finds no inbox, says so once, and lives on the backstop timer.
set_env AGENTOS_CHANNEL "$CHANNEL"
# Sticky across re-runs, exactly as on bare metal: this branch rewrites the key
# from the env var, so without the inherit an operator's narrowed policy would
# survive only until the next `install.sh` run. install_autoupdate_timer ran
# earlier (§2) and may already have filled the var from the migrated drop-in, in
# which case this is a no-op and that value wins.
inherit_policy_from_dotenv
set_env AGENTOS_AUTOUPDATE_POLICY "${AGENTOS_AUTOUPDATE_POLICY:-all}"
# Both pairs of signal keys — the host paths the root poller reads, and the
# mount sources compose interpolates. See write_signal_env_docker for which key
# belongs to whom and why they are not one key.
write_signal_env_docker
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

# Contour secrets merge into .env here too, so a container install's env-file
# carries them into the node. Repo checkouts, though, need a unix service account
# ($INSTALL_DIR is a container in docker mode), so they stay systemd-only — warn
# rather than silently ignore a --repo the operator passed.
merge_contour_secrets
if [ "${#CONTOUR_REPOS[@]}" -gt 0 ]; then
  warn "--repo is systemd-mode only (docker has no service account to check out under); secrets were still merged. Run the bare-metal install for repo checkouts."
fi

# ─── 6. up ──────────────────────────────────────────────────────────────────

# The host side of the signal channel, laid down before the mounts want it.
# Leaving it to compose is not an option: docker creates a missing bind-mount
# source itself, root-owned 0755, and the core (uid 1001) would then take EACCES
# on every poke it writes — a node that looks mounted and never updates.
#
# Must run AFTER the `chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"` in §2, which
# walks the whole install root on every re-run and would otherwise hand the inbox
# back to the invoking user.
create_signal_dirs

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
