# YiYi Media 部署 —— 分布式·控制面同机（`v2-all-in-one`）

一台服务器承载**全部控制面服务**；播放与存储能力由**外部工作节点**提供。

> 本仓库按 **Git 分支**区分三种部署形态，每个分支根目录都能直接
> `docker compose pull && docker compose up -d`。当前分支是 `v2-all-in-one`。

## 三种形态

| 分支 | 形态 | 容器 | 工作节点 |
| --- | --- | --- | --- |
| `main` | **单机版**（v1-standalone） | `yiyi-app` + `postgres` + `redis`（3 个） | 内置 2 个，不能新增 |
| **`v2-all-in-one`**（本分支） | **分布式·控制面同机** | 8 个（见下） | 外部，可任意新增 |
| `v3-multi-host` | **分布式·多机** | 每台机器按角色跑其中一部分 | 外部，可任意新增 |

许可证：单机版分支要求 `edition=STANDALONE`；两个分布式分支要求 `edition=DISTRIBUTED`。
Edition 写在**签名租约**里，由服务端强制，改环境变量无法越权。

## 本分支的拓扑

```
一台服务器（控制面）
├── frontend      :18080   浏览器入口（后台 + 用户门户）
├── gateway       :18086   统一 API 网关
├── config        :18085   配置、节点管理、二进制分发
├── user          :18082   用户与播放线路
├── media         :18083   媒体库与刮削
├── license-agent :18088   许可证租约
├── postgres      :5432    数据库（默认绑内网地址）
└── redis         :6379    缓存（默认绑内网地址）

其他机器（工作节点，不在本文件里）
├── Storage 节点      ← 网页「节点管理」新增，用页面给出的一键命令部署
└── Play Agent 节点   ← 同上，可多台
```

**工作节点不在本仓库的 Compose 文件里。** 在网页「节点管理」新增节点后，
页面会给出该节点专用的一键安装命令（安装脚本与节点二进制由 `config` 服务分发）。
这也是本形态与单机版的关键区别：单机版的节点是内置的，不能新增外部节点。

## 文件

| 文件 | 用途 |
| --- | --- |
| `compose.yaml` | 控制面 8 个服务的编排（**无 profile**，直接 up 即可） |
| `install.sh` | 安装 / 升级脚本（固定控制面同机，不需要角色选择） |
| `.env.example` | 环境变量模板 |
| `postgres-init.sql` | 首次启动时建库建角色 |
| `OPERATIONS.md` | 日常运维（备份、升级、排障） |
| `RELEASING.md` | 镜像发布说明 |

## 部署步骤

```bash
git clone -b v2-all-in-one <仓库地址> yiyi && cd yiyi
cp .env.example .env
# 填写必填项：YIYI_SERVER_HOST / YIYI_PUBLIC_HOST / YIYI_DATA_DIR /
#            YIYI_DB_PASSWORD / YIYI_LICENSE_PUBLIC_JWK_FILE / YIYI_IMAGE_TAG
sudo ./install.sh
```

装完后直接访问 `http://<YIYI_PUBLIC_HOST>:18080`，首次使用在网页上完成许可证激活。

后续升级：

```bash
git pull --ff-only
sudo ./install.sh          # 幂等，会按需重建容器
```

也可以用原生 Compose 命令（`.env` 已就绪时 `docker compose` 会自动读取）：

```bash
docker compose pull
docker compose up -d
docker compose ps
```

### 只跑部分服务？本分支不支持

本分支固定控制面同机，`docker compose up -d` 会启动全部 8 个服务。
如果只需要其中一部分，请用 `v3-multi-host` 分支——那里每个角色一台机器，
可以只在本机跑需要的角色。

## 数据库与缓存（可任选自带或外部，互相独立）

| 变量 | 取值 | 效果 |
| --- | --- | --- |
| `YIYI_DB_MODE` | `bundled`（默认） | 本机启动 `postgres` 容器 |
| | `external` | **不启动** `postgres` 容器，用你的 PostgreSQL |
| `YIYI_REDIS_MODE` | `bundled`（默认） | 本机启动 `redis` 容器 |
| | `external` | **不启动** `redis` 容器，用你的 Redis |

两者**独立**，因此支持任意组合，例如：

```bash
# 用外部 PostgreSQL + 本机自带 Redis
YIYI_DB_MODE=external
YIYI_DB_HOST=db.internal
YIYI_DB_USER=yiyi
YIYI_DB_PASSWORD=<外部库口令>
YIYI_REDIS_MODE=bundled
```

```bash
# 数据库与 Redis 都用外部的（本机只有 6 个应用容器）
YIYI_DB_MODE=external
YIYI_DB_HOST=db.internal
YIYI_DB_USER=yiyi
YIYI_DB_PASSWORD=<外部库口令>
YIYI_REDIS_MODE=external
YIYI_REDIS_HOST=redis.internal
YIYI_REDIS_PASSWORD=<外部缓存口令>
```

实现方式是 Compose profile：安装脚本按你的选择写入
`COMPOSE_PROFILES=bundled-postgres,bundled-redis` 的子集，
未选中的服务根本不会创建容器。

::: warning 使用外部 PostgreSQL 的前置条件
外部实例需要预先建好 `yiyi_config`、`yiyi_user`、`yiyi_media`、`yiyi_storage`
四个库与 `yiyi` 角色，可参考本仓库的 `postgres-init.sql`。
安装脚本会强校验 `YIYI_DB_HOST` / `YIYI_DB_USER` / `YIYI_DB_PASSWORD` 是否已填写。
:::

### 只用原生 Compose 命令时

直接用 `docker compose` 时同样受 `.env` 的 `COMPOSE_PROFILES` 控制；
若要临时覆盖，可显式指定：

```bash
# 只起应用服务，不起本机数据库（用外部库）
COMPOSE_PROFILES= docker compose up -d
# 自带数据库 + Redis
COMPOSE_PROFILES=bundled-postgres,bundled-redis docker compose up -d
```

## 与旧版（`single` 角色）的关系

本分支的形态等价于旧版的 `YIYI_DEPLOY_ROLE=single`：控制面全在一台机器、
工作节点在外部。旧部署升级到本分支时：

- `.env` 中的 `YIYI_DEPLOY_ROLE` 会被忽略（并打印提示），不需要手工删除；
- 旧版通过 profile 选择服务，本分支已移除 profile——`docker compose up -d`
  的行为从「按 profile 起一部分」变为「起全部控制面服务」，这正是同机形态的预期；
- 容器与 Compose 项目名仍是 `yiyi`，升级时能认出既有容器。

## 安全红线

1. **凭据不外泄**：数据库口令、服务令牌、节点令牌、许可证私钥一律不得提交到仓库，
   也不要在工单、日志或截图里回显。`.env` 权限保持 `600`。
2. **工作节点入站端口**：`config`(18085) 需要被工作节点访问（注册、心跳、
   拉取安装脚本）；`postgres`/`redis` 默认只绑内网地址，不要暴露到公网。
3. **许可证信任根**：`YIYI_LICENSE_PUBLIC_JWK_FILE` 指向的公钥必须与镜像内置的
   信任根一致，安装脚本会在启动前强校验，不一致直接中止。
