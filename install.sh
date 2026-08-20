#!/usr/bin/env bash
#
#   elele. DNS installer
#
#   Installs AdGuard Home and the elele. DNS dashboard on one box, wires them
#   together, and hands back two URLs.
#
#   The reason this exists rather than a README with twelve steps: every one of
#   those steps is a place to get it subtly wrong, and the failure mode of
#   getting DNS subtly wrong is a household that cannot load anything while
#   somebody reads a wiki page on a phone that also cannot load anything.
#
#   Usage:
#     curl -fsSL https://dns.elele.dev/install.sh | sudo bash
#     ./install.sh --help
#
#   It is safe to run twice. Every step checks for what it is about to create.
#
set -Eeuo pipefail

# Tracks the application's version rather than counting its own releases. The
# installer is not a separate product and nobody installs it on purpose: when
# somebody pastes a version into an issue, the useful answer is which elele. DNS
# this box is running, not which revision of the shell script fetched it.
VERSION="0.2.0"

# ---------------------------------------------------------------------------
# Defaults, all overridable
# ---------------------------------------------------------------------------

INSTALL_DIR="${ELELE_DIR:-/opt/elele-dns}"
DASH_PORT="${ELELE_PORT:-3000}"
AGH_UI_PORT="${AGH_PORT:-3001}"
AGH_HOST=""
AGH_USER=""
AGH_PASS=""
IMAGE="${ELELE_IMAGE:-hunterelele/elele-dns:latest}"

# Where to fetch this script from when it needs to leave a copy of itself behind
# and cannot find one on disk, which is every `curl | bash` run.
SELF_URL="${ELELE_INSTALLER_URL:-https://dns.elele.dev/install.sh}"

WITH_ADGUARD="ask"     # ask | yes | no
ASSUME_YES=0
DRY_RUN=0
DO_UNINSTALL=0
DO_UPDATE=0
LOG_FILE="${TMPDIR:-/tmp}/elele-install-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Terminal
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  ACCENT=$'\033[38;5;81m'   # the brand's blue, as close as 256 colours get
  AMBER=$'\033[38;5;214m'
  GREEN=$'\033[38;5;114m'
  RED=$'\033[38;5;203m'
  GREY=$'\033[38;5;245m'
else
  BOLD=""; DIM=""; RESET=""; ACCENT=""; AMBER=""; GREEN=""; RED=""; GREY=""
fi

STEP_NO=0
STEP_TOTAL=7

log()   { printf '%s\n' "$*" >>"$LOG_FILE"; }
say()   { printf '%s\n' "$*"; log "$*"; }
info()  { printf '  %s%s%s\n' "$GREY" "$*" "$RESET"; log "INFO $*"; }
ok()    { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; log "OK $*"; }
warn()  { printf '  %s!%s %s\n' "$AMBER" "$RESET" "$*"; log "WARN $*"; }
die()   { printf '\n  %s✗ %s%s\n\n' "$RED" "$*" "$RESET"; log "FATAL $*"; exit 1; }

step() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s%s[%d/%d]%s %s%s%s\n' "$BOLD" "$ACCENT" "$STEP_NO" "$STEP_TOTAL" "$RESET" "$BOLD" "$*" "$RESET"
  log "== STEP $STEP_NO $*"
}

rule() { printf '%s%s%s\n' "$GREY" "────────────────────────────────────────────────────────────" "$RESET"; }

banner() {
  printf '\n'
  printf '   %s%selele%s%s.%s%s DNS%s\n' "$BOLD" "" "$RESET" "$ACCENT" "$RESET" "$DIM" "$RESET"
  printf '   %sa dashboard for the DNS your house actually uses%s\n' "$GREY" "$RESET"
  printf '   %sinstaller v%s%s\n\n' "$DIM" "$VERSION" "$RESET"
}

