# 外部应用接入与部署规范指南 —— 以 wechat-account 为例

本文档定义如何将任意外部业务系统（Docker Compose 架构）标准化接入到 **HostKit** 基础设施底座中，实现 **HTTPS 自动签发**、**统一域名网关**、**WebSocket/SSE 协议代理**、**无侵入式 VictoriaLogs 日志聚合** 与 **单容器定向热更新**。

本文以 **`wechat-account`（微信公众号 AI 创作平台）** 为完整落地范例。

---

## 一、 为什么采用「外部应用」接入架构？

在 HostKit 架构中，服务被清晰划分为两类：

1. **基础环境组件（HostKit 内置）**：通过 `make <组件>` 安装在 `/opt/base/`（如 Traefik、OTel Collector、VictoriaLogs、VictoriaMetrics、Redis、PostgreSQL、Alertmanager 等）。
2. **业务应用栈（外部独立应用）**：业务代码（如电商系统、CRM、微信运营平台、AI 服务等）**不侵入 HostKit 核心仓库**，而是作为独立 Compose 栈部署在 `/opt/<app-name>`。

### 核心收益
- **生命周期解耦**：业务频繁发布、热重启、数据库 Migration 不影响 HostKit 底座及其他业务；
- **配置与数据隔离**：业务数据卷与密钥独立管理，不产生单点耦合；
- **零成本享受平台能力**：外部应用只要接入 HostKit，即可免费获得泛域名/单域名 Let's Encrypt 证书、强制 HTTPS、WebSocket 升级代理、容器指标监控以及全局集中式日志检索。

---

## 二、 外部应用接入 HostKit 的三大标准契约

```mermaid
flowchart TD
    subgraph HostKit 统一基础设施底座 [/opt/base]
        Traefik["Traefik 网关 (80/443)<br/>ACME 自动续期 / HTTP2 / WebSocket / SSE"]
        OTel["OTel Collector (采集器)<br/>filelog/docker 实时抓取"]
        VL["VictoriaLogs (日志检索)<br/>vlog.costalong.cn"]
        VM["VictoriaMetrics (指标监控)<br/>CPU / 内存 / 重启次数"]
    end

    subgraph 外部业务应用栈 [/opt/wechat-account]
        App["App 核心容器 (:8081)"]
        Collab["Collab 协同容器 (:8082)"]
        DB[("PostgreSQL 16 + pgvector (:5432)")]
    end

    Client["公网客户端 (浏览器)"] -->|"HTTPS / WSS"| Traefik
    Traefik -->|"反向代理 172.17.1.1:8081"| App
    App -.->|"读写与向量检索"| DB
    Collab -.->|"内部鉴权通信"| App

    App -.->|"stdout 日志"| DockerLog["/var/lib/docker/containers/*/*.log"]
    Collab -.->|"stdout 日志"| DockerLog
    DockerLog ==>|"自动监听"| OTel
    OTel ==>|"批量转存"| VL
    OTel -.->|"docker_stats 容器指标"| VM
```

### 1. 流量与网关契约（Traffic Ingress）
- **端口映射**：外部应用将对外 HTTP 服务映射至宿主机指定端口（例如 `8081:8081`）。
- **反代目标**：HostKit Traefik 位于 `base-net` 桥接网络中，通过默认网关 `172.17.1.1:端口` 访问业务容器（网关 IP 随时可通过 `docker network inspect base-net` 验证）。
- **自动获得的网关特性**：
  - 自动向 Let's Encrypt 申领单域名证书，并在临期时由 systemd timer 自动续期；
  - HTTP 80 访问全自动 301 强制跳转至 HTTPS 443；
  - 原生配置 `Upgrade` / `Connection` 协议升级头，透传 WebSocket 连接；
  - 配置 `proxy_read_timeout 3600s`，支持大模型流式输出（SSE）与长连接不被异常掐断。

### 2. 可观测性接入契约（Observability）
- **日志标准（零侵入）**：
  - 外部应用无需集成专门的日志 SDK 或 Daemon，只需按标准输出到 `stdout` / `stderr`（Docker json-file 驱动）；
  - 推荐采用 JSON 格式输出，包含 `service`、`level`、`msg`、`request_id` 字段；
  - HostKit 执行 `make otel` 启动收集器后，会自动监听本机所有容器日志并实时导入 VictoriaLogs。
- **指标标准**：
  - 应用暴露 Prometheus 格式的 `/metrics`，Compose 里给服务加标签即可被自动抓取进 VictoriaMetrics：
    ```yaml
    labels:
      - "prometheus.io/scrape=true"
      - "prometheus.io/port=8081"        # 可选，默认镜像声明的端口
      - "prometheus.io/path=/metrics"    # 可选
    ```
  - 容器必须接入 `base-net`；在 vmui 里按 `{container="..."}` 或 `{service="..."}` 查询。
- **健康检查标准**：
  - 应用建议暴露 `/healthz`（存活探测，返回 200 OK）与 `/readyz`（就绪探测，依赖的 DB、缓存就绪后返回 200 OK）。

