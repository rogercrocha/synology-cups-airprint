#!/bin/bash
# CUPS + Avahi AirPrint server for a network printer, built for Synology DSM 7
# (works on any Docker host with host networking).
#
# Design:
#  - cupsd.conf is written by this script on every boot (config as code).
#    cupsctl is not used here: it needs a running cupsd and breaks the boot
#    when it cannot connect.
#  - printers.conf, the PPDs and the TLS certificate live in the /etc/cups
#    volume (config as data) and survive rebuilds.
#  - Queue creation is idempotent: an existing queue is never touched.

set -uo pipefail

PRINTER_URI="${PRINTER_URI:?set PRINTER_URI in .env, e.g. socket://192.168.1.50:9100}"
PRINTER_PPD="${PRINTER_PPD:?set PRINTER_PPD in .env, see lpinfo -m}"
QUEUE_NAME="${QUEUE_NAME:-Printer}"
QUEUE_DESC="${QUEUE_DESC:-$QUEUE_NAME}"
PRINTER_LOCATION="${PRINTER_LOCATION:-}"
PAGE_SIZE="${PAGE_SIZE:-A4}"
COLOR_DEFAULT="${COLOR_DEFAULT:-color}"
CUPS_USER="${CUPS_USER:-print}"
CUPS_PASSWORD="${CUPS_PASSWORD:-}"

log() { printf '[entrypoint] %s\n' "$*"; }

# --- 1. clean up leftovers from a previous run ------------------------------
# On 'docker restart' the container filesystem persists, so stale PID files
# and sockets would block dbus, avahi and cupsd.
log "removing stale PID files and sockets"
rm -f /run/dbus/pid /run/avahi-daemon/pid /run/cups/cups.sock /run/cups/cupsd.pid
mkdir -p /run/dbus /run/avahi-daemon /run/cups

# --- 2. server config (rewritten on every boot) ------------------------------
mkdir -p /etc/cups/ppd
cat > /etc/cups/cupsd.conf <<'CONF'
LogLevel warn
MaxLogSize 1m
ErrorPolicy retry-job
# iOS polls the job after sending it. If CUPS has already purged the job
# history ("PreserveJobHistory No"), iOS concludes the job was lost and
# resubmits it, over and over. Keep history for one hour.
PreserveJobHistory 3600
PreserveJobFiles No

Listen 0.0.0.0:631
Listen /run/cups/cups.sock

Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes
SystemGroup lpadmin

<Location />
  Order allow,deny
  Allow all
</Location>

<Location /admin>
  Order allow,deny
  Allow all
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
CONF

# Files cupsd expects to find. The volume replaces the image's /etc/cups,
# so anything missing has to be restored here.
# ssl/: cupsd writes its self-signed IPPS certificate there. Without this
# directory TLS fails ("Unable to create server credentials") and iOS,
# which prefers IPPS, shows "Gathering printer information" and gives up.
mkdir -p /etc/cups/ssl && chown root:lp /etc/cups/ssl && chmod 700 /etc/cups/ssl
for f in cups-files.conf snmp.conf; do
  [ -f "/etc/cups/$f" ] || cp -a "/etc/cups-default/$f" /etc/cups/ 2>/dev/null || true
done

# --- 3. web interface admin user --------------------------------------------
if ! id "$CUPS_USER" >/dev/null 2>&1; then
  useradd -r -G lpadmin -s /bin/sh -M "$CUPS_USER"
fi
if [ -n "$CUPS_PASSWORD" ]; then
  echo "$CUPS_USER:$CUPS_PASSWORD" | chpasswd
else
  log "WARNING: CUPS_PASSWORD is empty; the web interface has no usable login"
fi

# --- 4. dbus + avahi (Bonjour / AirPrint announcement) ----------------------
# DSM's own avahi is normally not running, so the container brings its own.
if dbus-daemon --system --fork; then
  log "dbus started"
else
  log "WARNING: dbus did not start"
fi
sleep 1

if avahi-daemon --daemonize --no-drop-root; then
  log "avahi started"
else
  log "WARNING: avahi did not start; the queue will exist but not be announced"
fi

# --- 5. cupsd ----------------------------------------------------------------
/usr/sbin/cupsd -f &
CUPSD_PID=$!

