# shellcheck shell=bash
# 所有组件共用的外部网络 $NETWORK_NAME

network_install() {
  if docker network inspect "$NETWORK_NAME" &>/dev/null; then
    log "网络 $NETWORK_NAME 已存在: $(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME")"
  else
    docker network create --driver bridge "$NETWORK_NAME" >/dev/null
    log "已创建网络 $NETWORK_NAME: $(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME")"
  fi
}

network_uninstall() {
  docker_up && docker network inspect "$NETWORK_NAME" &>/dev/null || return 0
  if docker network rm "$NETWORK_NAME" >/dev/null 2>&1; then
    log "已删除网络 $NETWORK_NAME"
  else
    warn "网络 $NETWORK_NAME 仍有容器在用，保留"
  fi
}
