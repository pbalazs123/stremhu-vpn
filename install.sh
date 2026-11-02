#!/usr/bin/env bash
# StremHU VPN installer: puts an existing StremHU Source container behind a PIA WireGuard VPN.
#   install.sh [install]     guided install (default)
#   install.sh status        show the current state
#   install.sh uninstall     put everything back
# Unattended: --yes --container NAME --region ID, PIA login in STREMHU_VPN_PIA_USER + STREMHU_VPN_PIA_PASS_FILE.
#
# Deliberately no "set -e": every step checks its own result, and a failure after the first change rolls back.

set -u
umask 077

VERSION="0.1.0"
TITLE="StremHU VPN"
STATE_ROOT="/var/lib/stremhu-vpn"
LOG="/var/log/stremhu-vpn-install.log"
ADOPT_DIR="/opt/stremhu-vpn"
VPN_IMAGE="thrnz/docker-wireguard-pia:latest"
VPN_NAME="stremhu-vpn"
PORT_NAME="stremhu-vpn-port"
FILE_COMPOSE="compose.stremhu-vpn.yaml"
FILE_ENV="stremhu-vpn.env"
ENV_MARK="# added by stremhu-vpn"

ASSUME_YES=0; ARG_CONTAINER=""; ARG_REGION=""; ARG_MODE=""; CMD="install"
UI="plain"; APPLYING=0; ROLLED_BACK=0; TMP=""
CONTAINER=""; MODE=""; PROJECT=""; WORKDIR=""; SERVICE=""; CONFIG_FILES=""; IMAGE=""; WEB_PORT=7070
RUN_USER=""; USE_CAPS=0; WAS_STOPPED=0; PUBLISH=""; NET_NAMES=""; LOCAL_NETS=""; PIA_USER=""; PIA_PASS=""; REGION="hungary"
OLD_RELAY_PORT=""; WARNINGS=""; STATE=""; OLD_CMD=""; DROPPED_PORTS=""

# ---------------------------------------------------------------- output

log() { [ -w "$(dirname "$LOG")" ] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; return 0; }
say() { printf '%s\n' "$*" >&2; log "$*"; }
warn_add() { WARNINGS="${WARNINGS}- $1
"; log "WARN $1"; }

ui_msg() {
  case "$UI" in
    whiptail|dialog) "$UI" --title "$TITLE" --msgbox "$1" "${2:-20}" 76 </dev/tty >/dev/tty 2>&1 ;;
    *) printf '\n%s\n' "$1" >&2; [ "$ASSUME_YES" = 1 ] || { printf 'Press Enter to continue. ' >&2; read -r _ </dev/tty 2>/dev/null; } ;;
  esac
  return 0
}
ui_yesno() { # returns 0 for yes
  [ "$ASSUME_YES" = 1 ] && return 0
  case "$UI" in
    whiptail|dialog) "$UI" --title "$TITLE" --yesno "$1" "${2:-22}" 76 </dev/tty >/dev/tty 2>&1 ;;
    *) printf '\n%s\nContinue? [y/N] ' "$1" >&2; local a=""; read -r a </dev/tty 2>/dev/null; case "$a" in y|Y|yes|YES|i|I|igen) return 0 ;; *) return 1 ;; esac ;;
  esac
}
ui_input() { # prompt default -> stdout
  case "$UI" in
    whiptail|dialog) "$UI" --title "$TITLE" --inputbox "$1" 10 76 "$2" 3>&1 1>/dev/tty 2>&3 </dev/tty ;;
    *) local a=""; printf '%s [%s]: ' "$1" "$2" >&2; read -r a </dev/tty 2>/dev/null || return 1; printf '%s' "${a:-$2}" ;;
  esac
}
ui_pass() {
  case "$UI" in
    whiptail) whiptail --title "$TITLE" --passwordbox "$1" 10 76 3>&1 1>/dev/tty 2>&3 </dev/tty ;;
    dialog) dialog --title "$TITLE" --insecure --passwordbox "$1" 10 76 3>&1 1>/dev/tty 2>&3 </dev/tty ;;
    *) local a=""; printf '%s: ' "$1" >&2; read -rs a </dev/tty 2>/dev/null || return 1; printf '\n' >&2; printf '%s' "$a" ;;
  esac
}
ui_menu() { # prompt default tag label [tag label...] -> stdout
  local prompt="$1" def="$2"; shift 2
  case "$UI" in
    whiptail) whiptail --title "$TITLE" --default-item "$def" --menu "$prompt" 22 76 12 "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty ;;
    dialog) dialog --title "$TITLE" --default-item "$def" --menu "$prompt" 22 76 12 "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty ;;
    *) printf '\n%s\n' "$prompt" >&2
       while [ $# -ge 2 ]; do printf '  %-24s %s\n' "$1" "$2" >&2; shift 2; done
       local a=""; printf 'Choice [%s]: ' "$def" >&2; read -r a </dev/tty 2>/dev/null || return 1; printf '%s' "${a:-$def}" ;;
  esac
}
cancelled() { # a dialog closed before anything changed
  say "Cancelled, nothing was changed."
  [ "$WAS_STOPPED" = 1 ] && docker stop "$CONTAINER" >>"$LOG" 2>&1
  cleanup_tmp
  exit 0
}
die() { # before anything changed
  say "ERROR: $1"
  ui_msg "$1

Nothing was changed. Log: $LOG" 16
  exit 1
}

