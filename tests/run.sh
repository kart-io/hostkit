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

echo "== nginx 模板校验（$NGINX_IMAGE，含 /vm/ /vl/ /vmalert/ /am/ 观测入口、观测独立域名和 demo 公开入口 /）"
le=$DEPLOY_DIR/nginx/certbot/conf
mkdir -p "$le/live/example.com" "$DEPLOY_DIR/nginx/locations"
# 证书含 logs.example.com、不含 metrics.example.com：VL 走 443，VM 回落到 80
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -addext "subjectAltName=DNS:example.com,DNS:www.example.com,DNS:logs.example.com" \
  -keyout "$le/live/example.com/privkey.pem" -out "$le/live/example.com/fullchain.pem" 2>/dev/null
DOMAINS="example.com www.example.com" VL_DOMAIN=logs.example.com VM_DOMAIN=metrics.example.com AM_DOMAIN=example.com
warn() { :; }
INSTALLED="victoriametrics victorialogs alert demo"
render_locations 2>/dev/null || { echo "  FAIL 未生成观测入口"; exit 1; }
check() { "$@" || { echo "  FAIL $*"; exit 1; }; }
check test "$(tls_domains)" == "example.com www.example.com logs.example.com metrics.example.com"
check grep -q 'listen 443 ssl' "$DEPLOY_DIR/nginx/conf.d/obs-vl.conf"
check grep -q 'listen 80' "$DEPLOY_DIR/nginx/conf.d/obs-vm.conf"
check test ! -e "$DEPLOY_DIR/nginx/conf.d/obs-am.conf"
echo "  ok   独立域名：证书覆盖的走 443，未覆盖的走 80，与 DOMAINS 重复的忽略"
for tpl in default-http.conf default-tls.conf; do
  mkdir -p "$tmp/$tpl"
  cp "$DEPLOY_DIR"/nginx/conf.d/obs-*.conf "$tmp/$tpl/"
  sed -e 's|__SERVER_NAMES__|example.com www.example.com|g' -e 's|__CERT_NAME__|example.com|g' \
    "$ROOT/templates/nginx/$tpl" >"$tmp/$tpl/default.conf"
  docker run --rm -v "$tmp/$tpl:/etc/nginx/conf.d:ro" -v "$DEPLOY_DIR/nginx/locations:/etc/nginx/locations:ro" \
    -v "$le:/etc/letsencrypt:ro" --entrypoint nginx "$NGINX_IMAGE" -t -q
  echo "  ok   $tpl"
done
VM_DOMAIN=""
render_locations 2>/dev/null || true
check test ! -e "$DEPLOY_DIR/nginx/conf.d/obs-vm.conf"
echo "  ok   去掉域名配置后移除对应 server"
DOMAINS="" VL_DOMAIN="" AM_DOMAIN=""

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
