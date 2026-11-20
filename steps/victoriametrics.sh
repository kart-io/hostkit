# shellcheck shell=bash
# VictoriaMetrics 指标存储；装后 OTel 自动导出指标、Traefik 自动出现 /vm/

COMPONENTS+=("victoriametrics victoriametrics http 8428 /vm/health")
SITE_SERVICES+=("victoriametrics victoriametrics /vm/")

victoriametrics_install()   { comp_install victoriametrics; }
victoriametrics_uninstall() { comp_undo victoriametrics; }
victoriametrics_purge()     { comp_purge victoriametrics; }

victoriametrics_env() { echo "IMAGE=$VM_IMAGE"; echo "RETENTION=$VM_RETENTION"; }

victoriametrics_post() { log "VictoriaMetrics: 内网 http://victoriametrics:8428/vm/，外部经 Traefik /vm/"; }

victoriametrics_backup() {
  local ip snap rc
  ip=$(comp_ip victoriametrics victoriametrics) \
    && snap=$(curl -fsS --max-time 120 "http://$ip:8428/vm/snapshot/create" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["snapshot"])') || return 1
  # 快照由指向数据分区的相对符号链接组成，-h 打包实际文件
  tar -C "$DEPLOY_DIR/victoriametrics/data/snapshots/$snap" -chzf "$1/victoriametrics.tar.gz" .
  rc=$?
  curl -fsS -o /dev/null "http://$ip:8428/vm/snapshot/delete?snapshot=$snap" || true
  return $rc
}

victoriametrics_restore() {
  restore_aside victoriametrics
  tar -C "$DEPLOY_DIR/victoriametrics/data" -xzf "$1"
  comp_install victoriametrics
}
