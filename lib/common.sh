# shellcheck shell=bash
# 通用函数：日志、配置、环境探测。由 install.sh source。

# 项目名：状态目录、systemd 单元、配置文件名、备份指标名都由它派生
PROJECT=hostkit
METRIC_PREFIX=${PROJECT//-/_}
# 生成文件的首行
GEN_HEADER="# 由 $PROJECT 生成，勿手改"

VERSIONS_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/versions.env

log()  { printf '\033[32m[%s]\033[0m %s\n' "$(date +%T)" "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "请用 root 或 sudo 运行"; }

confirm() {
  [[ ${ASSUME_YES:-0} == 1 ]] && return 0
  [[ -t 0 ]] || die "$1 非交互环境请加 --yes（make 中用 CONFIRM=yes）"
  local ans
  read -r -p "$1 输入 yes 继续: " ans
  [[ $ans == yes ]] || die "已取消"
}

# 只删明确的绝对路径，防止变量为空时误删
safe_rm_dir() {
  [[ $1 == /?*/* || $1 =~ ^/[^/]{4,}$ ]] || die "拒绝删除可疑路径: '$1'"
  [[ -e $1 ]] || return 0
  # 独立挂载的数据盘只能清空内容
  if mountpoint -q "$1"; then
    find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    log "已清空 $1（挂载点）"
  else
    rm -rf -- "$1"
    log "已删除 $1"
  fi
}

# 记录本脚本做过什么，卸载时只撤销自己的改动
STATE_DIR=/var/lib/$PROJECT
state_set() { install -d -m 0700 "$STATE_DIR"; printf '%s\n' "${2:-1}" >"$STATE_DIR/$1"; }
state_get() { cat "$STATE_DIR/$1" 2>/dev/null || true; }
state_has() { [[ -e $STATE_DIR/$1 ]]; }
state_del() { rm -f "$STATE_DIR/$1" "$STATE_DIR/$1.orig"; }

# 首次修改前保存原文件（或记下原本不存在），restore_backup 据此还原
backup_once() {
  local key="backup${1//\//_}"
  state_has "$key" && return 0
  install -d -m 0700 "$STATE_DIR"
  if [[ -e $1 ]]; then cp -a "$1" "$STATE_DIR/$key.orig"; state_set "$key" present
  else state_set "$key" absent
  fi
}
# 有改动返回 0
restore_backup() {
  local key="backup${1//\//_}"
  case $(state_get "$key") in
    present) cmp -s "$STATE_DIR/$key.orig" "$1" && { state_del "$key"; return 1; }
             cp -a "$STATE_DIR/$key.orig" "$1"; log "已还原 $1" ;;
    absent)  [[ -e $1 ]] || { state_del "$key"; return 1; }
             rm -f "$1"; log "已删除 $1（安装前不存在）" ;;
    *)       [[ -e $1 ]] && warn "没有 $1 的安装前备份，保持不变"; return 1 ;;
  esac
  state_del "$key"
}

# 配置默认值；config.env 中同名变量优先
load_config() {
  local cfg=$1
  # shellcheck disable=SC1090
  [[ -f $cfg ]] && . "$cfg"
  : "${DEPLOY_DIR:=/opt/base}"
  : "${NETWORK_NAME:=base-net}"
  : "${SSH_PORT:=22}"
  : "${SSH_CLOSE_OLD_PORT:=0}"
  : "${EXTRA_TCP_PORTS:=}"
  : "${SWAP_SIZE_MB:=auto}"
  : "${DOCKER_LOG_MAX_SIZE:=50m}"
  : "${DOCKER_LOG_MAX_FILE:=3}"
  : "${DOCKER_REPO:=}"
  : "${REGISTRY_MIRRORS:=}"
  : "${AVOID_CIDRS:=}"
  : "${SITES:=}"
  : "${LE_EMAIL:=}"
  : "${LE_STAGING:=0}"
  # 版本只在 versions.env 维护；环境变量、config.env 已设的不覆盖
  local k v
  while IFS='=' read -r k v || [[ -n $k ]]; do
    if [[ $k =~ ^[A-Z_][A-Z0-9_]*$ && -z ${!k:-} ]]; then printf -v "$k" '%s' "$v"; fi
  done <"$VERSIONS_FILE"
  : "${VM_RETENTION:=30d}"
  : "${VL_RETENTION:=7d}"
  : "${ALERT_FEISHU_WEBHOOK:=}"
  : "${ALERT_FEISHU_SECRET:=}"
  : "${BACKUP_DIR:=/var/backups/$PROJECT}"
  : "${BACKUP_KEEP:=7}"
  : "${BACKUP_ONCALENDAR:=*-*-* 03:30:00}"
  : "${BACKUP_POST_HOOK:=}"
}

# 内容不变返回 1，调用方据此决定是否重载服务
write_if_changed() {
  local dst=$1 mode=${2:-0644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
  install -D -m "$mode" "$tmp" "$dst"
  rm -f "$tmp"
  log "已写入 $dst"
}

# dpkg -s 对 remove 后残留配置（rc 状态）的包也返回 0，不能用
pkg_installed() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }

apt_install() {
  local missing=() p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  log "apt 安装: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

# 设置 OS_ID OS_CODENAME OS_VERSION OS_PRETTY ARCH；Ubuntu 衍生版取 UBUNTU_CODENAME
detect_os() {
  local f=${OS_RELEASE_FILE:-/etc/os-release}
  eval "$(
    # shellcheck disable=SC1090
    . "$f"
    printf 'OS_ID=%q OS_LIKE=%q OS_CODENAME=%q OS_VERSION=%q OS_PRETTY=%q\n' \
      "${ID:-}" "${ID_LIKE:-}" "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" "${VERSION_ID:-}" "${PRETTY_NAME:-}"
  )"
  [[ $OS_ID == ubuntu || " $OS_LIKE " == *" ubuntu "* ]] || die "仅支持 Ubuntu 系列，当前: $OS_PRETTY"
  [[ -n $OS_CODENAME ]] || die "无法从 $f 识别 Ubuntu 代号"
  ARCH=$(dpkg --print-architecture)
}

# 通过 DMI 识别云厂商，不依赖网络
detect_cloud() {
  local dmi
  dmi=$(cat /sys/class/dmi/id/{sys_vendor,product_name,bios_vendor} 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case $dmi in
    *tencent*)           CLOUD=tencent ;;
    *alibaba*|*aliyun*)  CLOUD=aliyun ;;
    *huawei*)            CLOUD=huawei ;;
    *amazon*)            CLOUD=aws ;;
    *google*)            CLOUD=gcp ;;
    *microsoft*)         CLOUD=azure ;;
    *)                   CLOUD=unknown ;;
  esac
}

# 公网 IP：优先云元数据（内网、免外部依赖），失败再查公共服务
PUBLIC_IP_SOURCES=(
  "tencent http://metadata.tencentyun.com/latest/meta-data/public-ipv4"
  "aliyun  http://100.100.100.200/latest/meta-data/eipv4"
  "aliyun  http://100.100.100.200/latest/meta-data/public-ipv4"
  "huawei  http://169.254.169.254/latest/meta-data/public-ipv4"
  "any     https://api.ipify.org"
  "any     https://ifconfig.me/ip"
)
detect_public_ip() {
  local line cloud url ip
  for line in "${PUBLIC_IP_SOURCES[@]}"; do
    read -r cloud url <<<"$line"
    [[ $cloud == any || $cloud == "$CLOUD" ]] || continue
    ip=$(curl -4 -fsS --max-time 3 "$url" 2>/dev/null) || continue
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { echo "$ip"; return 0; }
  done
  return 1
}

mem_mb() { awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo; }

# 宿主机已占用的网段（排除 docker 自身接口）
host_cidrs() {
  ip -4 -o route show table all 2>/dev/null \
    | awk '$1 ~ /\// && $0 !~ / dev (docker[0-9]*|br-[0-9a-f]+|veth[^ ]*) / {print $1}'
  ip -4 -o addr show 2>/dev/null \
    | awk '$2 !~ /^(docker[0-9]*|br-[0-9a-f]+|veth.*)$/ {print $4}'
}

# socket 激活模式下 /run/sshd 要等首个连接才创建，没有它 sshd -t/-T 直接失败
sshd_check() { install -d -m 0755 /run/sshd; sshd "$@"; }
current_ssh_ports() { sshd_check -T | awk '$1=="port" {print $2}'; }

# 需要放行的 TCP 端口（UFW 与安全组共用一份）
required_tcp_ports() {
  local p ports=("$SSH_PORT")
  [[ $SSH_PORT != 22 && $SSH_CLOSE_OLD_PORT != 1 ]] && ports+=(22)
  ports+=(80 443)
  for p in $EXTRA_TCP_PORTS; do ports+=("$p"); done
  printf '%s\n' "${ports[@]}" | awk '!seen[$0]++'
}
