# shellcheck shell=bash
# make status：组件运行与升级状态、证书、备份、磁盘一览（只读）

status_row() { printf '%-16s %-44s %7s  %s\n' "$@"; }

status_components() {
  local line n img want size st
  # printf 按字节算宽度，中文每字 3 字节只占 2 列，表头宽度相应加大
  printf '%-18s %-46s %9s  %s\n' 组件 镜像 数据 状态
  for line in "${COMPONENTS[@]}"; do
    read -r n _ <<<"$line"
    if ! comp_installed "$n"; then status_row "$n" - - 未安装; continue; fi
    img=$(env_get "$DEPLOY_DIR/$n/.env" IMAGE)
    # 不生成密码，只取 versions.env 里的期望镜像
    # shellcheck disable=SC2329
    want=$( (cred_get() { :; }; "${n}_env") 2>/dev/null | sed -n 's/^IMAGE=//p')
    size=$(du -sh "$DEPLOY_DIR/$n" 2>/dev/null | cut -f1)
    if ! comp_running "$n"; then st=已停止
    elif comp_probe "$n"; then st=健康
    else st=异常
    fi
    [[ $want == "$img" ]] || st+="，待升级到 $want（make $n）"
    status_row "$n" "$img" "$size" "$st"
  done
}

# 站点与证书一览
status_sites() {
  local acme_f doms d
  acme_f="$DEPLOY_DIR/traefik/acme/acme.json"
  if [[ -f $acme_f && -s $acme_f ]]; then
    doms=$(grep -o '"main": "[^"]*"' "$acme_f" 2>/dev/null | cut -d'"' -f4 || true)
    if [[ -n $doms ]]; then
      while read -r d; do
        [[ -n $d ]] && echo "站点 (TLS 正常): https://$d"
      done <<<"$doms"
      return
    fi
  fi
  if declare -F sites >/dev/null && [[ -n $(sites) ]]; then
    while read -r dom s; do
      echo "站点: $dom → $s"
    done < <(sites)
  else
    echo "网关: Traefik 声明式路由生效中 (按容器 labels 自动管理)"
  fi
}

status_backup() {
  local last age result
  if ! state_has backup; then echo "备份: 未启用（make backup）"; return; fi
  last=$(backup_list | tail -1)
  result=$(systemctl show -P Result "$PROJECT"-backup.service 2>/dev/null)
  if [[ -n $last ]]; then
    age=$(( ($(date +%s) - $(date -d "${last:0:8} ${last:9:2}:${last:11:2}:${last:13:2}" +%s)) / 3600 ))
    echo "备份: 最近 $last（${age} 小时前），共 $(backup_list | wc -l) 份，上次运行结果 ${result:-未知}"
  else
    echo "备份: 还没有备份（make backup-now 立即执行）"
  fi
  echo "      目录 $BACKUP_DIR，下次 $(systemctl show -P NextElapseUSecRealtime "$PROJECT"-backup.timer 2>/dev/null)"
}

status_report() {
  if docker_up; then echo "Docker: $(docker version -f '{{.Server.Version}}' 2>/dev/null)"
  else echo "Docker: 未运行"
  fi
  echo
  status_components
  echo
  status_sites
  status_backup
  if [[ -f $(cred_file) ]]; then echo "账号密码: $(cred_file)"; fi
  echo
  df -h --output=target,size,used,avail,pcent / "$DEPLOY_DIR" 2>/dev/null | awk 'NR == 1 || !seen[$1]++' || true
}
