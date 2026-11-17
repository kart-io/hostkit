# shellcheck shell=bash
# OTel Collector：接收本机容器 OTLP，采集主机/容器/Redis/Postgres/证书指标与容器日志；按已装组件生成配置

COMPONENTS+=("otel otel-collector http 13133 /")

otel_install()   { comp_install otel; }
otel_uninstall() { comp_undo otel; }
otel_purge()     { comp_purge otel; }

otel_docker_root() { docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker; }

otel_env() {
  echo "IMAGE=$OTEL_IMAGE"
  echo "HOST_NAME=$(hostname)"
  echo "DOCKER_CONTAINERS_DIR=$(otel_docker_root)/containers"
  # 采集 Redis/Postgres 指标用的账号，只给已安装的
  if comp_installed redis; then echo "REDIS_PASSWORD=$(cred_get REDIS_PASSWORD)"; fi
  if comp_installed postgres; then
    echo "POSTGRES_USER=$(cred_get POSTGRES_USER)"
    echo "POSTGRES_PASSWORD=$(cred_get POSTGRES_PASSWORD)"
  fi
}

otel_prepare() {
  [[ $(docker info -f '{{.LoggingDriver}}' 2>/dev/null) == json-file ]] \
    || warn "Docker 日志驱动不是 json-file，容器日志采集不到（先执行 make dockerconf）"
  render_otel_config
}

otel_post() { log "OTel Collector: 业务容器加入 $NETWORK_NAME 后发往 otel-collector:4317(gRPC)/4318(HTTP)"; }

# 只给已安装的后端配导出；没有后端的信号丢给 nop，保证 OTLP 端仍可接收
render_otel_config() {
  local vm=0 vl=0 redis=0 pg=0 tls=0 mrx=otlp dom
  comp_installed victoriametrics && vm=1
  comp_installed victorialogs && vl=1
  # 指标只在有 VM 时采集
  ((vm)) && comp_installed redis && redis=1
  ((vm)) && comp_installed postgres && pg=1
  ((vm)) && tls_on && tls=1
  ((vm)) && mrx+=", hostmetrics, docker_stats"
  ((redis)) && mrx+=", redis"
  ((pg)) && mrx+=", postgresql"
  ((tls)) && mrx+=", tlscheck"
  install -d -m 0755 "$DEPLOY_DIR/otel"
  {
    cat <<'EOF'
# 由 hostkit 根据已安装组件生成，勿手改
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
EOF
    ((vm)) && cat <<'EOF'
  hostmetrics:
    root_path: /hostfs
    collection_interval: 30s
    scrapers:
      cpu: {}
      load: {}
      memory:
        metrics:
          system.memory.utilization: {enabled: true}
      paging: {}
      disk: {}
      filesystem:
        metrics:
          system.filesystem.utilization: {enabled: true}
  # 本机所有容器的 CPU/内存/网络/重启次数；Docker 25 起最低 API 1.44
  docker_stats:
    endpoint: unix:///var/run/docker.sock
    api_version: "1.44"
    collection_interval: 30s
    metrics:
      container.restarts: {enabled: true}
      container.uptime: {enabled: true}
EOF
    ((redis)) && cat <<'EOF'
  redis:
    endpoint: redis:6379
    password: ${env:REDIS_PASSWORD}
    collection_interval: 30s
EOF
    ((pg)) && cat <<'EOF'
  postgresql:
    endpoint: postgres:5432
    transport: tcp
    username: ${env:POSTGRES_USER}
    password: ${env:POSTGRES_PASSWORD}
    collection_interval: 30s
    tls:
      insecure: true
EOF
    # 直接读每张证书文件（宿主机根目录挂在 /hostfs），不依赖域名解析，也不受 Nginx 是否在跑影响
    if ((tls)); then
      printf '  tlscheck:\n    collection_interval: 1h\n    targets:\n'
      for dom in $(certs); do printf '      - file_path: /hostfs%s/fullchain.pem\n' "$(cert_dir "$dom")"; done
    fi
    ((vl)) && cat <<'EOF'
  filelog/docker:
    include: [/var/lib/docker/containers/*/*-json.log]
    start_at: end
    include_file_path: true
    operators:
      - type: container
        format: docker
        add_metadata_from_filepath: false
EOF
    cat <<'EOF'

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  resource/host:
    attributes:
      - key: host.name
        value: ${env:HOST_NAME}
        action: upsert
  batch: {}

exporters:
  nop: {}
EOF
    ((vm)) && cat <<'EOF'
  otlphttp/victoriametrics:
    metrics_endpoint: http://victoriametrics:8428/vm/opentelemetry/v1/metrics
EOF
    ((vl)) && cat <<'EOF'
  otlphttp/victorialogs:
    logs_endpoint: http://victorialogs:9428/vl/insert/opentelemetry/v1/logs
EOF
    cat <<EOF

service:
  extensions: [health_check]
  pipelines:
    metrics:
      receivers: [$mrx]
      processors: [memory_limiter, resource/host, batch]
      exporters: [$( ((vm)) && echo otlphttp/victoriametrics || echo nop)]
    logs:
      receivers: [otlp$( ((vl)) && echo ", filelog/docker")]
      processors: [memory_limiter, resource/host, batch]
      exporters: [$( ((vl)) && echo otlphttp/victorialogs || echo nop)]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [nop]
EOF
  } | write_if_changed "$DEPLOY_DIR/otel/config.yaml"
}

# 配置或账号（.env）变了都要重建容器，restart 不会重读 .env
otel_sync() {
  local changed=1
  render_otel_config && changed=0
  comp_write_env otel && changed=0
  if ((changed == 0)) && comp_running otel; then
    ccompose otel up -d --quiet-pull --force-recreate 2>/dev/null
    comp_wait otel
    log "OTel Collector 采集配置已更新"
  fi
  return 0
}
