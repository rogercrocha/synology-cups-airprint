#!/bin/bash
# Installs the CUPS/AirPrint server on a Synology NAS (DSM 7).
#
# Run ON THE NAS, from the folder you downloaded this repository to:
#   cd ~/synology-cups-airprint && sudo bash deploy.sh
#
# The first run asks a few questions (it finds the printer on the network and
# suggests a driver) and saves the answers. Later runs just rebuild and
# restart, keeping the queue. To change the printer or its settings:
#   sudo bash deploy.sh --reconfigure
#
# The screen shows one line per step, with the last lines of the running
# command underneath while it works. Everything is also written to
# deploy.log next to this script.

set -euo pipefail

DEST="${DEST:-/volume1/docker/synology-cups-airprint}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER=cups-airprint
IMAGE=synology-cups-airprint:local
LOG="$SRC/deploy.log"
WINDOW=4                       # lines of live output shown under a step
RECONFIGURE=no
[ "${1:-}" = "--reconfigure" ] && RECONFIGURE=yes

: > "$LOG"
log() { printf '%s\n' "$*" >> "$LOG"; }

# ---- screen helpers ------------------------------------------------------------
if [ -t 1 ]; then
  TTY=yes
  B=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; R=$'\e[0m'
else
  TTY=no; B=""; DIM=""; GRN=""; RED=""; YEL=""; R=""
fi
COLS="$( (tput cols 2>/dev/null || echo 80) | head -1)"; [ "$COLS" -gt 20 ] 2>/dev/null || COLS=80

section() { printf '\n%s%s%s\n' "$B" "$*" "$R"; log ""; log "== $*"; }
note()    { printf '  %s%s%s\n' "$DIM" "$*" "$R"; log "   $*"; }
ok()      { printf '  %s✔%s %s\n' "$GRN" "$R" "$*"; log " ok $*"; }
warn()    { printf '  %s!%s %s\n' "$YEL" "$R" "$*"; log " !! $*"; }
fail()    {
  printf '\n  %s✖ %s%s\n' "$RED" "$*" "$R" >&2; log " ERROR $*"
  printf '  Full log: %s\n' "$LOG" >&2
  exit 1
}

# step "Title" command...   runs the command, shows a live window of its last
# lines, then replaces everything with "✔ Title (time)" or prints the tail
# of the output on failure.
step() {
  local title="$1"; shift
  local t0=$SECONDS rc first
  log "-- $title: $*"
  first="$(( $(wc -l < "$LOG") + 1 ))"
  printf '  %s…%s %s\n' "$DIM" "$R" "$title"
  set +e
  "$@" 2>&1 | tee -a "$LOG" | {
    if [ "$TTY" = yes ]; then
      local ring=() shown=0 l i
      while IFS= read -r l; do
        l="${l//$'\r'/}"; l="${l//$'\t'/ }"
        ring+=("${l:0:$((COLS - 6))}")
        [ "${#ring[@]}" -gt "$WINDOW" ] && ring=("${ring[@]:1}")
        [ "$shown" -gt 0 ] && printf '\e[%dA' "$shown"
        for i in "${ring[@]}"; do printf '\e[2K    %s%s%s\n' "$DIM" "$i" "$R"; done
        shown="${#ring[@]}"
      done
      [ "$shown" -gt 0 ] && printf '\e[%dA\e[J' "$shown"
    else
      cat > /dev/null
    fi
  }
  rc="${PIPESTATUS[0]}"
  set -e
  local took="$((SECONDS - t0))s"
  [ "$TTY" = yes ] && printf '\e[1A\e[2K'
  if [ "$rc" -eq 0 ]; then
    printf '  %s✔%s %s %s(%s)%s\n' "$GRN" "$R" "$title" "$DIM" "$took" "$R"
  else
    printf '  %s✖%s %s %s(%s)%s\n' "$RED" "$R" "$title" "$DIM" "$took" "$R"
    tail -n +"$first" "$LOG" | tail -15 | sed 's/^/    /'

    fail "$title failed"
  fi
}

