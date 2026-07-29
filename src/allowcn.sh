#!/usr/bin/env bash
#
# AllowCN — refresh the China-mainland allow list and apply firewall rules.
#
# Modes:
#   (default)       download mmdb -> extract CN CIDRs -> load ipset -> apply iptables
#   --no-download   skip download, re-extract from the cached mmdb, then load & apply
#   --reload-only   skip download & extract, just reload cached CIDRs & apply (fast; @reboot)
#
set -euo pipefail

CONF="${ALLOWCN_CONF:-/etc/allowcn/allowcn.conf}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/allowcn"

# ---- defaults (overridable via the config file) ----------------------------
MMDB_URL="https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb"
MMDB_URL_FALLBACK="https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-Country.mmdb"
ALWAYS_OPEN_TCP_PORTS="22"   # 无条件对所有来源放行的 TCP 端口(默认放行 SSH,防锁死)
BLOCK_ACTION="DROP"          # DROP or REJECT
ENABLE_IPV6="1"
ALLOW_EXTRA=""               # space-separated extra allow CIDRs (e.g. your admin IP)
MIN_CN_V4="1000"             # sanity floor; abort if fewer CN IPv4 nets than this

SET4="allowcn4"
SET6="allowcn6"
CHAIN="ALLOWCN"

# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

MODE="download"
case "${1:-}" in
  --no-download) MODE="no-download" ;;
  --reload-only) MODE="reload-only" ;;
  "" ) ;;
  * ) echo "unknown argument: $1" >&2; exit 2 ;;
esac

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v ipset    >/dev/null 2>&1 || die "ipset not found"
command -v iptables >/dev/null 2>&1 || die "iptables not found"

MMDB="$STATE_DIR/GeoLite2-Country.mmdb"
V4FILE="$STATE_DIR/cn_ipv4.txt"
V6FILE="$STATE_DIR/cn_ipv6.txt"
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
download_mmdb() {
  local tmp
  tmp="$(mktemp "$STATE_DIR/.mmdb.XXXXXX")"
  local ok=0 url
  for url in "$MMDB_URL" "$MMDB_URL_FALLBACK"; do
    log "downloading mmdb from $url"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp" "$url" && ok=1 && break
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$tmp" "$url" && ok=1 && break
    else
      rm -f "$tmp"; die "neither curl nor wget is available"
    fi
  done
  if [ "$ok" -ne 1 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    if [ -f "$MMDB" ]; then
      log "download failed; keeping existing mmdb"
      return 0
    fi
    die "download failed and no cached mmdb exists"
  fi
  # a valid GeoLite2-Country.mmdb is a few MB; reject an obvious error page
  if [ "$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp")" -lt 100000 ]; then
    rm -f "$tmp"
    [ -f "$MMDB" ] && { log "downloaded file too small; keeping existing mmdb"; return 0; }
    die "downloaded file is too small to be a valid mmdb"
  fi
  mv -f "$tmp" "$MMDB"
  log "mmdb updated ($(stat -c%s "$MMDB" 2>/dev/null || stat -f%z "$MMDB") bytes)"
}

extract_cidr() {
  [ -f "$MMDB" ] || die "no mmdb present to extract from"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  local t4 t6
  t4="$(mktemp)"; t6="$(mktemp)"
  python3 "$LIB_DIR/mmdb_to_cidr.py" "$MMDB" "$t4" "$t6" \
    || { rm -f "$t4" "$t6"; die "CIDR extraction failed"; }
  local n4
  n4="$(wc -l < "$t4" | tr -d ' ')"
  if [ "$n4" -lt "$MIN_CN_V4" ]; then
    rm -f "$t4" "$t6"
    die "only $n4 CN IPv4 networks (< MIN_CN_V4=$MIN_CN_V4); refusing to apply"
  fi
  mv -f "$t4" "$V4FILE"; mv -f "$t6" "$V6FILE"
  log "CIDR lists refreshed: $n4 IPv4, $(wc -l < "$V6FILE" | tr -d ' ') IPv6"
}

# Build an atomic ipset restore stream: fill a temp set, then swap it in.
load_set() {
  local set="$1" fam="$2" file="$3"; shift 3
  local extras=("$@")
  [ -f "$file" ] || die "CIDR file missing: $file (run a full update first)"
  {
    echo "create ${set}_tmp hash:net family ${fam} hashsize 4096 maxelem 262144 -exist"
    echo "flush ${set}_tmp"
    local c
    while IFS= read -r c; do
      [ -n "$c" ] && echo "add ${set}_tmp $c -exist"
    done < "$file"
    if [ "${#extras[@]}" -gt 0 ]; then
      for c in "${extras[@]}"; do
        [ -n "$c" ] && echo "add ${set}_tmp $c -exist"
      done
    fi
    echo "create ${set} hash:net family ${fam} hashsize 4096 maxelem 262144 -exist"
    echo "swap ${set}_tmp ${set}"
    echo "destroy ${set}_tmp"
  } | ipset restore
  log "ipset $set loaded ($(ipset list "$set" | grep -c '^[0-9a-fA-F]') entries)"
}

# family-filtered extras: v4 = no colon, v6 = has colon
extras_for() {
  local want="$1" e
  for e in $ALLOW_EXTRA; do
    case "$e" in
      *:*) [ "$want" = "6" ] && echo "$e" ;;
      *)   [ "$want" = "4" ] && echo "$e" ;;
    esac
  done
}

del_hooks() {
  local ipt="$1" rule
  while $ipt -S INPUT 2>/dev/null | grep -q -- "-j $CHAIN"; do
    rule="$($ipt -S INPUT | grep -m1 -- "-j $CHAIN" | sed 's/^-A /-D /')"
    # shellcheck disable=SC2086
    $ipt $rule 2>/dev/null || break
  done
}

apply_rules() {
  local ipt="$1" set="$2"
  # (re)build the decision chain
  $ipt -N "$CHAIN" 2>/dev/null || $ipt -F "$CHAIN"
  $ipt -A "$CHAIN" -i lo -j ACCEPT
  $ipt -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # unconditionally open ports (any source, exempt from geo filter), e.g. SSH
  if [ -n "${ALWAYS_OPEN_TCP_PORTS:-}" ]; then
    $ipt -A "$CHAIN" -p tcp -m multiport --dports "$ALWAYS_OPEN_TCP_PORTS" -j ACCEPT
  fi
  $ipt -A "$CHAIN" -m set --match-set "$set" src -j ACCEPT
  $ipt -A "$CHAIN" -j "$BLOCK_ACTION"

  # catch-all: every inbound packet on every port/protocol goes through ALLOWCN
  del_hooks "$ipt"
  $ipt -I INPUT -j "$CHAIN"
  log "$ipt rules applied (all ports mainland-only, always-open tcp=[${ALWAYS_OPEN_TCP_PORTS:-none}], block=$BLOCK_ACTION)"
}

# ---------------------------------------------------------------------------
log "AllowCN run start (mode=$MODE)"

case "$MODE" in
  download)    download_mmdb; extract_cidr ;;
  no-download) extract_cidr ;;
  reload-only) : ;;
esac

# shellcheck disable=SC2046
load_set "$SET4" inet "$V4FILE" $(extras_for 4)
apply_rules iptables "$SET4"

if [ "$ENABLE_IPV6" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  load_set "$SET6" inet6 "$V6FILE" $(extras_for 6)
  apply_rules ip6tables "$SET6"
else
  log "IPv6 enforcement disabled or ip6tables missing; skipping"
fi

log "AllowCN run complete"
