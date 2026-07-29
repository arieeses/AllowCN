#!/usr/bin/env bash
#
# AllowCN uninstaller — removes firewall rules, ipsets, cron, and installed files.
#   sudo ./uninstall.sh            # remove everything but keep /var/lib/allowcn data
#   sudo ./uninstall.sh --purge    # also delete cached mmdb/CIDR data and the log
#
set -euo pipefail

LIB_DIR="/usr/local/lib/allowcn"
CONF_DIR="/etc/allowcn"
CRON="/etc/cron.d/allowcn"
LOG="/var/log/allowcn.log"
CHAIN="ALLOWCN"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { echo -e "\033[1;32m[AllowCN]\033[0m $*"; }
[ "$(id -u)" -eq 0 ] || { echo "please run as root" >&2; exit 1; }

remove_fw() {
  local ipt="$1"
  command -v "$ipt" >/dev/null 2>&1 || return 0
  # detach from INPUT
  while $ipt -S INPUT 2>/dev/null | grep -q -- "-j $CHAIN"; do
    rule="$($ipt -S INPUT | grep -m1 -- "-j $CHAIN" | sed 's/^-A /-D /')"
    # shellcheck disable=SC2086
    $ipt $rule 2>/dev/null || break
  done
  $ipt -F "$CHAIN" 2>/dev/null || true
  $ipt -X "$CHAIN" 2>/dev/null || true
}

log "removing firewall hooks and chain"
remove_fw iptables
remove_fw ip6tables

log "destroying ipsets"
for s in allowcn4 allowcn6 allowcn4_tmp allowcn6_tmp; do
  ipset destroy "$s" 2>/dev/null || true
done

log "removing cron, binaries and symlink"
rm -f "$CRON" /usr/local/sbin/allowcn
rm -rf "$LIB_DIR"

if [ "$PURGE" -eq 1 ]; then
  log "purging config, data and log"
  rm -rf "$CONF_DIR" /var/lib/allowcn "$LOG"
else
  log "keeping $CONF_DIR and /var/lib/allowcn (use --purge to remove them)"
fi

log "AllowCN uninstalled."