have_tty() { { : </dev/tty; } 2>/dev/null; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- setup

need_root() {
  [ "$(id -u)" = 0 ] && return 0
  if have sudo && [ -f "$0" ]; then
    say "Root access is needed, asking sudo."
    exec sudo -E bash "$0" "$@"
  fi
  printf 'Run this as root (sudo), because it manages Docker containers.\n' >&2
  exit 1
}

install_packages() { # never fatal: no dialogs means plain prompts
  local mgr="" pk="newt"
  if have apt-get; then mgr="apt-get install -y -qq"; pk="whiptail"
  elif have dnf; then mgr="dnf install -y -q"
  elif have yum; then mgr="yum install -y -q"
  elif have apk; then mgr="apk add --no-cache -q"
  elif have zypper; then mgr="zypper --non-interactive install"
  elif have pacman; then mgr="pacman -S --noconfirm --needed"; pk="libnewt"
  fi
  [ -n "$mgr" ] || return 1
  have apt-get && { DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1 || true; }
  if ! have curl; then DEBIAN_FRONTEND=noninteractive $mgr curl >>"$LOG" 2>&1 || true; fi
  if have_tty && ! have whiptail && ! have dialog; then
    say "Installing the setup dialog package ($pk)."
    DEBIAN_FRONTEND=noninteractive $mgr "$pk" >>"$LOG" 2>&1 || say "Couldn't install it, using plain prompts."
  fi
  return 0
}

pick_ui() {
  UI="plain"
  [ "$ASSUME_YES" = 1 ] && return 0
  have_tty || return 0
  [ "${TERM:-dumb}" = dumb ] && return 0
  if have whiptail; then UI=whiptail; elif have dialog; then UI=dialog; fi
  return 0
}

preflight_host() {
  [ "$(uname -s)" = Linux ] || die "This installer only supports Linux hosts."
  have docker || die "Docker wasn't found on this machine."
  docker info >/dev/null 2>&1 || die "Docker isn't running, or it can't be reached."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is needed. On Debian or Ubuntu, install Docker's docker-compose-plugin package."
  have curl || die "curl is needed and couldn't be installed."
  local v major minor
  v=$(docker compose version --short 2>/dev/null | sed 's/^v//'); major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
  case "$major$minor" in *[!0-9]*|"") die "Couldn't read the Docker Compose version ($v)." ;; esac
  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 24 ]; }; then
    die "Docker Compose 2.24 or newer is needed, and this machine has $v."
  fi
  mkdir -p "$STATE_ROOT" || die "Couldn't create $STATE_ROOT."
  chmod 700 "$STATE_ROOT"
  TMP=$(mktemp -d) || die "Couldn't create a temporary folder."
}

# ---------------------------------------------------------------- discovery

find_stremhu() {
  local names=() n
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(
    docker ps -a --format '{{.Names}} {{.Image}}' | awk '$2 ~ /stremhu-source/ {print $1}')
  if [ -n "$ARG_CONTAINER" ]; then CONTAINER="$ARG_CONTAINER"
  elif [ "${#names[@]}" -eq 0 ]; then
    die "No StremHU Source container was found. Install and start StremHU first, then run this again. If you built your own image, use --container NAME."
  elif [ "${#names[@]}" -eq 1 ]; then CONTAINER="${names[0]}"
  else
    local items=(); for n in "${names[@]}"; do items+=("$n" "$(docker inspect -f '{{.State.Status}}' "$n")"); done
    CONTAINER=$(ui_menu "Which StremHU container should go behind the VPN?" "${names[0]}" "${items[@]}") || cancelled
  fi
  docker inspect "$CONTAINER" >/dev/null 2>&1 || die "Container '$CONTAINER' doesn't exist."
  STATE="$STATE_ROOT/$CONTAINER"
}

ins() { docker inspect -f "$1" "$CONTAINER" 2>/dev/null; }

