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
  local changed=1 d email ca_line=""
  d=$(traefik_dir)
  email=${LE_EMAIL:-admin@example.com}
  [[ ${LE_STAGING:-0} == 1 ]] && ca_line="      caServer: \"https://acme-staging-v02.api.letsencrypt.org/directory\""

  cat <<EOF | write_if_changed "$d/traefik.yml" && changed=0
global:
  checkNewVersion: false
  sendAnonymousUsage: false

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

  return $changed
}

traefik_prepare() {
  local changed=1
  install -d -m 0755 "$(traefik_dir)"/{conf.d,acme,auth}
  ensure_acme_json
  ensure_traefik_obs_auth && changed=0
  render_traefik_config && changed=0
  return $changed
}

traefik_post() {
  log "Traefik 网关已就绪 (HTTP :80 / HTTPS :443 / Dashboard :443/traefik)"
}
