# shellcheck shell=bash
# VictoriaLogs 日志存储；装后 OTel 自动导出日志、Traefik 自动出现 /vl/

COMPONENTS+=("victorialogs victorialogs http 9428 /vl/health")
SITE_SERVICES+=("victorialogs victorialogs /vl/select/vmui/")

victorialogs_install()   { comp_install victorialogs; }
victorialogs_uninstall() { comp_undo victorialogs; }
victorialogs_purge()     { comp_purge victorialogs; }

victorialogs_env()    { echo "IMAGE=$VL_IMAGE"; echo "RETENTION=$VL_RETENTION"; }

victorialogs_post()    { log "VictoriaLogs: 内网 http://victorialogs:9428/vl/，外部经 Traefik /vl/"; }