analyse() {
  local netmode
  netmode=$(ins '{{.HostConfig.NetworkMode}}')
  [ -n "$(ins '{{index .Config.Labels "com.docker.swarm.service.id"}}')" ] && die "Docker Swarm services aren't supported."
  case "$netmode" in
    container:*|service:*) die "'$CONTAINER' already uses another container's network, so it's probably behind a VPN already. Remove that first." ;;
  esac
  docker volume inspect stremhu-vpn-pia >/dev/null 2>&1 && die "A volume called 'stremhu-vpn-pia' already exists. Remove it first if it's left over from an earlier try."
  [ -e "$ADOPT_DIR" ] && die "$ADOPT_DIR already exists. Remove it first if it's left over from an earlier try."
  docker inspect "$VPN_NAME" >/dev/null 2>&1 && die "A container called '$VPN_NAME' already exists. If this installer made it, run: install.sh status"

  if [ "$(ins '{{.State.Running}}')" != true ]; then
    say "Starting '$CONTAINER' so its settings can be read."
    WAS_STOPPED=1
    docker start "$CONTAINER" >>"$LOG" 2>&1 || die "'$CONTAINER' isn't running and wouldn't start."
    sleep 5
  fi
  IMAGE=$(ins '{{.Config.Image}}')
  docker exec "$CONTAINER" sh -c 'command -v setpriv >/dev/null && command -v python >/dev/null' \
    || die "This StremHU image doesn't have the tools the add-on relies on (setpriv, python)."

  # Web port: the PORT variable, else StremHU's default
  local p
  p=$(ins '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^PORT=//p' | head -1)
  case "$p" in ''|*[!0-9]*) WEB_PORT=7070 ;; *) WEB_PORT=$p ;; esac

  # Published web port: keep the same bind address. Torrent ports aren't needed behind PIA.
  local line host_ip host_port key
  PUBLISH=""; DROPPED_PORTS=""
  while IFS='|' read -r key host_ip host_port; do
    [ -n "$key" ] && [ -n "$host_port" ] || continue
    if [ "$key" = "$WEB_PORT/tcp" ]; then
      if [ -n "$host_ip" ] && [ "$host_ip" != "0.0.0.0" ] && [ "$host_ip" != "::" ]; then PUBLISH="$host_ip:$host_port:$WEB_PORT"
      else PUBLISH="$host_port:$WEB_PORT"; fi
    else
      DROPPED_PORTS="$DROPPED_PORTS $key"
    fi
  done < <(ins '{{range $k,$v := .HostConfig.PortBindings}}{{range $v}}{{$k}}|{{.HostIp}}|{{.HostPort}}{{"\n"}}{{end}}{{end}}')
  [ "$netmode" = host ] && { PUBLISH="$WEB_PORT:$WEB_PORT"; warn_add "It used host networking. Port $WEB_PORT will be published on all interfaces instead."; }
  [ -n "$DROPPED_PORTS" ] && warn_add "These published ports go away, because PIA handles incoming torrent connections:$DROPPED_PORTS"
  [ -z "$PUBLISH" ] && [ "$netmode" != host ] && warn_add "Port $WEB_PORT isn't published on the host today, and it stays that way."

  # User: keep a non-root user. Root gets moved off, because the VPN image lets root bypass the tunnel during recovery.
  local u dbu
  u=$(ins '{{.Config.User}}'); USE_CAPS=0
  case "$u" in
    ""|0|0:*|root|root:*)
      # Root-owned data stays root-owned: run as uid 1000 with just the file permissions it needs. Existing files aren't changed.
      dbu=$(docker exec "$CONTAINER" sh -c 'stat -c %u:%g /app/data/system/database/app.db 2>/dev/null')
      case "$dbu" in
        ""|0:*) RUN_USER="1000:1000"; USE_CAPS=1 ;;
        *) RUN_USER="$dbu" ;;
      esac ;;
    *[!0-9:]*) RUN_USER=$(docker exec "$CONTAINER" sh -c 'echo "$(id -u):$(id -g)"') ;;
    *:*) RUN_USER="$u" ;;
    *) RUN_USER="$u:$u" ;;
  esac
  case "$RUN_USER" in [0-9]*:[0-9]*) ;; *) die "Couldn't work out which user StremHU should run as ($RUN_USER)." ;; esac

  # Networks to keep, so a reverse proxy can still use the old container name
  NET_NAMES=$(ins '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | grep -v -E '^(bridge|host|none)$')
  case "$(ins '{{.NetworkSettings.Networks}}')" in *IPAMConfig:0x*) ;; esac

  # The command StremHU normally starts with
  OLD_CMD=$(ins '{{range .Config.Entrypoint}}{{println .}}{{end}}{{range .Config.Cmd}}{{println .}}{{end}}')
  [ -n "$OLD_CMD" ] || die "Couldn't read the command this container starts with."

  # Compose project we can really reach?
  PROJECT=$(ins '{{index .Config.Labels "com.docker.compose.project"}}')
  WORKDIR=$(ins '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
  SERVICE=$(ins '{{index .Config.Labels "com.docker.compose.service"}}')
  CONFIG_FILES=$(ins '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
  MODE="adopt"
  if [ -n "$PROJECT" ] && [ -n "$SERVICE" ] && [ -d "$WORKDIR" ] && [ -w "$WORKDIR" ] && [ -n "$CONFIG_FILES" ]; then
    MODE="compose"
    local f
    for f in $(printf '%s' "$CONFIG_FILES" | tr ',' ' '); do [ -f "$f" ] || MODE="adopt"; done
    if [ "$MODE" = compose ]; then
      (cd "$WORKDIR" && docker compose -p "$PROJECT" $(compose_flags "$CONFIG_FILES") config --images 2>>"$LOG") | grep -qxF "$IMAGE" || MODE="adopt"
    fi
    case "$WORKDIR" in /data/compose/*|/data/stacks/*|*/portainer/*) MODE="adopt" ;; esac
    [ -n "$(ins '{{index .Config.Labels "io.portainer.stack.id"}}')" ] && MODE="adopt"
    if [ "$MODE" = adopt ]; then
      warn_add "A tool like Portainer or Dockhand seems to manage this stack. If it redeploys the old stack, StremHU would run WITHOUT the VPN, so remove it from that tool."
    fi
  fi
  [ -n "$ARG_MODE" ] && MODE="$ARG_MODE"
  if [ "$MODE" = adopt ] && [ -z "$PROJECT" ]; then
    warn_add "This container wasn't started by Compose. Don't start it again with your old command, or it would run WITHOUT the VPN."
  fi

  # DDNS: StremHU learns its public IP through ipify, which the add-on blocks
  local net_mode
  net_mode=$(docker exec -i "$CONTAINER" python - 2>/dev/null <<'PY'
import sqlite3,json
try:
    d=sqlite3.connect("file:/app/data/system/database/app.db?mode=ro",uri=True)
    r=d.execute("SELECT value FROM settings WHERE key='network'").fetchone()
    v=json.loads(r[0]); print(v.get("mode",""),v.get("connection",""))
except Exception: pass
PY
)
  case "$net_mode" in
    auto*local*|AUTO*LOCAL*) ;;
    auto*|AUTO*) warn_add "Automatic external access (DDNS) is on. Your domain keeps its current IP, but StremHU can't update it if your home IP changes. Use your router's DDNS updater for that." ;;
  esac
  OLD_RELAY_PORT=$(relay_get port "$CONTAINER")
  have_local_nets
  log "analysis: container=$CONTAINER mode=$MODE project=$PROJECT service=$SERVICE port=$WEB_PORT publish=$PUBLISH user=$RUN_USER caps=$USE_CAPS nets=$(printf '%s' "$NET_NAMES" | tr '\n' ' ') local=$LOCAL_NETS"
}

compose_flags() { # comma-separated files -> -f a -f b
  local f out=""
  for f in $(printf '%s' "$1" | tr ',' ' '); do out="$out -f $f"; done
  printf '%s' "$out"
}

have_local_nets() {
  LOCAL_NETS="192.168.0.0/16,172.16.0.0/12,100.64.0.0/10"
  local s
  # LAN and attached Docker networks in 10.x need their exact subnet: PIA uses 10.0.0.0/8 inside the tunnel
  for s in $(ip -4 route 2>/dev/null | awk '$1 ~ /^10\./ && $1 ~ /\// {print $1}') \
           $(for n in $NET_NAMES; do docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$n" 2>/dev/null; done | grep '^10\.'); do
    case "$s" in
      10.0.0.*|10.0.0.0/*|10.0.0/*|10.0/*|10/*) warn_add "Your network $s overlaps with PIA's addresses, so it can't be reached outside the tunnel." ;;
      *) case ",$LOCAL_NETS," in *",$s,"*) ;; *) LOCAL_NETS="$LOCAL_NETS,$s" ;; esac ;;
    esac
  done
}

# value of a relay setting, read through StremHU's own API from inside the container
relay_get() {
  docker exec -i "$2" python - "$1" "$WEB_PORT" 2>/dev/null <<'PY'
import sqlite3,json,ssl,sys,urllib.request as u
k,port=sys.argv[1],sys.argv[2]
try:
    t=sqlite3.connect("file:/app/data/system/database/app.db?mode=ro",uri=True).execute("SELECT api_key FROM users WHERE role_id='admin' LIMIT 1").fetchone()[0]
except Exception: sys.exit(0)
c=ssl._create_unverified_context()
for s in ("http","https"):
    try:
        print(json.load(u.urlopen(f"{s}://127.0.0.1:{port}/api/{t}/relay/settings",timeout=8,context=c)).get(k,""))
        break
    except Exception: pass
PY
}
relay_set_port() { # value container
  docker exec -i "$2" python - "$1" "$WEB_PORT" >/dev/null 2>&1 <<'PY'
import sqlite3,json,ssl,sys,urllib.request as u
v,port=int(sys.argv[1]),sys.argv[2]
t=sqlite3.connect("file:/app/data/system/database/app.db?mode=ro",uri=True).execute("SELECT api_key FROM users WHERE role_id='admin' LIMIT 1").fetchone()[0]
c=ssl._create_unverified_context()
for s in ("http","https"):
    try:
        u.urlopen(u.Request(f"{s}://127.0.0.1:{port}/api/{t}/relay/settings",data=json.dumps({"port":v}).encode(),method="PUT",headers={"Content-Type":"application/json"}),timeout=8,context=c)
        break
    except Exception: pass
PY
}

# ---------------------------------------------------------------- questions

pia_check() { # 0 = accepted, 1 = rejected, 2 = couldn't check
  local code conf="$TMP/pia.curl" e_u e_p
  e_u=$(printf '%s' "$PIA_USER" | sed 's/\\/\\\\/g; s/"/\\"/g')
  e_p=$(printf '%s' "$PIA_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf 'form-string = "username=%s"\nform-string = "password=%s"\n' "$e_u" "$e_p" >"$conf"
  code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' -K "$conf" -X POST https://www.privateinternetaccess.com/api/client/v2/token 2>/dev/null)
  rm -f "$conf"
  case "$code" in 200) return 0 ;; 401|403|400) return 1 ;; *) log "PIA check http $code"; return 2 ;; esac
}

ask_login() {
  if [ -n "${STREMHU_VPN_PIA_USER:-}" ] && [ -n "${STREMHU_VPN_PIA_PASS_FILE:-}" ]; then
    PIA_USER="$STREMHU_VPN_PIA_USER"
    PIA_PASS=$(cat "$STREMHU_VPN_PIA_PASS_FILE" 2>/dev/null) || die "Couldn't read $STREMHU_VPN_PIA_PASS_FILE."
    pia_check; case $? in 1) die "PIA rejected that username or password." ;; 2) warn_add "PIA's login check couldn't be reached, so your login will be tested during the install." ;; esac
    return 0
  fi
  [ "$ASSUME_YES" = 1 ] && die "With --yes, set STREMHU_VPN_PIA_USER and STREMHU_VPN_PIA_PASS_FILE."
  have_tty || die "No terminal to ask for your PIA login. Set STREMHU_VPN_PIA_USER and STREMHU_VPN_PIA_PASS_FILE, and use --yes."
  local tries=0
  while [ $tries -lt 3 ]; do
    PIA_USER=$(ui_input "PIA username (p1234567)" "$PIA_USER") || cancelled
    PIA_PASS=$(ui_pass "PIA password") || cancelled
    [ -n "$PIA_USER" ] && [ -n "$PIA_PASS" ] || { tries=$((tries+1)); continue; }
    pia_check
    case $? in
      0) return 0 ;;
      2) warn_add "PIA's login check couldn't be reached, so your login will be tested during the install."; return 0 ;;
      1) ui_msg "PIA rejected that username or password. Try again." 8 ;;
    esac
    tries=$((tries+1))
  done
  die "PIA rejected the login three times."
}

ask_region() {
  [ -n "$ARG_REGION" ] && { REGION="$ARG_REGION"; return 0; }
  [ "$ASSUME_YES" = 1 ] && return 0
  local items=() id name
  while IFS='|' read -r id name; do [ -n "$id" ] && items+=("$id" "$name"); done < <(
    curl -s -m 15 https://serverlist.piaservers.net/vpninfo/servers/v6 2>/dev/null | head -1 \
      | sed 's/{"id":"/\n&/g' | grep '"port_forward":true' \
      | sed -E 's/^\{"id":"([^"]+)","name":"([^"]+)".*/\1|\2/' | sort -t'|' -k2)
  if [ "${#items[@]}" -gt 0 ]; then
    REGION=$(ui_menu "PIA location. Only locations with port forwarding are listed. Hungary suits most StremHU users." hungary "${items[@]}") || cancelled
  else
    REGION=$(ui_input "PIA location ID (the list couldn't be loaded)" hungary) || cancelled
  fi
  [ -n "$REGION" ] || REGION=hungary
}

summary() {
  local where text
  if [ "$MODE" = compose ]; then
    where="Compose project '$PROJECT' in $WORKDIR. Adds $FILE_COMPOSE and $FILE_ENV beside your files, plus a COMPOSE_FILE line in .env. Your compose files aren't edited, and 'docker compose' there keeps working."
  else
    where="A new stack in $ADOPT_DIR with this container's current settings. The old container is kept, stopped, as $CONTAINER-pre-vpn."
  fi
  text="Container: $CONTAINER ($IMAGE)
PIA location: $REGION
Web port: $WEB_PORT${PUBLISH:+, published as $PUBLISH}
Runs as user: $RUN_USER

$where"
  text="$text

Your volumes and folders aren't changed. Existing files stay as they are, and new ones StremHU creates belong to user $RUN_USER. The only setting that changes is its torrent port, and uninstall puts that back."
  [ -n "$WARNINGS" ] && text="$text

$WARNINGS"
  text="$text

StremHU restarts. If any check fails, everything is rolled back."
  say "$text"
  ui_yesno "$text" 24 || { [ "$WAS_STOPPED" = 1 ] && docker stop "$CONTAINER" >>"$LOG" 2>&1; say "Cancelled, nothing was changed."; cleanup_tmp; exit 0; }
}

# ---------------------------------------------------------------- file generation

yq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
envq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

caps_json() { [ "$USE_CAPS" = 1 ] && printf ', "--inh-caps=+dac_override,+fowner", "--ambient-caps=+dac_override,+fowner"'; return 0; }
caps_flags() { [ "$USE_CAPS" = 1 ] && printf ' --inh-caps=+dac_override,+fowner --ambient-caps=+dac_override,+fowner'; return 0; }

entrypoint_yaml() {
  local cmd="" a uid gid
  uid=${RUN_USER%%:*}; gid=${RUN_USER##*:}
  while IFS= read -r a; do
    [ -n "$a" ] && cmd="$cmd '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
  done <<<"$OLD_CMD"
  cat <<EOF
    # If the VPN container restarts, StremHU is left in its dead network, so exit and let Docker restart it on the new one.
    entrypoint:
      - sh
      - -c
      - |
EOF
  cat <<EOF
        setpriv --reuid=$uid --regid=$gid --clear-groups$(caps_flags)$cmd &
        app=\$\$!
        trap 'kill \$\$app; wait \$\$app; exit 0' TERM INT
        while kill -0 \$\$app 2>/dev/null; do
          if ! grep -q eth0: /proc/net/dev; then
            echo "VPN network is gone, restarting"
            kill \$\$app; wait \$\$app; exit 1
          fi
          sleep 10 & wait \$\$!
        done
        wait \$\$app
EOF
}

vpn_service_yaml() {
  cat <<EOF
  $VPN_NAME:
    image: $VPN_IMAGE
    container_name: $VPN_NAME
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1
    env_file:
      - $FILE_ENV
    environment:
      - LOC=$REGION
      - LOCAL_NETWORK=$LOCAL_NETS
      - KEEPALIVE=25
      - RECONNECT=1
      - PORT_FORWARDING=1
      - PORT_PERSIST=1
      - PORT_FILE=/pia-shared/port.dat
      # Web port: answer clients from any network, so router port forwards and VPS installs keep working.
      # Only replies to connections that came in on the web port skip the tunnel; everything StremHU starts stays in it.
      # StremHU's DDNS gets its public IP from api.ipify.org. Through the VPN that would point your domain at PIA,
      # so block that lookup: StremHU logs an error and leaves your DNS record alone.
      - |
        POST_UP=ip rule add fwmark 0x7070 lookup main priority 100
        iptables -t mangle -A OUTPUT -m connmark --mark 0x7070 -j CONNMARK --restore-mark
        for i in \$\$(ls /sys/class/net | grep -v -E '^(lo|wg0)\$\$'); do
        iptables -t mangle -A PREROUTING -i \$\$i -p tcp --dport $WEB_PORT -j MARK --set-mark 0x7070
        iptables -t mangle -A PREROUTING -i \$\$i -p tcp --dport $WEB_PORT -j CONNMARK --save-mark
        iptables -A INPUT -i \$\$i -p tcp --dport $WEB_PORT -j ACCEPT
        iptables -A OUTPUT -o \$\$i -m connmark --mark 0x7070 -j ACCEPT
        done
        iptables -I OUTPUT 1 -p tcp --dport 443 -m string --string api.ipify.org --algo bm -j REJECT --reject-with tcp-reset || echo "WARNING: could not block api.ipify.org. Don't use StremHU's automatic DDNS with this VPN."
    volumes:
      - pia:/pia
      - pia-shared:/pia-shared
EOF
  [ -n "$PUBLISH" ] && printf '    ports:\n      - "%s"\n' "$PUBLISH"
  local n i=0 alias_block=""
  if [ -n "$NET_NAMES" ]; then
    printf '    networks:\n'
    for n in $NET_NAMES; do
      printf '      net%s:\n        aliases:\n          - %s\n' "$i" "$(yq "$CONTAINER")"
      [ -n "$SERVICE" ] && [ "$SERVICE" != "$CONTAINER" ] && printf '          - %s\n' "$(yq "$SERVICE")"
      i=$((i+1))
    done
  fi
  printf '    restart: unless-stopped\n'
}

port_service_yaml() { # service name
  cat <<EOF

  # Tells StremHU the forwarded port whenever PIA assigns a new one. Reuses StremHU's own image.
  $PORT_NAME:
    image: $IMAGE
    container_name: $PORT_NAME
    network_mode: service:$VPN_NAME
    user: "0:0"
    entrypoint: ["setpriv", "--reuid=${RUN_USER%%:*}", "--regid=${RUN_USER##*:}", "--clear-groups"$(caps_json)]
    depends_on:
      - $1
    volumes_from:
      - $1
    volumes:
      - pia-shared:/pia-shared:ro
    command:
      - python
      - -u
      - -c
      - |
        import json, sqlite3, ssl, sys, time, urllib.request

        PORT_FILE = "/pia-shared/port.dat"
        DB = "file:/app/data/system/database/app.db?mode=ro"
        TLS = ssl._create_unverified_context()  # StremHU may serve its port over HTTPS; this is 127.0.0.1

        def read_port():
            try:
                with open(PORT_FILE) as f:
                    return int(f.read().strip())
            except (OSError, ValueError):
                return None

        def read_token():
            try:
                db = sqlite3.connect(DB, uri=True, timeout=10)
                try:
                    row = db.execute("SELECT api_key FROM users WHERE role_id='admin' LIMIT 1").fetchone()
                finally:
                    db.close()
            except sqlite3.Error:
                return None
            return row[0] if row else None

        def set_port(port, token):
            for scheme in ("http", "https"):
                url = f"{scheme}://127.0.0.1:$WEB_PORT/api/{token}/relay/settings"
                try:
                    with urllib.request.urlopen(url, timeout=10, context=TLS) as r:
                        if json.load(r).get("port") == port:
                            return True
                    req = urllib.request.Request(
                        url, data=json.dumps({"port": port}).encode(), method="PUT",
                        headers={"Content-Type": "application/json"})
                    urllib.request.urlopen(req, timeout=10, context=TLS)
                    return True
                except Exception:
                    pass
            return False

        done = None
        waiting = False
        while True:
            with open("/proc/net/dev") as f:
                if "eth0:" not in f.read():
                    sys.exit("VPN network is gone, restarting")
            port = read_port()
            if port and port != done:
                token = read_token()
                if token and set_port(port, token):
                    print(f"StremHU torrent port set to {port}")
                    done, waiting = port, False
                elif not waiting:
                    print("Waiting for StremHU: finish its setup and create the admin user")
                    waiting = True
            time.sleep(30)
    restart: unless-stopped
EOF
}

networks_yaml() {
  [ -n "$NET_NAMES" ] || return 0
  local n i=0
  printf '\nnetworks:\n'
  for n in $NET_NAMES; do
    printf '  net%s:\n    name: %s\n' "$i" "$(yq "$n")"
    case "$n" in
      "${PROJECT}_"*) [ -n "$PROJECT" ] && [ "$MODE" = compose ] || printf '    external: true\n' ;;
      *) printf '    external: true\n' ;;
    esac
    i=$((i+1))
  done
}

