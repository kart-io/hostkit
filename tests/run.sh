#!/usr/bin/env bash
# 本地测试：shellcheck + 多版本 Ubuntu 单测 + nginx/compose 模板校验。需要本机有 Docker
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
read -ra IMAGES <<<"${TEST_IMAGES:-ubuntu:22.04 ubuntu:24.04 ubuntu:26.04}"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
load_config /nonexistent

echo "== shellcheck"
(cd "$ROOT" && shellcheck install.sh lib/*.sh steps/*.sh tests/*.sh)

for img in "${IMAGES[@]}"; do
  echo "== 单测 $img"
  docker run --rm -v "$ROOT:/src:ro" "$img" bash -c \
    'apt-get update -qq >/dev/null && apt-get install -y -qq python3 curl ca-certificates iproute2 >/dev/null && bash /src/tests/unit.sh'
done

# shellcheck source=../lib/components.sh
. "$ROOT/lib/components.sh"
for f in "$ROOT"/steps/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
BASE_DIR=$ROOT
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
DEPLOY_DIR=$tmp/deploy
STATE_DIR=$tmp/state
log() { :; }
INSTALLED=""
comp_installed() { [[ " $INSTALLED " == *" $1 "* ]]; }

echo "== nginx 模板校验（$NGINX_IMAGE，含观测入口、demo 公开入口和 SITES 各类站点）"
le=$DEPLOY_DIR/nginx/certbot/conf
mkdir -p "$le/live/example.com" "$DEPLOY_DIR/nginx/locations" "$DEPLOY_DIR/nginx/conf.d"
# DOMAINS 是证书域名；metrics.example.com 只在 SITES 里绑定、不在证书里，回落到 80
DOMAINS="example.com shop.example.com www.example.com logs.example.com app.example.com demo.example.com am.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -addext "subjectAltName=DNS:${DOMAINS// /,DNS:}" \
  -keyout "$le/live/example.com/privkey.pem" -out "$le/live/example.com/fullchain.pem" 2>/dev/null
# shop.example.com 只在 DOMAINS（证书）里、没绑定，不算主站
SITES="
# 注释和空行忽略
example.com          main
logs.example.com     victorialogs
metrics.example.com  victoriametrics
www.example.com      alertmanager
app.example.com      myapp:8080
demo.example.com     demo
am.example.com       vmalert
"
warn() { :; }
INSTALLED="victoriametrics victorialogs demo"   # alert 未装：vmalert/alertmanager 站点返回 503
render_locations 2>/dev/null || { echo "  FAIL 未生成观测入口"; exit 1; }
render_sites || true
render_nginx_conf || true
check() { "$@" || { echo "  FAIL $*"; exit 1; }; }
c=$DEPLOY_DIR/nginx/conf.d
check test "$(cert_name)" == example.com
check test "$(main_server_names)" == "example.com"
check grep -q 'server_name example.com;' "$c/default.conf"
check grep -q 'listen 443 ssl' "$c/site-logs.example.com.conf"
check grep -q 'return 302 /vl/' "$c/site-logs.example.com.conf"
check grep -q 'listen 80;' "$c/site-metrics.example.com.conf"
check grep -q 'http://myapp:8080' "$c/site-app.example.com.conf"
check grep -q 'include /etc/nginx/locations/web-root.conf' "$c/site-demo.example.com.conf"
check grep -q 'return 503 "alert 未安装' "$c/site-www.example.com.conf"
check grep -q 'return 503 "alert 未安装' "$c/site-am.example.com.conf"
echo "  ok   站点：只认 SITES 绑定；证书覆盖的走 443、未覆盖走 80；内置服务/容器名:端口；未装组件返回 503"
docker run --rm -v "$c:/etc/nginx/conf.d:ro" -v "$DEPLOY_DIR/nginx/locations:/etc/nginx/locations:ro" \
  -v "$le:/etc/letsencrypt:ro" --entrypoint nginx "$NGINX_IMAGE" -t -q
echo "  ok   nginx -t（TLS 主站 + 各站点）"
for tpl in default-http.conf default-tls.conf; do
  mkdir -p "$tmp/$tpl"
  sed -e 's|__SERVER_NAMES__|example.com www.example.com|g' -e 's|__CERT_NAME__|example.com|g' \
    "$ROOT/templates/nginx/$tpl" >"$tmp/$tpl/default.conf"
  docker run --rm -v "$tmp/$tpl:/etc/nginx/conf.d:ro" -v "$DEPLOY_DIR/nginx/locations:/etc/nginx/locations:ro" \
    -v "$le:/etc/letsencrypt:ro" --entrypoint nginx "$NGINX_IMAGE" -t -q
  echo "  ok   $tpl"
done
SITES="logs.example.com victorialogs"
render_sites || true
check test ! -e "$c/site-app.example.com.conf"
echo "  ok   从 SITES 去掉的站点自动移除"
for bad in "logs.example.com" "logs.example.com victorilogs" "Bad_Domain myapp:80" $'a.com main\na.com demo' \
  "db.example.com redis:6379" "db.example.com postgres:5432" "db.example.com redis"; do
  if (SITES=$bad; sites_check) 2>/dev/null; then echo "  FAIL 应拒绝 SITES=\"$bad\""; exit 1; fi
done
echo "  ok   拒绝缺服务、未知服务、非法域名、重复域名、redis/postgres"
DOMAINS="" SITES=""

echo "== OTel 配置校验（$OTEL_IMAGE）"
TLS=0
tls_on() { ((TLS)); }
for combo in "|" "victoriametrics|" "victorialogs|" "victoriametrics victorialogs|" \
  "victoriametrics redis postgres|" "victoriametrics redis postgres|tls"; do
  INSTALLED=${combo%|*}
  TLS=$([[ ${combo#*|} == tls ]] && echo 1 || echo 0)
  render_otel_config || true
  docker run --rm -e HOST_NAME=h -e REDIS_PASSWORD=x -e POSTGRES_USER=x -e POSTGRES_PASSWORD=x -v /:/hostfs:ro \
    -v "$DEPLOY_DIR/otel/config.yaml:/cfg.yaml:ro" "$OTEL_IMAGE" validate --config=/cfg.yaml
  echo "  ok   已装=[$INSTALLED$([[ $TLS == 1 ]] && echo " tls")] 指标: $(grep -oE 'receivers: \[[^]]+\]' "$DEPLOY_DIR/otel/config.yaml" | head -1)"
done

echo "== 告警规则与 Alertmanager 配置校验（$VMALERT_IMAGE / $ALERTMANAGER_IMAGE）"
INSTALLED="redis victoriametrics otel alert"
state_has() { :; }
TLS=1
alert_render_rules || true
check_rules() {
  docker run --rm -v "$1:/rules:ro" "$VMALERT_IMAGE" -rule='/rules/*.yml' -dryRun -loggerLevel=ERROR
}
check_rules "$DEPLOY_DIR/alert/rules"
echo "  ok   已生成: $(cd "$DEPLOY_DIR/alert/rules" && echo *.yml)"
for f in "$ROOT"/templates/alert/rules/*.yml; do
  grep -q "$(basename "$f" .yml) " <<<"$(printf '%s\n' "${ALERT_RULES[@]}")" || { echo "  FAIL $f 未登记在 ALERT_RULES"; exit 1; }
done
docker run --rm -v "$ROOT/templates/alert/alertmanager.yml:/am.yml:ro" --entrypoint amtool "$ALERTMANAGER_IMAGE" check-config /am.yml >/dev/null
echo "  ok   alertmanager.yml"

echo "== compose 校验"
for f in "$ROOT"/templates/*/docker-compose.yml; do
  IMAGE=x CERTBOT_IMAGE=x NETWORK_NAME=$NETWORK_NAME REDIS_PASSWORD=x POSTGRES_USER=x POSTGRES_PASSWORD=x RETENTION=1d HOST_NAME=h DOCKER_CONTAINERS_DIR=/tmp \
    ALERTMANAGER_IMAGE=x PYTHON_IMAGE=x FEISHU_WEBHOOK='' FEISHU_SECRET='' \
    docker compose -f "$f" config -q
  echo "  ok   $(basename "$(dirname "$f")")"
done
echo "全部通过"
