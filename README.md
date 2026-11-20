# hostkit

新机器基础环境一键部署：系统与 Docker（阶段 1）+ 基础服务（阶段 2）+ 可选组件（阶段 3：Redis、Postgres、VictoriaMetrics、VictoriaLogs、OTel Collector、告警、定时备份）。支持 Ubuntu 系列（含 Mint 等衍生版），版本、架构、云厂商自动识别。

> 项目名在 `lib/common.sh` 的 `PROJECT` 定义，状态目录 `/var/lib/hostkit`、systemd 单元 `hostkit-*`、sysctl/sshd 配置文件名、备份目录和备份指标名都由它派生。

## 快速开始

```bash
cp config.env.example config.env   # 按需修改，全部可留默认
make help                          # 查看所有目标
make list                          # 步骤列表，及各步骤是否支持卸载/清数据
```

### 新主机部署流程

在目标 Ubuntu（22.04/24.04/26.04）上执行，非 root 时 make 会自动加 sudo：

```bash
git clone git@kart.github.com:kart-io/hostkit.git && cd hostkit
cp config.env.example config.env   # 证书邮箱填 LE_EMAIL，要告警填 ALERT_FEISHU_*

make install                       # 1. 基础环境：Docker、Swap、UFW、SSH 加固、网络、Traefik 网关；按输出放行安全组

make demo                          # 2. 测试页，浏览器打开 http://<域名或公网IP>/ 看到「hostkit 部署正常」即链路通
make uninstall-demo                #    验证完腾出 /

make redis postgres                # 4. 可选组件按需装
make victoriametrics victorialogs otel
make alert                         #    飞书告警，依赖 victoriametrics
make backup                        #    每天定时备份

make status                        # 5. 查看整体状态；账号密码在 /opt/base/credentials.env
```

| 操作 | 命令 |
|---|---|
| 基础环境 | `make install`（阶段 1、2，不含可选组件） |
| 单个阶段 | `make stage1` / `make stage2` / `make stage3`（全部可选组件） |
| 单个步骤/组件 | `make swap` / `make postgres` |
| 多个步骤 | `make swap ufw ssh`（按命令行顺序）或 `make install STEPS="swap ssh"`（按步骤表顺序） |
| 卸载 | `make uninstall`（全部，含组件）/ `make uninstall-redis` / `make uninstall STEPS="redis postgres"` |
| 清除数据 | `make purge` / `make purge-postgres` / `make purge STEPS=3` |
| 账号密码 | `make credentials`（文件位置及变量名） |
| 运行状态 | `make status`（组件健康/待升级、证书剩余天数、最近备份、磁盘） |
| 备份/恢复 | `make backup-now` / `make restore-postgres [BACKUP=<备份名>]`，见「备份与恢复」 |

- **安装**：可以重复执行，没有变化的步骤不会改文件，也不会重启服务。
- **卸载**：撤销配置、停掉服务，**保留数据**（组件数据、证书、Docker 镜像和卷）。按步骤表的逆序执行。
- **清除**：先卸载，再**永久删除数据**。执行前要输入 yes 确认；非交互环境加 `CONFIRM=yes`。卸载 Docker 时同样需要确认。
- 卸载和清除指定步骤时，要用 `STEPS=` 或 `uninstall-<步骤>`。`make uninstall swap` 会被 make 拆成「卸载全部」加「安装 swap」两件事，所以直接报错拒绝。
- 也可以不用 make，直接调用 `sudo ./install.sh [install|uninstall|purge] <步骤...> [--yes]`。

### 卸载/清除各步骤做什么

卸载只撤销本脚本做过的改动，状态记录在 `/var/lib/hostkit`。