# A spinner that survives being piped to a file: it only draws on a real tty.
spin() {
  local pid=$1 message=$2 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  if [[ ! -t 1 ]]; then wait "$pid"; return $?; fi
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % ${#frames} ))
    printf '\r  %s%s%s %s' "$ACCENT" "${frames:i:1}" "$RESET" "$message"
    sleep 0.08
  done
  printf '\r\033[K'
  wait "$pid"
}

confirm() {
  local prompt=$1 default=${2:-y} reply
  if (( ASSUME_YES )); then return 0; fi
  if [[ ! -t 0 ]]; then
    # Piped from curl with no tty: anything that needs an answer takes the
    # default rather than reading the script's own source as keystrokes.
    [[ "$default" == "y" ]]
    return $?
  fi
  local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
  printf '  %s?%s %s %s%s%s ' "$ACCENT" "$RESET" "$prompt" "$DIM" "$hint" "$RESET"
  read -r reply || true
  reply="${reply:-$default}"
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

ask() {
  local prompt=$1 default=$2 reply
  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then printf '%s' "$default"; return; fi
  printf '  %s?%s %s %s[%s]%s ' "$ACCENT" "$RESET" "$prompt" "$DIM" "$default" "$RESET" >&2
  read -r reply || true
  printf '%s' "${reply:-$default}"
}

ask_secret() {
  local prompt=$1 reply
  if [[ ! -t 0 ]]; then printf ''; return; fi
  printf '  %s?%s %s ' "$ACCENT" "$RESET" "$prompt" >&2
  read -rs reply || true
  printf '\n' >&2
  printf '%s' "$reply"
}

run() {
  log "RUN $*"
  if (( DRY_RUN )); then
    printf '  %s· would run:%s %s\n' "$DIM" "$RESET" "$*"
    return 0
  fi
  "$@" >>"$LOG_FILE" 2>&1
}

on_error() {
  local line=$1
  printf '\n  %s✗ failed at line %s%s\n' "$RED" "$line" "$RESET"
  printf '  %sthe full log is at %s%s\n\n' "$GREY" "$LOG_FILE" "$RESET"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF

  ${BOLD}elele. DNS installer${RESET}

  ${BOLD}Usage${RESET}
    ./install.sh [options]

  ${BOLD}Options${RESET}
    --with-adguard        Install AdGuard Home as well (default: ask)
    --dashboard-only      Assume AdGuard Home is already running
    --agh-url URL         Existing AdGuard Home, e.g. http://192.168.1.10:3000
    --agh-user USER       AdGuard Home admin username
    --agh-pass PASS       AdGuard Home admin password
    --port PORT           Port for the dashboard        (default: ${DASH_PORT})
    --agh-port PORT       Port for AdGuard Home's UI    (default: ${AGH_UI_PORT})
    --dir PATH            Install directory             (default: ${INSTALL_DIR})
    --image REF           Container image               (default: ${IMAGE})
    -y, --yes             Take every default, ask nothing
    --dry-run             Print what would happen, change nothing
    --update              Pull the newest image and restart, nothing else
    --uninstall           Stop and remove the dashboard (keeps your data)
    -h, --help            This
    -V, --version         Print the version and exit

  ${BOLD}Examples${RESET}
    ${GREY}# the whole thing, on a fresh Raspberry Pi${RESET}
    sudo ./install.sh --with-adguard -y

    ${GREY}# dashboard only, pointed at the resolver you already run${RESET}
    sudo ./install.sh --dashboard-only --agh-url http://192.168.1.10:3000

    ${GREY}# later, to move to the newest release${RESET}
    sudo ./install.sh --update

  ${BOLD}Reading it first${RESET}
    ${GREY}# if you would rather not pipe a URL into a root shell${RESET}
    curl -fsSL https://dns.elele.dev/install.sh -o install.sh
    less install.sh
    chmod +x install.sh && sudo ./install.sh

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-adguard)   WITH_ADGUARD="yes"; shift ;;
    --dashboard-only) WITH_ADGUARD="no"; shift ;;
    --agh-url)        AGH_HOST="${2:?}"; shift 2 ;;
    --agh-user)       AGH_USER="${2:?}"; shift 2 ;;
    --agh-pass)       AGH_PASS="${2:?}"; shift 2 ;;
    --port)           DASH_PORT="${2:?}"; shift 2 ;;
    --agh-port)       AGH_UI_PORT="${2:?}"; shift 2 ;;
    --dir)            INSTALL_DIR="${2:?}"; shift 2 ;;
    --image)          IMAGE="${2:?}"; shift 2 ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --update|--upgrade) DO_UPDATE=1; shift ;;
    --uninstall)      DO_UNINSTALL=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    -V|--version)     printf 'elele. DNS installer %s\n' "$VERSION"; exit 0 ;;
    *)                die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

port_busy() {
  local port=$1
  if have ss; then ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
  elif have netstat; then netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
  else return 1
  fi
}

