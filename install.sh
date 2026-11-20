#!/usr/bin/env bash
# 基础环境快速部署。用法见 ./install.sh --help
set -euo pipefail

BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$BASE_DIR/lib/common.sh"
# shellcheck source=lib/components.sh
. "$BASE_DIR/lib/components.sh"
# shellcheck source=lib/credentials.sh
. "$BASE_DIR/lib/credentials.sh"
# shellcheck source=lib/status.sh
. "$BASE_DIR/lib/status.sh"

# 阶段 名称 说明；每个步骤一个文件 steps/<名称>.sh，实现 <名称>_install，可选 _uninstall/_purge/_purge_hint
# 安装按此顺序，卸载/清除按逆序；ufw 必须在 ssh 前：改端口时先放行新端口
# 阶段 3 为可选组件：install all 不含，需显式指定；uninstall/purge all 含
STEPS=(
  "1 docker          安装 Docker CE"
  "1 dockerconf      Docker 日志轮转/镜像加速/地址池"
  "1 swap            配置 Swap"
  "1 ufw             配置 UFW"
  "1 ssh             SSH 加固"
  "1 secgroup        输出安全组放行清单"
  "1 netcheck        检查 Docker 网络"
  "2 network         创建 Compose 网络"
  "2 traefik         部署 Traefik 声明式网关"
  "3 redis           Redis"
  "3 postgres        PostgreSQL"
  "3 victoriametrics VictoriaMetrics（指标）"
  "3 victorialogs    VictoriaLogs（日志）"
  "3 otel            OTel Collector（OTLP、主机/容器/中间件指标、容器日志）"
  "3 alert           告警（vmalert + Alertmanager → 飞书）"
  "3 backup          定时备份（systemd timer）"
  "3 demo            测试页（Traefik / 公开访问）"
)
for _line in "${STEPS[@]}"; do
  read -r _ _name _ <<<"$_line"
  # shellcheck source=/dev/null
  . "$BASE_DIR/steps/$_name.sh"
done
unset _line _name

has_fn() { declare -F "$1" >/dev/null; }

usage() {
  cat <<EOF
用法: sudo $0 [install|uninstall|purge] [all | 1 | 2 | 3 | <步骤名>...] [--yes]
  install    安装（默认）
  uninstall  卸载：撤销配置、停服务，保留数据
  purge      清除：卸载并删除数据，不可恢复
  all        默认。安装时为阶段 1、2；卸载/清除时含阶段 3 组件
  1 / 2 / 3  按阶段；也可写多个步骤名，如: $0 install redis postgres
  --yes      跳过确认
  --list     列出步骤

账号密码（统一在 \$DEPLOY_DIR/credentials.env，可在安装前手填）:
  $0 passwords [组件...]   预生成，已有的不覆盖
  $0 credentials           显示账号密码文件位置及其中的变量名
  $0 rotate <组件> [--yes] 换新密码并立即生效

运维:
  $0 status                        组件/证书/备份/磁盘一览
  $0 update                        更新 hostkit 代码并热重载组件配置
  $0 backup-run                    立即备份一次（定时任务也调用它）
  $0 restore <组件> [备份名] [--yes] 从备份恢复，默认用最新一份

配置: 复制 config.env.example 为 config.env 后修改
EOF
}

list_steps() {
  local line stage name desc
  for line in "${STEPS[@]}"; do
    read -r stage name desc <<<"$line"
    printf '  阶段%s  %-16s 卸载:%s 清数据:%s  %s\n' "$stage" "$name" \
      "$(has_fn "${name}_uninstall" && echo 有 || echo 无)" "$(has_fn "${name}_purge" && echo 有 || echo 无)" "$desc"
  done
}

list_names() { local line; for line in "${STEPS[@]}"; do read -r _ name _ <<<"$line"; echo "$name"; done; }

# set -e 退出时没有任何提示，这里补上失败的步骤名
on_exit() {
  local rc=$?
  ((rc == 0)) || printf '\033[31m[ERROR]\033[0m 步骤 [%s] 失败（退出码 %s）\n' "$CURRENT_STEP" "$rc" >&2
}