# quiet "Title" var command...   like step, for commands whose output is data:
# shows a waiting line, stores stdout in the named variable.
quiet() {
  local title="$1" __var="$2"; shift 2
  local t0=$SECONDS out
  printf '  %s…%s %s\n' "$DIM" "$R" "$title"
  out="$("$@" 2>>"$LOG" || true)"
  log "-- $title"; log "$out"
  [ "$TTY" = yes ] && printf '\e[1A\e[2K'
  printf '  %s✔%s %s %s(%ss)%s\n' "$GRN" "$R" "$title" "$DIM" "$((SECONDS - t0))" "$R"
  printf -v "$__var" '%s' "$out"
}

# ask "Question" "default" -> answer on stdout
ask() {
  local reply
  if [ -n "${2:-}" ]; then printf '  %s [%s]: ' "$1" "$2" > /dev/tty
  else printf '  %s: ' "$1" > /dev/tty; fi
  IFS= read -r reply < /dev/tty || true
  log "   ? $1 -> ${reply:-${2:-}}"
  printf '%s' "${reply:-${2:-}}"
}

# ask_secret "Question" -> answer on stdout, typed without echo
ask_secret() {
  local reply
  printf '  %s: ' "$1" > /dev/tty
  IFS= read -rs reply < /dev/tty || true
  printf '\n' > /dev/tty
  printf '%s' "$reply"
}

# ---- 1. prerequisites ----------------------------------------------------------------
printf '%ssynology-cups-airprint installer%s\n' "$B" "$R"
note "full log: $LOG"

[ "$(id -u)" -eq 0 ] || fail "run with sudo: sudo bash deploy.sh"

section "Checking the NAS"
DOCKER="$(command -v docker || echo /usr/local/bin/docker)"
[ -x "$DOCKER" ] || fail "docker not found. Install Container Manager in DSM."
ok "Docker $("$DOCKER" --version 2>/dev/null | sed 's/^Docker version //; s/,.*//')"

if "$DOCKER" compose version >/dev/null 2>&1; then
  COMPOSE=("$DOCKER" compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
elif [ -x /usr/local/bin/docker-compose ]; then
  COMPOSE=(/usr/local/bin/docker-compose)
else
  fail "neither 'docker compose' nor 'docker-compose' is available"
fi
ok "Compose: ${COMPOSE[*]}"

# Port 631 (IPP) must be free, unless it is our own container holding it.
# port_owner prints "PID NAME" of the process listening on 631, if any.
port_owner() {
  netstat -tlnp 2>/dev/null | awk '$4 ~ /:631$/ {split($7, a, "/"); print a[1], a[2]; exit}'
}
# container_of PID prints the name of the Docker container the process runs
# in, or nothing when it belongs to the NAS itself.
container_of() {
  local id
  id="$(grep -o -m1 -E '[0-9a-f]{64}' "/proc/$1/cgroup" 2>/dev/null || true)"
  [ -n "$id" ] || return 0
  "$DOCKER" ps --no-trunc --format '{{.ID}} {{.Names}}' | awk -v id="$id" '$1 == id {print $2}'
}

if "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  ok "Port 631 is ours (the server is already running)"
elif netstat -tln 2>/dev/null | grep -q ':631 '; then
  read -r OWNER_PID OWNER_NAME <<<"$(port_owner)"
  OWNER_CT="$( [ -n "${OWNER_PID:-}" ] && container_of "$OWNER_PID" || true)"
  if [ -n "$OWNER_CT" ]; then
    fail "port 631 is used by the Docker container \"$OWNER_CT\" ($OWNER_NAME). Stop it (sudo docker stop $OWNER_CT) and run this again."
  elif [ "${OWNER_NAME:-}" = cupsd ]; then
    warn "Port 631 is used by DSM's own print service."
    note "DSM starts it for printers added in Control Panel > External Devices > Printer."
    note "Those printers stop working while this server runs; remove them there"
    note "too, or DSM may start its print service again after a reboot."
    answer="$(ask "Stop DSM's print service now? (yes/no)" "no")"
    case "$answer" in
      y|Y|yes|Yes|YES|s|S|sim|Sim)
        for svc in cupsd cups-service-handler cups-lpd; do
          synosystemctl stop "$svc" >> "$LOG" 2>&1 || true
        done
        sleep 2
        if netstat -tln 2>/dev/null | grep -q ':631 '; then
          fail "port 631 is still in use after stopping DSM's print service. Remove the printers in Control Panel > External Devices > Printer and try again."
        fi
        ok "DSM's print service stopped"
        note "To bring it back later: sudo synosystemctl start cupsd"
        ;;
      *)
        fail "port 631 is in use by DSM's print service. Remove the printers in Control Panel > External Devices > Printer, or answer yes to stop it."
        ;;
    esac
  else
    fail "port 631 is in use by ${OWNER_NAME:-another program}${OWNER_PID:+ (PID $OWNER_PID)}. Stop it and run this again."
  fi