lan_address() {
  local ip=""
  if have ip; then ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  fi
  [[ -z "$ip" ]] && have hostname && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "${ip:-127.0.0.1}"
}

# Resolved once into a real command, deliberately not a shell function.
#
# This used to be `compose() { docker compose "$@"; }`, called as
# `as_root "${COMPOSE[@]}" pull`. For anyone not already root that expands to
# `sudo compose pull`, and sudo does not know about shell functions: it searches
# PATH and, on Debian and Ubuntu, finds /usr/bin/compose from the `mailcap`
# package. The install then failed with
#
#   Warning: unknown mime-type for "pull" -- using "application/octet-stream"
#   Error: no "compose" mailcap rules found for type "application/octet-stream"
#
# which names neither Docker nor this script, and sends the reader looking for a
# problem with their MIME configuration.
#
# An array holds a real binary and its subcommand, so it survives sudo intact.
COMPOSE=()

resolve_compose() {
  # Written as an if rather than `(( ... )) && return 0`. Under `set -e` an
  # arithmetic expression evaluating to zero is a failing command, and relying on
  # where it sits in a && list to stay non-fatal is the kind of subtlety that
  # breaks the moment somebody edits the line.
  if (( ${#COMPOSE[@]} )); then return 0; fi
  if as_root docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif as_root docker-compose version >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    die "no Docker Compose found (tried 'docker compose' and 'docker-compose')"
  fi
}

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------
#
# This script stays on the box after it has done its job, so the cheapest place
# to put "get the newest one" is the thing already sitting in the install
# directory. The alternative is asking somebody to remember two compose
# subcommands and which directory to run them in, months after the one evening
# they thought about any of this.
#
# It does not touch the resolver, the configuration or the database. Updating a
# dashboard should be the least interesting thing that happens all week.

if (( DO_UPDATE )); then
  banner
  say "  ${BOLD}Updating the dashboard${RESET}"
  rule

  [[ -f "$INSTALL_DIR/docker-compose.yml" ]] \
    || die "nothing installed at $INSTALL_DIR (use --dir if it lives elsewhere)"

  have docker || die "docker is not installed"

  # The tag is a moving target, so identity comes from the image ID. Comparing
  # the tag against itself would report success without proving anything moved.
  before="$(as_root docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || echo none)"
  info "currently running ${before#sha256:}"

  # After the dry-run exit, because resolving it shells out to Docker and a
  # dry run is supposed to be inspectable on a box where that might not answer.
  if (( DRY_RUN )); then
    printf '  %s· would run:%s docker compose pull && docker compose up -d in %s\n' "$DIM" "$RESET" "$INSTALL_DIR"
    say ""
    exit 0
  fi

  resolve_compose

  (cd "$INSTALL_DIR" && as_root "${COMPOSE[@]}" pull >>"$LOG_FILE" 2>&1) &
  spin $! "pulling ${IMAGE}"
  ok "pulled"

  after="$(as_root docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || echo none)"

  if [[ "$before" == "$after" ]]; then
    say ""
    say "  ${GREEN}Already current.${RESET} ${GREY}Nothing to restart.${RESET}"
    say ""
    say "  ${GREY}Pinned to a version tag rather than :latest? Then this only ever${RESET}"
    say "  ${GREY}moves when you edit the tag in ${INSTALL_DIR}/docker-compose.yml.${RESET}"
    say ""
    exit 0
  fi

  (cd "$INSTALL_DIR" && as_root "${COMPOSE[@]}" up -d >>"$LOG_FILE" 2>&1) &
  spin $! "restarting"
  ok "restarted"

  # Same health gate the install path uses. An update that returns you to a
  # prompt before the container is answering has told you nothing.
  say ""
  UPDATED_HEALTHY=0
  for _ in $(seq 1 40); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${DASH_PORT}/api/health" >/dev/null 2>&1; then
      UPDATED_HEALTHY=1
      break
    fi
    sleep 2
  done

  if (( UPDATED_HEALTHY )); then
    ok "healthy"
  else
    warn "updated, but /api/health has not answered in 80s"
    info "check it with: cd $INSTALL_DIR && sudo docker compose logs -f"
  fi

  say ""
  say "  ${GREY}was${RESET}  ${DIM}${before#sha256:}${RESET}"
  say "  ${GREY}now${RESET}  ${BOLD}${after#sha256:}${RESET}"
  say ""
  say "  ${GREY}Your history and configuration were not touched.${RESET}"
  say ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if (( DO_UNINSTALL )); then
  banner
  say "  ${BOLD}Removing the dashboard${RESET}"
  rule
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    info "stopping containers"
    resolve_compose
    (cd "$INSTALL_DIR" && as_root "${COMPOSE[@]}" down) >>"$LOG_FILE" 2>&1 || true
    ok "stopped"
  else
    warn "nothing installed at $INSTALL_DIR"
  fi
  say ""
  say "  ${GREY}Your query history is still at ${INSTALL_DIR}/data.${RESET}"
  say "  ${GREY}Delete it yourself if you want it gone:${RESET}"
  say "  ${DIM}    sudo rm -rf ${INSTALL_DIR}${RESET}"
  say ""
  say "  ${GREY}AdGuard Home, if this script installed it, is untouched and still${RESET}"
  say "  ${GREY}answering DNS. That is deliberate: removing a dashboard should${RESET}"
  say "  ${GREY}never take the household's resolver down with it.${RESET}"
  say ""
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

banner
say "  ${GREY}log: ${LOG_FILE}${RESET}"
(( DRY_RUN )) && say "  ${AMBER}dry run: nothing will be changed${RESET}"

step "Checking this machine"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ARCH_LABEL="arm64" ;;
  x86_64|amd64)  ARCH_LABEL="amd64" ;;
  *)             ARCH_LABEL="$ARCH" ;;
esac

DISTRO="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  DISTRO="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$NAME}")"
elif [[ "$OS" == "Darwin" ]]; then
  DISTRO="macOS $(sw_vers -productVersion 2>/dev/null || true)"
