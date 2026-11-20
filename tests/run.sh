#!/usr/bin/env bash
# 本地测试：shellcheck + 多版本 Ubuntu 单测 + Traefik 路由 / OTel / 告警 / compose 校验。需要本机有 Docker
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
# 和 install.sh 一样只加载步骤表里的文件，避免测试用到生产不加载的代码
for n in $("$ROOT/install.sh" --names); do
  # shellcheck source=/dev/null
  . "$ROOT/steps/$n.sh"
done
BASE_DIR=$ROOT
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
DEPLOY_DIR=$tmp/deploy
STATE_DIR=$tmp/state
log() { :; }
INSTALLED=""
comp_installed() { [[ " $INSTALLED " == *" $1 "* ]]; }

echo "== Traefik 站点路由（$TRAEFIK_IMAGE，真实启动，只开文件 provider）"
check() { "$@" || { echo "  FAIL $*"; exit 1; }; }
warn() { :; }
td=$DEPLOY_DIR/traefik
INSTALLED="traefik victorialogs"
SITES="
# 注释和空行忽略
example.com          main
logs.example.com     victorialogs
app.example.com      myapp:8080
"
render_traefik_config || true
render_traefik_sites || true
# shellcheck disable=SC2016  # 反引号是 Traefik 规则语法
check grep -qF 'Host(`example.com`)' "$td/conf.d/sites.yml"
# 测试用的静态配置：不连 Docker、不签证书
cat >"$tmp/static.yml" <<'YML'
experimental:
  localPlugins:
    custom404:
      moduleName: github.com/kart-io/traefik-plugin-custom404
entryPoints:
  websecure:
    address: ":443"
providers:
  file:
    directory: /etc/traefik/conf.d
YML
n=$(docker run -d -v "$tmp/static.yml:/etc/traefik/traefik.yml:ro" -v "$td/conf.d:/etc/traefik/conf.d:ro" \
  -v "$td/html:/etc/traefik/html:ro" -v "$td/plugins-local:/plugins-local:ro" -w / "$TRAEFIK_IMAGE")
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n")
req() { curl -sk -o "$tmp/body" -w '%{http_code} %{redirect_url}' --resolve "$1:443:$ip" "https://$1$2" || true; }
for _ in {1..30}; do [[ $(req example.com /nope) == 404* ]] && break; sleep 1; done
r1=$(req example.com /nope); b1=$(cat "$tmp/body")
r2=$(req logs.example.com /)
r3=$(req logs.example.com /nope)
r4=$(req app.example.com /x)
r5=$(req unknown.example.org /x); b5=$(cat "$tmp/body")
docker logs "$n" 2>&1 | grep -iE 'level=error|ERR' | head -5 || true
docker rm -f "$n" >/dev/null
check test "$r1" == "404 "
check grep -q '页面不存在' <<<"$b1"
echo "  ok   main 站点没匹配到路由返回自定义 404 页面"
check test "$r2" == "302 https://logs.example.com/vl/select/vmui/"
check test "$r3" == "404 "
echo "  ok   内置服务站点根路径跳到入口，其余路径 404"
check test "$r4" == "502 "
echo "  ok   容器名:端口 站点整站反代（后端不存在返回 502，说明已路由到后端）"
check test "$r5" == "404 "
check grep -q '页面不存在' <<<"$b5"
echo "  ok   未配置的域名返回自定义 404 页面"
SITES="example.com main"
render_traefik_sites || true
check test -z "$(grep 'app.example.com' "$td/conf.d/sites.yml")"
SITES=""
render_traefik_sites || true
check test ! -e "$td/conf.d/sites.yml"
echo "  ok   从 SITES 去掉的站点自动移除"
for bad in "logs.example.com" "logs.example.com victorilogs" "Bad_Domain myapp:80" $'a.com main\na.com demo' \
  "db.example.com redis:6379" "db.example.com postgres:5432" "db.example.com redis"; do
  if (SITES=$bad; sites_check) 2>/dev/null; then echo "  FAIL 应拒绝 SITES=\"$bad\""; exit 1; fi
done
echo "  ok   拒绝缺服务、未知服务、非法域名、重复域名、redis/postgres"
# 生成的 traefik.yml 原样启动；conf.d 里没有 Host 路由，不会去 Let's Encrypt 申请证书
n=$(docker run -d -v "$td/traefik.yml:/etc/traefik/traefik.yml:ro" -v "$td/conf.d:/etc/traefik/conf.d:ro" \
  -v "$td/html:/etc/traefik/html:ro" -v "$td/plugins-local:/plugins-local:ro" -w / "$TRAEFIK_IMAGE")
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n")
for _ in {1..30}; do curl -fs -o /dev/null "http://$ip:8080/ping" && break; sleep 1; done
hdr=$(curl -sk -D - -o /dev/null "https://$ip/nope" || true)
docker rm -f "$n" >/dev/null
check grep -q '^HTTP/[0-9.]* 404' <<<"$hdr"
check grep -qi '^x-content-type-options: nosniff' <<<"$hdr"
check grep -qi '^strict-transport-security:' <<<"$hdr"
check grep -q 'basePath: /traefik' "$td/traefik.yml"
# shellcheck disable=SC2016  # 反引号是 Traefik 规则语法
check test -z "$(grep -F 'PathPrefix(`/api`)' "$ROOT/templates/traefik/docker-compose.yml")"
echo "  ok   生成的 traefik.yml 可启动；HTTPS 统一带安全响应头；Dashboard 收在 /traefik 下，不占用 /api"
c=$(docker run -d --name hostkit-test-offnet "$TRAEFIK_IMAGE")
# shellcheck disable=SC2329  # 桩函数供 render_traefik_sites 调用
msg=$(SITES="app.example.com hostkit-test-offnet:80"; warn() { echo "$*"; }; render_traefik_sites)
docker rm -f "$c" >/dev/null
check grep -q "hostkit-test-offnet 没接入 $NETWORK_NAME" <<<"$msg"
SITES=""; render_traefik_sites || true
echo "  ok   反代目标容器没接入 $NETWORK_NAME 时提示"
# shellcheck disable=SC2329  # 桩函数供 traefik_sync 调用
sync_runs=$(
  comp_running() { :; }; comp_wait() { :; }; ccompose() { echo "$*" >>"$tmp/ccompose"; }
  : >"$tmp/ccompose"; traefik_sync; wc -l <"$tmp/ccompose"
  : >"$tmp/ccompose"; traefik_sync; wc -l <"$tmp/ccompose"
  : >"$tmp/ccompose"; LE_STAGING=1 traefik_sync; grep -c -- --force-recreate "$tmp/ccompose"
)
check test "${sync_runs//$'\n'/ }" == "1 0 1"
echo "  ok   make update：静态配置/compose 有变化才重建 Traefik，无变化不动"