main() {
  case ${1:-} in
    -h|--help) usage; return 0 ;;
    --list) list_steps; return 0 ;;
    --names) list_names; return 0 ;;
  esac
  local action=install
  [[ ${1:-} =~ ^(install|uninstall|purge|passwords|credentials|rotate|status|backup-run|restore|update)$ ]] && { action=$1; shift; }
  local targets=() a
  for a in "$@"; do
    if [[ $a == --yes ]]; then ASSUME_YES=1; else targets+=("$a"); fi
  done
  ((${#targets[@]})) || targets=(all)

  if [[ $action =~ ^(passwords|credentials|rotate|status|backup-run|restore|update)$ ]]; then
    require_root
    load_config "$BASE_DIR/config.env"
    case $action in
      passwords)  cred_ensure "${targets[@]}" ;;
      credentials) cred_show ;;
      status)     status_report ;;
      backup-run) backup_run ;;
      update)
        if [[ -d "$BASE_DIR/.git" ]]; then
          log "拉取最新 hostkit 代码..."
          if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
            sudo -u "$SUDO_USER" git -C "$BASE_DIR" pull --ff-only || warn "git pull 失败，请检查网络或工作区改动"
          else
            git -C "$BASE_DIR" pull --ff-only || warn "git pull 失败，请检查网络或工作区改动"
          fi
        fi
        load_config "$BASE_DIR/config.env"
        sync_integrations
        log "hostkit 更新与组件同步完成"
        ;;
      rotate)
        ((${#targets[@]} == 1)) && [[ ${targets[0]} != all ]] || { usage; die "rotate 需要指定一个组件"; }
        cred_rotate "${targets[0]}" ;;
      restore)
        [[ ${targets[0]} != all ]] || { usage; die "restore 需要指定组件"; }
        backup_restore "${targets[@]}" ;;
    esac
    return 0
  fi

  local line stage name desc t selected=() known
  known=" $(list_names | xargs) "
  for t in "${targets[@]}"; do
    [[ $t =~ ^(all|1|2|3)$ || $known == *" $t "* ]] || { usage; die "未知步骤: $t"; }
  done
  for line in "${STEPS[@]}"; do
    read -r stage name desc <<<"$line"
    for t in "${targets[@]}"; do
      [[ ($t == all && ($action != install || $stage != 3)) || $t == "$stage" || $t == "$name" ]] || continue
      if [[ $action == install ]]; then selected+=("$line"); else selected=("$line" "${selected[@]}"); fi
      break
    done
  done

  require_root
  load_config "$BASE_DIR/config.env"
  detect_os
  apt_install curl ca-certificates python3 iproute2 openssl
  detect_cloud
  log "环境: $OS_PRETTY ($OS_CODENAME/$ARCH)  云: $CLOUD  内存: $(mem_mb)MB  操作: $action"

  if [[ $action == purge ]]; then
    echo "将卸载并永久删除：" >&2
    for line in "${selected[@]}"; do
      read -r stage name desc <<<"$line"
      has_fn "${name}_purge" || continue
      if has_fn "${name}_purge_hint"; then echo "  - $("${name}_purge_hint")" >&2
      else echo "  - $desc：$DEPLOY_DIR/$name" >&2
      fi
    done
    confirm "确认清除？"
  elif [[ $action == uninstall && " ${selected[*]} " == *" docker "* ]]; then
    confirm "卸载 Docker 会停止本机所有容器，确认？"
  fi

  CURRENT_STEP=init
  trap on_exit EXIT
  for line in "${selected[@]}"; do
    read -r stage name desc <<<"$line"
    CURRENT_STEP=$name
    case $action in
      install)   log "==== [$name] $desc"; "${name}_install" ;;
      uninstall) log "==== [$name] 卸载"; if has_fn "${name}_uninstall"; then "${name}_uninstall"; else log "无需卸载"; fi ;;
      purge)
        log "==== [$name] 清除"
        if has_fn "${name}_uninstall"; then "${name}_uninstall"; fi
        if has_fn "${name}_purge"; then "${name}_purge"; fi
        ;;
    esac
  done
  [[ $action == install ]] || rmdir "$STATE_DIR" 2>/dev/null || true
  log "完成"
}

main "$@"