fi

ok "$DISTRO"
ok "$ARCH_LABEL"

case "$ARCH_LABEL" in
  arm64|amd64) ;;
  *) warn "$ARCH_LABEL is not an architecture the published images are built for" ;;
esac

if [[ "$OS" != "Linux" && "$OS" != "Darwin" ]]; then
  die "this installer supports Linux and macOS; found $OS"
fi

if [[ $EUID -ne 0 ]] && ! have sudo; then
  die "run this as root, or install sudo"
fi

# Free space, because a query log is the one thing here that grows.
if have df; then
  AVAIL_MB=$(df -Pm "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2{print $4}' || printf '0')
  if [[ "${AVAIL_MB:-0}" -gt 0 && "${AVAIL_MB:-0}" -lt 2048 ]]; then
    warn "only ${AVAIL_MB}MB free; 90 days of history wants a couple of GB"
  else
    ok "${AVAIL_MB}MB free on $(dirname "$INSTALL_DIR")"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Docker
# ---------------------------------------------------------------------------

step "Docker"

if have docker && docker info >/dev/null 2>&1; then
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || printf 'present')"
elif have docker; then
  die "docker is installed but not running (try: sudo systemctl start docker)"
else
  info "docker is not installed"
  if confirm "Install Docker now, from get.docker.com?"; then
    if (( DRY_RUN )); then
      info "would install docker"
    else
      curl -fsSL https://get.docker.com -o "${TMPDIR:-/tmp}/get-docker.sh" 2>>"$LOG_FILE" \
        || die "could not download the Docker installer"
      as_root sh "${TMPDIR:-/tmp}/get-docker.sh" >>"$LOG_FILE" 2>&1 &
      spin $! "installing docker (this takes a minute)"
      ok "docker installed"
      if [[ -n "${SUDO_USER:-}" ]]; then
        as_root usermod -aG docker "$SUDO_USER" >>"$LOG_FILE" 2>&1 || true
        info "added $SUDO_USER to the docker group (log out and back in for it to apply)"
      fi
    fi
  else
    die "Docker is required. Install it and run this again."
  fi
fi

# ---------------------------------------------------------------------------
# 3. AdGuard Home
# ---------------------------------------------------------------------------

step "AdGuard Home"

AGH_RUNNING=0
if [[ -n "$AGH_HOST" ]]; then
  info "using the address you gave: $AGH_HOST"
  AGH_RUNNING=1
elif curl -fsS --max-time 3 "http://127.0.0.1:${AGH_UI_PORT}/control/status" >/dev/null 2>&1; then
  AGH_HOST="http://127.0.0.1:${AGH_UI_PORT}"
  ok "found one already running on port ${AGH_UI_PORT}"
  AGH_RUNNING=1