| 步骤 | 卸载 | 清除（额外） |
|---|---|---|
| docker | 只有本脚本装的 Docker 才卸载包和 apt 源 | 删除 Docker 数据目录（按实际 data-root）、`/var/lib/containerd`、`/etc/docker`；如果是挂载点，只清空内容 |
| dockerconf | 把 `daemon.json` 还原成安装前的样子（安装前没有就删除），然后重启 Docker | — |
| swap | 只有本脚本建的 `/swapfile` 才 swapoff 并删除，同时删 sysctl | — |
| ufw | 删除本脚本加的规则；安装前 UFW 没启用就关掉它；如果 UFW 要继续启用，保留 SSH 端口规则 | — |
| ssh | 删除 `00-hostkit.conf`，先在防火墙放行原 SSH 端口，再生效 | — |
| network | 删除 `base-net`（仍有容器在用时保留） | — |
| traefik | `compose down` | 删除镜像和 `$DEPLOY_DIR/traefik`（含 acme 证书、观测入口账号） |
| redis / postgres / victoriametrics / victorialogs / otel / alert | `compose down`，联动更新 OTel 采集、告警规则；redis 另删 sysctl | 删除镜像和 `$DEPLOY_DIR/<组件>` |
| backup | 停掉备份 timer，备份文件保留 | 删除 `$BACKUP_DIR` 下全部备份 |

## 步骤

| 阶段 | 步骤 | 做什么 | 自动判断 |
|---|---|---|---|
| 1 | docker | 安装 Docker CE + compose 插件 | 按云厂商优先内网镜像源，探测可用性；新 Ubuntu 版本源上还没有时回退到 noble |
| 1 | dockerconf | `/etc/docker/daemon.json`：日志轮转（50m×3）、镜像加速、地址池 | Docker Hub 不可达时，腾讯云自动用内网加速；地址池避开宿主机路由和 `AVOID_CIDRS` |
| 1 | swap | 创建 `/swapfile`，`vm.swappiness=10` | 已有 swap 跳过；大小按内存、磁盘余量算；btrfs 跳过 |
| 1 | ufw | 默认拒绝入站，放行 SSH/80/443/`EXTRA_TCP_PORTS` | 额外放行当前 sshd 实际端口，防止锁死 |
| 1 | ssh | `sshd_config.d/00-hostkit.conf`：禁 root 密码、限制重试等 | 没有 authorized_keys 时保留密码登录；`sshd -t` 失败自动撤销；兼容 22.10+ socket 激活 |
| 1 | secgroup | 输出安全组需放行的端口清单 | DMI 识别云厂商，给出控制台位置和公网 IP |
| 1 | netcheck | 检查 ip_forward、bridge 网段冲突、拉镜像跑容器 | |
| 2 | network | 创建外部网络 `base-net` | |
| 2 | traefik | compose 部署 Traefik 声明式网关（80/443），内置全自动 ACME TLS 证书与动态路由 | 自动识别容器 Labels 发现路由并自动签发证书 |
| 3 | redis | Redis，开启密码与 AOF | 密码首次生成后保留；写入 `vm.overcommit_memory=1` |
| 3 | postgres | PostgreSQL | 密码首次生成后保留 |
| 3 | victoriametrics | 指标存储，保留 `VM_RETENTION` | 自带 Traefik `/vm/` 入口和 OTel 指标导出 |
| 3 | victorialogs | 日志存储，保留 `VL_RETENTION` | 自带 Traefik `/vl/` 入口和 OTel 日志导出 |
| 3 | otel | OTel Collector：接收 OTLP，采集主机/容器/Redis/Postgres/证书指标、容器日志 | 采集项和导出目标按已装组件生成 |
| 3 | alert | vmalert + Alertmanager + 飞书转发 | 规则按已装组件生成；自带 Traefik `/vmalert/` 和 `/am/` 入口 |
| 3 | backup | systemd timer 每天备份已运行的组件 | 只备份正在运行、支持备份的组件 |
| 3 | demo | 测试页容器，Traefik `/` 公开访问，页面显示容器名、Host、客户端 IP | 验证 公网 → Traefik → `base-net` 容器 整条链路；占用 `/`，业务要挂 `/` 前先 `make uninstall-demo` |

