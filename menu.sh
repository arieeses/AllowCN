#!/usr/bin/env bash
#
# AllowCN — interactive one-click menu.
#
# Run locally:   sudo ./menu.sh
# Or remotely:   bash <(curl -fsSL https://raw.githubusercontent.com/arieeses/AllowCN/main/menu.sh)
#
set -uo pipefail

REPO_URL="https://github.com/arieeses/AllowCN"
RAW_TARBALL="https://codeload.github.com/arieeses/AllowCN/tar.gz/refs/heads/main"
SRC_CACHE="/usr/local/src/AllowCN"

CONF="/etc/allowcn/allowcn.conf"
CONF_EXAMPLE_NAME="allowcn.conf.example"
CRON="/etc/cron.d/allowcn"
LOG="/var/log/allowcn.log"
LIB="/usr/local/lib/allowcn/allowcn.sh"
NETOPT="/usr/local/lib/allowcn/netopt.sh"

# ---- colors ----------------------------------------------------------------
if [ -t 1 ]; then
  R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;36m'; D='\033[2m'; N='\033[0m'
else
  R=''; G=''; Y=''; B=''; D=''; N=''
fi
info()  { echo -e "${G}[AllowCN]${N} $*"; }
warn()  { echo -e "${Y}[AllowCN]${N} $*"; }
err()   { echo -e "${R}[AllowCN]${N} $*" >&2; }
pause() { echo; read -rp "按回车返回菜单..." _; }

[ "$(id -u)" -eq 0 ] || { err "请用 root 运行:sudo $0"; exit 1; }

# ---- locate project files (local checkout, or fetch to cache) --------------
locate_repo() {
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -n "$self" ] && [ -f "$self/src/allowcn.sh" ]; then
    REPO="$self"; return
  fi
  info "获取 AllowCN 源码到 $SRC_CACHE ..."
  if command -v git >/dev/null 2>&1; then
    if [ -d "$SRC_CACHE/.git" ]; then
      git -C "$SRC_CACHE" pull -q || warn "更新源码失败,使用现有缓存"
    else
      rm -rf "$SRC_CACHE"
      git clone -q "$REPO_URL" "$SRC_CACHE" || { err "git clone 失败"; exit 1; }
    fi
  else
    # no git — fall back to tarball
    command -v curl >/dev/null 2>&1 || { err "需要 git 或 curl 之一"; exit 1; }
    mkdir -p "$SRC_CACHE"
    curl -fsSL "$RAW_TARBALL" | tar -xz -C "$SRC_CACHE" --strip-components=1 \
      || { err "下载源码失败"; exit 1; }
  fi
  REPO="$SRC_CACHE"
  [ -f "$REPO/src/allowcn.sh" ] || { err "源码不完整:$REPO"; exit 1; }
}

is_installed() { [ -f "$LIB" ]; }

# ---- config helpers --------------------------------------------------------
get_conf() { # key -> value (strip quotes); reads $CONF
  [ -f "$CONF" ] || { echo ""; return; }
  local v; v="$(grep -E "^$1=" "$CONF" | tail -1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; echo "$v"
}
set_conf() { # key value file
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$file"
  else
    echo "${key}=\"${val}\"" >> "$file"
  fi
}

detect_ssh_ip() { [ -n "${SSH_CONNECTION:-}" ] && echo "${SSH_CONNECTION%% *}"; }

# Robustly find the TCP port(s) sshd actually listens on — independent of the
# environment (works under sudo and on non-SSH consoles). Returns a comma list.
detect_ssh_ports() {
  local ports="" sshd_bin
  sshd_bin="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
  [ -x "$sshd_bin" ] && ports="$("$sshd_bin" -T 2>/dev/null | awk '/^port /{print $2}')"
  [ -z "$ports" ] && [ -r /etc/ssh/sshd_config ] && \
    ports="$(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config)"
  [ -z "$ports" ] && command -v ss >/dev/null 2>&1 && \
    ports="$(ss -H -tlnp 2>/dev/null | awk '/"sshd"/{print $4}' | sed 's/.*://')"
  [ -n "${SSH_CONNECTION:-}" ] && ports="$ports $(echo "$SSH_CONNECTION" | awk '{print $4}')"
  ports="$(printf '%s\n' $ports | grep -E '^[0-9]+$' | sort -un | paste -sd, -)"
  echo "${ports:-22}"
}

# ---------------------------------------------------------------------------
do_install() {
  echo -e "${B}== 安装 / 重装 AllowCN ==${N}"
  echo -e "${D}规则:整机所有端口仅大陆可访问,SSH 端口对所有来源开放(防锁死)。${N}"
  local extra sched="30 4 * * *" ssh_ip ssh_port ans

  # 自动探测 sshd 实际监听端口(问 sshd 本身,不依赖环境变量)
  ssh_port="$(detect_ssh_ports)"
  info "检测到 SSH 监听端口:${ssh_port}"
  read -rp "确认对所有来源放行的 SSH 端口(防锁死)[${ssh_port}]: " ans
  [ -n "$ans" ] && ssh_port="$ans"

  # 可选:把当前 SSH 来源 IP 也加进永久白名单(双保险)
  ssh_ip="$(detect_ssh_ip)"
  extra=""
  if [ -n "$ssh_ip" ]; then
    read -rp "把当前来源 IP ${ssh_ip} 也加入永久白名单? [Y/n]: " ans
    case "${ans:-Y}" in [Nn]*) : ;; *) extra="$ssh_ip" ;; esac
  fi
  read -rp "额外永久放行的网段(空格分隔,可留空)[$extra]: " ans
  [ -n "$ans" ] && extra="$ans"

  read -rp "自动更新周期(cron 表达式)[默认每天 04:30 → ${sched}]: " ans
  [ -n "$ans" ] && sched="$ans"

  echo
  warn "确认:整机仅大陆 + SSH端口=${ssh_port}对所有来源  白名单=[${extra:-无}]  周期=[${sched}]"
  read -rp "开始安装? [Y/n]: " ans
  case "${ans:-Y}" in [Nn]*) warn "已取消"; return ;; esac

  bash "$REPO/install.sh" --schedule "$sched" --no-run || { err "安装失败"; return; }
  set_conf ALWAYS_OPEN_TCP_PORTS "$ssh_port" "$CONF"
  set_conf ALLOW_EXTRA "$extra" "$CONF"
  info "应用规则中..."
  "$LIB" 2>&1 | tee -a "$LOG"
  info "完成。整机所有端口仅大陆可访问,SSH(端口 ${ssh_port})对所有来源开放。"
}