### 3. 运维与更新契约（Lifecycle & Ops）
- **独立目录管理**：推荐统一部署至 `/opt/<应用名称>/`（如 `/opt/wechat-account`）。
- **环境隔离**：生产密钥放置于 `/opt/<应用名称>/.env`，权限设置为 `0600`。
- **单服务定向更新**：每个业务栈应配备标准维护脚本，支持只更新 `app` 或只更新 `collab`，避免无关服务中断。

---

## 三、 实战：以 wechat-account 为例的完整接入流程

### 第一步：准备业务部署目录与配置

在服务器上创建独立的部署目录 `/opt/wechat-account`：

```bash
mkdir -p /opt/wechat-account/docker /opt/wechat-account/api/configs /opt/wechat-account/scripts
```

创建 `/opt/wechat-account/.env`（权限 `0600`）：

```dotenv
POSTGRES_USER=wechat
POSTGRES_PASSWORD=your_strong_password
POSTGRES_DB=wechat_articles
DB_PORT=5432

JWT_SECRET=your_jwt_secret_32bytes
COLLAB_SERVICE_TOKEN=your_collab_token_32bytes
WECHAT_MASTER_KEY=your_encryption_master_key_32bytes

# 镜像引用（腾讯云 CCR 预置镜像）
APP_IMAGE=ccr.ccs.tencentyun.com/kart/wechat-account-app:v0.1.4
COLLAB_IMAGE=ccr.ccs.tencentyun.com/kart/wechat-account-collab:v0.1.4
```

将业务 `docker-compose.yml` 放置在 `/opt/wechat-account/docker/docker-compose.yml`。

### 第二步：拉取基础镜像并启动业务容器

```bash
cd /opt/wechat-account

# 1. 预拉取带 pgvector 扩展的基础数据库镜像
docker pull pgvector/pgvector:pg16

# 2. 启动数据库并等待健康探测通过
docker compose -p wechat-account -f docker/docker-compose.yml --env-file .env up -d --wait db

# 3. 执行启动前数据预检
sh ./scripts/cordis-cutover-preflight.sh docker/docker-compose.yml .env wechat-account
sh ./scripts/migrate-app-data-volume.sh docker/docker-compose.yml .env wechat-account

# 4. 启动应用核心服务（自动执行全套 SQL 迁移）
docker compose -p wechat-account -f docker/docker-compose.yml --env-file .env up -d --no-build app collab

# 5. 验证业务容器状态
docker compose -p wechat-account -f docker/docker-compose.yml --env-file .env ps
```

### 第三步：HostKit 域名接入与自动 HTTPS

1. 在 DNS 服务商处，将需要绑定的域名（如 `crm.costalong.cn`）添加 A 记录解析到服务器公网 IP。
2. 编辑 HostKit 配置文件 `~/hostkit/config.env`，在 `SITES` 列表中追加映射：
   ```dotenv
   SITES="
   crm.costalong.cn     172.17.1.1:8081
   vlog.costalong.cn    victorialogs
   "
   ```
3. 在 `~/hostkit` 执行生效命令：
   ```bash
   cd ~/hostkit
   make traefik
   ```
   HostKit 会自动向 Let's Encrypt 签发 SSL 证书、自动配置 HTTP 跳转 HTTPS 及 WebSocket 反代，Traefik 监听配置目录，无需重启。
4. 验证公网连通性：
   ```bash
   curl -sI https://crm.costalong.cn/       # 返回 HTTP/2 200 OK
   curl -s https://crm.costalong.cn/readyz   # 返回 {"status":"ok"}
   ```

### 第四步：打通日志到 VictoriaLogs

如果服务器上尚未启动 OTel 收集器，在 `~/hostkit` 目录执行一次：

```bash
cd ~/hostkit
make otel
```

- OTel 容器启动后，自动实时抓取 `/opt/wechat-account` 容器的 stdout 日志。
- 打开浏览器访问 **`https://vlog.costalong.cn/`**，输入 `wechat-api` 或 `service: "wechat-api"` 即可实时查看和检索业务日志。

---

## 四、 运维操作指引：如何更新某一个具体的 Docker 服务？

在日常维护中，无需重新启动整个项目，可根据变更场景单独更新某一个具体的容器服务：

### 1. 更新业务应用中的单个服务（推荐使用 scripts/update.sh）

在 `/opt/wechat-account/scripts/update.sh` 中已内置安全单服务更新机制：

```bash
cd /opt/wechat-account

# 仅更新核心 API / Web 前端容器 (app)
sh scripts/update.sh app

# 仅更新协同编辑容器 (collab)
sh scripts/update.sh collab

# 指定新镜像 tag 并单独更新 app
sh scripts/update.sh app v0.1.5

# 全量更新应用容器 (app + collab)
sh scripts/update.sh
```