## 需要人工处理的事

- **安全组**：脚本不持有云凭证，只打印清单，需在控制台放行。
- **改 SSH 端口**：设 `SSH_PORT=2222` 后会同时监听 22 和 2222。先在安全组放行 2222，用新端口登录确认，再设 `SSH_CLOSE_OLD_PORT=1` 跑 `sudo ./install.sh ssh`，此时会关闭 22，并从 UFW 中删掉 22 的放行规则。
- **Docker 绕过 UFW**：`ports:` 发布的端口不受 UFW 限制。只有 Traefik 发布 80/443，阶段 3 组件都不发布端口，只在 `base-net` 内可达。
- **地址池**：只在 `daemon.json` 里还没有 `default-address-pools` 时才写入，已有配置不动。VPC 网段不在本机路由表里时，要填到 `AVOID_CIDRS`。
- **UFW 规则只增不减**：从 `EXTRA_TCP_PORTS` 里去掉的端口，需要手工 `ufw delete allow <port>/tcp`。

## 部署目录（`/opt/base`）

每个组件是独立的 compose 项目（项目名 `base-<组件>`），都接入外部网络 `base-net`：

```
credentials.env                  # 所有账号密码（0600），见「账号密码」
<组件>/docker-compose.yml        # 从 templates/<组件>/ 复制，勿手改
<组件>/.env                      # 镜像版本、密码等（0600）
traefik/traefik.yml              # 生成，勿手改（入口、ACME、provider）
traefik/conf.d/global.yml        # 中间件（Basic Auth、404）与兜底路由，从 templates/traefik/ 复制
traefik/conf.d/sites.yml         # 按 SITES 生成，勿手改；Traefik 监听该目录，改动立即生效
traefik/html/404.html            # 没匹配到路由时的 404 页面，改样式改 templates/traefik/html/404.html
traefik/acme/acme.json           # Let's Encrypt 账号与证书（0600）
traefik/auth/htpasswd            # 观测入口 Basic Auth
redis/data  postgres/data  victoriametrics/data  victorialogs/data
demo/html  demo/conf.d            # 测试页，从 templates/demo/ 复制
otel/config.yaml                 # 按已装组件生成，勿手改
alert/rules/*.yml                # 按已装组件生成，勿手改
alert/alertmanager.yml  alert/feishu.py  alert/am-data
```

业务容器加入 `base-net` 即可被 Traefik 反代，并访问 `redis:6379`、`postgres:5432`、`otel-collector:4317/4318`：

```yaml
networks:
  default:
    name: base-net
    external: true
```

业务容器也可以自带 Traefik 标签（`traefik.enable=true` 等）自行声明路由，写法参考 `templates/victoriametrics/docker-compose.yml`。

## 域名与 TLS

只有一个配置 **`SITES`**：每行「域名 服务」，决定域名打开什么。每个要访问的域名都写一行，主站写 `main`。

HTTPS 证书也按 `SITES` 来：Traefik 按每个站点的 `Host` 规则自动向 Let's Encrypt 签发并续期（HTTP-01），一个域名失败不影响其他域名。HTTP 一律 301 跳 HTTPS。

```bash
# config.env
SITES="
crm.example.com      main
logs.example.com     victorialogs
app.example.com      myapp:8080
"
LE_EMAIL="ops@example.com"
LE_STAGING=1      # 先用测试环境，不消耗正式限额
```

上例中 `crm` 是主站，`logs` 直达 VictoriaLogs，`app` 反代到业务容器，三个域名各有一张证书。

| 服务 | 访问效果 |
|---|---|
| `main` | 主站：`/vm/` `/vl/` `/vmalert/` `/am/` 观测入口，装了 demo 时 `/` 为 demo，其余路径返回 404 页面 |
| `victoriametrics` `victorialogs` `vmalert` `alertmanager` | 打开域名根路径跳到该观测后端（如 victorialogs 跳到 `/vl/select/vmui/`），Basic Auth；其余未匹配路径返回 404 |
| `demo` | 测试页 |
| `容器名:端口` | 整站公开反代到 `base-net` 里的容器，如 `myapp:8080`；容器没起时返回 502；redis、postgres 不允许绑定 |
| `IP:端口` | 整站公开反代到宿主机或跨网络服务，如 `172.17.1.1:8081`（反代默认支持 WebSocket、SSE 流式输出与长连接） |

