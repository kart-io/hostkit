# shellcheck shell=bash
# Traefik 声明式边缘网关（80/443）：支持容器标签自发现、自动证书与中间件
# shellcheck disable=SC2154

COMPONENTS+=("traefik traefik http 8080 /ping")
# 观测入口与 Traefik Dashboard 的 Basic Auth 账号
CREDENTIALS+=("traefik OBS_AUTH_USER     user admin")
CREDENTIALS+=("traefik OBS_AUTH_PASSWORD password")

traefik_install()   { comp_install traefik; }
traefik_uninstall() { comp_undo traefik; }
traefik_purge()     { comp_purge traefik; }

traefik_dir() { echo "$DEPLOY_DIR/traefik"; }

traefik_env() {
  echo "IMAGE=$TRAEFIK_IMAGE"
}

# 确保 acme.json 存在且权限为 0600（Traefik 安全要求）
ensure_acme_json() {
  local f
  f=$(traefik_dir)/acme/acme.json
  install -d -m 0700 "$(dirname "$f")"
  if [[ ! -f $f ]]; then
    touch "$f"
    chmod 0600 "$f"
  else
    chmod 0600 "$f"
  fi
}

# 生成观测入口和 Dashboard 的 Basic Auth htpasswd
ensure_traefik_obs_auth() {
  local f user pw u h
  f=$(traefik_dir)/auth/htpasswd
  cred_prepare traefik
  user=$(cred_get OBS_AUTH_USER); pw=$(cred_get OBS_AUTH_PASSWORD)
  if [[ -s $f ]]; then
    IFS=: read -r u h <"$f"
    [[ $u == "$user" && $(openssl passwd -apr1 -salt "$(cut -d'$' -f3 <<<"$h")" "$pw") == "$h" ]] && return 1
  fi
  install -d -m 0755 "$(dirname "$f")"
  printf '%s:%s\n' "$user" "$(openssl passwd -apr1 "$pw")" | write_if_changed "$f" 0644
  log "网关/观测入口账号已更新，见 $(cred_file) 的 OBS_AUTH_USER/OBS_AUTH_PASSWORD"
}

render_traefik_config() {
  local changed=1 d email ca_line="" plug_dir
  d=$(traefik_dir)
  email=${LE_EMAIL:-admin@example.com}
  [[ ${LE_STAGING:-0} == 1 ]] && ca_line="      caServer: \"https://acme-staging-v02.api.letsencrypt.org/directory\""

  cat <<EOF | write_if_changed "$d/traefik.yml" && changed=0
global:
  checkNewVersion: false
  sendAnonymousUsage: false

experimental:
  localPlugins:
    custom404:
      moduleName: github.com/kart-io/traefik-plugin-custom404

ping:
  entryPoint: "ping"

entryPoints:
  ping:
    address: ":8080"

  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: "websecure"
          scheme: "https"
          permanent: true

  websecure:
    address: ":443"
    http:
      tls:
        certResolver: "le"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: "${NETWORK_NAME}"
    watch: true
  file:
    directory: "/etc/traefik/conf.d"
    watch: true

certificatesResolvers:
  le:
    acme:
      email: "${email}"
      storage: "/etc/traefik/acme/acme.json"
${ca_line}
      httpChallenge:
        entryPoint: "web"

api:
  dashboard: true
  insecure: false

log:
  level: "INFO"

accessLog: {}
EOF

  write_if_changed "$d/conf.d/global.yml" <"$BASE_DIR/templates/traefik/conf.d/global.yml" && changed=0
  write_if_changed "$d/html/404.html" <"$BASE_DIR/templates/traefik/html/404.html" && changed=0

  plug_dir="$d/plugins-local/src/github.com/kart-io/traefik-plugin-custom404"
  install -d -m 0755 "$plug_dir"
  write_if_changed "$plug_dir/.traefik.yml" <"$BASE_DIR/templates/traefik/plugins-local/src/github.com/kart-io/traefik-plugin-custom404/.traefik.yml" && changed=0
  write_if_changed "$plug_dir/custom404.go" <"$BASE_DIR/templates/traefik/plugins-local/src/github.com/kart-io/traefik-plugin-custom404/custom404.go" && changed=0

  return $changed
}

traefik_prepare() {
  local changed=1
  sites_check
  install -d -m 0755 "$(traefik_dir)"/{conf.d,acme,auth,html,plugins-local}
  ensure_acme_json
  ensure_traefik_obs_auth && changed=0
  render_traefik_config && changed=0
  return $changed
}

traefik_post() {
  log "Traefik 网关已就绪 (HTTP :80 / HTTPS :443 / Dashboard :443/traefik)"
}