write_env_file() { # path
  { printf 'USER=%s\n' "$(envq "$PIA_USER")"; printf 'PASS=%s\n' "$(envq "$PIA_PASS")"; } >"$1" && chmod 600 "$1"
}

write_compose_mode() {
  local f="$WORKDIR/$FILE_COMPOSE"
  {
    printf '# Generated by the StremHU VPN installer %s. Remove with: install.sh uninstall\nservices:\n  %s:\n' "$VERSION" "$SERVICE"
    cat <<EOF
    # The VPN container owns the network, so these move there or go away.
    network_mode: service:$VPN_NAME
    ports: !reset []
    expose: !reset []
    networks: !reset null
    hostname: !reset null
    domainname: !reset null
    dns: !reset []
    dns_search: !reset []
    dns_opt: !reset []
    extra_hosts: !reset []
    links: !reset []
    mac_address: !reset null
    # Starts as root only to drop to $RUN_USER. Root must not run the app:
    # while recovering a dead tunnel, the VPN image lets root processes bypass it.
    user: "0:0"
    restart: unless-stopped
    depends_on:
      $VPN_NAME:
        condition: service_healthy
        restart: true
    command: !reset []
EOF
    entrypoint_yaml
    printf '\n'
    vpn_service_yaml
    port_service_yaml "$SERVICE"
    networks_yaml
    printf '\nvolumes:\n  pia:\n    name: stremhu-vpn-pia\n  pia-shared:\n    name: stremhu-vpn-pia-shared\n'
  } >"$f" || return 1
  write_env_file "$WORKDIR/$FILE_ENV" || return 1

  # .env: plain "docker compose" keeps working in that folder, with our file included
  local envf="$WORKDIR/.env" joined
  joined="$(printf '%s' "$CONFIG_FILES" | tr ',' ':'):$f"
  [ -f "$envf" ] || : >"$STATE/env.absent"
  if [ -f "$envf" ] && grep -q '^COMPOSE_FILE=' "$envf"; then
    grep '^COMPOSE_FILE=' "$envf" | head -1 >"$STATE/env.compose_file"
    sed -i "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$joined $ENV_MARK|" "$envf" || return 1
  else
    printf 'COMPOSE_FILE=%s %s\n' "$joined" "$ENV_MARK" >>"$envf" || return 1
  fi
  if [ -n "$PROJECT" ] && ! grep -q '^COMPOSE_PROJECT_NAME=' "$envf" 2>/dev/null && [ "$PROJECT" != "$(basename "$WORKDIR" | tr '[:upper:]' '[:lower:]')" ]; then
    printf 'COMPOSE_PROJECT_NAME=%s %s\n' "$PROJECT" "$ENV_MARK" >>"$envf" || return 1
  fi
  return 0
}

