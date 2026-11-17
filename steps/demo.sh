# shellcheck shell=bash
# 测试页：验证 公网 → Nginx → base-net 内容器 整条链路，挂在 Nginx 的 /，公开访问

COMPONENTS+=("demo demo http 80 /")
WEB_ROUTES+=("demo / demo:80")

demo_install()   { comp_install demo; }
demo_uninstall() { comp_undo demo; }
# 与 nginx 共用镜像，不走 comp_purge，免得删掉 nginx 的镜像
demo_purge()     { safe_rm_dir "$DEPLOY_DIR/demo"; }

demo_env() { echo "IMAGE=$NGINX_IMAGE"; }

demo_prepare() {
  local f changed=1
  for f in html/index.html conf.d/default.conf; do
    write_if_changed "$DEPLOY_DIR/demo/$f" <"$BASE_DIR/templates/demo/$f" && changed=0
  done
  return $changed
}

demo_post() { log "测试页: http://<域名或公网 IP>/，验证完可 make uninstall-demo 腾出 /"; }
