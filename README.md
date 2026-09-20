# YiYi Media 部署 —— 分布式·多机（`v3-multi-host`）

控制面按 `control` / `user` / `media` / `edge` **角色分散到多台机器**；
播放与存储能力由**外部工作节点**提供。

> 本仓库按 **Git 分支**区分三种部署形态，每个分支根目录都能直接
> `docker compose pull && docker compose up -d`。当前分支是 `v3-multi-host`。

## 三种形态

| 分支 | 形态 | 容器 | 工作节点 |
| --- | --- | --- | --- |
| `main` | **单机版**（v1-standalone） | `yiyi-app` + `postgres` + `redis`（3 个） | 内置 2 个，不能新增 |
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

## 数据库模式

- **bundled**（默认）：`control` 角色本机跑 `postgres` 与 `redis`。
- **external**：使用已有 PostgreSQL / Redis，设置 `YIYI_DB_MODE=external`
  与 `YIYI_DB_HOST` / `YIYI_REDIS_HOST` 等；安装脚本会把
  `YIYI_POSTGRES_REPLICAS` 置 0。

## 安全红线

1. **凭据不外泄**：数据库口令、服务令牌、节点令牌、集群令牌（`join.env`）、
   许可证私钥一律不得提交到仓库，也不要在工单、日志或截图里回显。
   `.env` 权限保持 `600`。
2. **机器间入站端口**：`config`(18085) 需被所有角色与工作节点访问；
   `postgres`(5432) / `redis`(6379) 只应在内网可达，**不要暴露到公网**。
3. **许可证信任根**：`YIYI_LICENSE_PUBLIC_JWK_FILE` 指向的公钥必须与镜像内置的
   信任根一致，安装脚本会在启动前强校验，不一致直接中止。
