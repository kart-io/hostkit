# shellcheck shell=bash
# Docker CE + compose 插件；卸载只处理本脚本装的 Docker

# 云厂商匹配的镜像源先试；都不通再走 any
DOCKER_REPO_CANDIDATES=(
  "tencent https://mirrors.cloud.tencent.com/docker-ce"
  "aliyun  https://mirrors.aliyun.com/docker-ce"
  "huawei  https://mirrors.huaweicloud.com/docker-ce"
  "any     https://download.docker.com"
  "any     https://mirrors.aliyun.com/docker-ce"
  "any     https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
)

# 新发布的 Ubuntu 在 Docker 源上线前，回退到最近的 LTS
DOCKER_CODENAME_FALLBACK=noble

# 输出 "<repo> <codename>"
pick_docker_repo() {
  local codenames=("$OS_CODENAME") pass line cloud url cn
  [[ $OS_CODENAME != "$DOCKER_CODENAME_FALLBACK" ]] && codenames+=("$DOCKER_CODENAME_FALLBACK")
  if [[ -n $DOCKER_REPO ]]; then
    for cn in "${codenames[@]}"; do
      curl -fsS --max-time 8 -o /dev/null "$DOCKER_REPO/linux/ubuntu/dists/$cn/Release" && { echo "$DOCKER_REPO $cn"; return 0; }
    done
    die "DOCKER_REPO=$DOCKER_REPO 不可用"
  fi
  for cn in "${codenames[@]}"; do
    for pass in cloud any; do
      for line in "${DOCKER_REPO_CANDIDATES[@]}"; do
        read -r cloud url <<<"$line"
        if [[ $pass == cloud ]]; then [[ $cloud == "$CLOUD" ]] || continue
        else [[ $cloud == any ]] || continue
        fi
        curl -fsS --max-time 5 -o /dev/null "$url/linux/ubuntu/dists/$cn/Release" && { echo "$url $cn"; return 0; }
      done
    done
  done
  return 1
}

docker_install() {
  if pkg_installed docker-ce && docker compose version &>/dev/null; then
    log "Docker 已安装: $(docker --version)"
    systemctl enable --now docker >/dev/null
    return 0
  fi
  apt_install ca-certificates curl
  local repo codename
  read -r repo codename < <(pick_docker_repo) || die "找不到可用的 Docker 源（$OS_CODENAME/$DOCKER_CODENAME_FALLBACK），可在 config.env 设置 DOCKER_REPO"
  [[ $codename != "$OS_CODENAME" ]] && warn "Docker 源暂无 $OS_CODENAME，改用 $codename 的包"
  log "Docker 源: $repo ($codename, $ARCH)"

  local p conflicts=()
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    pkg_installed "$p" && conflicts+=("$p")
  done
  ((${#conflicts[@]})) && { log "卸载冲突包: ${conflicts[*]}"; apt-get remove -y -qq "${conflicts[@]}"; }

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$repo/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  write_if_changed /etc/apt/sources.list.d/docker.list <<EOF || true
deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] $repo/linux/ubuntu $codename stable
EOF
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  state_set docker-installed
  log "Docker 安装完成: $(docker --version)"
}

DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras)

# 只返回 dpkg 里还有记录的包（含 remove 后残留配置的），apt 对不存在的包会整批失败
docker_pkgs_present() {
  local p
  for p in "${DOCKER_PKGS[@]}"; do
    dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qv not-installed && echo "$p"
  done
  return 0
}

docker_uninstall() {
  if ! state_has docker-installed; then
    if state_has docker-data-root || ! pkg_installed docker-ce; then log "Docker 未安装"
    else warn "Docker 不是本脚本安装的，跳过"
    fi
    return 0
  fi
  # 清除时要用；data-root 可能被 daemon.json 改过
  state_set docker-data-root "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  systemctl disable --now docker.socket docker.service containerd.service >/dev/null 2>&1 || true
  local pkgs; mapfile -t pkgs < <(docker_pkgs_present)
  ((${#pkgs[@]})) && DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "${pkgs[@]}" >/dev/null
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
  state_del docker-installed
  log "Docker 已卸载（数据保留在 $(state_get docker-data-root)）"
}

docker_purge() {
  state_has docker-data-root || { log "没有本脚本安装 Docker 的记录，不删除 Docker 数据"; return 0; }
  # docker.list 已在卸载时删除，apt 找不到包；残留配置用 dpkg 清
  local pkgs; mapfile -t pkgs < <(docker_pkgs_present)
  ((${#pkgs[@]})) && dpkg --purge "${pkgs[@]}" >/dev/null
  safe_rm_dir "$(state_get docker-data-root)"
  safe_rm_dir /var/lib/containerd
  safe_rm_dir /etc/docker
  state_del docker-data-root
}

docker_purge_hint() { echo "Docker 数据目录（所有镜像、容器、卷）"; }
