# shellcheck shell=bash
# Let's Encrypt（webroot）签发、切换 HTTPS、systemd timer 自动续期

# SITES 里每个域名单独一张证书（证书名即域名），签发、续期互不牵连
cert_dir() { echo "$(nginx_dir)/certbot/conf/live/$1"; }

# 从 SITES 去掉的域名，即使证书还在也不再使用
cert_has() { site_bound "$1" && [[ -s $(cert_dir "$1")/fullchain.pem ]]; }

certs() { local dom; for dom in $(site_domains); do cert_has "$dom" && echo "$dom"; done; }

# 执行过 make tls 且没卸载
tls_enabled() { state_has tls; }

tls_on() { tls_enabled && [[ -n $(certs) ]]; }

site_tls() { tls_enabled && cert_has "$1"; }

# 本机 / 未解析 / 指向 x.x.x.x；域名没解析到本机时 HTTP-01 必失败，白白消耗 LE 限额
dns_state() {
  local resolved
  resolved=$(getent ahostsv4 "$1" | awk '{print $1}' | sort -u | xargs)
  if [[ -z $resolved ]]; then echo 未解析
  elif [[ " $resolved " == *" $2 "* ]]; then echo 本机
  else echo "指向 $resolved"
  fi
}

# 证书目录若被整个删除重建过，运行中的容器仍挂着已删的旧目录，看不到新证书，需重建容器重新挂载
nginx_remount_certs() {
  ccompose nginx exec -T nginx test -s "/etc/letsencrypt/live/$1/fullchain.pem" </dev/null && return 0
  warn "Nginx 容器内看不到证书，重建容器以重新挂载证书目录"
  ccompose nginx up -d --force-recreate nginx
  comp_wait nginx
}

# 本次运行已尝试过的域名，sync 多次触发时不重复申请
TLS_TRIED=" "

# 给还没有证书的站点逐个签发，一个失败不影响其他；签到新证书返回 0
tls_issue_missing() {
  local dom ip="" st args missing=() issued=()
  for dom in $(site_domains); do
    cert_has "$dom" || [[ $TLS_TRIED == *" $dom "* ]] || missing+=("$dom")
  done
  ((${#missing[@]})) || return 1
  if [[ $TLS_SKIP_DNS_CHECK != 1 ]]; then
    ip=$(detect_public_ip) || warn "无法获取本机公网 IP，跳过 DNS 校验"
  fi
  for dom in "${missing[@]}"; do
    TLS_TRIED+="$dom "
    if [[ -n $ip ]] && st=$(dns_state "$dom" "$ip") && [[ $st != 本机 ]]; then
      warn "$dom DNS $st，不是本机公网 IP $ip，暂不签发、只能 HTTP 访问。到 DNS 服务商加 A 记录指向 $ip，生效后执行 make tls（前面有 CDN/负载均衡时设 TLS_SKIP_DNS_CHECK=1）"
      continue
    fi
    args=(certonly --webroot -w /var/www/certbot --cert-name "$dom" -d "$dom"
          --non-interactive --agree-tos --keep-until-expiring)
    if [[ -n $LE_EMAIL ]]; then args+=(--email "$LE_EMAIL"); else args+=(--register-unsafely-without-email); fi
    [[ $LE_STAGING == 1 ]] && args+=(--staging)
    log "申请证书: $dom"
    if ccompose nginx run --rm --quiet-pull certbot "${args[@]}"; then
      issued+=("$dom")
    else
      warn "$dom 证书签发失败，只能 HTTP 访问；日志见 $(nginx_dir)/certbot/logs/letsencrypt.log"
    fi
  done
  ((${#issued[@]})) || return 1
  nginx_remount_certs "${issued[0]}"
  log "已签发证书: ${issued[*]}"
}

tls_install() {
  local dom insecure=() missing=() i
  sites_check
  [[ -n $(sites) ]] || { log "未配置 SITES，跳过 TLS"; return 0; }
  comp_running nginx || die "Nginx 未运行，先执行 make nginx"
  state_set tls
  tls_issue_missing || true
  sync_integrations  # 站点切到 HTTPS，证书到期监控与告警
  [[ $LE_STAGING == 1 ]] && insecure=(-k)  # staging 证书不受信任
  for dom in $(certs); do
    for i in 1 2 3; do
      curl -fsS --max-time 5 -o /dev/null "${insecure[@]}" --resolve "$dom:443:127.0.0.1" "https://$dom/healthz" && break
      ((i == 3)) && warn "$dom HTTPS 自检失败"
      sleep 1
    done
  done
  [[ -z $(certs) ]] || log "已启用 HTTPS: $(certs | xargs)"

  write_if_changed /etc/systemd/system/"$PROJECT"-certrenew.service <<EOF || true
[Unit]
Description=Renew Let's Encrypt certificates ($PROJECT)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=$(nginx_dir)
# 某张证书续期失败时 certbot 返回非 0；加 - 前缀照样 reload，让续期成功的证书生效（失败的由证书到期告警兜底）
ExecStart=-/usr/bin/docker compose run --rm certbot renew --quiet
ExecStartPost=/usr/bin/docker compose exec -T nginx nginx -s reload
EOF
  write_if_changed /etc/systemd/system/"$PROJECT"-certrenew.timer <<EOF || true
[Unit]
Description=Renew Let's Encrypt certificates twice daily ($PROJECT)

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$PROJECT"-certrenew.timer >/dev/null 2>&1
  log "自动续期: $(systemctl list-timers "$PROJECT"-certrenew.timer --no-legend | awk '{print $1, $2, $3}')"
  for dom in $(site_domains); do cert_has "$dom" || missing+=("$dom"); done
  ((${#missing[@]} == 0)) || die "以下站点还没有证书，只能 HTTP 访问: ${missing[*]}（原因见上方提示，make status 可查看）"
}

tls_uninstall() {
  systemctl disable --now "$PROJECT"-certrenew.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/"$PROJECT"-certrenew.{service,timer}
  systemctl daemon-reload
  state_del tls
  sync_integrations
  log "已切回 HTTP、停用证书自动续期（证书保留）"
}

tls_purge() {
  local d; d=$(nginx_dir)/certbot/conf
  # 是运行中 nginx 的 bind mount，删目录后容器仍指向已删的旧目录，重签的证书它看不到；只清空内容
  if [[ -d $d ]]; then
    find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    log "已清空 $d"
  fi
  safe_rm_dir "$(nginx_dir)/certbot/logs"
  state_del tls
}

tls_purge_hint() { echo "已签发的证书与 Let's Encrypt 账号"; }
