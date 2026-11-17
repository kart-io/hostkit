# shellcheck shell=bash
# Nginx 反代（80/443）：主站、观测后端的 Basic Auth 入口、应用的公开入口，以及 SITES 配置的各域名站点

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

# 兜底的 default_server；内容变化返回 0
render_nginx_conf() {
  write_if_changed "$(nginx_dir)/conf.d/default.conf" <"$BASE_DIR/templates/nginx/default.conf"
}

nginx_prepare() {
  sites_check
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

# 路由文件名：观测入口 obs-<路径>，公开入口 web-<路径>，/ 记为 root
route_file() { local f=${2//\//}; echo "$1-${f:-root}.conf"; }

# 有变化返回 0。观测入口带 Basic Auth，公开入口不带；不再需要的生成文件（看文件头）删除，业务文件不动
render_locations() {
  local d line mode n path upstream f auth changed=1 nauth=0 want=()
  d=$(nginx_dir)
  for line in "${OBS_ROUTES[@]/#/obs }" "${WEB_ROUTES[@]/#/web }"; do
    read -r mode n path upstream <<<"$line"
    comp_installed "$n" || continue
    f=$d/locations/$(route_file "$mode" "$path")
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
  done
  for f in "$d"/locations/*.conf; do
    [[ -e $f && " ${want[*]} " != *" $f "* && $(head -1 "$f") == "$GEN_HEADER" ]] || continue
    rm -f "$f"; changed=0
    log "已移除 Nginx 入口 $(basename "$f")"
  done
  if ((changed == 0 && nauth)) && ! tls_on; then
    warn "未启用 TLS，观测入口的 Basic Auth 密码以明文传输，建议配置 SITES 后执行 make tls"
  fi
  return $changed
}

# 站点表：SITES 去掉空行和注释，每行「域名 服务」
sites() {
  local dom s
  while read -r dom s _; do
    [[ -z $dom || $dom == \#* ]] || echo "$dom $s"
  done <<<"${SITES:-}"
}

site_bound() { sites | awk -v d="$1" '$1 == d {f=1} END {exit !f}'; }

# 服务名即路由的内网主机名（victorialogs、alertmanager、demo…），输出「模式 组件 路径」
site_route() {
  local line mode n path upstream
  for line in "${OBS_ROUTES[@]/#/obs }" "${WEB_ROUTES[@]/#/web }"; do
    read -r mode n path upstream <<<"$line"
    [[ ${upstream%%:*} == "$1" ]] && { echo "$mode $n $path"; return 0; }
  done
  return 1
}

SITES_DENY="redis postgres"

# 配置错误在写任何文件前拦下；不能放在 $() 里调用，die 只会退出子 shell
sites_check() {
  local dom s seen=" "
  while read -r dom s; do
    [[ $dom =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "SITES: 域名不合法: $dom"
    [[ $seen != *" $dom "* ]] || die "SITES: $dom 重复"
    seen+="$dom "
    [[ -n $s ]] || die "SITES: $dom 缺少服务，写成「$dom 服务」"
    [[ " $SITES_DENY " != *" ${s%%:*} "* ]] || die "SITES: $dom 不能绑定 $s，数据库不经 Nginx 对外；需要访问用 SSH 隧道"
    [[ $s == main || $s =~ ^[A-Za-z0-9_.-]+:[0-9]+$ ]] || site_route "$s" >/dev/null ||
      die "SITES: $dom 的服务 $s 不认识；可用 main、$(sites_known)，或 容器名:端口"
  done < <(sites)
}

sites_known() {
  local line upstream out=()
  for line in "${OBS_ROUTES[@]}" "${WEB_ROUTES[@]}"; do
    read -r _ _ upstream <<<"$line"
    out+=("${upstream%%:*}")
  done
  echo "${out[*]}"
}

# 域名的 server。80 始终保留 ACME 校验路径供签发和续期；有该域名的证书时 80 跳 HTTPS，站点开在 443
site_server() {
  local dom=$1 body=$2
  cat <<EOF
$GEN_HEADER
server {
    listen 80;
    listen [::]:80;
    server_name $dom;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
EOF
  if site_tls "$dom"; then
    cat <<EOF
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $dom;
    ssl_certificate     /etc/letsencrypt/live/$dom/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$dom/privkey.pem;
    add_header Strict-Transport-Security "max-age=63072000" always;
EOF
  fi
  cat <<EOF
    location = /healthz {
        access_log off;
        return 200 "ok\n";
    }
$body
}
EOF
}

# main：主站全部入口；内置服务：根路径跳到入口路径，location 复用 locations/ 下生成的文件，组件未装时返回 503；容器名:端口：整站公开反代
site_body() {
  local s=$1 mode n path
  if [[ $s == main ]]; then
    echo "    include /etc/nginx/locations/*.conf;"
  elif read -r mode n path < <(site_route "$s"); then
    if ! comp_installed "$n"; then
      printf '    location / {\n        default_type text/plain;\n        return 503 "%s 未安装\\n";\n    }\n' "$n"
      return 0
    fi
    [[ $path == / ]] || printf '    location = / {\n        return 302 %s;\n    }\n' "$path"
    echo "    include /etc/nginx/locations/$(route_file "$mode" "$path");"
  else
    cat <<EOF
    location / {
        resolver 127.0.0.11 valid=10s;
        set \$upstream http://$s;
        proxy_pass \$upstream;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
EOF
  fi
}

# 有变化返回 0。每个站点生成 conf.d/site-<域名>.conf
render_sites() {
  local d dom s body f changed=1 want=()
  d=$(nginx_dir)
  sites_check
  while read -r dom s; do
    body=$(site_body "$s")
    [[ $body != *"return 503"* ]] || warn "$dom 绑定的 $s 未安装，访问返回 503"
    f=$d/conf.d/site-$dom.conf
    want+=("$f")
    if site_server "$dom" "$body" | write_if_changed "$f"; then
      changed=0
      if tls_on && ! cert_has "$dom"; then warn "$dom 没有证书，只能 HTTP 访问；加到 DOMAINS 后执行 make tls"; fi
    fi
  done < <(sites)
  for f in "$d"/conf.d/site-*.conf; do
    [[ -e $f && " ${want[*]} " != *" $f "* && $(head -1 "$f") == "$GEN_HEADER" ]] || continue
    rm -f "$f"; changed=0
    log "已移除站点 $(basename "$f")"
  done
  return $changed
}

nginx_purge_hint() { echo "$DEPLOY_DIR/nginx（配置、证书）及观测入口账号"; }

nginx_sync() {
  local changed=1
  render_nginx_conf && changed=0
  render_locations && changed=0
  render_sites && changed=0
  if ((changed == 0)) && comp_running nginx; then
    nginx_reload
    log "Nginx 入口已更新"
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
