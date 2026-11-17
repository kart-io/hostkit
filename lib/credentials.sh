# shellcheck shell=bash
# 账号密码统一存放在 $DEPLOY_DIR/credentials.env（0600），组件只从这里读。
# 可在安装前手填；缺的自动生成，已有的不覆盖。各组件在 steps/<组件>.sh 登记：
#   CREDENTIALS+=("<组件> <变量名> user|password [用户名默认值]")
CREDENTIALS=()

# 类型 校验 说明；值会进 compose .env 和 htpasswd，限制字符避免 $ : 引号被解释
CRED_KINDS=(
  'user     ^[a-z_][a-z0-9_]{0,62}$    小写字母、数字、下划线，不以数字开头'
  'password ^[A-Za-z0-9._~+-]{16,128}$ 16-128 位字母、数字或 ._~+-'
)

cred_file() { echo "$DEPLOY_DIR/credentials.env"; }
# make credentials：只列位置和已有的变量名，不打印密码，免得留在终端记录里
cred_show() {
  local f line c k
  f=$(cred_file)
  echo "账号密码文件: $f"
  if [[ ! -f $f ]]; then echo "  尚未生成（安装组件或 make passwords 时生成）"; return 0; fi
  for line in "${CREDENTIALS[@]}"; do
    read -r c k _ <<<"$line"
    [[ -z $(env_get "$f" "$k") ]] || printf '  %-8s %s\n' "$c" "$k"
  done
  echo "查看: sudo cat $f"
}

cred_gen() { python3 -c 'import secrets; print(secrets.token_hex(24))'; }

cred_row() {
  local line; for line in "${CREDENTIALS[@]}"; do
    read -r _ k _ <<<"$line"; [[ $k == "$1" ]] && { echo "$line"; return 0; }
  done
  return 1
}

cred_check() { # 变量名 类型 值
  local line kind re desc
  for line in "${CRED_KINDS[@]}"; do
    read -r kind re desc <<<"$line"
    [[ $kind == "$2" ]] || continue
    [[ $3 =~ $re ]] || die "$(cred_file) 中 $1 不合法：需为$desc"
    return 0
  done
}

# 替换或追加一行；先写临时文件再 mv，中途失败不会留下半个文件
cred_put() {
  local f; f=$(cred_file)
  install -d -m 0755 "$DEPLOY_DIR"
  (
    umask 077
    { [[ -f $f ]] && grep -v "^$1=" "$f" || echo "# $PROJECT 账号密码，组件只从这里读；改密码用 make rotate-password-<组件>"
      echo "$1=$2"; } >"$f.tmp"
  )
  mv "$f.tmp" "$f"
}

# 输出变量值；不存在时用户名取默认值、密码随机生成并写入
cred_get() {
  local row comp k kind def v
  # die 在 $() 里只退出子 shell，所以由这里判断
  row=$(cred_row "$1") || die "未登记的账号变量: $1"
  read -r comp k kind def <<<"$row"
  v=$(env_get "$(cred_file)" "$k")
  if [[ -z $v ]]; then
    if [[ $kind == user ]]; then v=$def; else v=$(cred_gen); fi
    cred_put "$k" "$v"
    log "已生成 $k（$comp）→ $(cred_file)" >&2
  fi
  cred_check "$k" "$kind" "$v"
  echo "$v"
}

# 生成并校验组件的账号密码。组件里多在 $() 中取值，校验失败只会退出子 shell，
# 所以安装前先在这里（不在子 shell 中）调用一次，非法值才能真正中止
cred_prepare() {
  local line comp k
  for line in "${CREDENTIALS[@]}"; do
    read -r comp k _ <<<"$line"
    if [[ $comp == "$1" ]]; then cred_get "$k" >/dev/null; fi
  done
}

# 预生成指定组件（默认全部）的账号密码
cred_ensure() {
  local line comp t comps=()
  for line in "${CREDENTIALS[@]}"; do
    read -r comp _ <<<"$line"
    [[ " ${comps[*]} " == *" $comp "* ]] || comps+=("$comp")
  done
  for t in "$@"; do
    [[ $t == all || " ${comps[*]} " == *" $t "* ]] || die "$t 没有登记账号密码（有: ${comps[*]}）"
  done
  for comp in "${comps[@]}"; do
    [[ ${1:-all} == all || " $* " == *" $comp "* ]] && cred_prepare "$comp"
  done
  log "账号密码文件: $(cred_file)（查看: sudo cat $(cred_file)）"
}

# 换新密码；组件已安装则立即生效（有 <组件>_rotate 用它，否则重跑安装让容器按新 .env 重建）
cred_rotate() {
  local n=$1 line comp k kind keys=()
  for line in "${CREDENTIALS[@]}"; do
    read -r comp k kind _ <<<"$line"
    [[ $comp == "$n" && $kind == password ]] && keys+=("$k")
  done
  ((${#keys[@]})) || die "$n 没有可轮换的密码"
  confirm "轮换 $n 的密码（${keys[*]}），使用方需同步更新，确认？"
  for k in "${keys[@]}"; do cred_put "$k" "$(cred_gen)"; done
  log "已生成新密码 ${keys[*]} → $(cred_file)"
  if comp_installed "$n"; then
    if declare -F "${n}_rotate" >/dev/null; then "${n}_rotate"; else comp_install "$n"; fi
    log "$n 已使用新密码"
  fi
}

# 清除组件时删除它的账号密码；文件里没有账号了就删文件
cred_purge() {
  local f line comp k; f=$(cred_file)
  [[ -f $f ]] || return 0
  for line in "${CREDENTIALS[@]}"; do
    read -r comp k _ <<<"$line"
    [[ $comp == "$1" ]] || continue
    if grep -q "^$k=" "$f"; then
      (umask 077; grep -v "^$k=" "$f" >"$f.tmp" || true)
      mv "$f.tmp" "$f"
    fi
  done
  grep -qE '^[A-Z_]+=' "$f" || rm -f "$f"
}
