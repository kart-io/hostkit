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
# shellcheck source=../lib/status.sh
. "$ROOT/lib/status.sh"
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
mkdir -p "$le" "$DEPLOY_DIR/nginx/locations" "$DEPLOY_DIR/nginx/conf.d"
check() { "$@" || { echo "  FAIL $*"; exit 1; }; }
c=$DEPLOY_DIR/nginx/conf.d
nginx_t() {
  docker run --rm -v "$c:/etc/nginx/conf.d:ro" -v "$DEPLOY_DIR/nginx/locations:/etc/nginx/locations:ro" \
    -v "$le:/etc/letsencrypt:ro" --entrypoint nginx "$NGINX_IMAGE" -t -q
}
warn() { :; }
INSTALLED="victoriametrics victorialogs demo"   # alert 未装：vmalert/alertmanager 站点返回 503
render_locations 2>/dev/null || { echo "  FAIL 未生成观测入口"; exit 1; }
render_nginx_conf || true
nginx_t
echo "  ok   nginx -t（还没有任何证书和站点）"

# 每个站点域名一张证书；shop、metrics 还没签下来只走 80；old.example.com 有证书但已不在 SITES，不再使用
detect_public_ip() { return 1; }
for dom in example.com www.example.com logs.example.com app.example.com demo.example.com am.example.com old.example.com; do
  mkdir -p "$le/live/$dom"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$dom" \
    -keyout "$le/live/$dom/privkey.pem" -out "$le/live/$dom/fullchain.pem" 2>/dev/null
done
SITES="
# 注释和空行忽略
example.com          main
shop.example.com     main
logs.example.com     victorialogs
metrics.example.com  victoriametrics
www.example.com      alertmanager
app.example.com      myapp:8080
demo.example.com     demo
am.example.com       vmalert
"
render_sites || true
for dom in logs.example.com example.com; do check test -z "$(grep 'listen 443' "$c/site-$dom.conf")"; done
echo "  ok   没执行 make tls 时，有证书也只走 80"
state_set tls
render_sites || true
check test "$(certs | xargs)" == "example.com logs.example.com www.example.com app.example.com demo.example.com am.example.com"
check grep -q 'ssl_reject_handshake on' "$c/default.conf"
check grep -q 'live/example.com/fullchain.pem' "$c/site-example.com.conf"
check grep -q 'include /etc/nginx/locations/\*.conf' "$c/site-example.com.conf"
check grep -q 'include /etc/nginx/locations/\*.conf' "$c/site-shop.example.com.conf"
check grep -q 'live/logs.example.com/fullchain.pem' "$c/site-logs.example.com.conf"
check grep -q 'return 301 https' "$c/site-logs.example.com.conf"
check grep -q 'return 302 /vl/' "$c/site-logs.example.com.conf"
for dom in shop metrics; do
  check grep -q 'acme-challenge' "$c/site-$dom.example.com.conf"
  check test -z "$(grep -E 'listen 443|return 301' "$c/site-$dom.example.com.conf")"
done
check grep -q 'http://myapp:8080' "$c/site-app.example.com.conf"
check grep -q 'include /etc/nginx/locations/web-root.conf' "$c/site-demo.example.com.conf"
check grep -q 'return 503 "alert 未安装' "$c/site-www.example.com.conf"
check grep -q 'return 503 "alert 未安装' "$c/site-am.example.com.conf"
check grep -qx '站点: shop.example.com → main  DNS -  证书 未签发  http://shop.example.com' <<<"$(status_sites)"
check grep -qxE '站点: logs.example.com → victorialogs  DNS -  证书 剩余 [0-9]+ 天  https://logs.example.com' <<<"$(status_sites)"
echo "  ok   站点：每个域名用自己的证书，没证书的只走 80；main/内置服务/容器名:端口；未装组件返回 503"
nginx_t
echo "  ok   nginx -t（各站点 + 证书）"
SITES="logs.example.com victorialogs"
render_sites || true
check test ! -e "$c/site-app.example.com.conf"
echo "  ok   从 SITES 去掉的站点自动移除"
for bad in "logs.example.com" "logs.example.com victorilogs" "Bad_Domain myapp:80" $'a.com main\na.com demo' \
  "db.example.com redis:6379" "db.example.com postgres:5432" "db.example.com redis"; do
  if (SITES=$bad; sites_check) 2>/dev/null; then echo "  FAIL 应拒绝 SITES=\"$bad\""; exit 1; fi
done
echo "  ok   拒绝缺服务、未知服务、非法域名、重复域名、redis/postgres"
for t in "localhost 127.0.0.1|本机" "localhost 203.0.113.1|指向 127.0.0.1" "no-such-host.invalid 203.0.113.1|未解析"; do
  read -r dom ip <<<"${t%|*}"
  check test "$(dns_state "$dom" "$ip")" == "${t#*|}"
done
echo "  ok   DNS 状态：本机 / 指向其他 IP / 未解析"
# shellcheck disable=SC2329  # 桩函数供 tls_issue_missing 调用
msg=$(
  SITES="no-such-host.invalid demo"
  detect_public_ip() { echo 203.0.113.1; }
  ccompose() { echo "调用了 certbot"; }
  warn() { echo "$*"; }
  tls_issue_missing || true
)
check grep -q '^no-such-host.invalid DNS 未解析，不是本机公网 IP 203.0.113.1' <<<"$msg"
check test -z "$(grep 'certbot' <<<"$msg")"
echo "  ok   DNS 没解析到本机的站点不申请证书，并提示原因"
SITES=""

echo "== OTel 配置校验（$OTEL_IMAGE）"
TLS=0
tls_on() { ((TLS)); }
for combo in "|" "victoriametrics|" "victorialogs|" "victoriametrics victorialogs|" \
  "victoriametrics redis postgres|" "victoriametrics redis postgres|tls"; do
  INSTALLED=${combo%|*}
  TLS=$([[ ${combo#*|} == tls ]] && echo 1 || echo 0)
  SITES=$([[ $TLS == 1 ]] && echo $'example.com main\nlogs.example.com victorialogs' || true)
  render_otel_config || true
  [[ $TLS == 0 ]] || check grep -q "file_path: /hostfs$le/live/logs.example.com/fullchain.pem" "$DEPLOY_DIR/otel/config.yaml"
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
