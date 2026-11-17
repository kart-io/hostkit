# shellcheck shell=bash
# Nginx 反代（80/443），以及观测后端的 Basic Auth 入口和应用的公开入口

COMPONENTS+=("nginx nginx http 80 /healthz")
# 观测入口（/vm/ /vl/ /vmalert/ /am/）的 Basic Auth 账号
CREDENTIALS+=("nginx OBS_AUTH_USER     user admin")
CREDENTIALS+=("nginx OBS_AUTH_PASSWORD password")

nginx_install()   { comp_install nginx; }
nginx_uninstall() { comp_undo nginx; }
nginx_purge()     { comp_purge nginx; }

nginx_dir() { echo "$DEPLOY_DIR/nginx"; }

nginx_env() {
  echo "IMAGE=$NGINX_IMAGE"
  echo "CERTBOT_IMAGE=$CERTBOT_IMAGE"
}

# 有证书且未卸载 tls 时用 TLS 版，否则 HTTP 版；内容变化返回 0
render_nginx_conf() {
  local tpl=default-http.conf
  tls_on && tpl=default-tls.conf
  sed -e "s|__SERVER_NAMES__|${DOMAINS:-_}|g" -e "s|__CERT_NAME__|$(cert_name)|g" \
    "$BASE_DIR/templates/nginx/$tpl" | write_if_changed "$(nginx_dir)/conf.d/default.conf"
}

nginx_prepare() {
  install -d -m 0755 "$(nginx_dir)"/{conf.d,locations,auth} "$(nginx_dir)"/certbot/{conf,www,logs}
  render_nginx_conf
}

nginx_reload() {
  ccompose nginx exec -T nginx nginx -t -q || die "nginx 配置校验失败"
  ccompose nginx exec -T nginx nginx -s reload 2>/dev/null
  sleep 1  # reload 异步，旧 worker 退出前仍按旧配置响应
}

# 账号密码只生成一次；明文放在不挂进容器的文件里
ensure_obs_auth() {
  local f user pw u h
  f=$(nginx_dir)/auth/htpasswd
  cred_prepare nginx
  user=$(cred_get OBS_AUTH_USER); pw=$(cred_get OBS_AUTH_PASSWORD)
  # 哈希带随机盐，用原盐重算比对，账号没变就不重写，避免每次都 reload
  if [[ -s $f ]]; then
    IFS=: read -r u h <"$f"
    [[ $u == "$user" && $(openssl passwd -apr1 -salt "$(cut -d'$' -f3 <<<"$h")" "$pw") == "$h" ]] && return 1
  fi
  install -d -m 0755 "$(dirname "$f")"
  printf '%s:%s\n' "$user" "$(openssl passwd -apr1 "$pw")" | write_if_changed "$f" 0644
  log "观测入口账号已更新，见 $(cred_file) 的 OBS_AUTH_USER/OBS_AUTH_PASSWORD"
}

# 观测入口的独立域名：根路径跳到入口路径，location 复用 locations/ 下生成的同名文件。
# 证书含该域名时只开 443（80 由默认 server 跳转 HTTPS），否则开 80 并保留 ACME 校验路径，供 make tls 签发
obs_domain_server() {
  local dom=$1 path=$2 loc=$3
  echo "$GEN_HEADER"
  echo "server {"
  if tls_on && cert_covers "$dom"; then
    cat <<EOF
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $dom;
    ssl_certificate     /etc/letsencrypt/live/$(cert_name)/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$(cert_name)/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=63072000" always;
EOF
  else
    cat <<EOF
    listen 80;
    listen [::]:80;
    server_name $dom;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
EOF
  fi
  cat <<EOF
    location = / {
        return 302 $path;
    }
    include /etc/nginx/locations/$loc;
}
EOF
}

# 有变化返回 0。观测入口带 Basic Auth、文件名 obs-<路径>，公开入口文件名 web-<路径>；
# 观测入口配了独立域名时另生成 conf.d/obs-<路径>.conf。
# 不再需要的生成文件（看文件头，含旧命名）删除，业务文件不动
render_locations() {
  local d line mode n path upstream dvar dom name f auth changed=1 nauth=0 want=()
  d=$(nginx_dir)
  for line in "${OBS_ROUTES[@]/#/obs }" "${WEB_ROUTES[@]/#/web }"; do
    read -r mode n path upstream dvar <<<"$line"
    comp_installed "$n" || continue
    name=${path//\//}
    name=$mode-${name:-root}.conf
    f=$d/locations/$name
    want+=("$f")
    auth=""
    if [[ $mode == obs ]]; then
      ensure_obs_auth && changed=0
      auth=$'\n    auth_basic "'$n$'";\n    auth_basic_user_file /etc/nginx/auth/htpasswd;'
      ((++nauth))
    fi
    # 用变量 + Docker DNS 运行时解析，后端没起时 nginx 也能正常加载
    write_if_changed "$f" <<EOF && changed=0
$GEN_HEADER
location $path {$auth
    resolver 127.0.0.11 valid=10s;
    set \$upstream http://$upstream;
    proxy_pass \$upstream;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF
    dom=${dvar:+${!dvar:-}}
    if [[ -n $dom ]]; then
      if [[ " $DOMAINS " == *" $dom "* ]]; then
        warn "$dvar=$dom 与 DOMAINS 重复，忽略（主域名已可用 $path 访问）"
      else
        want+=("$d/conf.d/$name")
        if obs_domain_server "$dom" "$path" "$name" | write_if_changed "$d/conf.d/$name"; then
          changed=0
          tls_on && ! cert_covers "$dom" && warn "$dom 不在证书里，暂时只能 HTTP 访问；执行 make tls 加入证书"
        fi
      fi
    fi
  done
  for f in "$d"/locations/*.conf "$d"/conf.d/obs-*.conf; do
    [[ -e $f && " ${want[*]} " != *" $f "* && $(head -1 "$f") == "$GEN_HEADER" ]] || continue
    rm -f "$f"; changed=0
    log "已移除 Nginx 入口 $(basename "$f")"
  done
  if ((changed == 0 && nauth)) && ! tls_on; then
    warn "未启用 TLS，观测入口的 Basic Auth 密码以明文传输，建议配置 DOMAINS 后执行 make tls"
  fi
  return $changed
}

nginx_purge_hint() { echo "$DEPLOY_DIR/nginx（配置、证书）及观测入口账号"; }

nginx_sync() {
  if render_locations && comp_running nginx; then
    nginx_reload
    log "Nginx 观测入口已更新"
  fi
  return 0
}

# 证书能重新签发；备份是为了重建时不撞 Let's Encrypt 频率限制
nginx_backup() {
  [[ -d $(nginx_dir)/certbot/conf/live ]] || return 0
  tar -C "$(nginx_dir)/certbot" -czf "$1/nginx.tar.gz" conf
}

# 目录是 bind mount，先停容器再换，否则容器仍指向改名后的旧目录
nginx_restore() {
  local d; d=$(nginx_dir)/certbot
  ccompose nginx down
  if [[ -d $d/conf ]]; then mv "$d/conf" "$d/conf.before-restore-$(date +%Y%m%d-%H%M%S)"; fi
  tar -C "$d" -xzf "$1"
  comp_install nginx
}