> **注：也可以在开发机本地终端一键远程触发**：
> ```bash
> ssh ubuntu@<服务器IP> "cd /opt/wechat-account && sh scripts/update.sh app"
> ```

#### 原生 Docker Compose 单服务操作命令
```bash
# 强制重建并替换单个服务容器（保留数据库运行）
docker compose -p wechat-account -f docker/docker-compose.yml --env-file .env up -d --no-build --force-recreate app

# 改了挂载的配置文件（如 api/configs/config.yaml），不重建镜像仅重启生效
docker compose -p wechat-account -f docker/docker-compose.yml --env-file .env restart app
```

---

### 2. 更新 HostKit 自身管理的基础设施单个服务

HostKit 的基础设施容器相互解耦，进入 `~/hostkit` 目录执行 `make <组件名>` 即可仅更新对应服务：

| 目标服务 | 执行命令 | 说明 |
|---|---|---|
| **Traefik 网关** | `make traefik` | 按 SITES 重新生成站点路由并自动签发新证书 |
| **OTel Collector** | `make otel` | 仅重新拉取/应用采集配置（`config.yaml`）并重启收集器 |
| **VictoriaLogs** | `make victorialogs` | 仅更新 VictoriaLogs 引擎，已有日志卷数据完全保留 |
| **VictoriaMetrics** | `make victoriametrics` | 仅更新 VictoriaMetrics 指标引擎 |
| **同步 HostKit 仓库** | `make update` | 自动拉取 Git 最新代码并自动热同步所有已运行组件 |

---

## 五、 自动化更新脚本实现参考 (`scripts/update.sh`)

放置于 `/opt/wechat-account/scripts/update.sh`（赋予执行权限 `chmod +x`）：

```bash
#!/bin/sh
# 在部署服务器上运行：安全更新指定的 Docker 容器服务并校验就绪状态
# 用法:
#   sh scripts/update.sh                 # 默认更新所有应用服务 (app + collab)
#   sh scripts/update.sh app             # 仅更新核心 API / Web 前端 (app)
#   sh scripts/update.sh collab          # 仅更新协同编辑服务 (collab)
#   sh scripts/update.sh app v0.1.5      # 指定新镜像 tag 并更新 app
set -eu

DEPLOY_DIR="/opt/wechat-account"
cd "$DEPLOY_DIR"

COMPOSE_FILE="docker/docker-compose.yml"
ENV_FILE=".env"
PROJECT="${COMPOSE_PROJECT_NAME:-wechat-account}"

if [ ! -f "$ENV_FILE" ]; then
    echo "缺少 $ENV_FILE，无法执行更新" >&2
    exit 1
fi

TARGET="${1:-all}"
TAG="${2:-}"

# 兼容第一个参数直接传 tag 的情况
if [ "$TARGET" != "app" ] && [ "$TARGET" != "collab" ] && [ "$TARGET" != "all" ]; then
    TAG="$TARGET"
    TARGET="all"
fi

if [ -n "$TAG" ]; then
    echo ">> 更新 .env 镜像标签为: $TAG"
    if [ "$TARGET" = "app" ]; then
        sed -i "s|^\(APP_IMAGE=.*:\).*|\1${TAG}|" "$ENV_FILE"
    elif [ "$TARGET" = "collab" ]; then
        sed -i "s|^\(COLLAB_IMAGE=.*:\).*|\1${TAG}|" "$ENV_FILE"
    else
        sed -i "s|^\(APP_IMAGE=.*:\).*|\1${TAG}|" "$ENV_FILE"
        sed -i "s|^\(COLLAB_IMAGE=.*:\).*|\1${TAG}|" "$ENV_FILE"
    fi
fi

compose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

echo ">> 确保数据库健康运行..."
compose up -d --wait db

SERVICES="app collab"
if [ "$TARGET" = "app" ]; then
    SERVICES="app"
elif [ "$TARGET" = "collab" ]; then
    SERVICES="collab"
fi

echo ">> 执行切换与数据卷迁移预检..."
sh ./scripts/cordis-cutover-preflight.sh "$COMPOSE_FILE" "$ENV_FILE" "$PROJECT"
sh ./scripts/migrate-app-data-volume.sh "$COMPOSE_FILE" "$ENV_FILE" "$PROJECT"

echo ">> 重新拉起指定服务: $SERVICES..."
compose up -d --no-build --force-recreate --wait --wait-timeout 300 $SERVICES

echo ">> 执行健康检查探测..."
if [ "$TARGET" = "all" ] || [ "$TARGET" = "app" ]; then
    curl -fsS http://localhost:8081/healthz >/dev/null && echo "  - API healthz: OK"
    curl -fsS http://localhost:8081/readyz >/dev/null && echo "  - API readyz: OK"
fi
if [ "$TARGET" = "all" ] || [ "$TARGET" = "collab" ]; then
    curl -fsS http://localhost:8082/readyz >/dev/null && echo "  - Collab readyz: OK"
fi

echo ">> 更新完成，当前容器状态："
compose ps $SERVICES
```
