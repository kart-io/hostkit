# shellcheck shell=bash
# Docker 网络检查：ip_forward、网段冲突、拉镜像跑容器

# 输出 used 中与 nets 重叠的网段
overlapping() {
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
nets = [ipaddress.ip_network(c, strict=False) for c in sys.argv[1].split()]
used = [ipaddress.ip_network(c, strict=False) for c in sys.argv[2].split()
        if not c.startswith(("0.0.0.0", "127.", "169.254."))]
for n in nets:
    for u in used:
        if n.overlaps(u):
            print(f"{n} <-> {u}")
PY
}

netcheck_install() {
  local ok=1 subnets conflicts
  systemctl is-active --quiet docker || die "Docker 未运行"
  [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || { warn "net.ipv4.ip_forward=0，容器无法出网"; ok=0; }

  subnets=$(docker network ls -q --filter driver=bridge \
    | xargs -r docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | xargs)
  log "Docker bridge 网段: ${subnets:-无}"
  conflicts=$(overlapping "$subnets" "$(host_cidrs | xargs) $AVOID_CIDRS")
  if [[ -n $conflicts ]]; then
    warn "Docker 网段与宿主机/AVOID_CIDRS 冲突（会导致访问对应内网不通）："
    printf '%s\n' "$conflicts" | sed 's/^/    /' >&2
    ok=0
  fi

  if docker run --rm hello-world >/dev/null 2>&1; then
    log "镜像拉取与容器运行正常"
  else
    warn "docker run hello-world 失败，检查镜像加速（REGISTRY_MIRRORS）或出网"
    ok=0
  fi
  ((ok)) && log "Docker 网络检查通过"
  return 0
}