elif curl -fsS --max-time 3 "http://127.0.0.1:3000/control/status" >/dev/null 2>&1; then
  AGH_HOST="http://127.0.0.1:3000"
  ok "found one already running on port 3000"
  AGH_UI_PORT=3000
  AGH_RUNNING=1
fi

if (( ! AGH_RUNNING )); then
  if [[ "$WITH_ADGUARD" == "ask" ]]; then
    say ""
    say "  ${GREY}No AdGuard Home found on this machine. It is the thing that${RESET}"
    say "  ${GREY}actually answers DNS; this dashboard reads its query log.${RESET}"
    say ""
    if confirm "Install AdGuard Home too?"; then WITH_ADGUARD="yes"; else WITH_ADGUARD="no"; fi
  fi

  if [[ "$WITH_ADGUARD" == "no" ]]; then
    AGH_HOST="$(ask 'Address of your AdGuard Home' 'http://192.168.1.10:3000')"
    [[ -z "$AGH_HOST" ]] && die "the dashboard needs an AdGuard Home to read"
  else
    # Port 53 is the one that actually matters, and the one most likely to be
    # taken: systemd-resolved holds it on most modern distros.
    if port_busy 53; then
      warn "something is already listening on port 53"
      if [[ -f /etc/systemd/resolved.conf ]] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        say ""
        say "  ${GREY}That is systemd-resolved, the stub resolver. AdGuard Home cannot${RESET}"
        say "  ${GREY}bind port 53 while it holds it. The fix is to stop it taking the${RESET}"
        say "  ${GREY}port while leaving name resolution working.${RESET}"
        say ""
        if confirm "Free port 53 by disabling the systemd-resolved stub listener?"; then
          run as_root mkdir -p /etc/systemd/resolved.conf.d
          if (( ! DRY_RUN )); then
            printf '[Resolve]\nDNSStubListener=no\n' | as_root tee /etc/systemd/resolved.conf.d/elele.conf >/dev/null
            as_root ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
            as_root systemctl restart systemd-resolved
          fi
          ok "port 53 freed"
        else
          die "port 53 is not available"
        fi
      else
        die "port 53 is in use by something this script does not recognise"
      fi
    fi

    info "starting AdGuard Home"
    run as_root mkdir -p "$INSTALL_DIR/adguard/work" "$INSTALL_DIR/adguard/conf"

    if (( ! DRY_RUN )); then
      as_root docker rm -f adguardhome >>"$LOG_FILE" 2>&1 || true
      as_root docker run -d \
        --name adguardhome \
        --restart unless-stopped \
        --network host \
        -v "$INSTALL_DIR/adguard/work:/opt/adguardhome/work" \
        -v "$INSTALL_DIR/adguard/conf:/opt/adguardhome/conf" \
        adguard/adguardhome:latest >>"$LOG_FILE" 2>&1 &
      spin $! "pulling and starting adguard/adguardhome"
    fi

    AGH_HOST="http://127.0.0.1:${AGH_UI_PORT}"
    ok "AdGuard Home is up"

    say ""
    say "  ${BOLD}One thing only you can do${RESET}"
    say "  ${GREY}AdGuard Home ships unconfigured and asks for an admin account on${RESET}"
    say "  ${GREY}first run. Open its setup wizard, finish it, then come back here.${RESET}"
    say ""
    say "      ${ACCENT}http://$(lan_address):3000${RESET}   ${DIM}(setup wizard)${RESET}"
    say ""
    say "  ${GREY}Set the admin interface to port ${AGH_UI_PORT} when it asks, and leave${RESET}"
    say "  ${GREY}the DNS port at 53.${RESET}"
    say ""
    if [[ -t 0 ]] && (( ! ASSUME_YES )); then
      printf '  %s?%s Press enter once the wizard is finished ' "$ACCENT" "$RESET"
      read -r _ || true
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Credentials
# ---------------------------------------------------------------------------

step "Connecting to AdGuard Home"

AGH_HOST="${AGH_HOST%/}"

if [[ -z "$AGH_USER" ]]; then
  AGH_USER="$(ask 'AdGuard Home admin username' 'admin')"
fi
if [[ -z "$AGH_PASS" ]]; then
  AGH_PASS="$(ask_secret 'AdGuard Home admin password')"
fi

