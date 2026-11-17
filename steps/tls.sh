# shellcheck shell=bash
# Let's Encrypt（webroot）签发、切换 HTTPS、systemd timer 自动续期

cert_name() { echo "${DOMAINS%% *}"; }

cert_ready() { [[ -n $DOMAINS && -s $(nginx_dir)/certbot/conf/live/$(cert_name)/fullchain.pem ]]; }

tls_on() { cert_ready && ! state_has tls-disabled; }

# 证书域名：DOMAINS 加上观测入口配置的独立域名
tls_domains() {
  local line dvar out=$DOMAINS
  for line in "${OBS_ROUTES[@]}"; do
    read -r _ _ _ dvar <<<"$line"
    [[ -n ${!dvar:-} && " $out " != *" ${!dvar} "* ]] && out+=" ${!dvar}"
  done
  echo "$out"
}

cert_covers() {
  openssl x509 -noout -ext subjectAltName -in "$(nginx_dir)/certbot/conf/live/$(cert_name)/fullchain.pem" 2>/dev/null |
    tr ',' '\n' | tr -d ' ' | grep -qx "DNS:$1"
}

# 每个域名都必须解析到本机公网 IP，否则 HTTP-01 必失败，白白消耗 LE 限额
check_dns() {
  local ip dom resolved bad=0
  ip=$(detect_public_ip) || { warn "无法获取本机公网 IP，跳过 DNS 校验"; return 0; }
  for dom in $(tls_domains); do
    resolved=$(getent ahostsv4 "$dom" | awk '{print $1}' | sort -u | xargs)
    if [[ " $resolved " != *" $ip "* ]]; then
      warn "$dom 解析为 [${resolved:-无}]，不是本机公网 IP $ip"
      bad=1
    fi
  done
  return $bad
}

# 证书目录若被整个删除重建过，运行中的容器仍挂着已删的旧目录，看不到新证书，需重建容器重新挂载
nginx_remount_certs() {
  ccompose nginx exec -T nginx test -s "/etc/letsencrypt/live/$(cert_name)/fullchain.pem" </dev/null && return 0
  warn "Nginx 容器内看不到证书，重建容器以重新挂载证书目录"
  ccompose nginx up -d --force-recreate nginx
  comp_wait nginx
}

tls_install() {
  [[ -n $DOMAINS ]] || { log "未配置 DOMAINS，跳过 TLS"; return 0; }
  comp_running nginx || die "Nginx 未运行，先执行 make nginx"
  if [[ $TLS_SKIP_DNS_CHECK != 1 ]] && ! check_dns; then
    warn "DNS 未就绪，跳过签发。若前面有 CDN/负载均衡，设 TLS_SKIP_DNS_CHECK=1"
    return 0
  fi

  local args=(certonly --webroot -w /var/www/certbot --cert-name "$(cert_name)"
              --non-interactive --agree-tos --keep-until-expiring --expand) dom
  for dom in $(tls_domains); do args+=(-d "$dom"); done
  if [[ -n $LE_EMAIL ]]; then args+=(--email "$LE_EMAIL"); else args+=(--register-unsafely-without-email); fi
  [[ $LE_STAGING == 1 ]] && args+=(--staging)

  state_del tls-disabled
  log "申请/检查证书: $(tls_domains)"
  ccompose nginx run --rm --quiet-pull certbot "${args[@]}" || die "证书签发失败，日志见 $(nginx_dir)/certbot/logs/letsencrypt.log"
  nginx_remount_certs

  if render_nginx_conf; then
    nginx_reload
    log "已启用 HTTPS"
  fi
  local insecure=() i
  [[ $LE_STAGING == 1 ]] && insecure=(-k)  # staging 证书不受信任
  for i in 1 2 3; do
    if curl -fsS --max-time 5 -o /dev/null "${insecure[@]}" --resolve "$(cert_name):443:127.0.0.1" "https://$(cert_name)/healthz"; then
      log "HTTPS 自检通过"; break
    fi
    ((i == 3)) && warn "HTTPS 自检失败"
    sleep 1
  done

  write_if_changed /etc/systemd/system/"$PROJECT"-certrenew.service <<EOF || true
[Unit]
Description=Renew Let's Encrypt certificates ($PROJECT)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=$(nginx_dir)
ExecStart=/usr/bin/docker compose run --rm certbot renew --quiet
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
}

tls_uninstall() {
  systemctl disable --now "$PROJECT"-certrenew.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/"$PROJECT"-certrenew.{service,timer}
  systemctl daemon-reload
  state_set tls-disabled
  if comp_running nginx && render_nginx_conf; then
    nginx_reload
    log "Nginx 已切回 HTTP"
  fi
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