do_update() {
  is_installed || { warn "尚未安装,请先选 1"; return; }
  echo -e "${B}== 立即更新 IP 数据并应用 ==${N}"
  "$LIB" 2>&1 | tee -a "$LOG"
}

do_edit_conf() {
  is_installed || { warn "尚未安装,请先选 1"; return; }
  echo -e "${B}== 修改配置 ==${N}"
  echo "  1) 引导式快速设置(端口 / 白名单 / 拦截动作 / IPv6)"
  echo "  2) 直接用编辑器打开 $CONF"
  read -rp "选择 [1]: " c
  case "${c:-1}" in
    2)
      "${EDITOR:-$(command -v nano || command -v vi)}" "$CONF"
      ;;
    *)
      local openp action ipv6 extra ans
      read -rp "SSH/无条件放行的 TCP 端口(对所有来源) [$(get_conf ALWAYS_OPEN_TCP_PORTS)]: " openp
      read -rp "拦截动作 DROP/REJECT [$(get_conf BLOCK_ACTION)]: " action
      read -rp "启用 IPv6 1/0 [$(get_conf ENABLE_IPV6)]: " ipv6
      read -rp "永久白名单网段 [$(get_conf ALLOW_EXTRA)]: " extra
      [ -n "$openp" ]  && set_conf ALWAYS_OPEN_TCP_PORTS "$openp" "$CONF"
      [ -n "$action" ] && set_conf BLOCK_ACTION "$action" "$CONF"
      [ -n "$ipv6" ]   && set_conf ENABLE_IPV6 "$ipv6" "$CONF"
      [ -n "$extra" ]  && set_conf ALLOW_EXTRA "$extra" "$CONF"
      ;;
  esac
  read -rp "立即应用新配置? [Y/n]: " ans
  case "${ans:-Y}" in [Nn]*) warn "已保存,未应用(下次定时更新生效)" ;; *) "$LIB" --reload-only 2>&1 | tee -a "$LOG" ;; esac
}

do_schedule() {
  is_installed || { warn "尚未安装,请先选 1"; return; }
  echo -e "${B}== 更改自动更新周期 ==${N}"
  echo "当前:"; grep -vE '^\s*(#|SHELL|PATH|$)' "$CRON" 2>/dev/null || echo "  (无)"
  read -rp "新的 cron 表达式(如 '0 3 * * *'): " sched
  [ -z "$sched" ] && { warn "未修改"; return; }
  sed -i "s|^[^@#].* root ${LIB} >>|${sched}  root ${LIB} >>|" "$CRON" \
    || { err "修改失败"; return; }
  info "已更新周期为:$sched"
}