log "waiting for cupsd"
READY=no
for _ in $(seq 1 60); do
  if lpstat -r 2>/dev/null | grep -qx "scheduler is running"; then READY=yes; break; fi
  if ! kill -0 "$CUPSD_PID" 2>/dev/null; then
    log "ERROR: cupsd died during boot"
    exit 1
  fi
  sleep 1
done
if [ "$READY" != yes ]; then
  log "ERROR: cupsd did not answer within 60s"
  kill "$CUPSD_PID" 2>/dev/null
  exit 1
fi
log "cupsd ready"

# --- 6. queue ----------------------------------------------------------------
create_queue() {
  local name="$1"
  if lpstat -p "$name" >/dev/null 2>&1; then
    log "queue $name already exists, leaving it as is"
    return 0
  fi
  # Neither ColorModel nor Duplex is forced, so the client's IPP attributes
  # (print-color-mode, sides) decide. CUPS maps sides -> Duplex by itself.
  log "creating queue $name"
  if lpadmin -p "$name" -E \
      -v "$PRINTER_URI" \
      -m "$PRINTER_PPD" \
      -D "$QUEUE_DESC" \
      -L "$PRINTER_LOCATION" \
      -o printer-is-shared=true \
      -o "PageSize=$PAGE_SIZE" \
      -o "print-color-mode-default=$COLOR_DEFAULT"; then
    log "queue $name created"
  else
    log "WARNING: could not create $name (does PPD '$PRINTER_PPD' exist?)"
  fi
}

# Stock CUPS 2.4 maps print-color-mode=monochrome to a PPD option only through
# presets. With no *APPrinterPreset in the PPD, it auto-creates the grayscale
# preset only when ColorModel has a choice named exactly "Gray". Foomatic PPDs
# call it "Grayscale", so the iOS/macOS black & white toggle is advertised
# but silently ignored (jobs print in color). This adds explicit presets.
# (Ubuntu's CUPS carries a patch that hides the problem; Debian's does not.)
add_color_presets() {
  local name="$1" src="/etc/cups/ppd/$1.ppd" new="/tmp/$1.presets.ppd" color=""
  [ -f "$src" ] || { log "WARNING: $src not found, presets not added"; return 0; }
  if grep -q '^\*APPrinterPreset' "$src"; then
    log "queue $name already has color presets"
    return 0
  fi
  if ! grep -q '^\*ColorModel Grayscale[/:]' "$src"; then
    log "queue $name has no ColorModel Grayscale choice; presets not needed"
    return 0
  fi
  for c in Color RGB CMYK; do
    if grep -q "^\*ColorModel $c[/:]" "$src"; then color="$c"; break; fi
  done

  cp "$src" "$new"
  cat >> "$new" <<'PRESETS'

*% print-color-mode=monochrome -> ColorModel=Grayscale
*APPrinterPreset Gray_with_Paper_Auto-Detect/Black and White: "
  *ColorModel Grayscale
  com.apple.print.preset.graphicsType General
  com.apple.print.preset.quality mid
  com.apple.print.preset.media-front-coating autodetect
  com.apple.print.preset.output-mode monochrome"
*End
PRESETS
  if [ -n "$color" ]; then
    cat >> "$new" <<PRESETS
*APPrinterPreset Color_with_Paper_Auto-Detect/Color: "
  *ColorModel $color
  com.apple.print.preset.graphicsType General
  com.apple.print.preset.quality mid
  com.apple.print.preset.media-front-coating autodetect
  com.apple.print.preset.output-mode color"
*End
PRESETS
  fi

  if command -v cupstestppd >/dev/null && ! cupstestppd -r -q "$new"; then
    log "WARNING: cupstestppd rejected the PPD with presets; queue left unchanged"
    return 0
  fi
  if lpadmin -p "$name" -P "$new"; then
    cupsenable "$name"; cupsaccept "$name"
    log "color presets added to $name"
  else
    log "WARNING: lpadmin -P failed for $name"
  fi
}

create_queue "$QUEUE_NAME"
add_color_presets "$QUEUE_NAME"
lpadmin -d "$QUEUE_NAME" 2>/dev/null || true

log "queues:"
lpstat -v 2>&1 | sed 's/^/[entrypoint]   /'
log "ready. Web interface: http://<NAS-IP>:631/  (user: $CUPS_USER)"

wait "$CUPSD_PID"