- 加站点：先在 DNS 服务商把域名 A 记录指向本机公网 IP，再改 `SITES`，执行 `make traefik`（或 `make update`）。新站点立即生效并自动签证书，无需重启。
- 签发失败（多半是 DNS 没指向本机或 80 端口不通）时 Traefik 先用自签的默认证书，原因见 `docker compose --project-directory /opt/base/traefik logs traefik`。
- `make status` 逐个列出站点：服务、证书是否已签发、访问地址。
- 从 `SITES` 删掉的站点自动移除；绑定的组件未安装时访问返回 404，装上后自动生效。
- 没在 `SITES` 里的域名、直接用 IP 访问：组件路径照常可用，其余返回 404 页面。
- 所有 HTTPS 响应统一加安全头（HSTS、`X-Content-Type-Options: nosniff`、`X-Frame-Options: SAMEORIGIN`，见 `templates/traefik/conf.d/global.yml` 的 `security-headers`），会覆盖后端自己下发的同名头；业务需要被跨域 iframe 嵌入时要调整这里。
- `容器名:端口` 的容器必须接入 `base-net`，否则访问 502；`make traefik` 发现没接入会提示 `docker network connect` 命令。
- Traefik Dashboard 在 `https://<域名>/traefik/dashboard/`，用观测入口账号登录；API 也在 `/traefik/api/`，不占用业务的 `/api`。
- 路由优先级（大者先匹配）：`容器名:端口` 站点和根路径跳转 1000 > 组件路径（`/vm` 等）> 内置服务站点 4 > demo 3 > `main` 2 > 兜底 404 1。因此 `/vm` `/vl` `/traefik` 等观测入口只在 `main` 和内置服务站点上可用，`容器名:端口` 站点整站交给后端，不暴露管理入口。

`LE_STAGING=1` 调通后改为 0，清空 `/opt/base/traefik/acme/acme.json`（保持 0600）再执行 `make traefik` 重新签发。

### 业务应用接入与部署（如 wechat-account）

外部业务系统（如电商、CRM、微信平台、AI 服务）建议保持**独立部署、统一网关与统一可观测性**：
1. **独立编排与目录规范**：业务项目统一部署在独立目录（如 `/opt/wechat-account`），自带 Docker Compose 与独立 `.env`（权限 `0600`），生命周期不侵入 HostKit 底座。
2. **反向代理与自动 HTTPS**：在 HostKit 的 `config.env` 中为 `SITES` 增加域名与目标映射（例如 `crm.example.com 172.17.1.1:8081`），执行 `make traefik` 即可全自动完成 Let's Encrypt 证书签发、HTTP 301 强制跳转 HTTPS、以及原生的 WebSocket / SSE 流式长连接代理。
3. **零侵入集中日志收集**：执行 `make otel` 启动 OTel Collector，系统会自动监听 `/var/lib/docker/containers/` 下的所有容器日志，实时持久化到 VictoriaLogs，直接在 `https://vlog.example.com` 集中查询检索。
4. **单服务定向更新**：业务栈配备标准维护脚本，支持只更新 `app` 核心容器或 `collab` 协同容器，保留数据库持续健康运行。

详细的架构契约与端到端实战流程，见 **[外部应用接入与部署规范指南 —— 以 wechat-account 为例](docs/deploy-applications.md)**。

#### 单个 Docker 服务更新命令速查

