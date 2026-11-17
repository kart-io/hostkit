# shellcheck shell=bash
# PostgreSQL（仅 $NETWORK_NAME 内网可达）

COMPONENTS+=("postgres postgres exec pg_isready -q")
# 用户名只在首次初始化数据目录时生效，之后改需手工在库里处理
CREDENTIALS+=("postgres POSTGRES_USER     user postgres")
CREDENTIALS+=("postgres POSTGRES_PASSWORD password")

postgres_install()   { comp_install postgres; }
postgres_uninstall() { comp_undo postgres; }
postgres_purge()     { comp_purge postgres; }

postgres_env() {
  echo "IMAGE=$POSTGRES_IMAGE"
  echo "POSTGRES_USER=$(cred_get POSTGRES_USER)"
  echo "POSTGRES_PASSWORD=$(cred_get POSTGRES_PASSWORD)"
}

# POSTGRES_PASSWORD 只在初始化数据目录时生效；之后文件里的密码变了（手改或轮换），要 ALTER 到库里。
# 每次安装都同步一次（幂等），本地 socket 免密，不需要旧密码
postgres_apply_password() {
  local u p
  u=$(cred_get POSTGRES_USER); p=$(cred_get POSTGRES_PASSWORD)
  ccompose postgres exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$u" -d postgres -v u="$u" -v p="$p" \
    <<<"ALTER USER :\"u\" PASSWORD :'p';" >/dev/null \
    || die "同步 Postgres 密码失败；若改过 POSTGRES_USER：用户名只在首次初始化时生效，需手工在库里处理"
}

postgres_post() {
  postgres_apply_password
  log "Postgres: postgres:5432，账号密码见 $(cred_file) 的 POSTGRES_USER/POSTGRES_PASSWORD"
}

postgres_rotate() {
  comp_running postgres || die "Postgres 未运行，新密码已写入 $(cred_file)，启动后执行 make postgres 生效"
  postgres_apply_password
  comp_write_env postgres || true  # 只同步 .env，不重建容器
  sync_integrations                # OTel 用同一账号采集指标
}

postgres_backup() {
  ccompose postgres exec -T postgres pg_dumpall -U "$(cred_get POSTGRES_USER)" </dev/null | gzip >"$1/postgres.sql.gz"
}

# 在新初始化的空库上导入；导出里含当前超级用户，「已存在」类报错可忽略
postgres_restore() {
  local errs
  restore_aside postgres
  comp_install postgres
  errs=$(gunzip -c "$1" | ccompose postgres exec -T postgres psql -q -U "$(cred_get POSTGRES_USER)" -d postgres 2>&1 >/dev/null \
    | grep ERROR | grep -v 'already exists') || true
  [[ -z $errs ]] || { echo "$errs" >&2; die "导入有报错，原数据目录保留为 data.before-restore-*"; }
  postgres_apply_password  # 导出里带着备份时的密码
}
