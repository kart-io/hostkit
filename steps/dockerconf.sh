# shellcheck shell=bash
# /etc/docker/daemon.json：日志轮转、镜像加速、地址池

# Docker 地址池候选，按顺序选第一个与宿主机网段、AVOID_CIDRS 都不重叠的
DOCKER_POOL_CANDIDATES=(172.17.0.0/16 10.200.0.0/16 192.168.128.0/18)

pick_docker_pool() {
  local used
  used="$(host_cidrs) ${AVOID_CIDRS}"
  python3 - "$used" "${DOCKER_POOL_CANDIDATES[@]}" <<'PY'
import ipaddress, sys
used = [ipaddress.ip_network(c, strict=False) for c in sys.argv[1].split()
        if c and not c.startswith(("0.0.0.0", "127.", "169.254."))]
for cand in sys.argv[2:]:
    net = ipaddress.ip_network(cand)
    if not any(net.overlaps(u) for u in used):
        print(cand); sys.exit(0)
sys.exit(1)
PY
}

# 合并 JSON 补丁到 daemon.json 并输出结果；值为 null 的键会被删除
merge_json() {
  python3 - "$1" "$2" <<'PY'
import json, os, sys
path, patch = sys.argv[1], json.loads(sys.argv[2])
cur = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        cur = json.load(f)
for k, v in patch.items():
    if v is None:
        cur.pop(k, None)
    else:
        cur[k] = v
print(json.dumps(cur, indent=2, sort_keys=True))
PY
}

docker_hub_reachable() {
  local code
  code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' https://registry-1.docker.io/v2/) || true
  [[ $code == 401 || $code == 200 ]]
}

# 日志轮转 + 镜像加速 + 不与宿主机冲突的地址池
dockerconf_install() {
  local f=/etc/docker/daemon.json patch mirrors pool
  patch=$(printf '{"log-driver":"json-file","log-opts":{"max-size":"%s","max-file":"%s"}}' \
    "$DOCKER_LOG_MAX_SIZE" "$DOCKER_LOG_MAX_FILE")

  if [[ -n $REGISTRY_MIRRORS ]]; then
    mirrors=$REGISTRY_MIRRORS
  elif ! docker_hub_reachable; then
    case $CLOUD in
      tencent) mirrors=https://mirror.ccs.tencentyun.com ;;
      *) warn "Docker Hub 不可达，且未配置 REGISTRY_MIRRORS，后续拉镜像可能失败" ;;
    esac
  fi
  if [[ -n ${mirrors:-} ]]; then
    log "镜像加速: $mirrors"
    patch=$(python3 -c 'import json,sys; p=json.loads(sys.argv[1]); p["registry-mirrors"]=sys.argv[2].split(); print(json.dumps(p))' "$patch" "$mirrors")
  fi

  # 已有地址池说明之前配置过，不改，避免已有网络与新池不一致
  if [[ ! -f $f ]] || ! grep -q '"default-address-pools"' "$f"; then
    pool=$(pick_docker_pool) || die "候选地址池 ${DOCKER_POOL_CANDIDATES[*]} 都与宿主机网段冲突，请在 config.env 设置 AVOID_CIDRS 或修改候选"
    log "Docker 地址池: $pool"
    patch=$(python3 -c 'import json,sys; p=json.loads(sys.argv[1]); p["default-address-pools"]=[{"base":sys.argv[2],"size":24}]; print(json.dumps(p))' "$patch" "$pool")
  fi

  local merged
  merged=$(merge_json "$f" "$patch")
  if dockerd --help 2>/dev/null | grep -q -- '--validate'; then
    dockerd --validate --config-file <(echo "$merged") >/dev/null || die "daemon.json 校验失败"
  fi
  backup_once "$f"
  if write_if_changed "$f" <<<"$merged"; then
    log "重启 Docker 使配置生效（日志轮转仅对新建容器生效）"
    systemctl restart docker
  else
    log "daemon.json 无变化"
  fi
}

dockerconf_uninstall() {
  if restore_backup /etc/docker/daemon.json && systemctl is-active --quiet docker; then
    log "重启 Docker"
    systemctl restart docker
  fi
  return 0
}
