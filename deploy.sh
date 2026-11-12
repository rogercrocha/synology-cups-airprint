#!/bin/bash
# Builds and starts the CUPS/AirPrint container on a Synology NAS (DSM 7).
#
# Run ON THE NAS, with sudo, from the folder you copied this repository to:
#   cd ~/synology-cups-airprint && sudo bash deploy.sh
#
# Idempotent: run it again to rebuild the image. Queues are kept in the
# config volume and are not recreated.

set -euo pipefail

DEST="${DEST:-/volume1/docker/synology-cups-airprint}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER=cups-airprint

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- 1. prerequisites ---------------------------------------------------------
[ "$(id -u)" -eq 0 ] || fail "run with sudo: sudo bash deploy.sh"

DOCKER="$(command -v docker || echo /usr/local/bin/docker)"
[ -x "$DOCKER" ] || fail "docker not found. Install Container Manager in DSM."

if "$DOCKER" compose version >/dev/null 2>&1; then
  COMPOSE=("$DOCKER" compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
elif [ -x /usr/local/bin/docker-compose ]; then
  COMPOSE=(/usr/local/bin/docker-compose)
else
  fail "neither 'docker compose' nor 'docker-compose' is available"
fi
say "compose: ${COMPOSE[*]}"

# Port 631 must be free. If DSM's own print server is on, turn it off in
# Control Panel > External Devices > Printer.
if ! "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
   && netstat -tln 2>/dev/null | grep -q ':631 '; then
  fail "port 631 is in use (DSM print server on?). Turn it off and try again."
fi

# --- 2. copy files to the docker share ----------------------------------------
say "installing into $DEST"
mkdir -p "$DEST/config"
for f in Dockerfile entrypoint.sh docker-compose.yml .env.example; do
  [ -f "$SRC/$f" ] || fail "missing file: $f"
  cp -a "$SRC/$f" "$DEST/$f"
done

# --- 3. .env (printer settings and web password, mode 600) ---------------------
if [ ! -f "$DEST/.env" ]; then
  if [ -f "$SRC/.env" ]; then
    cp "$SRC/.env" "$DEST/.env"
  else
    cp "$DEST/.env.example" "$DEST/.env"
    say "created $DEST/.env from .env.example. Edit PRINTER_URI, PRINTER_PPD and the rest, then run this script again."
    chmod 600 "$DEST/.env"
    exit 0
  fi
fi
chmod 600 "$DEST/.env"
if grep -q '^CUPS_PASSWORD=change-me' "$DEST/.env"; then
  NEW_PASS="$(openssl rand -base64 18 2>/dev/null || head -c 18 /dev/urandom | base64)"
  sed -i "s|^CUPS_PASSWORD=.*|CUPS_PASSWORD=$NEW_PASS|" "$DEST/.env"
  unset NEW_PASS
  say "generated a random web interface password in $DEST/.env"
fi

# --- 4. build and start -------------------------------------------------------
cd "$DEST"
say "building the image (takes a few minutes the first time)"
"${COMPOSE[@]}" up -d --build

QUEUE_NAME="$(sed -n 's/^QUEUE_NAME=//p' "$DEST/.env")"
QUEUE_NAME="${QUEUE_NAME:-Printer}"

# Wait for the entrypoint to finish (it creates the queue after cupsd is up).
say "waiting for the container to finish setting up"
STATE=timeout
for _ in $(seq 1 60); do
  LOG="$("$DOCKER" logs "$CONTAINER" 2>&1 || true)"
  # here-strings, not pipes: with pipefail, "grep -q" closing the pipe early
  # would make the whole pipeline fail even on a match
  if grep -q '^\[entrypoint\] ready\.' <<<"$LOG"; then STATE=ready; break; fi
  if grep -q '^\[entrypoint\] ERROR' <<<"$LOG"; then STATE=error; break; fi
  sleep 2
done

say "container log"
"${COMPOSE[@]}" logs --tail 40 || true

[ "$STATE" = ready ] || fail "the container did not finish setting up ($STATE); see the log above"

say "queue status"
"$DOCKER" exec "$CONTAINER" lpstat -t || true

say "IPP attributes the iPhone uses for its color and duplex toggles"
"$DOCKER" exec "$CONTAINER" ipptool -tv \
  "ipp://localhost:631/printers/$QUEUE_NAME" get-printer-attributes.test \
  | grep -E 'print-color-mode-(supported|default)|sides-supported' \
  || echo "WARNING: could not read the IPP attributes"

say "Bonjour announcement as seen from inside the container"
ANNOUNCE="$(timeout 10 "$DOCKER" exec "$CONTAINER" avahi-browse -rpt _ipp._tcp 2>/dev/null || true)"
if grep -qE '^=.*(@|\\064)' <<<"$ANNOUNCE"; then
  grep -E '^=.*(@|\\064)' <<<"$ANNOUNCE" | cut -d';' -f2,3,4,8,9 | sed 's/\\032/ /g; s/\\040/(/g; s/\\041/)/g; s/\\064/@/g'
else
  echo "WARNING: no announcement found (iPhone will not see the queue)"
fi

cat <<FIM

==> Done.

Web interface:  http://<NAS-IP>:631/   (login in $DEST/.env)

Test page with the black & white mapping:
  sudo docker exec $CONTAINER sh -c "printf '%%!PS\\n1 0 0 setrgbcolor 72 72 200 200 rectfill showpage\\n' | lp -d $QUEUE_NAME -o print-color-mode=monochrome"
FIM