| 更新需求 | 执行命令 |
|---|---|
| **仅更新业务核心后端容器 (app)** | `cd /opt/wechat-account && sh scripts/update.sh app` |
| **仅更新业务协同编辑容器 (collab)** | `cd /opt/wechat-account && sh scripts/update.sh collab` |
| **改了业务挂载配置热重启** | `cd /opt/wechat-account && docker compose restart app` |
| **仅更新 HostKit Traefik 网关** | `cd ~/hostkit && make traefik` |
| **仅更新 HostKit OTel 采集器** | `cd ~/hostkit && make otel` |
| **仅更新 HostKit VictoriaLogs 引擎** | `cd ~/hostkit && make victorialogs` |

## 可观测性

```bash
make victoriametrics victorialogs otel     # 顺序不限，后装的会自动接上
```

- **OTel Collector** 不发布端口，只接收本机 `base-net` 内容器的 OTLP（`otel-collector:4317` gRPC / `4318` HTTP）。
  - 指标导出到 VictoriaMetrics。
  - 日志导出到 VictoriaLogs。
  - Trace 没有后端，暂时丢弃（`nop`）。
- **指标**（装了 VM 才采集，每 30s 一次）：
  - 主机：cpu、load、memory、paging、disk、filesystem。不采集网络指标：Collector 在容器网络命名空间里，采到的不是宿主机网卡。
  - 容器（`docker_stats`）：本机所有容器的 CPU、内存、网络、块 IO、重启次数、运行时长。
  - Redis、Postgres：装了才采，账号从 `credentials.env` 读取，改密码后自动跟上。
  - 证书（`tlscheck`）：配置了 `SITES` 时每小时连一次各站点 443，取线上证书的剩余时间（需要容器能访问本机公网 IP）。
  - 指标名是 Prometheus 风格（VM 开了 `-opentelemetry.usePrometheusNaming`），如 `system_filesystem_utilization_ratio`、`container_restarts_total`、`redis_memory_used_bytes`。
- **docker.sock**：采集容器指标要把 `/var/run/docker.sock` 只读挂进 Collector。只读挂载也能调用全部 Docker API，等同宿主机 root。Collector 不发布端口，只在 `base-net` 内收 OTLP。
- **容器日志**（装了 VL 才启用）：读取 Docker json-file 日志，从启用后的新日志开始。
  - 需要日志驱动为 json-file，`make dockerconf` 已配置。
  - 日志里带 `log.file.path`（含容器 ID），不带容器名。
- **查询入口**：经 Traefik 访问 `https://<主机>/vm/`（vmui 在 `/vm/vmui/`）、`/vl/`（UI 在 `/vl/select/vmui/`）、`/vmalert/`（规则与告警状态）、`/am/`（Alertmanager，可设静默），都用 Basic Auth 登录。
  - 账号密码见 `/opt/base/credentials.env` 的 `OBS_AUTH_USER` / `OBS_AUTH_PASSWORD`。
- **独立域名**：在 `SITES` 里写如 `logs.example.com victorialogs`，打开即直达，见「域名与 TLS」。
- 卸载 VM 或 VL 时，OTel 导出和 Traefik 入口（容器标签）随容器一起撤掉。

## 告警

```bash
# config.env 里配置飞书群机器人（群设置 → 机器人 → 自定义机器人）
ALERT_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/xxxx"
ALERT_FEISHU_SECRET=""     # 机器人开启「签名校验」时填写
make victoriametrics otel alert
```

链路：vmalert 每分钟按规则查 VictoriaMetrics → Alertmanager 分组、去重，4 小时重复一次，恢复时也发 → `alert-feishu` 转成飞书文本消息。

- 没配置 Webhook 时，告警只打印到 `docker logs base-alert-alert-feishu-1`。
- 改了 Webhook 后执行 `make alert` 生效。
- 规则按已装组件生成，装/卸组件后自动更新：