if (( ! DRY_RUN )); then
  info "checking those credentials"
  STATUS_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -u "${AGH_USER}:${AGH_PASS}" "${AGH_HOST}/control/status" || printf '000')

  case "$STATUS_CODE" in
    200) ok "authenticated against ${AGH_HOST}" ;;
    401|403) die "AdGuard Home rejected that username and password" ;;
    000) die "could not reach ${AGH_HOST} at all" ;;
    *) warn "unexpected response ${STATUS_CODE} from ${AGH_HOST}; carrying on" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 5. Configuration
# ---------------------------------------------------------------------------

step "Writing the configuration"

run as_root mkdir -p "$INSTALL_DIR/data"

# The container runs as uid 1001, not as root. The image chowns /data when it is
# built, but a bind mount covers that over with a directory root has just made,
# and SQLite cannot create a database in a directory it cannot write to.
run as_root chown -R 1001:1001 "$INSTALL_DIR/data"

ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

if [[ -f "$ENV_FILE" ]] && ! confirm "$ENV_FILE exists. Overwrite it?" "n"; then
  info "keeping the existing .env"
else
  if (( DRY_RUN )); then
    info "would write $ENV_FILE"
  else
    as_root tee "$ENV_FILE" >/dev/null <<EOF
# Written by install.sh on $(date -Is)
#
# The dashboard reads AdGuard Home's query log through its admin API, so it
# needs the same credentials you use to log in. They never leave this machine.
DNS_PROVIDER=adguard
ADGUARD_URL=${AGH_HOST}
ADGUARD_USERNAME=${AGH_USER}
ADGUARD_PASSWORD=${AGH_PASS}

# Where the query history is kept. This is the only thing here worth backing up.
DATABASE_PATH=/data/queries.db

# How long per-query detail is kept. Hourly rollups outlive it and are forever.
RETENTION_DAYS=90

# The address this dashboard is reachable at, used for links in notifications.
PUBLIC_URL=http://$(lan_address):${DASH_PORT}
EOF
    as_root chmod 600 "$ENV_FILE"
    ok "wrote .env (chmod 600: it holds your admin password)"
  fi
fi

if (( DRY_RUN )); then
  info "would write $COMPOSE_FILE"
else
  as_root tee "$COMPOSE_FILE" >/dev/null <<EOF
# Written by install.sh on $(date -Is)
services:
  elele-dns:
    image: ${IMAGE}
    container_name: elele-dns
    restart: unless-stopped
    env_file: .env
    ports:
      # The image listens on 3001. Only the left-hand side is yours to choose.
      - "${DASH_PORT}:3001"
    volumes:
      # Bind-mounted rather than a named volume so the history is somewhere you
      # can find, copy and back up without knowing Docker's storage layout.
      - ./data:/data
    # No healthcheck here on purpose: the image declares its own, against
    # /api/health with node's own fetch. Overriding it with a shell tool is how
    # you end up permanently unhealthy, since the image ships neither wget nor
    # curl.
EOF
  ok "wrote docker-compose.yml"
fi

if port_busy "$DASH_PORT"; then
  warn "port ${DASH_PORT} is already in use; the dashboard may fail to bind"
fi

# ---------------------------------------------------------------------------
# 6. Start
# ---------------------------------------------------------------------------

step "Starting the dashboard"

if (( DRY_RUN )); then
  info "would run: docker compose up -d"
else
  resolve_compose
  (cd "$INSTALL_DIR" && as_root "${COMPOSE[@]}" pull >>"$LOG_FILE" 2>&1) &
  spin $! "pulling ${IMAGE}"
  (cd "$INSTALL_DIR" && as_root "${COMPOSE[@]}" up -d >>"$LOG_FILE" 2>&1) &
  spin $! "starting"
  ok "container is up"
fi

# ---------------------------------------------------------------------------
# 7. Wait for it to be honest about itself
# ---------------------------------------------------------------------------

step "Waiting for the first ingest"

if (( DRY_RUN )); then
  info "would poll /api/health"
