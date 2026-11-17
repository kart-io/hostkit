# shellcheck shell=bash
# UFW：默认拒绝入站，放行 SSH/80/443/EXTRA_TCP_PORTS

ufw_install() {
  apt_install ufw
  local p ports
  ports=$( { required_tcp_ports; current_ssh_ports; } | awk '!seen[$0]++')
  state_has ufw-was-active || state_set ufw-was-active "$(ufw status | grep -q '^Status: active' && echo yes || echo no)"
  state_set ufw-ports "$( { state_get ufw-ports; echo "$ports"; } | awk 'NF && !seen[$0]++')"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in $ports; do ufw allow "$p/tcp" >/dev/null; done
  ufw --force enable >/dev/null
  log "UFW 已启用，放行 TCP: $(echo "$ports" | paste -sd ' ')"
  warn "Docker 发布的端口（-p）会绕过 UFW，只发布确实需要对外的端口"
}

ufw_uninstall() {
  command -v ufw &>/dev/null || return 0
  local p was ssh_ports
  was=$(state_get ufw-was-active)
  ssh_ports=" $(current_ssh_ports | xargs) "
  for p in $(state_get ufw-ports); do
    # UFW 还要保持启用时，删掉 SSH 端口规则会把自己锁在外面
    [[ $was == yes && $ssh_ports == *" $p "* ]] && { log "保留 SSH 端口 $p 的规则"; continue; }
    ufw delete allow "$p/tcp" >/dev/null 2>&1 || true
  done
  if [[ $was == no ]]; then
    ufw --force disable >/dev/null
    log "UFW 已关闭（安装前未启用）"
  else
    log "已删除本脚本添加的 UFW 规则"
  fi
  state_del ufw-ports
  state_del ufw-was-active
}