| 规则 | 条件 | 启用条件 |
|---|---|---|
| HostMetricsMissing | 10 分钟没有主机指标 | 装了 otel |
| DiskUsageHigh / MemoryUsageHigh / LoadHigh | 磁盘 >85%、内存 >90%（持续 10 分钟）；15 分钟负载 > 2 倍核数（持续 15 分钟） | 装了 otel |
| ContainerDown | 已装组件的容器停止超过 5 分钟 | 装了 otel |
| ContainerRestarting | `base-*` 容器 15 分钟内重启过 | 装了 otel |
| BackupFailed / BackupNotRunning | 最近一次备份失败；超过 26 小时没跑备份 | 装了 backup |
| CertExpiringSoon | 证书剩余不足 14 天（正常 30 天内会自动续期） | 启用了 TLS |

- 自定义规则：在 `templates/alert/rules/` 加文件，并登记到 `steps/alert.sh` 的 `ALERT_RULES`。
- 维护期间不想收告警：在 `/am/` 页面加静默（Silence）。
- 局限：告警组件自己（vmalert、Alertmanager、转发器）挂了不会有告警，`make status` 能看到。

## 维护与更新

```bash
make status                  # 查看组件、证书状态与站点一览
make update                  # 拉取最新代码并自动同步已安装组件（如按 SITES 刷新 Traefik 站点）
```

## 备份与恢复

```bash
make backup                  # 启用每日定时备份（默认 03:30）
make backup-now              # 立即备份一次
make status                  # 看最近一次备份
make restore-postgres        # 用最新一份恢复，需输入 yes 确认
make restore-redis BACKUP=20261117-033000 CONFIRM=yes
```

每次备份是 `$BACKUP_DIR/<时间>/` 下的一个目录（0700），保留最近 `BACKUP_KEEP` 份（默认 7 份）：

| 组件 | 备份文件 | 方式 |
|---|---|---|
| postgres | `postgres.sql.gz` | `pg_dumpall`，不停服务 |
| redis | `redis.rdb.gz` | `redis-cli --rdb`，不停服务 |
| victoriametrics | `victoriametrics.tar.gz` | 快照，不停服务 |
| traefik | `traefik.tar.gz` | `acme.json`（证书与 Let's Encrypt 账号）；重签也行，备份是为了避开签发频率限制 |
| — | `credentials.env` | 备份当时的账号密码 |

- VictoriaLogs 的日志不备份。
- **只在本机**：磁盘坏了备份会一起丢。用 `BACKUP_POST_HOOK` 把每次的备份目录（`$1`）复制到异地，例如 `rclone copy "$1" remote:hostkit/$(hostname)/$(basename "$1")`。钩子失败也算备份失败。
- 每次备份结果会推送到 VictoriaMetrics（`hostkit_backup_success`、`hostkit_backup_last_run_timestamp_seconds`），装了 alert 时失败或停跑会告警；systemd 里也能看到：`journalctl -u hostkit-backup`。
- 定时任务直接调用本目录下的 `install.sh`，挪动目录后要重新执行 `make backup`。

**恢复**：

- 组件要先在运行。
- 原数据目录不会删除，会改名为 `<组件>/data.before-restore-<时间>`（traefik 为 `acme.before-restore-<时间>`）。确认无误后手工删除。
- postgres 在新初始化的空库上导入，导入后把密码改回 `credentials.env` 里的当前值。
- redis 开着 AOF：先关 AOF 载入 RDB，再在线开启 AOF 等它重写完，最后正常启动。
- 换新机器恢复：
  1. 装好阶段 1、2。
  2. 把备份目录拷到 `$BACKUP_DIR`。
  3. 把其中的 `credentials.env` 放到 `/opt/base/`。
  4. `make redis postgres ...`，再逐个 `make restore-<组件>`。

## 账号密码

所有账号密码统一放在 `/opt/base/credentials.env`（`$DEPLOY_DIR/credentials.env`，0600，仅 root 可读），组件只从这里读。`make credentials` 显示文件位置和其中有哪些变量（不打印密码），查看密码用 `sudo cat /opt/base/credentials.env`。

