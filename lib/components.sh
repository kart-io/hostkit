# shellcheck shell=bash
# 通用组件框架：每个组件是 $DEPLOY_DIR/<组件>/ 下独立的 compose 项目，接入 $NETWORK_NAME，
# compose 模板在 templates/<组件>/。组件在 steps/<组件>.sh 里登记 COMPONENTS 并实现钩子：
#   <n>_env      输出 .env 内容（必需，至少含 IMAGE=）
#   <n>_prepare  渲染配置文件；有变化返回 0，会触发容器重建
#   <n>_post     安装后执行
#   <n>_postundo 卸载后执行
#   <n>_rotate   轮换密码后让新密码生效（不实现则重跑安装，按新 .env 重建容器）
#   <n>_sync     任一组件装/卸后执行，按「当前装了什么」更新自身配置（如 OTel 导出、Nginx 入口）
#   <n>_backup   备份到给定目录，文件名用 <n>.*（make backup 定时调用）
#   <n>_restore  从给定的备份文件恢复（make restore-<n>）

# 组件 compose服务名(即 base-net 内主机名) 就绪检查(http 端口 路径 | exec 命令)
COMPONENTS=()
# 经 Nginx 暴露、带 Basic Auth 的观测后端：组件 路径 内网上游
OBS_ROUTES=()
# 经 Nginx 公开暴露（无鉴权）的应用：组件 路径 内网上游
WEB_ROUTES=()

# 卸载时 Docker 可能已被卸载或没运行
docker_up() { command -v docker &>/dev/null && docker info &>/dev/null; }
ccompose() { local n=$1; shift; docker compose --project-directory "$DEPLOY_DIR/$n" "$@"; }
comp_installed() { state_has "comp-$1"; }
comp_running() { comp_installed "$1" && docker_up && [[ -n $(ccompose "$1" ps -q 2>/dev/null) ]]; }
env_get() { [[ ! -f $1 ]] || sed -n "s/^$2=//p" "$1" | tail -1; }
# 有变化返回 0
comp_write_env() { { echo "NETWORK_NAME=$NETWORK_NAME"; "${1}_env"; } | write_if_changed "$DEPLOY_DIR/$1/.env" 0600; }

comp_row() { local line; for line in "${COMPONENTS[@]}"; do [[ $line == "$1 "* ]] && { echo "$line"; return; }; done; die "未登记的组件: $1"; }

comp_ip() {
  local cid; cid=$(ccompose "$1" ps -q "$2" 2>/dev/null) && [[ -n $cid ]] || return 1
  docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK_NAME\").IPAddress}}" "$cid" 2>/dev/null
}

# 就绪检查一次；http 走宿主机到容器 IP，不依赖端口映射
comp_probe() {
  local n=$1 svc kind rest ip port path
  read -r _ svc kind rest <<<"$(comp_row "$n")"
  if [[ $kind == http ]]; then
    read -r port path <<<"$rest"
    ip=$(comp_ip "$n" "$svc") && [[ -n $ip ]] && curl -fs --max-time 2 -o /dev/null "http://$ip:$port$path"
  else
    # shellcheck disable=SC2086
    ccompose "$n" exec -T "$svc" $rest &>/dev/null </dev/null
  fi
}

comp_wait() {
  local i svc
  for i in {1..30}; do comp_probe "$1" && return 0; sleep 2; done
  read -r _ svc _ <<<"$(comp_row "$1")"
  ccompose "$1" logs --tail 20 "$svc" >&2 || true
  die "$1 未就绪"
}

comp_install() {
  local n=$1 d=$DEPLOY_DIR/$1 recreate=()
  docker_up || die "Docker 未运行，先执行 make docker"
  docker network inspect "$NETWORK_NAME" &>/dev/null || die "网络 $NETWORK_NAME 不存在，先执行 make network"
  install -d -m 0755 "$d"
  write_if_changed "$d/docker-compose.yml" <"$BASE_DIR/templates/$n/docker-compose.yml" && recreate=(--force-recreate)
  cred_prepare "$n"
  comp_write_env "$n" && recreate=(--force-recreate)
  if declare -F "${n}_prepare" >/dev/null && "${n}_prepare"; then recreate=(--force-recreate); fi
  ccompose "$n" up -d --quiet-pull --remove-orphans "${recreate[@]}"
  comp_wait "$n"
  state_set "comp-$n"
  log "$n 运行正常"
  if declare -F "${n}_post" >/dev/null; then "${n}_post"; fi
  sync_integrations
}

comp_undo() {
  local n=$1
  if [[ -f $DEPLOY_DIR/$n/docker-compose.yml ]] && docker_up && [[ -n $(ccompose "$n" --profile '*' ps -aq 2>/dev/null) ]]; then
    ccompose "$n" --profile '*' down --remove-orphans
    log "$n 已停止（数据保留在 $DEPLOY_DIR/$n）"
  fi
  state_del "comp-$n"
  if declare -F "${n}_postundo" >/dev/null; then "${n}_postundo"; fi
  sync_integrations
}

comp_purge() {
  local n=$1 img
  if docker_up && [[ -f $DEPLOY_DIR/$n/.env ]]; then
    while read -r img; do
      docker image rm "$img" >/dev/null 2>&1 || true
    done < <(sed -nE 's/^([A-Z_]+_)?IMAGE=//p' "$DEPLOY_DIR/$n/.env")
  fi
  safe_rm_dir "$DEPLOY_DIR/$n"
  cred_purge "$n"
}

# 组件之间的接线由各组件的 <n>_sync 按「当前装了什么」推导
sync_integrations() {
  local line n
  for line in "${COMPONENTS[@]}"; do
    read -r n _ <<<"$line"
    if comp_installed "$n" && declare -F "${n}_sync" >/dev/null; then "${n}_sync"; fi
  done
  return 0
}
