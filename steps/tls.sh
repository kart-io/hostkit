# shellcheck shell=bash
# Let's Encrypt（webroot）签发、切换 HTTPS、systemd timer 自动续期

# DOMAINS 里每个域名单独一张证书（证书名即域名），互不牵连；域名指向哪个服务由 SITES 决定
cert_dir() { echo "$(nginx_dir)/certbot/conf/live/$1"; }

# 从 DOMAINS 去掉的域名，即使证书还在也不再使用
cert_has() { [[ " $DOMAINS " == *" $1 "* && -s $(cert_dir "$1")/fullchain.pem ]]; }

certs() { local dom; for dom in $DOMAINS; do cert_has "$dom" && echo "$dom"; done; }

tls_on() { ! state_has tls-disabled && [[ -n $(certs) ]]; }

site_tls() { tls_on && cert_has "$1"; }

# 域名必须解析到本机公网 IP，否则 HTTP-01 必失败，白白消耗 LE 限额
dns_ok() {
  local dom=$1 ip=$2 resolved
  [[ -z $ip ]] && return 0
  resolved=$(getent ahostsv4 "$dom" | awk '{print $1}' | sort -u | xargs)
  [[ " $resolved " == *" $ip "* ]] && return 0
  warn "$dom 解析为 [${resolved:-无}]，不是本机公网 IP $ip，跳过签发。若前面有 CDN/负载均衡，设 TLS_SKIP_DNS_CHECK=1"
  return 1
}

# 证书目录若被整个删除重建过，运行中的容器仍挂着已删的旧目录，看不到新证书，需重建容器重新挂载
nginx_remount_certs() {
  ccompose nginx exec -T nginx test -s "/etc/letsencrypt/live/$1/fullchain.pem" </dev/null && return 0
  warn "Nginx 容器内看不到证书，重建容器以重新挂载证书目录"
  ccompose nginx up -d --force-recreate nginx
  comp_wait nginx
}

# 逐个域名签发，一个失败不影响其他域名
tls_install() {
  local dom ip="" args ok=() failed=() insecure=() i
  sites_check
  [[ -n $DOMAINS ]] || { log "未配置 DOMAINS，跳过 TLS"; return 0; }
  comp_running nginx || die "Nginx 未运行，先执行 make nginx"
  if [[ $TLS_SKIP_DNS_CHECK != 1 ]]; then
    ip=$(detect_public_ip) || warn "无法获取本机公网 IP，跳过 DNS 校验"
  fi
  for dom in $DOMAINS; do
    site_bound "$dom" || warn "$dom 在 DOMAINS 里但 SITES 没绑定，签了证书也没有站点使用"
    dns_ok "$dom" "$ip" || { failed+=("$dom"); continue; }
    args=(certonly --webroot -w /var/www/certbot --cert-name "$dom" -d "$dom"
                --non-interactive --agree-tos --keep-until-expiring)
    if [[ -n $LE_EMAIL ]]; then args+=(--email "$LE_EMAIL"); else args+=(--register-unsafely-without-email); fi
    [[ $LE_STAGING == 1 ]] && args+=(--staging)
    log "申请/检查证书: $dom"
    if ccompose nginx run --rm --quiet-pull certbot "${args[@]}"; then ok+=("$dom"); else failed+=("$dom"); fi
  done

  if ((${#ok[@]})); then
    state_del tls-disabled
    nginx_remount_certs "${ok[0]}"
    nginx_sync
    [[ $LE_STAGING == 1 ]] && insecure=(-k)  # staging 证书不受信任
    for dom in "${ok[@]}"; do
      site_bound "$dom" || continue
      for i in 1 2 3; do
        curl -fsS --max-time 5 -o /dev/null "${insecure[@]}" --resolve "$dom:443:127.0.0.1" "https://$dom/healthz" && break
        ((i == 3)) && warn "$dom HTTPS 自检失败"
        sleep 1
      done
    done
    log "已启用 HTTPS: ${ok[*]}"
  fi

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
  sync_integrations  # 证书到期监控与告警
  ((${#failed[@]} == 0)) || die "以下域名未签发: ${failed[*]}；日志见 $(nginx_dir)/certbot/logs/letsencrypt.log"
}

tls_uninstall() {
  systemctl disable --now "$PROJECT"-certrenew.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/"$PROJECT"-certrenew.{service,timer}
  systemctl daemon-reload
  state_set tls-disabled
  comp_running nginx && nginx_sync && log "Nginx 已切回 HTTP"
  log "已停用证书自动续期（证书保留）"
  sync_integrations
}

tls_purge() {
  local d; d=$(nginx_dir)/certbot/conf
  # 是运行中 nginx 的 bind mount，删目录后容器仍指向已删的旧目录，重签的证书它看不到；只清空内容
  if [[ -d $d ]]; then
    find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    log "已清空 $d"
  fi
  safe_rm_dir "$(nginx_dir)/certbot/logs"
  state_del tls-disabled
}

tls_purge_hint() { echo "已签发的证书与 Let's Encrypt 账号"; }