| 变量 | 组件 | 默认 |
|---|---|---|
| `REDIS_PASSWORD` | redis | 随机 48 位 |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | postgres | `postgres` / 随机 |
| `OBS_AUTH_USER` / `OBS_AUTH_PASSWORD` | traefik（`/vm/` `/vl/` 等观测入口与 Dashboard） | `admin` / 随机 |

- **自动生成**：安装组件时缺什么生成什么，已有的不覆盖。
- **预生成**：`make passwords`（全部）或 `make passwords STEPS="redis postgres"`，生成后再安装。
- **手填**：安装前在文件里写好 `KEY=VALUE`，安装时直接使用。
  - 用户名：小写字母、数字、下划线。
  - 密码：16-128 位字母、数字或 `._~+-`。
  - 不合规会拒绝安装，避免 `$`、`:`、引号被 compose 或 htpasswd 误解析。
- **手改密码**：直接改文件里的值，再执行 `make <组件>` 生效（redis 重建容器，postgres 同步到库里，traefik 重建容器）。
- **轮换**：`make rotate-password-redis` / `rotate-password-postgres` / `rotate-password-traefik`，需确认，非交互加 `CONFIRM=yes`。
  - redis：重建容器。
  - postgres：在库里 `ALTER USER`，不重启。
  - traefik：重写 htpasswd 并重建容器。
  - 使用方要同步换密码。
- **改用户名**：Postgres 用户名只在首次初始化数据目录时生效，之后改要手工在库里处理；观测入口用户名改完执行 `make traefik` 即生效。
- **清除**：清除组件时，它的账号密码一并从文件中删除。

## 代码结构

```
install.sh              # 入口 + 步骤表 STEPS（阶段、顺序、说明）
versions.env            # 所有镜像版本，唯一出处
lib/credentials.sh      # 账号密码：生成、校验、轮换
lib/common.sh           # 通用函数：日志、状态记录、配置加载、环境识别；项目名 PROJECT=hostkit 在文件开头
lib/components.sh       # compose 组件框架：安装/卸载/清除、就绪检查、组件间联动
lib/status.sh           # make status
steps/<步骤>.sh         # 每个步骤/应用一个文件
templates/<组件>/       # 组件的 docker-compose.yml 及配置模板
```

每个 `steps/<名称>.sh` 按约定实现函数，`install.sh` 按名称调用，没实现的就跳过：

| 函数 | 作用 |
|---|---|
| `<名称>_install` | 安装（必需） |
| `<名称>_uninstall` | 卸载，保留数据 |
| `<名称>_purge` | 删除数据（在卸载之后执行） |
| `<名称>_purge_hint` | 清除前提示要删什么；不实现时显示「说明：$DEPLOY_DIR/<名称>」 |

compose 组件另外在文件里登记 `COMPONENTS+=(...)`（服务名、就绪检查），并实现 `<名称>_env`（输出 `.env`），可选 `_prepare/_post/_postundo/_sync/_rotate`，要支持备份就实现 `_backup/_restore`，钩子说明见 `lib/components.sh` 文件头。

**新增一个 compose 应用**（以 `foo` 为例）：

1. 新建 `templates/foo/docker-compose.yml`，网络用外部网络 `${NETWORK_NAME}`，镜像用 `${IMAGE}`。
2. 新建 `steps/foo.sh`，参照 `steps/postgres.sh`。
3. 在 `install.sh` 的 `STEPS` 里加一行 `"3 foo 说明"`。
4. 镜像版本加到 `versions.env`，如 `FOO_IMAGE=foo:1.2.3`，在 `foo_env` 里输出 `IMAGE=$FOO_IMAGE`。

`make foo`、`make uninstall-foo`、`make purge-foo` 会自动生效。

## 测试

```bash
make test           # shellcheck + Ubuntu 22.04/24.04/26.04 单测 + Traefik 路由/OTel/告警规则/Alertmanager/compose 模板校验，需本机 Docker
```

## 许可证

[Apache License 2.0](LICENSE)。
