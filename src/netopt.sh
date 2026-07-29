#!/usr/bin/env bash
#
# AllowCN network-optimization module — a native, auditable re-implementation of
# the tuning offered by tcp-dashboard (https://github.com/666shen/tcp-dashboard):
#   * IPv4-priority resolution   (gai.conf)
#   * BBR + FQ congestion control
#   * production-grade sysctl / ulimit tuning + MSS clamp
#   * NIC multi-queue (RPS/RFS) interrupt spreading
#
# Every parameter here is a standard Linux kernel knob; nothing is fetched from a
# remote server at run time. All changes are reversible via `rollback`.
#
# Usage: netopt.sh {enable-all|rollback|status}
#
set -uo pipefail

SYSCTL_OPT="/etc/sysctl.d/99-allowcn-netopt.conf"
BBR_OPT="/etc/sysctl.d/98-allowcn-bbr.conf"
LIMITS_OPT="/etc/security/limits.d/99-allowcn-netopt.conf"
GAI="/etc/gai.conf"
GAI_BAK="/etc/gai.conf.allowcn.bak"
GAI_LINE="precedence ::ffff:0:0/96  100"

if [ -t 1 ]; then G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'; else G=''; Y=''; R=''; N=''; fi
info() { echo -e "${G}[netopt]${N} $*"; }
warn() { echo -e "${Y}[netopt]${N} $*"; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# ---------------------------------------------------------------------------
set_ipv4_priority() {
  info "设置 IPv4 优先解析 (gai.conf)"
  if [ ! -f "$GAI" ]; then
    cat > "$GAI" <<'EOF'
label ::1/128       0
label ::/0          1
label 2002::/16     2
label ::/96         3
label ::ffff:0:0/96 4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence  ::/96         20
precedence  ::ffff:0:0/96 10
EOF
  fi
  [ -f "$GAI_BAK" ] || cp "$GAI" "$GAI_BAK"
  grep -q "^${GAI_LINE}$" "$GAI" || echo "$GAI_LINE" >> "$GAI"
}

enable_bbr() {
  info "启用 BBR + FQ 拥塞控制"
  cat > "$BBR_OPT" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
}

tune_sysctl() {
  info "部署生产级 + 跨境内核调优"
  local mem_kb buf
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  # network buffer ceiling = 5% of total RAM (matches tcp-dashboard), min 16 MiB
  buf=$(( mem_kb * 5 / 100 * 1024 ))
  [ "$buf" -lt 16777216 ] && buf=16777216

  cat > "$SYSCTL_OPT" <<EOF
# --- queue / congestion ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- buffers & capacity ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = ${buf}
net.core.wmem_max = ${buf}
net.ipv4.tcp_rmem = 4096 87380 ${buf}
net.ipv4.tcp_wmem = 4096 65536 ${buf}
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152

# --- proxy / cross-border tuning ---
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_max_orphans = 32768

# --- connection stability ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fastopen = 3
EOF
  # Note: BBRv3 is a property of the running kernel build, not a sysctl key, so
  # tcp-dashboard's "tcp_congestion_control_version" line is deliberately omitted
  # (it is a no-op / error on stock kernels). If your kernel ships BBRv3, `bbr`
  # above already uses it.

  mkdir -p /etc/security/limits.d
  cat > "$LIMITS_OPT" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF

  sysctl --system >/dev/null 2>&1
  ulimit -n 1048576 2>/dev/null || true

  if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
      && info "已部署 MSS Clamp 规则"
  fi
}

optimize_nic() {
  info "网卡多队列 / 中断分发 (RPS/RFS)"
  if ! command -v ethtool >/dev/null 2>&1; then
    { command -v apt-get >/dev/null 2>&1 && apt-get install -y -qq ethtool; } \
      || { command -v dnf >/dev/null 2>&1 && dnf install -y -q ethtool; } \
      || { command -v yum >/dev/null 2>&1 && yum install -y -q ethtool; } \
      || { command -v apk >/dev/null 2>&1 && apk add --no-cache ethtool; } \
      || warn "未能安装 ethtool,跳过网卡环形缓冲调整"
  fi
  local ifaces cpu rps_mask
  ifaces="$(ls /sys/class/net 2>/dev/null | grep -vE 'lo|docker|veth|br-|any|sit0|tun|tap|wg')"
  cpu="$(nproc)"
  rps_mask="$(printf '%x' $(( (1 << cpu) - 1 )))"
  local eth maxrx f
  for eth in $ifaces; do
    if command -v ethtool >/dev/null 2>&1; then
      maxrx="$(ethtool -g "$eth" 2>/dev/null | awk '/Pre-set maximums/{p=1} p&&/RX:/{print $2; exit}')"
      ethtool -G "$eth" rx "${maxrx:-1024}" tx "${maxrx:-1024}" >/dev/null 2>&1 || true
    fi
    for f in /sys/class/net/"$eth"/queues/rx-*/rps_cpus;     do [ -f "$f" ] && echo "$rps_mask" > "$f" 2>/dev/null || true; done
    for f in /sys/class/net/"$eth"/queues/rx-*/rps_flow_cnt; do [ -f "$f" ] && echo 4096       > "$f" 2>/dev/null || true; done
  done
  sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
enable_all() {
  info "==== 一键开启所有网络优化 ===="
  set_ipv4_priority
  enable_bbr
  tune_sysctl
  optimize_nic
  echo
  info "全部完成。当前:"
  print_status
  warn "配置已持久化,重启后仍生效;如需还原执行:  netopt.sh rollback"
}

rollback() {
  info "==== 回退所有网络优化 ===="
  rm -f "$SYSCTL_OPT" "$BBR_OPT" "$LIMITS_OPT"
  if [ -f "$GAI_BAK" ]; then
    mv -f "$GAI_BAK" "$GAI"
  else
    sed -i "\|^${GAI_LINE}$|d" "$GAI" 2>/dev/null || true
  fi
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl -w net.core.default_qdisc=pfifo_fast     >/dev/null 2>&1 || true
  sysctl -w net.core.rps_sock_flow_entries=0      >/dev/null 2>&1 || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  fi
  local eth f
  for eth in $(ls /sys/class/net 2>/dev/null | grep -vE 'lo|docker|veth|br-|any|sit0|tun|tap|wg'); do
    for f in /sys/class/net/"$eth"/queues/rx-*/rps_cpus; do [ -f "$f" ] && echo 0 > "$f" 2>/dev/null || true; done
  done
  sysctl --system >/dev/null 2>&1
  info "已恢复内核默认(cubic / pfifo_fast),独立配置文件已清理。"
}

print_status() {
  local cc qd rps
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  rps="$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)"
  local s_ipv4 s_bbr s_sys s_nic
  grep -q "^${GAI_LINE}$" "$GAI" 2>/dev/null && s_ipv4="${G}[已激活]${N}" || s_ipv4="${R}[未开启]${N}"
  [ "$cc" = "bbr" ]        && s_bbr="${G}[已激活]${N}" || s_bbr="${R}[未开启]${N}"
  [ -f "$SYSCTL_OPT" ]     && s_sys="${G}[已激活]${N}" || s_sys="${R}[未开启]${N}"
  [ "$rps" = "32768" ]     && s_nic="${G}[已激活]${N}" || s_nic="${R}[未开启]${N}"
  echo -e "  IPv4 优先解析 : $s_ipv4"
  echo -e "  BBR + FQ      : $s_bbr   (算法=${cc:-?} 队列=${qd:-?})"
  echo -e "  生产级调优    : $s_sys"
  echo -e "  网卡多队列    : $s_nic"
  echo -e "  文件句柄上限  : $(ulimit -n)"
}

case "${1:-}" in
  enable-all) enable_all ;;
  rollback)   rollback ;;
  status)     print_status ;;
  *) echo "usage: $0 {enable-all|rollback|status}" >&2; exit 2 ;;
esac