write_adopt_mode() {
  mkdir -p "$ADOPT_DIR" && chmod 700 "$ADOPT_DIR" || return 1
  local f="$ADOPT_DIR/compose.yaml" envs="$ADOPT_DIR/stremhu.env" type name src dst rw vols="" top="" e
  local imgenv
  imgenv=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null)
  : >"$envs"; chmod 600 "$envs"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    printf '%s\n' "$imgenv" | grep -qxF "$e" && continue
    printf '%s=%s\n' "${e%%=*}" "$(envq "${e#*=}")" >>"$envs"
  done < <(ins '{{range .Config.Env}}{{println .}}{{end}}')
  while IFS='|' read -r type name src dst rw; do
    [ -n "$type" ] || continue
    local ro=""; [ "$rw" = false ] && ro=":ro"
    case "$type" in
      bind) vols="$vols      - $(yq "$src:$dst$ro")
" ;;
      volume) vols="$vols      - $(yq "$name:$dst$ro")
"; top="$top  $name:
    external: true
" ;;
    esac
  done < <(ins '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}|{{.RW}}{{"\n"}}{{end}}')
  local mem; mem=$(ins '{{.HostConfig.Memory}}')
  {
    printf '# Generated by the StremHU VPN installer %s from container %s. Remove with: install.sh uninstall\nname: stremhu-vpn\nservices:\n  stremhu-source:\n' "$VERSION" "$CONTAINER"
    printf '    image: %s\n    container_name: %s\n    network_mode: service:%s\n    user: "0:0"\n    restart: unless-stopped\n    env_file:\n      - stremhu.env\n' "$IMAGE" "$CONTAINER" "$VPN_NAME"
    [ "${mem:-0}" != 0 ] && printf '    mem_limit: %s\n' "$mem"
    printf '    depends_on:\n      %s:\n        condition: service_healthy\n        restart: true\n' "$VPN_NAME"
    [ -n "$vols" ] && printf '    volumes:\n%s' "$vols"
    entrypoint_yaml
    printf '\n'
    vpn_service_yaml
    port_service_yaml stremhu-source
    networks_yaml
    printf '\nvolumes:\n  pia:\n    name: stremhu-vpn-pia\n  pia-shared:\n    name: stremhu-vpn-pia-shared\n%s' "$top"
  } >"$f" || return 1
  write_env_file "$ADOPT_DIR/$FILE_ENV" || return 1
  return 0
}