do_status() {
  echo -e "${B}== AllowCN 运行状态 ==${N}"
  if is_installed; then info "已安装:$LIB"; else warn "未安装"; fi
  echo -e "${D}--- 配置 ---${N}"
  [ -f "$CONF" ] && grep -vE '^\s*(#|$)' "$CONF" || echo "  (无配置)"
  echo -e "${D}--- ipset 集合 ---${N}"
  for s in allowcn4 allowcn6; do
    if ipset list "$s" >/dev/null 2>&1; then
      echo "  $s: $(ipset list "$s" | awk -F': ' '/Number of entries/{print $2}') 条网段"
    else
      echo "  $s: 未加载"
    fi
  done
  echo -e "${D}--- iptables 判定链 ---${N}"
  iptables -L ALLOWCN -n 2>/dev/null || echo "  (未应用)"
  echo -e "${D}--- INPUT 挂载点 ---${N}"
  iptables -S INPUT 2>/dev/null | grep -- '-j ALLOWCN' || echo "  (无)"
  echo -e "${D}--- cron ---${N}"
  [ -f "$CRON" ] && grep -vE '^\s*(#|SHELL|PATH|$)' "$CRON" || echo "  (无)"
  echo -e "${D}--- 最近日志 ---${N}"
  [ -f "$LOG" ] && tail -n 8 "$LOG" || echo "  (无日志)"
}

do_disable() {
  is_installed || { warn "尚未安装"; return; }
  echo -e "${B}== 暂停规则(保留安装)==${N}"
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    while $ipt -S INPUT 2>/dev/null | grep -q -- '-j ALLOWCN'; do
      rule="$($ipt -S INPUT | grep -m1 -- '-j ALLOWCN' | sed 's/^-A /-D /')"
      # shellcheck disable=SC2086
      $ipt $rule 2>/dev/null || break
    done
    $ipt -F ALLOWCN 2>/dev/null || true
    $ipt -X ALLOWCN 2>/dev/null || true
  done
  warn "已移除防火墙规则(所有来源均可访问)。选 2 可随时重新应用。"
}

do_netopt() {
  # netopt.sh may exist without a full AllowCN install (menu also runs from checkout)
  local np="$NETOPT"
  [ -f "$np" ] || np="$REPO/src/netopt.sh"
  [ -f "$np" ] || { warn "找不到 netopt.sh"; return; }
  while true; do
    echo -e "${B}== 网络内核优化(集成 tcp-dashboard 的调优项,原生实现)==${N}"
    echo -e "${D}  BBR+FQ / 生产级 sysctl / 网卡多队列 / IPv4 优先 —— 参数均为标准内核项${N}"
    echo
    bash "$np" status 2>/dev/null
    echo
    echo -e "   ${G}1)${N} 一键开启所有优化"
    echo -e "   ${G}2)${N} 回退所有优化(恢复内核默认)"
    echo -e "   ${G}3)${N} 刷新状态"
    echo -e "   ${D}0)${N} 返回主菜单"
    echo
    read -rp "请选择 [0-3]: " c
    case "$c" in
      1) echo; bash "$np" enable-all; pause ;;
      2) echo; bash "$np" rollback;  pause ;;
      3) : ;;
      0) return ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
    clear 2>/dev/null || true
  done
}

do_uninstall() {
  echo -e "${B}== 卸载 AllowCN ==${N}"
  read -rp "同时删除缓存数据/配置/日志(--purge)? [y/N]: " ans
  case "${ans:-N}" in
    [Yy]*) bash "$REPO/uninstall.sh" --purge ;;
    *)     bash "$REPO/uninstall.sh" ;;
  esac
}

banner() {
  clear 2>/dev/null || true
  local st="${R}未安装${N}"
  is_installed && st="${G}已安装${N}"
  echo -e "${B}╔══════════════════════════════════════════════╗${N}"
  echo -e "${B}║${N}   ${G}AllowCN${N} — 仅允许中国大陆访问的防火墙        ${B}║${N}"
  echo -e "${B}║${N}   数据源: P3TERX/GeoLite.mmdb · iptables+ipset ${B}║${N}"
  echo -e "${B}╚══════════════════════════════════════════════╝${N}"
  echo -e "   状态: ${st}    配置: ${CONF}"
  echo
  echo -e "   ${G}1)${N} 安装 / 重装"
  echo -e "   ${G}2)${N} 立即更新 IP 数据并应用规则"
  echo -e "   ${G}3)${N} 修改配置(端口 / 白名单 / 拦截动作)"
  echo -e "   ${G}4)${N} 更改自动更新周期"
  echo -e "   ${G}5)${N} 查看运行状态"
  echo -e "   ${G}6)${N} 暂停规则(保留安装)"
  echo -e "   ${B}7)${N} 网络内核优化(BBR/调优/多队列,一键全开)"
  echo -e "   ${R}8)${N} 卸载"
  echo -e "   ${D}0)${N} 退出"
  echo
}

main() {
  locate_repo
  while true; do
    banner
    read -rp "请选择 [0-8]: " choice
    echo
    case "$choice" in
      1) do_install ;;
      2) do_update ;;
      3) do_edit_conf ;;
      4) do_schedule ;;
      5) do_status ;;
      6) do_disable ;;
      7) do_netopt ;;
      8) do_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
    pause
  done
}

main "$@"
