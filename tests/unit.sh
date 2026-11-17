#!/usr/bin/env bash
# 纯函数单测，在 Ubuntu 容器内运行（见 tests/run.sh）
set -uo pipefail
BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$BASE_DIR/lib/common.sh"
# shellcheck source=../lib/components.sh
. "$BASE_DIR/lib/components.sh"
# shellcheck source=../lib/credentials.sh
. "$BASE_DIR/lib/credentials.sh"
for f in docker dockerconf swap backup; do
  # shellcheck source=/dev/null
  . "$BASE_DIR/steps/$f.sh"
done
load_config /nonexistent

fails=0
check() { # 名称 期望 实际
  if [[ $2 == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: 期望 [$2] 实际 [$3]"; fails=$((fails + 1)); fi
}

echo "recommend_swap_mb"
while read -r mem free want; do
  check "mem=$mem free=$free" "$want" "$(recommend_swap_mb "$mem" "$free")"
done <<'EOF'
1024  50000 2048
2048  50000 4096
4096  50000 4096
16384 50000 4096
4096  8000  2000
EOF

echo "detect_os"
tmp=$(mktemp -d)
while IFS='|' read -r name content want; do
  printf '%b\n' "$content" >"$tmp/os-release"
  got=$(OS_RELEASE_FILE=$tmp/os-release; detect_os 2>/dev/null; echo "$OS_CODENAME") || got=DIE
  check "$name" "$want" "$got"
done <<'EOF'
ubuntu 24.04|ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble|noble
mint 22|ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=wilma\nUBUNTU_CODENAME=noble|noble
debian 12|ID=debian\nVERSION_CODENAME=bookworm|DIE
EOF
check "本机 os-release" "ok" "$(detect_os && [[ -n $OS_CODENAME && -n $ARCH ]] && echo ok)"

echo "load_config 版本优先级"
want_vm=$(sed -n 's/^VM_IMAGE=//p' "$BASE_DIR/versions.env")
echo 'REDIS_IMAGE=redis:from-config' >"$tmp/config.env"
while IFS='|' read -r name env_val key want; do
  got=$(unset REDIS_IMAGE VM_IMAGE; [[ -n $env_val ]] && export "${env_val?}"; load_config "$tmp/config.env"; echo "${!key}")
  check "$name" "$want" "$got"
done <<EOF
versions.env 默认||VM_IMAGE|$want_vm
config.env 覆盖||REDIS_IMAGE|redis:from-config
环境变量覆盖|VM_IMAGE=vm:from-env|VM_IMAGE|vm:from-env
EOF
check "versions.env 无引号" "" "$(grep -E '^[A-Z_]+=.*["'"'"']' "$BASE_DIR/versions.env")"

echo "账号密码"
DEPLOY_DIR=$tmp/deploy
CREDENTIALS=("a A_USER user admin" "a A_PASS password" "b B_PASS password")
cf=$DEPLOY_DIR/credentials.env
pw=$(cred_get A_PASS 2>/dev/null)
while IFS='|' read -r name want got; do
  check "$name" "$want" "$(eval "$got")"
done <<'EOF'
用户名取默认值|admin|cred_get A_USER 2>/dev/null
密码随机生成 48 位|ok|[[ $pw =~ ^[0-9a-f]{48}$ ]] && echo ok
再次读取不变|ok|[[ $(cred_get A_PASS) == "$pw" ]] && echo ok
文件权限 600|600|stat -c %a "$cf"
手填值保留|my_handfilled.pass-1234|echo B_PASS=my_handfilled.pass-1234 >>"$cf"; cred_get B_PASS
非法密码拒绝|DIE|(sed -i 's/^B_PASS=.*/B_PASS=sh$rt/' "$cf"; cred_get B_PASS 2>/dev/null) || echo DIE
非法用户名拒绝|DIE|(sed -i 's/^A_USER=.*/A_USER=Admin:x/' "$cf"; cred_get A_USER 2>/dev/null) || echo DIE
未登记变量拒绝|DIE|(cred_get NOPE 2>/dev/null) || echo DIE
安装前校验非法值中止|DIE|(cred_prepare b 2>/dev/null; echo 未中止) | grep -q 未中止 || echo DIE
清除只删本组件|B_PASS|cred_purge a; grep -o '^[A-Z_]*=' "$cf" | tr -d = | xargs
最后一个组件清除后删文件|gone|cred_purge b; [[ -f $cf ]] || echo gone
EOF

echo "pick_docker_pool"
host_cidrs() { echo "10.0.0.0/24"; echo "0.0.0.0/0"; }
while IFS='|' read -r avoid want; do
  check "AVOID_CIDRS=[$avoid]" "$want" "$(AVOID_CIDRS=$avoid pick_docker_pool || echo NONE)"
done <<'EOF'
|172.17.0.0/16
172.16.0.0/12|10.200.0.0/16
172.16.0.0/12 10.0.0.0/8|192.168.128.0/18
172.16.0.0/12 10.0.0.0/8 192.168.0.0/16|NONE
EOF

echo "required_tcp_ports"
while IFS='|' read -r port close extra want; do
  check "SSH_PORT=$port close=$close extra=[$extra]" "$want" \
    "$(SSH_PORT=$port SSH_CLOSE_OLD_PORT=$close EXTRA_TCP_PORTS=$extra required_tcp_ports | xargs)"
done <<'EOF'
22|0||22 80 443
2222|0||2222 22 80 443
2222|1|8080 443|2222 80 443 8080
EOF

echo "merge_json"
echo '{"debug":true,"log-opts":{"max-size":"1m"}}' >"$tmp/daemon.json"
check "保留已有键并覆盖" '{"debug": true, "log-opts": {"max-size": "50m"}}' \
  "$(merge_json "$tmp/daemon.json" '{"log-opts":{"max-size":"50m"}}' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')"
check "文件不存在" '{"a": 1}' "$(merge_json "$tmp/none.json" '{"a":1}' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))')"

echo "backup_expired"
while IFS='|' read -r keep names want; do
  check "保留 $keep 份 [$names]" "$want" "$(tr ' ' '\n' <<<"$names" | backup_expired "$keep" | xargs)"
done <<'EOF'
2|20261101-030000 20261103-030000 20261102-030000|20261101-030000
3|20261101-030000 20261102-030000|
1|20261101-030000 x 20261102-030000.partial 20261103-030000|20261101-030000
EOF

echo "飞书告警转发"
fs() { PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys, json; sys.path.insert(0, '$BASE_DIR/templates/alert'); import feishu; $1"; }
payload='{"alerts":[{"status":"firing","labels":{"alertname":"DiskUsageHigh","severity":"warning"},"annotations":{"summary":"磁盘 / 已用 90%"}},{"status":"resolved","labels":{"alertname":"ContainerDown"},"annotations":{"summary":"x"}}]}'
sign=$(printf '' | openssl dgst -sha256 -hmac $'1700000000\nsec' -binary | base64)
while IFS='|' read -r name want code; do
  check "$name" "$want" "$(fs "$code")"
done <<EOF
告警与恢复合并为一条|h/[告警] DiskUsageHigh(warning): 磁盘 / 已用 90%/[恢复] ContainerDown: x|print(feishu.render(json.loads('$payload'), 'h').replace(chr(10), '/'))
无密钥不签名|False|print('sign' in feishu.message('t', '', 1700000000))
有密钥按飞书算法签名|$sign|print(feishu.message('t', 'sec', 1700000000)['sign'])
EOF

echo "pick_docker_repo（联网）"
detect_os
CLOUD=unknown
got=$(pick_docker_repo || echo NONE)
echo "  $OS_CODENAME -> $got"
[[ $got != NONE ]]; check "找到可用源" 0 $?

rm -rf "$tmp"
((fails == 0)) || { echo "$fails 项失败"; exit 1; }
echo "全部通过"
