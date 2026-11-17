# shellcheck shell=bash
# Redis（仅 $NETWORK_NAME 内网可达）

COMPONENTS+=("redis redis exec redis-cli ping")
CREDENTIALS+=("redis REDIS_PASSWORD password")

redis_install()   { comp_install redis; }
redis_uninstall() { comp_undo redis; }
redis_purge()     { comp_purge redis; }

redis_env() {
  echo "IMAGE=$REDIS_IMAGE"
  echo "REDIS_PASSWORD=$(cred_get REDIS_PASSWORD)"
}

# Redis 官方建议，避免 BGSAVE fork 失败
redis_post() {
  write_if_changed /etc/sysctl.d/99-"$PROJECT"-redis.conf <<<'vm.overcommit_memory=1' \
    && sysctl -q -p /etc/sysctl.d/99-"$PROJECT"-redis.conf
  log "Redis: redis:6379，密码见 $(cred_file) 的 REDIS_PASSWORD"
}

redis_postundo() { rm -f /etc/sysctl.d/99-"$PROJECT"-redis.conf; }

redis_backup() {
  local d=$DEPLOY_DIR/redis/data
  ccompose redis exec -T redis redis-cli --rdb /data/backup.rdb >/dev/null </dev/null \
    && gzip -c "$d/backup.rdb" >"$1/redis.rdb.gz" && rm -f "$d/backup.rdb"
}

redis_aof_ready() { docker exec "$1" redis-cli info persistence | tr -d '\r' | grep -c -E '^(aof_enabled:1|aof_rewrite_in_progress:0|aof_rewrite_scheduled:0)$'; }

# 开着 AOF 时 Redis 只从 AOF 加载，空目录放 dump.rdb 会以空库启动：
# 先关 AOF 临时启动载入 RDB，在线开启 AOF 等它重写完，再正常启动
redis_restore() {
  local c=base-redis-restore i
  restore_aside redis
  gunzip -c "$1" >"$DEPLOY_DIR/redis/data/dump.rdb"
  ccompose redis run -d --no-deps --name "$c" redis \
    redis-server --requirepass "$(cred_get REDIS_PASSWORD)" --appendonly no >/dev/null
  for i in {1..60}; do [[ $(docker exec "$c" redis-cli ping 2>/dev/null) == PONG ]] && break; sleep 1; done
  docker exec "$c" redis-cli config set appendonly yes >/dev/null
  for i in {1..120}; do
    [[ $(redis_aof_ready "$c") == 3 ]] && break
    ((i == 120)) && { docker rm -f "$c" >/dev/null; die "等待 AOF 重写超时"; }
    sleep 1
  done
  # 不用 run --rm：异步删除会和 up --remove-orphans 清理同一个容器冲突
  docker stop "$c" >/dev/null && docker rm "$c" >/dev/null
  comp_install redis
  log "Redis 键数: $(ccompose redis exec -T redis redis-cli dbsize)"
}