# 站点表：SITES 去掉空行和注释，每行「域名 服务」
sites() {
  local dom s
  while read -r dom s _; do
    [[ -z $dom || $dom == \#* ]] || echo "$dom $s"
  done <<<"${SITES:-}"
}

site_domains() { sites | awk '{print $1}'; }

# 输出「组件 入口路径」
site_service() {
  local line svc n entry
  for line in "${SITE_SERVICES[@]}"; do
    read -r svc n entry <<<"$line"
    [[ $svc == "$1" ]] && { echo "$n $entry"; return 0; }
  done
  return 1
}

SITES_DENY="redis postgres"

# 配置错误在写任何文件前拦下；不能放在 $() 里调用，die 只会退出子 shell
sites_check() {
  local dom s seen=" " known
  while read -r dom s; do
    [[ $dom =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "SITES: 域名不合法: $dom"
    [[ $seen != *" $dom "* ]] || die "SITES: $dom 重复"
    seen+="$dom "
    [[ -n $s ]] || die "SITES: $dom 缺少服务，写成「$dom 服务」"
    [[ " $SITES_DENY " != *" ${s%%:*} "* ]] || die "SITES: $dom 不能绑定 $s，数据库不经网关对外；需要访问用 SSH 隧道"
    if ! [[ $s == main || $s =~ ^[A-Za-z0-9_.-]+:[0-9]+$ ]] && ! site_service "$s" >/dev/null; then
      known=$(printf '%s\n' "${SITE_SERVICES[@]}" | awk '{print $1}' | xargs)
      die "SITES: $dom 的服务 $s 不认识；可用 main、$known，或 容器名:端口"
    fi
  done < <(sites)
}

# 每个站点一个 Host 路由，证书由 websecure 入口的 certResolver 按 Host 自动签发。
# main：只兜底 404，组件路径路由照常命中；内置服务：根路径跳到入口，入口为 / 时整站交给它；容器名:端口：整站反代
render_traefik_sites() {
  local f dom s id n entry routers="" mws="" svcs=""
  f=$(traefik_dir)/conf.d/sites.yml
  sites_check
  if [[ -z $(sites) ]]; then
    [[ ! -e $f ]] || { rm -f "$f"; log "已移除 $f"; }
    return 0
  fi
  while read -r dom s; do
    id=site-${dom//./-}
    if [[ $s == main ]]; then
      routers+=$(site_router "$id" "Host(\`$dom\`)" 2 noop@internal custom-404@file)
    elif read -r n entry < <(site_service "$s"); then
      comp_installed "$n" || warn "$dom 绑定的 $s 未安装（make $n），装好前访问返回 404"
      if [[ $entry == / ]]; then
        routers+=$(site_router "$id" "Host(\`$dom\`)" 4 "$s@docker")
      else
        routers+=$(site_router "$id" "Host(\`$dom\`)" 4 noop@internal custom-404@file)
        routers+=$(site_router "$id-root" "Host(\`$dom\`) && Path(\`/\`)" 1000 noop@internal "$id-root")
        mws+=$'\n'"    $id-root:"$'\n'"      redirectRegex:"$'\n'"        regex: \".*\""$'\n'"        replacement: \"https://$dom$entry\""
      fi
    else
      routers+=$(site_router "$id" "Host(\`$dom\`)" 1000 "$id")
      svcs+=$'\n'"    $id:"$'\n'"      loadBalancer:"$'\n'"        servers:"$'\n'"          - url: \"http://$s\""
    fi
  done < <(sites)
  {
    echo "$GEN_HEADER，来源 config.env 的 SITES"
    echo "http:"
    echo "  routers:$routers"
    [[ -z $mws ]] || echo "  middlewares:$mws"
    [[ -z $svcs ]] || echo "  services:$svcs"
  } | write_if_changed "$f"
}

# 参数：名称 规则 优先级 服务 [中间件]；前面带换行，便于拼接
site_router() {
  printf '\n    %s:\n      rule: "%s"\n      entryPoints: [websecure]\n      priority: %s\n      service: "%s"\n' "$1" "$2" "$3" "$4"
  [[ -z ${5:-} ]] || printf '      middlewares: ["%s"]\n' "$5"
  printf '      tls: {}'
}

# 有站点即会签证书；OTel 据此连各站点 443 检查证书剩余时间
tls_on() { comp_installed traefik && [[ -n $(sites) ]]; }

# 文件 provider 监听 conf.d，改 SITES 后无需重启
traefik_sync() { render_traefik_sites; }

# 证书能重新签发；备份是为了重建时不撞 Let's Encrypt 频率限制
traefik_backup() {
  [[ -s $(traefik_dir)/acme/acme.json ]] || return 0
  tar -C "$(traefik_dir)" -czf "$1/traefik.tar.gz" acme
}

# 目录是 bind mount，先停容器再换，否则容器仍指向改名后的旧目录
traefik_restore() {
  local d; d=$(traefik_dir)
  ccompose traefik down
  if [[ -d $d/acme ]]; then mv "$d/acme" "$d/acme.before-restore-$(date +%Y%m%d-%H%M%S)"; fi
  tar -C "$d" -xzf "$1"
  comp_install traefik
}

traefik_purge_hint() { echo "$DEPLOY_DIR/traefik（配置、证书）及观测入口账号"; }