else
  HEALTHY=0
  for _ in $(seq 1 40); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${DASH_PORT}/api/health" >/dev/null 2>&1; then
      HEALTHY=1
      break
    fi
    sleep 2
  done

  if (( HEALTHY )); then
    ok "the dashboard is answering"
    # The query log is a circular buffer, so the first backfill has something to
    # do immediately. Reporting the number makes the install feel finished.
    sleep 3
    STORED=$(curl -fsS --max-time 5 "http://127.0.0.1:${DASH_PORT}/api/ingest/status" 2>/dev/null \
      | grep -o '"storedQueries":[0-9]*' | head -1 | cut -d: -f2 || true)
    [[ -n "${STORED:-}" ]] && ok "${STORED} queries ingested already"
  else
    warn "no answer yet on port ${DASH_PORT}"
    say ""
    say "  ${GREY}It may still be pulling. Watch it with:${RESET}"
    say "  ${DIM}    cd ${INSTALL_DIR} && docker compose logs -f${RESET}"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Leave a copy of this script behind
# ---------------------------------------------------------------------------
#
# `curl | sudo bash` leaves nothing on disk. The script was a stream that bash
# has already consumed, $0 is "bash", and there is no file to run a second time.
# So `--update`, and the line printed below telling somebody to use it, would
# both name a path that does not exist.
#
# Persist it now: copy the local file when this was run as one, and re-fetch from
# the same URL when it was piped. Failure here is not fatal. It costs the
# convenience of an update command, not the install that just succeeded.

SELF_DEST="$INSTALL_DIR/install.sh"
SELF_SAVED=0

if (( DRY_RUN )); then
  info "would leave a copy of this script at $SELF_DEST"
else
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    as_root cp "${BASH_SOURCE[0]}" "$SELF_DEST" >>"$LOG_FILE" 2>&1 && SELF_SAVED=1
  elif have curl; then
    as_root curl -fsSL --max-time 20 "$SELF_URL" -o "$SELF_DEST" >>"$LOG_FILE" 2>&1 && SELF_SAVED=1
  fi

  if (( SELF_SAVED )); then
    as_root chmod +x "$SELF_DEST" >>"$LOG_FILE" 2>&1 || true
    log "SELF saved to $SELF_DEST"
  else
    log "SELF could not be saved to $SELF_DEST"
  fi
fi

LAN="$(lan_address)"

printf '\n'
rule
printf '\n'
printf '  %s%sInstalled.%s\n\n' "$BOLD" "$GREEN" "$RESET"
printf '  %sDashboard%s        %s%shttp://%s:%s%s\n' "$GREY" "$RESET" "$BOLD" "$ACCENT" "$LAN" "$DASH_PORT" "$RESET"
printf '  %sAdGuard Home%s     %shttp://%s:%s%s\n' "$GREY" "$RESET" "$DIM" "$LAN" "$AGH_UI_PORT" "$RESET"
printf '\n'
printf '  %sConfig%s           %s\n' "$GREY" "$RESET" "$INSTALL_DIR"
printf '  %sHistory%s          %s/data/queries.db\n' "$GREY" "$RESET" "$INSTALL_DIR"
printf '  %sLog%s              %s\n' "$GREY" "$RESET" "$LOG_FILE"
printf '  %sVersion%s          %s\n' "$GREY" "$RESET" "$VERSION"
printf '\n'
# Said here because the moment somebody needs it is months from now, and this
# screen is the one they screenshot. Only promises the saved copy when there
# actually is one; otherwise it gives the two compose commands, which always work.
if (( SELF_SAVED )); then
  printf '  %sLater, to move to the newest release:%s\n' "$GREY" "$RESET"
  printf '  %s    sudo %s --update%s\n' "$DIM" "$SELF_DEST" "$RESET"
else
  printf '  %sLater, to move to the newest release:%s\n' "$GREY" "$RESET"
  printf '  %s    cd %s && sudo docker compose pull && sudo docker compose up -d%s\n' "$DIM" "$INSTALL_DIR" "$RESET"
fi
printf '\n'
rule
printf '\n'
printf '  %sOne more thing, and it is the one that matters:%s\n\n' "$BOLD" "$RESET"
printf '  %sPoint your router'"'"'s DNS at %s%s%s, or nothing on the network%s\n' "$GREY" "$BOLD" "$LAN" "$RESET$GREY" "$RESET"
printf '  %sis actually being filtered and both of these screens stay empty.%s\n\n' "$GREY" "$RESET"
printf '  %sThe dashboard has no login. It can read every DNS query this%s\n' "$AMBER" "$RESET"
printf '  %shousehold makes. Keep it on the LAN.%s\n\n' "$AMBER" "$RESET"

log "DONE"
