# shellcheck shell=bash
# SSH 加固：sshd_config.d/00-<项目名>.conf

# Ubuntu 22.10+ 默认 socket 激活，端口由 generator 从 sshd_config 生成
ssh_apply() {
  if systemctl is-active --quiet ssh.socket; then
    systemctl daemon-reload
    systemctl restart ssh.socket
  else
    systemctl reload ssh
  fi
}

# 至少有一个可登录账号配了公钥，才关闭密码登录，避免把自己锁在外面
has_authorized_keys() {
  local u home
  for u in root ${SUDO_USER:-}; do
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -s $home/.ssh/authorized_keys ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" && return 0
  done
  return 1
}

ssh_install() {
  apt_install openssh-server
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config \
    || die "/etc/ssh/sshd_config 未 Include sshd_config.d，请手工处理"

  local pw=no conf=/etc/ssh/sshd_config.d/00-$PROJECT.conf
  has_authorized_keys || { pw=yes; warn "root ${SUDO_USER:-} 没有可用的 authorized_keys，保留密码登录"; }

  # sshd 取首次出现的值；00- 前缀保证排在 cloud-init 的 50-cloud-init.conf 之前
  if write_if_changed "$conf" <<EOF; then
Port $SSH_PORT
$( [[ $SSH_PORT != 22 && $SSH_CLOSE_OLD_PORT != 1 ]] && echo "Port 22" )
PermitRootLogin prohibit-password
PasswordAuthentication $pw
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    if ! sshd_check -t; then
      rm -f "$conf"
      die "sshd 配置校验失败，已撤销 $conf"
    fi
    ssh_apply
    log "SSH 已加固（端口: $(current_ssh_ports | paste -sd ' ')，密码登录: $pw）"
  else
    log "SSH 配置无变化"
  fi
  local eff
  eff=$(sshd_check -T | awk '$1=="passwordauthentication" {print $2}')
  [[ $eff == "$pw" ]] || warn "sshd 实际 PasswordAuthentication=$eff，被其他配置覆盖，请检查 /etc/ssh/sshd_config.d/"
  if [[ $SSH_PORT != 22 ]]; then
    if [[ $SSH_CLOSE_OLD_PORT == 1 ]]; then
      # ufw 步骤在 ssh 之前跑，那时 22 仍在监听会被放行，这里收尾
      ufw status | grep -qE '^22/tcp ' && ufw delete allow 22/tcp >/dev/null && log "已从 UFW 移除 22"
    else
      warn "仍同时监听 22；用新端口 $SSH_PORT 登录验证后，设 SSH_CLOSE_OLD_PORT=1 再跑 ssh 步骤"
    fi
  fi
  return 0
}

ssh_uninstall() {
  local conf=/etc/ssh/sshd_config.d/00-$PROJECT.conf p
  [[ -f $conf ]] || { log "SSH 配置不存在，跳过"; return 0; }
  rm -f "$conf"
  sshd_check -t || die "移除 $conf 后 sshd 配置校验失败，请手工检查"
  # 端口会回到原配置（通常是 22），重启前先确保防火墙放行
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    for p in $(current_ssh_ports); do ufw allow "$p/tcp" >/dev/null; done
  fi
  ssh_apply
  log "SSH 已恢复系统默认配置（端口: $(current_ssh_ports | xargs)）"
}