else
  ok "Port 631 is available"
fi

# ---- 2. files and image --------------------------------------------------------------
section "Preparing the server"
mkdir -p "$DEST/config"
for f in Dockerfile entrypoint.sh airprint-setup docker-compose.yml .env.example; do
  [ -f "$SRC/$f" ] || fail "missing file: $f"
  cp -a "$SRC/$f" "$DEST/$f"
done
ok "Files copied to $DEST"
note "The first build downloads about 300 MB; later builds take seconds."
step "Building the image (Debian, CUPS, Ghostscript, Foomatic and HP drivers, Avahi)" \
  "$DOCKER" build -t "$IMAGE" "$DEST"

helper()      { "$DOCKER" run --rm --network host --entrypoint airprint-setup "$IMAGE" "$@"; }
helper_isol() { "$DOCKER" run --rm --network none --entrypoint airprint-setup "$IMAGE" "$@"; }

# ---- 3. setup wizard (first run, or --reconfigure) ------------------------------------
if [ -f "$SRC/.env" ] && [ ! -f "$DEST/.env" ]; then
  cp "$SRC/.env" "$DEST/.env"          # a hand-made .env next to deploy.sh
fi

if [ ! -f "$DEST/.env" ] || [ "$RECONFIGURE" = yes ]; then
  [ -r /dev/tty ] || fail "the setup needs a terminal. Run it in an SSH session, or create $DEST/.env from .env.example."

  section "Printer"
  quiet "Looking for printers on the network (SNMP)" FOUND_TXT helper discover
  mapfile -t FOUND < <(printf '%s' "$FOUND_TXT" | grep . || true)

  IP=""; MM=""; DEVID=""
  if [ "${#FOUND[@]}" -gt 0 ]; then
    i=0
    for line in "${FOUND[@]}"; do
      i=$((i + 1))
      IFS=$'\t' read -r f_ip f_uri f_mm f_id <<<"$line"
      printf '    %d) %-40s %s\n' "$i" "$f_mm" "$f_ip"
    done
    printf '    m) type the IP address\n'
    choice="$(ask "Printer" 1)"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#FOUND[@]}" ]; then
      IFS=$'\t' read -r IP f_uri MM DEVID <<<"${FOUND[$((choice - 1))]}"
    fi
  else
    warn "No printer answered. That is common when SNMP is off on the printer."
  fi

  if [ -z "$IP" ]; then
    IP="$(ask "Printer IP address (see the printer's network settings page)")"
    [ -n "$IP" ] || fail "no IP address given"
    quiet "Asking $IP for its model" PROBE helper probe "$IP"
    if [ -n "$PROBE" ]; then
      IFS=$'\t' read -r _ _ MM DEVID <<<"$PROBE"
      ok "It is a $MM"
    else
      MM="$(ask "Printer make and model, e.g. Brother MFC-9460CDN")"
    fi
  fi

  quiet "Testing the printing ports on $IP (9100, 631, 515)" PORTS_TXT helper ports "$IP"
  while [ "$PORTS_TXT" = unresolved ]; do
    warn "The name $IP does not resolve from the NAS."
    IP="$(ask "Printer IP address (see the printer's network settings page)")"
    [ -n "$IP" ] || fail "no IP address given"
    quiet "Testing the printing ports on $IP (9100, 631, 515)" PORTS_TXT helper ports "$IP"
  done
  PORTS=" $(printf '%s' "$PORTS_TXT" | tr '\n' ' ') "
  if [[ "$PORTS" == *" 9100 "* ]]; then
    URI="socket://$IP:9100"
    ok "Printing to $URI"
  else
    OPEN="$(printf '%s' "$PORTS_TXT" | tr '\n' ' ')"
    warn "Port 9100 does not answer (open: ${OPEN:-none})"
    note "Examples: lpd://$IP/queue   ipp://$IP/ipp/print"
    URI="$(ask "Printer URI")"
    [ -n "$URI" ] || fail "no printer URI given"
  fi

  case "$URI" in
    *://[0-9]*.[0-9]*.[0-9]*.[0-9]*)
      HOSTPART="${URI#*://}"; HOSTPART="${HOSTPART%%[:/]*}"
      warn "Reserve $HOSTPART for this printer in your router (DHCP reservation)."
      note "If the router gives the printer another address, printing stops."
      ;;
  esac

  section "Driver"
  if [ -n "$DEVID" ]; then
    LANGS="$(printf '%s' "$DEVID" | tr ';' '\n' | sed -n 's/^\(CMD\|COMMAND SET\)://Ip' | head -1)"
    [ -n "$LANGS" ] && note "The printer speaks: $LANGS"
  fi
  PPD=""
  while [ -z "$PPD" ]; do
    quiet "Reading the driver list for ${MM:-the printer}" DRV_TXT helper_isol drivers "$MM" "$DEVID"
    mapfile -t DRV < <(printf '%s' "$DRV_TXT" | grep . || true)
    note "Drivers for this exact model come first, then generic ones."
    i=0
    for line in "${DRV[@]}"; do
      i=$((i + 1)); printf '    %d) %s\n' "$i" "${line#*$'\t'}"
    done
    printf '    s) search the driver list\n'
    default=1; [ "${#DRV[@]}" -eq 0 ] && default=s
    choice="$(ask "Driver" "$default")"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DRV[@]}" ]; then
      PPD="${DRV[$((choice - 1))]%%$'\t'*}"
    else
      term="$(ask "Search for (model number or brand)")"
      quiet "Searching for \"$term\"" HITS_TXT helper_isol search "$term"
      mapfile -t HITS < <(printf '%s' "$HITS_TXT" | grep . || true)
      if [ "${#HITS[@]}" -eq 0 ]; then warn "Nothing found for \"$term\"."; continue; fi
      i=0
      for line in "${HITS[@]}"; do
        i=$((i + 1)); printf '    %d) %s\n' "$i" "${line#*$'\t'}"
      done
      choice="$(ask "Driver (Enter to go back)")"
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#HITS[@]}" ]; then
        PPD="${HITS[$((choice - 1))]%%$'\t'*}"
      fi
    fi
  done

  section "Details"
  DESC="$(ask "Name shown on iPhone and Mac" "${MM:-Printer}")"
  PAPER="$(ask "Paper size (A4 or Letter)" "A4")"
  LOCATION="$(ask "Location (optional)" "")"
  # queue names cannot contain spaces, slashes or '#'
  QUEUE="$(printf '%s' "$DESC" | tr -c 'A-Za-z0-9_.-' '_' | tr -s '_' | sed 's/^_//; s/_$//')"
  QUEUE="${QUEUE:-Printer}"

  # Password for the CUPS web interface (user "print")
  OLDPASS="$(grep -s '^CUPS_PASSWORD=' "$DEST/.env" | cut -d= -f2- || true)"
  [ "$OLDPASS" = change-me ] && OLDPASS=""
  note "The CUPS web interface (http://NAS:631) asks for user \"print\" and a password."
  if [ -n "$OLDPASS" ]; then
    note "Press Enter to keep the current password."
  else
    note "Press Enter to have one generated and shown at the end."
  fi
  PASS=""; SHOWPASS=no
  while :; do
    P1="$(ask_secret "Password for the web interface")"
    if [ -z "$P1" ]; then
      if [ -n "$OLDPASS" ]; then PASS="$OLDPASS"; ok "Password kept"
      else PASS="$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' || head -c 12 /dev/urandom | base64 | tr -d '/+=')"; SHOWPASS=yes; ok "Password generated"; fi
      break
    fi
    case "$P1" in
      *'$'*|*'"'*|*"'"*|*'\'*) warn "Please avoid \$, quotes and backslashes in the password."; continue ;;
    esac
    [ "${#P1}" -ge 6 ] || { warn "Use at least 6 characters."; continue; }
    P2="$(ask_secret "Type it again")"
    [ "$P1" = "$P2" ] || { warn "The two passwords differ, try again."; continue; }
    PASS="$P1"; ok "Password set"
    break
  done

  umask 177
  cat > "$DEST/.env" <<ENV
# Written by deploy.sh. Change with: sudo bash deploy.sh --reconfigure
PRINTER_URI=$URI
PRINTER_PPD=$PPD
QUEUE_NAME=$QUEUE
QUEUE_DESC=$DESC
PRINTER_LOCATION=$LOCATION
PAGE_SIZE=$PAPER
COLOR_DEFAULT=color
CUPS_USER=print
CUPS_PASSWORD=$PASS
ENV
  umask 022
  chmod 600 "$DEST/.env"
  ok "Settings saved to $DEST/.env"

  # The queue is only created when it does not exist yet, so a new
  # configuration starts from an empty config folder (the old one is kept).
  if [ "$RECONFIGURE" = yes ] && [ -n "$(ls -A "$DEST/config" 2>/dev/null)" ]; then
    "$DOCKER" rm -f "$CONTAINER" >/dev/null 2>&1 || true
    OLD="$DEST/config.old-$(date +%Y%m%d-%H%M%S)"
    mv "$DEST/config" "$OLD"; mkdir -p "$DEST/config"
    ok "Previous configuration kept in $OLD"
  fi
fi
chmod 600 "$DEST/.env"

# ---- 4. start ------------------------------------------------------------------------
QUEUE_NAME="$(sed -n 's/^QUEUE_NAME=//p' "$DEST/.env")"
QUEUE_NAME="${QUEUE_NAME:-Printer}"

section "Starting"
cd "$DEST"
step "Starting the container (host network, restarts with the NAS)" \
  "${COMPOSE[@]}" up -d

# Streams the container's own log until the entrypoint says it is ready.
follow_setup() {
  local shown=0 total out
  for _ in $(seq 1 60); do
    out="$("$DOCKER" logs "$CONTAINER" 2>&1 || true)"
    total="$(printf '%s\n' "$out" | wc -l)"
    if [ "$total" -gt "$shown" ]; then
      printf '%s\n' "$out" | tail -n +"$((shown + 1))"
      shown="$total"
    fi
    grep -q '^\[entrypoint\] ready\.' <<<"$out" && return 0
    grep -q '^\[entrypoint\] ERROR' <<<"$out" && return 1
    sleep 2
  done
  echo "timed out after 120 s"
  return 1
}
step "Setting up CUPS, the queue and the black & white fix" follow_setup

# ---- 5. checks -------------------------------------------------------------------------
section "Checking what the iPhone and Mac will see"
ATTRS="$("$DOCKER" exec "$CONTAINER" ipptool -tv "ipp://localhost:631/printers/$QUEUE_NAME" get-printer-attributes.test 2>/dev/null || true)"
log "$ATTRS"
if grep -q 'print-color-mode-supported.*monochrome' <<<"$ATTRS"; then
  ok "Color / black & white toggle"
else
  warn "No color / black & white toggle (black & white printer, or a driver without color modes)"
fi
if grep -q 'sides-supported.*two-sided' <<<"$ATTRS"; then
  ok "Two-sided toggle"
else
  warn "No two-sided toggle (the driver does not offer duplex)"
fi
if "$DOCKER" exec "$CONTAINER" sh -c "grep -q '^\*APPrinterPreset' /etc/cups/ppd/$QUEUE_NAME.ppd" 2>/dev/null; then
  ok "Black & white fix applied to the driver"
fi
ANNOUNCE="$(timeout 10 "$DOCKER" exec "$CONTAINER" avahi-browse -rpt _ipp._tcp 2>/dev/null || true)"
log "$ANNOUNCE"
NAME="$(grep -E '^=.*(@|\\064)' <<<"$ANNOUNCE" | grep -F "$(hostname)" | head -1 | cut -d';' -f4 | sed 's/\\032/ /g; s/\\040/(/g; s/\\041/)/g; s/\\064/@/g' || true)"
if [ -n "$NAME" ]; then
  ok "Announced on the network as \"$NAME\""
else
  warn "No Bonjour announcement found (iPhone and Mac will not see the printer)"
fi

NAS_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
NAS_IP="${NAS_IP:-$(hostname)}"
printf '\n%sDone.%s On the iPhone or Mac, print and choose "%s".\n' "$B" "$R" "${NAME:-the printer ending in @ $(hostname)}"
note "Web interface: http://$NAS_IP:631/  (user: print)"
if [ "${SHOWPASS:-no}" = yes ]; then
  printf '  Generated password: %s%s%s  (also saved in %s/.env)\n' "$B" "$PASS" "$R" "$DEST"
fi
note "Change the printer or settings: sudo bash deploy.sh --reconfigure"
note "Full log: $LOG"
