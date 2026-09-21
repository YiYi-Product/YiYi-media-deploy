# YiYi Media 部署 —— 分布式·多机（`v3-multi-host`）

控制面按 `control` / `user` / `media` / `edge` **角色分散到多台机器**；
播放与存储能力由**外部工作节点**提供。

> 本仓库按 **Git 分支**区分三种部署形态，每个分支根目录都能直接
> `docker compose pull && docker compose up -d`。当前分支是 `v3-multi-host`。

## 三种形态

| 分支 | 形态 | 容器 | 工作节点 |
| --- | --- | --- | --- |
| `main` | **单机版**（v1-standalone） | `yiyi-media` + `postgres` + `redis`（3 个） | 内置 2 个，不能新增 |
| `v2-all-in-one` | **分布式·控制面同机** | 8 个，全在一台机器 | 外部，可任意新增 |
| **`v3-multi-host`**（本分支） | **分布式·多机** | 每台机器按角色跑其中一部分 | 外部，可任意新增 |

许可证：单机版分支要求 `edition=STANDALONE`；两个分布式分支要求 `edition=DISTRIBUTED`。
Edition 写在**签名租约**里，由服务端强制，改环境变量无法越权。

## 角色划分

每台机器通过 `.env` 的 `YIYI_DEPLOY_ROLE` 决定本机跑哪些服务
（安装脚本会写入 `COMPOSE_PROFILES`，Compose 按 profile 启停）：

| 角色 | 本机服务 | 说明 |
| --- | --- | --- |
| `control` | postgres、redis、license-agent、config | 控制中枢；`config` 需被其他机器访问 |
| `user` | license-sync、user | 用户与播放线路 |
| `media` | license-sync、media | 媒体库与刮削 |
| `edge` | license-sync、gateway、frontend | 对外入口（浏览器访问这台） |

`control` / `user` / `media` / `edge` 是**分布式部署内部的角色**，
不是独立的部署模式。`license-sync` 在 user / media / edge 上从 `control` 同步租约。

```
       ┌──────────── edge ────────────┐
       │ frontend :18080  gateway :18086 │ ← 浏览器入口
       └───────────────┬───────────────┘
                       │
       ┌──────────── control ──────────┐
       │ config :18085  license-agent  │
       │ postgres :5432 redis :6379     │
       └───────┬───────────────┬───────┘
               │               │
        ┌──────┴─────┐   ┌─────┴──────┐
        │ user :18082│   │ media :18083│
        └────────────┘   └────────────┘

   工作节点（其他机器，不在本文件里）
   ├── Storage 节点      ← 网页「节点管理」新增，一键命令部署
   └── Play Agent 节点   ← 同上，可多台
```

## 文件

| 文件 | 用途 |
| --- | --- |
| `compose.yaml` | 全部服务 + profile（按角色启停） |
| `install.sh` | 安装 / 升级脚本（读 `YIYI_DEPLOY_ROLE` 决定本机角色） |
| `.env.example` | 环境变量模板 |
| `postgres-init.sql` | 首次启动时建库建角色（仅 control 角色用到） |
| `OPERATIONS.md` | 日常运维（备份、升级、排障） |
| `RELEASING.md` | 镜像发布说明 |

## 部署步骤

**每台机器**各做一次：

```bash
git clone -b v3-multi-host <仓库地址> yiyi && cd yiyi
cp .env.example .env
# 填写必填项，并设置本机角色：
#   YIYI_DEPLOY_ROLE=control|user|media|edge
#   YIYI_SERVER_HOST=<本机内网地址>
#   YIYI_PUBLIC_HOST=<对外域名或公网 IP>
sudo ./install.sh
```

顺序建议：先 `control`（数据库与配置中心），再 `user` / `media`，最后 `edge`。

`control` 角色装完后会生成 `join.env` 与 `cluster-relay.crt`，
需要通过**安全方式**复制到其他角色的机器上（其中含集群令牌，不要走明文渠道）。