echo "== OTel 配置校验（$OTEL_IMAGE）"
TLS=0
tls_on() { ((TLS)); }
for combo in "|" "victoriametrics|" "victorialogs|" "victoriametrics victorialogs|" \
  "victoriametrics redis postgres|" "victoriametrics redis postgres|tls"; do
  INSTALLED=${combo%|*}
  TLS=$([[ ${combo#*|} == tls ]] && echo 1 || echo 0)
  SITES=$([[ $TLS == 1 ]] && echo $'example.com main\nlogs.example.com victorialogs' || true)
  render_otel_config || true
  [[ $TLS == 0 ]] || check grep -q "endpoint: logs.example.com:443" "$DEPLOY_DIR/otel/config.yaml"
  docker run --rm -e HOST_NAME=h -e REDIS_PASSWORD=x -e POSTGRES_USER=x -e POSTGRES_PASSWORD=x -v /:/hostfs:ro \
    -v "$DEPLOY_DIR/otel/config.yaml:/cfg.yaml:ro" "$OTEL_IMAGE" validate --config=/cfg.yaml
  echo "  ok   已装=[$INSTALLED$([[ $TLS == 1 ]] && echo " tls")] 指标: $(grep -oE 'receivers: \[[^]]+\]' "$DEPLOY_DIR/otel/config.yaml" | head -1)"
done

echo "== 业务容器 /metrics 自动发现（真实 collector 写入 VictoriaMetrics）"
net=hostkit-test-net
prom_cleanup() { docker rm -f hostkit-test-vm t-app t-def t-nolabel t-offnet hostkit-test-otel >/dev/null 2>&1 || true; docker network rm $net >/dev/null 2>&1 || true; }
prom_cleanup
INSTALLED="victoriametrics"; TLS=0
NETWORK_NAME=$net render_otel_config || true
# 只验证 prometheus/docker；docker_stats 依赖本机 Docker API 版本，这里去掉
sed -e 's/, docker_stats, /, /' -e 's#http://victoriametrics:8428#http://hostkit-test-vm:8428#' "$DEPLOY_DIR/otel/config.yaml" >"$tmp/otel-prom.yaml"
docker network create $net >/dev/null
docker run -d --name hostkit-test-vm --network $net "$VM_IMAGE" -http.pathPrefix=/vm -opentelemetry.usePrometheusNaming >/dev/null
docker run -d --name t-app --network $net -l prometheus.io/scrape=true -l prometheus.io/port=8428 -l com.docker.compose.service=myapp "$VM_IMAGE" >/dev/null
docker run -d --name t-def --network $net -l prometheus.io/scrape=true "$VM_IMAGE" >/dev/null
docker run -d --name t-nolabel --network $net "$VM_IMAGE" >/dev/null
docker run -d --name t-offnet -l prometheus.io/scrape=true -l prometheus.io/port=8428 "$VM_IMAGE" >/dev/null
docker run -d --name hostkit-test-otel --network $net --user 0:0 -e HOST_NAME=h -v /:/hostfs:ro -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v "$tmp/otel-prom.yaml:/etc/otelcol-contrib/config.yaml:ro" "$OTEL_IMAGE" >/dev/null
ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" hostkit-test-vm)
scraped() {
  curl -s "http://$ip:8428/vm/api/v1/query" --data-urlencode 'query=count by (container, service) (vm_app_version)' \
    | python3 -c 'import json,sys; print(" ".join(sorted("%s/%s=%s" % (r["metric"].get("container"), r["metric"].get("service", "-"), r["value"][1]) for r in json.load(sys.stdin)["data"]["result"])))'
}
for _ in {1..60}; do [[ $(scraped 2>/dev/null) == "t-app/myapp=1 t-def/-=1" ]] && break; sleep 2; done
got=$(scraped 2>/dev/null || true)
prom_cleanup
check test "$got" == "t-app/myapp=1 t-def/-=1"
echo "  ok   带 prometheus.io/scrape 标签且在网络内的容器被抓取（指定端口/默认端口各一次），无标签或不在网络内的忽略"

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
  IMAGE=x NETWORK_NAME=$NETWORK_NAME REDIS_PASSWORD=x POSTGRES_USER=x POSTGRES_PASSWORD=x RETENTION=1d HOST_NAME=h DOCKER_CONTAINERS_DIR=/tmp \
    ALERTMANAGER_IMAGE=x PYTHON_IMAGE=x FEISHU_WEBHOOK='' FEISHU_SECRET='' \
    docker compose -f "$f" config -q
  echo "  ok   $(basename "$(dirname "$f")")"
done
echo "全部通过"
