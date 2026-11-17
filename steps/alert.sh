# shellcheck shell=bash
# 告警：vmalert 按规则查 VictoriaMetrics → Alertmanager 分组去重 → 飞书机器人

COMPONENTS+=("alert vmalert http 8880 /vmalert/health")
OBS_ROUTES+=("alert /vmalert/ vmalert:8880")
OBS_ROUTES+=("alert /am/ alertmanager:9093")

# 规则文件 templates/alert/rules/<名称>.yml 与启用条件（命令）；containers 规则按已装组件生成
ALERT_RULES=(
  "host   comp_installed otel"
  "backup state_has backup"
  "tls    tls_on"
)

alert_install() {
  comp_installed victoriametrics || die "告警依赖 VictoriaMetrics，先执行 make victoriametrics"
  comp_install alert
}
alert_uninstall() { comp_undo alert; }
alert_purge()     { comp_purge alert; }

alert_env() {
  echo "IMAGE=$VMALERT_IMAGE"
  echo "ALERTMANAGER_IMAGE=$ALERTMANAGER_IMAGE"
  echo "PYTHON_IMAGE=$PYTHON_IMAGE"
  echo "HOST_NAME=$(hostname)"
  echo "FEISHU_WEBHOOK=$ALERT_FEISHU_WEBHOOK"
  echo "FEISHU_SECRET=$ALERT_FEISHU_SECRET"
}

# 容器不在运行：只能逐个按名字查 absent，所以按已装组件生成。
# absent 类规则在刚装好、还没有数据时也成立，靠 for 跳过启动期
alert_containers_rules() {
  local line n svc
  echo "$GEN_HEADER"
  cat <<'EOF'
groups:
  - name: containers
    rules:
      - alert: ContainerRestarting
        expr: increase(container_restarts_total{container_name=~"base-.+"}[15m]) > 0
        labels: {severity: warning}
        annotations:
          summary: '容器 {{ $labels.container_name }} 15 分钟内重启了 {{ $value }} 次'
EOF
  for line in "${COMPONENTS[@]}"; do
    read -r n svc _ <<<"$line"
    comp_installed "$n" || continue
    cat <<EOF
      - alert: ContainerDown
        expr: absent_over_time(container_uptime_seconds{container_name="base-$n-$svc-1"}[2m])
        for: 3m
        labels: {severity: critical, component: $n}
        annotations:
          summary: '容器 base-$n-$svc-1 已停止超过 5 分钟'
EOF
  done
}

# 有变化返回 0
alert_render_rules() {
  local d=$DEPLOY_DIR/alert/rules line name check f changed=1
  install -d -m 0755 "$d"
  for line in "${ALERT_RULES[@]}" "containers comp_installed otel"; do
    read -r name check <<<"$line"
    f=$d/$name.yml
    # shellcheck disable=SC2086
    if $check; then
      if [[ $name == containers ]]; then alert_containers_rules
      else sed -e "s/__METRIC_PREFIX__/$METRIC_PREFIX/g" -e "s/__PROJECT__/$PROJECT/g" "$BASE_DIR/templates/alert/rules/$name.yml"
      fi \
        | write_if_changed "$f" && changed=0
    elif [[ -f $f ]]; then
      rm -f "$f"; changed=0
    fi
  done
  return $changed
}

alert_prepare() {
  local d=$DEPLOY_DIR/alert changed=1 f
  # Alertmanager 以 nobody 运行
  install -d -m 0755 -o 65534 -g 65534 "$d/am-data"
  for f in alertmanager.yml feishu.py; do
    write_if_changed "$d/$f" <"$BASE_DIR/templates/alert/$f" && changed=0
  done
  alert_render_rules || true  # 规则启动时加载，不需要重建
  return $changed
}

alert_post() {
  local ip i
  for i in {1..15}; do
    ip=$(comp_ip alert alertmanager) && curl -fs --max-time 2 -o /dev/null "http://$ip:9093/am/-/ready" && break
    ((i == 15)) && die "Alertmanager 未就绪"
    sleep 2
  done
  if [[ -z $ALERT_FEISHU_WEBHOOK ]]; then
    warn "未配置 ALERT_FEISHU_WEBHOOK，告警只打印到 docker logs base-alert-alert-feishu-1；配置后再执行 make alert"
  fi
  log "告警: 规则 $DEPLOY_DIR/alert/rules，外部经 Nginx /vmalert/（规则状态）、/am/（Alertmanager）"
}

alert_sync() {
  comp_installed victoriametrics || warn "VictoriaMetrics 未安装，告警不会工作"
  if alert_render_rules && comp_running alert; then
    local ip
    if ip=$(comp_ip alert vmalert) && curl -fs --max-time 5 -o /dev/null "http://$ip:8880/vmalert/-/reload"; then
      log "告警规则已更新"
    else
      warn "vmalert 重载规则失败，执行 make alert 重试"
    fi
  fi
  return 0
}
