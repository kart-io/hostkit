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

status_tls() {
  local dom end days off
  [[ -n $DOMAINS ]] || { echo "证书: 未配置 DOMAINS"; return; }
  state_has tls-disabled && off="，已停用（make tls 启用）"
  for dom in $DOMAINS; do
    if ! cert_has "$dom"; then echo "证书: $dom 未签发（make tls）"; continue; fi
    end=$(openssl x509 -enddate -noout -in "$(cert_dir "$dom")/fullchain.pem" | cut -d= -f2)
    days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
    echo "证书: $dom 剩余 $days 天$off"
  done
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
  status_tls
  status_backup
  if [[ -f $(cred_file) ]]; then echo "账号密码: $(cred_file)"; fi
  echo
  df -h --output=target,size,used,avail,pcent / "$DEPLOY_DIR" 2>/dev/null | awk 'NR == 1 || !seen[$1]++' || true
}