# ---------------------------------------------------------------- state + rollback

save_state() {
  rm -rf "$STATE"; mkdir -p "$STATE" || return 1; chmod 700 "$STATE"
  docker inspect "$CONTAINER" >"$STATE/inspect.json" 2>/dev/null
  {
    printf 'MODE=%q\nCONTAINER=%q\nPROJECT=%q\nWORKDIR=%q\nSERVICE=%q\nCONFIG_FILES=%q\nWEB_PORT=%q\nOLD_RELAY_PORT=%q\nRUN_USER=%q\nIMAGE=%q\nWAS_STOPPED=%q\n' \
      "$MODE" "$CONTAINER" "$PROJECT" "$WORKDIR" "$SERVICE" "$CONFIG_FILES" "$WEB_PORT" "$OLD_RELAY_PORT" "$RUN_USER" "$IMAGE" "$WAS_STOPPED"
  } >"$STATE/state" || return 1
  if [ "$MODE" = compose ]; then
    local f; for f in $(printf '%s' "$CONFIG_FILES" | tr ',' ' '); do sha256sum "$f"; done >"$STATE/files.sha256" 2>/dev/null
    # Compose may create this for the VPN container. Only remove it later if it wasn't there before.
    docker network inspect "${PROJECT}_default" >/dev/null 2>&1 || : >"$STATE/net.absent"
  fi
  return 0
}

dc() { # docker compose in the original project, with its original files
  (cd "$WORKDIR" && docker compose -p "$PROJECT" $(compose_flags "$CONFIG_FILES") "$@")
}

teardown_new() {
  if [ "$MODE" = compose ]; then
    docker rm -f "$PORT_NAME" "$VPN_NAME" >>"$LOG" 2>&1
  else
    [ -f "$ADOPT_DIR/compose.yaml" ] && (cd "$ADOPT_DIR" && docker compose down --remove-orphans) >>"$LOG" 2>&1
    docker rm -f "$PORT_NAME" "$VPN_NAME" >>"$LOG" 2>&1
  fi
}

restore_env() { # removes only the installer's lines, so later edits to .env survive
  local e="$WORKDIR/.env"
  [ -f "$e" ] || return 0
  sed -i "/$ENV_MARK\$/d" "$e"
  if [ -f "$STATE/env.compose_file" ]; then cat "$STATE/env.compose_file" >>"$e"; fi
  if [ -f "$STATE/env.absent" ] && [ ! -s "$e" ]; then rm -f "$e"; fi
  return 0
}

restore_original() { # puts the original container back. 0 if it's running again
  say "Putting the original setup back."
  if [ "$MODE" = compose ]; then
    teardown_new
    restore_env
    rm -f "$WORKDIR/$FILE_COMPOSE" "$WORKDIR/$FILE_ENV"
    # Only this service: other services in the project are left alone
    dc up -d --no-deps --force-recreate "$SERVICE" >>"$LOG" 2>&1
    [ -f "$STATE/net.absent" ] && docker network rm "${PROJECT}_default" >>"$LOG" 2>&1
  else
    teardown_new
    # Only delete the new container once the original is known to exist. Without it, the current one IS the original.
    if docker inspect "$CONTAINER-pre-vpn" >/dev/null 2>&1; then
      docker rm -f "$CONTAINER" >>"$LOG" 2>&1
      docker rename "$CONTAINER-pre-vpn" "$CONTAINER" >>"$LOG" 2>&1
    fi
    local pol; pol=$(cat "$STATE/restart_policy" 2>/dev/null); [ -n "$pol" ] && docker update --restart "$pol" "$CONTAINER" >>"$LOG" 2>&1
    docker start "$CONTAINER" >>"$LOG" 2>&1
    rm -rf "$ADOPT_DIR"
  fi
  sleep 8
  [ "$(ins '{{.State.Running}}')" = true ] || return 1
  if [ -n "$OLD_RELAY_PORT" ]; then wait_web "$CONTAINER" 40 && relay_set_port "$OLD_RELAY_PORT" "$CONTAINER"; fi
  [ "$WAS_STOPPED" = 1 ] && docker stop "$CONTAINER" >>"$LOG" 2>&1
  if [ "$MODE" = compose ] && [ -s "$STATE/files.sha256" ] && ! sha256sum -c --status "$STATE/files.sha256" 2>/dev/null; then
    warn_add "Your compose files changed after the install. That was you or another tool: this installer never edits them."
  fi
  # Only the add-on's own two volumes, by exact name. Never the user's.
  docker volume rm stremhu-vpn-pia stremhu-vpn-pia-shared >>"$LOG" 2>&1
  return 0
}

