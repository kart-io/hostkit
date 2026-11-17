# shellcheck shell=bash
# 定时备份：systemd timer 调 install.sh backup-run，逐个调用已运行组件的 <组件>_backup。
# 每次一个目录 $BACKUP_DIR/<时间>/，保留最近 BACKUP_KEEP 份；结果推送到 VM 供告警

BACKUP_UNIT=/etc/systemd/system/$PROJECT-backup

backup_install() {
  install -d -m 0700 "$BACKUP_DIR"
  write_if_changed "$BACKUP_UNIT.service" <<EOF || true
[Unit]
Description=Backup $PROJECT components
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$BASE_DIR/install.sh backup-run
EOF
  write_if_changed "$BACKUP_UNIT.timer" <<EOF || true
[Unit]
Description=Backup $PROJECT components (timer)

[Timer]
OnCalendar=$BACKUP_ONCALENDAR
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$PROJECT"-backup.timer >/dev/null 2>&1
  state_set backup
  log "备份: $BACKUP_DIR，保留 $BACKUP_KEEP 份，下次 $(systemctl show -P NextElapseUSecRealtime "$PROJECT"-backup.timer)"
  [[ -n $BACKUP_POST_HOOK ]] || warn "备份只在本机，磁盘损坏会一起丢；建议配置 BACKUP_POST_HOOK 复制到异地"
  sync_integrations  # 备份告警规则
}

backup_uninstall() {
  systemctl disable --now "$PROJECT"-backup.timer >/dev/null 2>&1 || true
  rm -f "$BACKUP_UNIT".{service,timer}
  systemctl daemon-reload
  state_del backup
  log "已停用定时备份（已有备份保留在 $BACKUP_DIR）"
  sync_integrations
}

backup_purge() { safe_rm_dir "$BACKUP_DIR"; }
backup_purge_hint() { echo "全部备份：$BACKUP_DIR"; }

backup_list() {
  local d
  for d in "$BACKUP_DIR"/*/; do
    d=${d%/}; d=${d##*/}
    if [[ $d =~ ^[0-9]{8}-[0-9]{6}$ ]]; then echo "$d"; fi
  done
}

# 从 stdin 的备份名中选出超过保留份数的（最旧的）
backup_expired() { grep -E '^[0-9]{8}-[0-9]{6}$' | sort | head -n "-$1"; }

# 备份与恢复互斥
backup_lock() {
  exec 9>/run/"$PROJECT"-backup.lock
  flock -n 9 || die "另一个备份/恢复正在进行"
}

# 推送到 VM：每个组件成功与否 + 本次运行时间
backup_report() {
  local ip body=$1
  ip=$(comp_running victoriametrics && comp_ip victoriametrics victoriametrics) || return 0
  body+="${METRIC_PREFIX}_backup_last_run_timestamp_seconds $(date +%s)"$'\n'
  curl -fsS --max-time 5 -o /dev/null --data-binary "$body" "http://$ip:8428/vm/api/v1/import/prometheus" \
    || warn "备份结果推送到 VictoriaMetrics 失败"
}

backup_run() {
  local d line n ok=1 metrics="" old
  backup_lock
  install -d -m 0700 "$BACKUP_DIR"
  rm -rf "$BACKUP_DIR"/*.partial  # 上次中断留下的
  d=$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)
  install -d -m 0700 "$d.partial"
  for line in "${COMPONENTS[@]}"; do
    read -r n _ <<<"$line"
    { comp_running "$n" && has_fn "${n}_backup"; } || continue
    log "备份 $n"
    # 在 if 里 set -e 不生效，各 _backup 需自己用 && 串起来返回真实结果
    if "${n}_backup" "$d.partial"; then
      metrics+="${METRIC_PREFIX}_backup_success{component=\"$n\"} 1"$'\n'
    else
      warn "$n 备份失败"; ok=0
      metrics+="${METRIC_PREFIX}_backup_success{component=\"$n\"} 0"$'\n'
      rm -f "$d.partial/$n".*
    fi
  done
  # 恢复时要用备份当时的账号密码
  if [[ -f $(cred_file) ]]; then cp -p "$(cred_file)" "$d.partial/"; fi
  mv "$d.partial" "$d"
  while read -r old; do safe_rm_dir "$BACKUP_DIR/$old"; done < <(backup_list | backup_expired "$BACKUP_KEEP")
  if [[ -n $BACKUP_POST_HOOK ]]; then
    log "执行 BACKUP_POST_HOOK"
    if bash -c "$BACKUP_POST_HOOK" _ "$d"; then
      metrics+="${METRIC_PREFIX}_backup_success{component=\"post_hook\"} 1"$'\n'
    else
      warn "BACKUP_POST_HOOK 失败"; ok=0
      metrics+="${METRIC_PREFIX}_backup_success{component=\"post_hook\"} 0"$'\n'
    fi
  fi
  backup_report "$metrics"
  ((ok)) || die "部分备份失败，见上方日志"
  log "备份完成: $d（$(du -sh "$d" | cut -f1)）"
}

# 停组件，原 data 改名保留（确认恢复无误后手工删除），换成空目录
restore_aside() {
  local d=$DEPLOY_DIR/$1
  ccompose "$1" down
  if [[ -d $d/data ]]; then mv "$d/data" "$d/data.before-restore-$(date +%Y%m%d-%H%M%S)"; fi
  install -d -m 0755 "$d/data"
}

# 组件 [备份名]；不指定时用含该组件的最新一份
backup_restore() {
  local n=${1:-} id=${2:-} line c can=() f
  for line in "${COMPONENTS[@]}"; do
    read -r c _ <<<"$line"
    has_fn "${c}_restore" && can+=("$c")
  done
  [[ -n $n && " ${can[*]} " == *" $n "* ]] || die "用法: restore <组件> [备份名]；支持: ${can[*]}"
  comp_running "$n" || die "$n 未运行，先执行 make $n（新机器恢复：先把备份里的 credentials.env 放到 $(cred_file)）"
  if [[ -z $id ]]; then
    for id in $(backup_list | tac) ""; do compgen -G "$BACKUP_DIR/$id/$n.*" >/dev/null && break; done
    [[ -n $id ]] || die "$BACKUP_DIR 下没有 $n 的备份"
  fi
  f=$(compgen -G "$BACKUP_DIR/$id/$n.*" | head -1) || die "备份 $id 中没有 $n（现有备份: $(backup_list | xargs)）"
  backup_lock
  confirm "用 $f 覆盖 $n 当前数据？原数据目录会在 $DEPLOY_DIR/$n 下改名为 *.before-restore-<时间> 保留"
  "${n}_restore" "$f"
  log "$n 已恢复到备份 $id；确认无误后可删除 $DEPLOY_DIR/$n 下的 *.before-restore-*"
}