后续升级：

```bash
git pull --ff-only
sudo ./install.sh          # 幂等
```

当升级首次引入 `YIYI_NODE_TOKEN` 的旧部署时，先在 control 运行脚本生成新的 `join.env`，
再把它重新分发到 user / media / edge 后依次升级。其他角色不会各自生成节点密钥，
避免同一集群出现多把不一致的密钥。控制面升级后，还需对已有 Storage / Play Agent 执行一次新版节点升级命令。

也可以用原生 Compose 命令（`.env` 已就绪时自动读取 profile）：

```bash
docker compose pull
docker compose up -d
docker compose ps
```

### 只跑部分服务

本分支天然按角色拆分：设置不同的 `YIYI_DEPLOY_ROLE`，
或用 `docker compose --profile <角色> up -d` 直接指定。
若控制面全在一台机器上，用 `v2-all-in-one` 分支更省事（无需角色与 join 分发）。

## 数据库与缓存（可任选自带或外部，互相独立）

只在 `control` 角色上生效：

| 变量 | 取值 | 效果 |
| --- | --- | --- |
| `YIYI_DB_MODE` | `bundled`（默认） | `control` 上启动 `postgres` 容器 |
| | `external` | **不启动**，用你的 PostgreSQL（需填 `YIYI_DB_HOST`） |
| `YIYI_REDIS_MODE` | `bundled`（默认） | `control` 上启动 `redis` 容器 |
| | `external` | **不启动**，用你的 Redis（需填 `YIYI_REDIS_HOST`） |

两者**独立**，支持任意组合：

```bash
# 外部 PostgreSQL + 自带 Redis
YIYI_DB_MODE=external
YIYI_DB_HOST=db.internal
YIYI_DB_USER=yiyi
YIYI_DB_PASSWORD=<外部库口令>
YIYI_REDIS_MODE=bundled
```

```bash
# 数据库与 Redis 都用外部（control 只剩 2 个容器：license-agent、config）
YIYI_DB_MODE=external
YIYI_DB_HOST=db.internal
YIYI_DB_USER=yiyi
YIYI_DB_PASSWORD=<外部库口令>
YIYI_REDIS_MODE=external
YIYI_REDIS_HOST=redis.internal
YIYI_REDIS_PASSWORD=<外部缓存口令>
```

其他角色（`user` / `media` / `edge`）通过 `.env` 的
`YIYI_DB_HOST` / `YIYI_REDIS_HOST` 指向 `control` 或你的外部实例，
它们不涉及这两个 mode 变量。

::: warning 使用外部 PostgreSQL 的前置条件
外部实例需预先建好 `yiyi_config`、`yiyi_user`、`yiyi_media`、`yiyi_storage`
四个库与 `yiyi` 角色，可参考本仓库的 `postgres-init.sql`。
:::

### 实现说明

`control` 的服务用 profile `control` 启停，而 Compose 的 profile 是**「或」**
语义——启用 `control` 必然带起 postgres/redis，无法用 profile 单独剔除。
因此这两个服务改用 `deploy.replicas`（`YIYI_POSTGRES_REPLICAS` /
`YIYI_REDIS_REPLICAS`）控制，安装脚本按上面的 mode 写 0 或 1。

## 安全红线

1. **凭据不外泄**：数据库口令、服务令牌、节点令牌、集群令牌（`join.env`）、
   许可证私钥一律不得提交到仓库，也不要在工单、日志或截图里回显。
   `.env` 权限保持 `600`。
2. **机器间入站端口**：`config`(18085) 需被所有角色与工作节点访问；
   `postgres`(5432) / `redis`(6379) 只应在内网可达，**不要暴露到公网**。
3. **许可证信任根**：`YIYI_LICENSE_PUBLIC_JWK_FILE` 指向的公钥必须与镜像内置的
   信任根一致，安装脚本会在启动前强校验，不一致直接中止。