rollback() { # reason
  [ "$ROLLED_BACK" = 1 ] && return 0
  ROLLED_BACK=1; APPLYING=0
  say "Failed: $1"
  if restore_original; then
    rm -rf "$STATE"
    ui_msg "The install didn't finish, and your original StremHU is running again.

Reason: $1

Log: $LOG" 16
    say "Rolled back. Log: $LOG"
  else
    ui_msg "The install failed, and the original StremHU didn't come back by itself.

Reason: $1

Your data wasn't deleted. Saved state: $STATE
Log: $LOG" 16
    say "Rollback incomplete. Saved state: $STATE. Log: $LOG"
  fi
  cleanup_tmp
  exit 1
}

on_signal() { if [ "$APPLYING" = 1 ]; then rollback "cancelled"; fi; cleanup_tmp; exit 130; }
cleanup_tmp() { [ -n "$TMP" ] && rm -rf "$TMP"; PIA_PASS=""; return 0; }

# ---------------------------------------------------------------- verification

wait_web() { # container seconds
  local c="$1" end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    docker exec "$c" python -c "
import ssl,urllib.request as u,sys
c=ssl._create_unverified_context()
for s in ('http','https'):
    try:
        u.urlopen(f'{s}://127.0.0.1:$WEB_PORT/api/health',timeout=4,context=c); sys.exit(0)
    except Exception as e:
        if hasattr(e,'code'): sys.exit(0)
sys.exit(1)" >/dev/null 2>&1 && return 0
    sleep 4
  done
  return 1
}

exit_ip() { # container user
  docker exec -u "$2" "$1" python -c "
import urllib.request as u
try: print(u.urlopen('https://checkip.amazonaws.com',timeout=8).read().decode().strip())
except Exception: pass" 2>/dev/null | tail -1
}

kill_switch_test() { # 0 = nothing escaped
  local ep open
  ep=$(docker exec "$VPN_NAME" wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1)
  [ -n "$ep" ] || return 2
  docker exec "$VPN_NAME" iptables -I OUTPUT 1 -d "$ep" -j DROP || return 2
  docker exec "$VPN_NAME" iptables -I INPUT 1 -s "$ep" -j DROP
  sleep 5
  open=$(docker exec -u "$RUN_USER" "$CONTAINER" python -c "
import socket,time
o=0
for i in range(15):
    s=socket.socket(); s.settimeout(1); o+=s.connect_ex(('1.1.1.1',443))==0; s.close(); time.sleep(1)
print(o)" 2>/dev/null)
  docker exec "$VPN_NAME" iptables -D OUTPUT -d "$ep" -j DROP
  docker exec "$VPN_NAME" iptables -D INPUT -s "$ep" -j DROP
  [ "$open" = 0 ]
}

verify() {
  local end i home vpnip s rp
  say "Waiting for the VPN tunnel."
  end=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$VPN_NAME" 2>/dev/null)
    [ "$s" = healthy ] && break
    sleep 5
  done
  [ "$s" = healthy ] || rollback "the VPN didn't connect within 3 minutes (check the PIA login and location)"

  say "Waiting for StremHU."
  wait_web "$CONTAINER" 120 || rollback "StremHU didn't answer behind the VPN"
  [ "$(ins '{{.State.Running}}')" = true ] || rollback "StremHU stopped"

  say "Checking the public IP."
  home=$(curl -4 -s -m 10 https://checkip.amazonaws.com 2>/dev/null)
  for i in 1 2 3 4; do vpnip=$(exit_ip "$CONTAINER" "$RUN_USER"); [ -n "$vpnip" ] && break; sleep 5; done
  [ -n "$vpnip" ] || rollback "StremHU has no internet through the VPN"
  [ -z "$home" ] && warn_add "This machine's own public IP couldn't be read, so the VPN IP wasn't compared with it."
  [ "$vpnip" = "$home" ] && rollback "StremHU's traffic isn't going through the VPN"

  if [ -n "$PUBLISH" ]; then
    local bind="127.0.0.1"
    case "$PUBLISH" in *:*:*) bind=${PUBLISH%%:*} ;; esac
    local hp; hp=$(printf '%s' "$PUBLISH" | awk -F: '{print $(NF-1)}')
    say "Checking the web port from the host."
    s=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "https://$bind:$hp/api/health"); [ "$s" = 000 ] && s=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$bind:$hp/api/health")
    [ "$s" != 000 ] || rollback "the web port doesn't answer on $bind:$hp"
  fi

  say "Waiting for the forwarded port."
  local pf=""; end=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    pf=$(docker exec "$VPN_NAME" cat /pia-shared/port.dat 2>/dev/null)
    [ -n "$pf" ] && break
    sleep 5
  done
  if [ -z "$pf" ]; then
    warn_add "PIA hasn't given a forwarded port yet. Torrents still work, with fewer incoming connections. Some locations don't support it."
  else
    sleep 35
    rp=$(relay_get port "$CONTAINER")
    if [ -z "$rp" ]; then warn_add "The torrent port will be set once you've created StremHU's admin user."
    elif [ "$rp" != "$pf" ]; then warn_add "StremHU's torrent port ($rp) doesn't match PIA's ($pf) yet. Check: docker logs $PORT_NAME"; fi
  fi

  say "Testing the kill switch: cutting the tunnel for about 20 seconds."
  kill_switch_test; case $? in
    0) say "Kill switch OK: nothing got out." ;;
    2) rollback "the kill switch test couldn't run" ;;
    *) rollback "the kill switch test failed: traffic got out with the tunnel cut" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- commands

