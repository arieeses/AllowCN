#!/usr/bin/env bash
#
# AllowCN one-click installer.
#   sudo ./install.sh                 # install + first run (daily 04:30 refresh)
#   sudo ./install.sh --schedule "0 3 * * *"   # custom cron schedule
#   sudo ./install.sh --no-run        # install without applying rules immediately
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/allowcn"
CONF_DIR="/etc/allowcn"
CONF="$CONF_DIR/allowcn.conf"
CRON="/etc/cron.d/allowcn"
LOG="/var/log/allowcn.log"

SCHEDULE="30 4 * * *"
RUN_NOW=1
for arg in "$@"; do
  case "$arg" in
    --schedule) shift; SCHEDULE="${1:?missing cron expression}"; shift || true ;;
    --schedule=*) SCHEDULE="${arg#*=}" ;;
    --no-run) RUN_NOW=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

log() { echo -e "\033[1;32m[AllowCN]\033[0m $*"; }
warn() { echo -e "\033[1;33m[AllowCN]\033[0m $*"; }
die() { echo -e "\033[1;31m[AllowCN] ERROR:\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "please run as root (sudo ./install.sh)"

# ---- detect package manager & install dependencies -------------------------
install_deps() {
  local pkgs_common="ipset iptables"
  if command -v apt-get >/dev/null 2>&1; then
    log "installing dependencies via apt-get"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      $pkgs_common python3 python3-pip curl ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    log "installing dependencies via dnf"
    dnf install -y -q $pkgs_common python3 python3-pip curl >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    log "installing dependencies via yum"
    yum install -y -q $pkgs_common python3 python3-pip curl >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    log "installing dependencies via apk"
    apk add --no-cache $pkgs_common python3 py3-pip curl >/dev/null
  else
    warn "unknown package manager; ensure ipset, iptables, python3, pip, curl are installed"
  fi

  log "installing python 'maxminddb' module"
  if ! python3 -c 'import maxminddb' >/dev/null 2>&1; then
    pip3 install --quiet "maxminddb>=2.0" 2>/dev/null \
      || pip3 install --quiet --break-system-packages "maxminddb>=2.0" \
      || die "failed to install python maxminddb module"
  fi
}

install_deps

# ---- lay down files --------------------------------------------------------
log "installing files into $LIB_DIR and $CONF_DIR"
mkdir -p "$LIB_DIR" "$CONF_DIR" /var/lib/allowcn
install -m 0755 "$SRC_DIR/src/allowcn.sh"     "$LIB_DIR/allowcn.sh"
install -m 0755 "$SRC_DIR/src/mmdb_to_cidr.py" "$LIB_DIR/mmdb_to_cidr.py"

if [ -f "$CONF" ]; then
  log "keeping existing config at $CONF"
else
  install -m 0644 "$SRC_DIR/allowcn.conf.example" "$CONF"
  log "wrote default config to $CONF"
fi

# convenience symlink
ln -sf "$LIB_DIR/allowcn.sh" /usr/local/sbin/allowcn

# ---- cron schedule (periodic + @reboot for persistence) --------------------
log "installing cron schedule: '$SCHEDULE'"
cat > "$CRON" <<EOF
# AllowCN — refresh China-mainland allow rules. Managed by install.sh.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
$SCHEDULE  root $LIB_DIR/allowcn.sh >> $LOG 2>&1
@reboot    root $LIB_DIR/allowcn.sh --reload-only >> $LOG 2>&1
EOF
chmod 0644 "$CRON"
touch "$LOG"

# ---- safety banner ---------------------------------------------------------
# shellcheck disable=SC1090
. "$CONF"
warn "=============================================================="
warn " Protected TCP ports : ${PROTECT_TCP_PORTS:-<none>}"
warn " Protected UDP ports : ${PROTECT_UDP_PORTS:-<none>}"
warn " Extra allow CIDRs   : ${ALLOW_EXTRA:-<none>}"
warn " SSH (port 22) is NOT protected by default — you stay reachable."
warn " Edit $CONF then re-run 'allowcn' to change ports."
warn "=============================================================="

if [ "$RUN_NOW" -eq 1 ]; then
  log "running first update now..."
  "$LIB_DIR/allowcn.sh" 2>&1 | tee -a "$LOG"
  log "done. Only mainland-China IPs can now reach the protected ports."
else
  log "installed without running. Start it with:  allowcn"
fi

log "logs: $LOG   |   uninstall: sudo ./uninstall.sh"
