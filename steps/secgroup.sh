# shellcheck shell=bash
# 云安全组：脚本不持有云凭证，只输出放行清单

SECGROUP_CONSOLE=(
  "tencent 腾讯云控制台 → 云服务器 → 安全组"
  "aliyun  阿里云控制台 → ECS → 网络与安全 → 安全组"
  "huawei  华为云控制台 → 弹性云服务器 → 安全组"
  "aws     AWS Console → EC2 → Security Groups"
  "gcp     GCP Console → VPC network → Firewall"
  "azure   Azure Portal → Network security groups"
)

# 安全组在云 API 侧，脚本不持有云凭证，只输出需要放行的清单
secgroup_install() {
  local line cloud rest hint="" ip
  for line in "${SECGROUP_CONSOLE[@]}"; do
    read -r cloud rest <<<"$line"
    [[ $cloud == "$CLOUD" ]] && hint=$rest
  done
  ip=$(detect_public_ip) || ip="未知"
  log "云厂商: $CLOUD   公网 IP: $ip"
  echo "  请在安全组入站规则中放行（来源建议收窄到办公网段，80/443 可 0.0.0.0/0）："
  required_tcp_ports | sed 's/^/    TCP /'
  [[ -n $hint ]] && echo "  位置: $hint"
  echo "  Redis/Postgres/OTel/Victoria* 只在 Docker 内网访问，不要在安全组放行它们的端口"
  return 0
}