do_install() {
  install_packages
  pick_ui
  preflight_host
  find_stremhu
  [ -f "$STATE/state" ] && die "'$CONTAINER' is already set up by this installer. Use: install.sh status, or install.sh uninstall"
  ui_msg "This puts your StremHU container behind a PIA VPN.

Torrent traffic goes through the tunnel, with a kill switch and automatic port forwarding. Web access keeps working as it does now.

You'll need your PIA login. Nothing changes until you confirm, and any failure is rolled back." 16
  analyse
  ask_login
  ask_region
  summary

  say "Downloading images."
  docker pull -q "$VPN_IMAGE" >>"$LOG" 2>&1 || die "Couldn't download $VPN_IMAGE."

  save_state || die "Couldn't save the current state to $STATE."
  APPLYING=1

  if [ "$MODE" = compose ]; then
    write_compose_mode || rollback "couldn't write the files in $WORKDIR"
    (cd "$WORKDIR" && docker compose config -q) >>"$LOG" 2>&1 || rollback "Compose rejected the generated file (see the log)"
    say "Starting StremHU behind the VPN."
    # The old container holds the web port until it stops, and the VPN container takes that port over
    docker stop "$CONTAINER" >>"$LOG" 2>&1
    (cd "$WORKDIR" && docker compose up -d --no-recreate --no-deps "$VPN_NAME" && docker compose up -d --force-recreate --no-deps "$SERVICE" && docker compose up -d --no-deps "$PORT_NAME") >>"$LOG" 2>&1 || rollback "'docker compose up' failed (see the log)"
  else
    write_adopt_mode || rollback "couldn't write the files in $ADOPT_DIR"
    (cd "$ADOPT_DIR" && docker compose config -q) >>"$LOG" 2>&1 || rollback "Compose rejected the generated file (see the log)"
    ins '{{.HostConfig.RestartPolicy.Name}}' >"$STATE/restart_policy"
    docker update --restart no "$CONTAINER" >>"$LOG" 2>&1
    docker stop "$CONTAINER" >>"$LOG" 2>&1
    docker rename "$CONTAINER" "$CONTAINER-pre-vpn" >>"$LOG" 2>&1 || rollback "couldn't rename the old container"
    say "Starting StremHU behind the VPN."
    (cd "$ADOPT_DIR" && docker compose up -d) >>"$LOG" 2>&1 || rollback "'docker compose up' failed (see the log)"
  fi

  verify
  APPLYING=0

  local text="Done. StremHU is behind the VPN.

Checked: tunnel up, public IP is PIA's, web port answers, and traffic stopped when the tunnel was cut."
  [ -n "$WARNINGS" ] && text="$text

$WARNINGS"
  if [ "$MODE" = compose ]; then
    text="$text
Keep using 'docker compose' in $WORKDIR as usual."
  else
    text="$text
The stack is now in $ADOPT_DIR. To update: cd there, then docker compose pull && docker compose up -d. The old container stays stopped as $CONTAINER-pre-vpn until you uninstall."
  fi
  text="$text

Status: install.sh status
Remove: install.sh uninstall"
  say "$text"
  ui_msg "$text" 22
  cleanup_tmp
}

load_state() {
  local names=() d
  for d in "$STATE_ROOT"/*/; do [ -f "$d/state" ] && names+=("$(basename "$d")"); done
  [ "${#names[@]}" -gt 0 ] || { say "Nothing is installed by this tool."; exit 0; }
  if [ -n "$ARG_CONTAINER" ]; then CONTAINER="$ARG_CONTAINER"; else CONTAINER="${names[0]}"; fi
  STATE="$STATE_ROOT/$CONTAINER"
  [ -f "$STATE/state" ] || { say "'$CONTAINER' wasn't set up by this tool."; exit 1; }
  # shellcheck disable=SC1091
  . "$STATE/state"
}

do_status() {
  load_state
  printf 'Container: %s (%s mode)\n' "$CONTAINER" "$MODE"
  printf 'VPN: %s\n' "$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$VPN_NAME" 2>/dev/null || echo missing)"
  printf 'StremHU: %s\n' "$(ins '{{.State.Status}}')"
  printf 'Network: %s\n' "$(ins '{{.HostConfig.NetworkMode}}' | cut -c1-30)"
  printf 'Forwarded port: %s\n' "$(docker exec "$VPN_NAME" cat /pia-shared/port.dat 2>/dev/null)"
  printf 'StremHU torrent port: %s\n' "$(relay_get port "$CONTAINER")"
  local home vip; home=$(curl -4 -s -m 10 https://checkip.amazonaws.com); vip=$(exit_ip "$CONTAINER" "$RUN_USER")
  if [ -z "$vip" ]; then echo "Public IP: none (blocked, or the tunnel is down)"
  elif [ "$vip" = "$home" ]; then echo "Public IP: WARNING, same as this machine, NOT behind the VPN"
  else echo "Public IP: VPN ($vip)"; fi
  case "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER" 2>/dev/null)" in
    container:*) ;;
    *) echo "WARNING: the container isn't using the VPN's network. Was the old stack redeployed?" ;;
  esac
}

do_uninstall() {
  install_packages; pick_ui; TMP=$(mktemp -d)
  load_state
  ui_yesno "Remove the VPN from '$CONTAINER' and put the original setup back?" 10 || exit 0
  if restore_original; then
    rm -rf "$STATE"
    ui_msg "Removed. Your original setup is back, and StremHU runs WITHOUT the VPN.

Your files and volumes weren't changed. $WARNINGS" 12
    say "Removed. StremHU is running without the VPN."
  else
    ui_msg "The original StremHU didn't come back by itself. Saved state: $STATE. Log: $LOG" 10
    say "Uninstall incomplete. Saved state: $STATE"; exit 1
  fi
  cleanup_tmp
}

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- main

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    install|status|uninstall) CMD="$1" ;;
    --yes|-y) ASSUME_YES=1 ;;
    --container) shift; ARG_CONTAINER="${1:-}" ;;
    --region) shift; ARG_REGION="${1:-}" ;;
    --mode) shift; ARG_MODE="${1:-}" ;;
    --version) printf '%s\n' "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

need_root "${ORIG_ARGS[@]}"
: >>"$LOG" 2>/dev/null && chmod 600 "$LOG" 2>/dev/null
log "=== $CMD, version $VERSION"
trap on_signal INT TERM HUP

if ! mkdir "$STATE_ROOT.lock" 2>/dev/null; then
  if [ -z "$(find "$STATE_ROOT.lock" -mmin +30 2>/dev/null)" ]; then
    printf 'Another copy of this installer seems to be running. If not, remove %s.lock\n' "$STATE_ROOT" >&2; exit 1
  fi
fi
trap 'rmdir "$STATE_ROOT.lock" 2>/dev/null' EXIT

case "$CMD" in
  install) do_install ;;
  status) do_status ;;
  uninstall) do_uninstall ;;
esac
