# shellcheck shell=bash
# /swapfile + vm.swappiness

# 推荐 swap 大小（MB）：≤2G 内存给 2 倍，≤8G 给 1 倍，更大给 4G；不超过根分区可用空间的 25%
recommend_swap_mb() {
  local mem=$1 free_mb=$2 size
  if ((mem <= 2048)); then size=$((mem * 2))
  elif ((mem <= 8192)); then size=$mem
  else size=4096
  fi
  ((size > free_mb / 4)) && size=$((free_mb / 4))
  echo "$size"
}

swap_install() {
  if [[ -n $(swapon --noheadings --show 2>/dev/null) ]]; then
    log "已有 swap，跳过: $(swapon --noheadings --show | awk '{print $1" "$3}' | paste -sd ',')"
  else
    local size fs free_mb
    fs=$(stat -f -c %T /)
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    size=$SWAP_SIZE_MB
    [[ $size == auto ]] && size=$(recommend_swap_mb "$(mem_mb)" "$free_mb")
    if ((size <= 0)); then
      log "swap 大小为 0，跳过"
    elif [[ $fs == btrfs ]]; then
      warn "根分区是 btrfs，swapfile 需要特殊处理，跳过"
    else
      log "创建 /swapfile ${size}MB（内存 $(mem_mb)MB，根分区可用 ${free_mb}MB）"
      fallocate -l "${size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size" status=none
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
      state_set swapfile-created
    fi
  fi
  if write_if_changed /etc/sysctl.d/99-"$PROJECT"-swap.conf <<<'vm.swappiness=10'; then
    sysctl -q -p /etc/sysctl.d/99-"$PROJECT"-swap.conf
  fi
}

swap_uninstall() {
  if state_has swapfile-created; then
    swapon --noheadings --show=NAME | grep -qx /swapfile && swapoff /swapfile
    sed -i '\#^/swapfile none swap sw 0 0$#d' /etc/fstab
    rm -f /swapfile
    state_del swapfile-created
    log "已删除 /swapfile"
  else
    log "swap 不是本脚本创建的，保留"
  fi
  rm -f /etc/sysctl.d/99-"$PROJECT"-swap.conf
  sysctl -q --system >/dev/null 2>&1 || true
}
