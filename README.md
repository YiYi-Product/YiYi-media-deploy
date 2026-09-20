# YiYi Media Docker 部署

本仓库用于部署 YiYi Media，提供**两种且只有两种**正式部署模式：

| 模式 | 标识 | 标准拓扑 | 对应许可证 |
| --- | --- | --- | --- |
| **单机版部署** | `STANDALONE` | 一台服务器，`yiyi-app` + `postgres` + `redis` **三个容器** | `edition=STANDALONE` |
| **分布式部署** | `DISTRIBUTED` | 控制面按 `control` / `user` / `media` / `edge` 角色拆分，可异机部署 | `edition=DISTRIBUTED` |

> 部署说明一律先标明适用模式。本文每一节都会写清楚属于哪种模式。
>
> 三种形态各占一个 **Git 分支**，每个分支根目录都能直接
> `docker compose pull && docker compose up -d`：
> `main`（单机版三容器）、`v2-all-in-one`（分布式·控制面同机）、
> `v3-multi-host`（分布式·按角色多机）。

单机版部署是官方推荐的默认入门路径：Storage（`node-local-storage`）与
Play Agent（`node-local-play-agent`）**已内置在应用容器里**，随主应用安装、启动和升级，
不需要安装任何节点。分布式部署继续支持外部工作节点与横向扩容。

::: danger 两种模式不能只改配置互转
不允许只改 `.env`、Compose 文件或角色变量在两种模式之间切换。
单机版升级为分布式版必须走授权的专用版本升级操作，并完成部署拓扑迁移与数据校验，
见 [`MIGRATION.md`](MIGRATION.md)。
:::

## 仓库文件一览

| 文件 | 适用模式 | 说明 |
| --- | --- | --- |
| `compose.yaml` | 单机版 | 三容器 Compose，解析后**严格只有** `yiyi-app`、`postgres`、`redis` |
| `install.sh` | 单机版 | 单机版安装 / 升级脚本 |
| `.env.example` | 单机版 | 单机版环境变量模板 |
| `postgres-init.sql` | 两者 | 首次初始化时创建四个业务库 |
| `migrate-precheck.sh` | 迁移 | 只读预检与影响报告 |
| `MIGRATION.md` | 迁移 | 迁移、回滚与多节点阻断说明 |
| `OPERATIONS.md` | 两者 | 升级、备份、端口与安全 |

## 准备工作

- Linux 服务器（单机版一台；分布式至少四台，且在同一私有网络）
- Docker Engine 与 Docker Compose v2（`docker compose` 子命令可用）
- `openssl`、`curl`、`python3`（安装脚本启动即检查，缺一个直接退出）
- 服务器 IP 或已解析的域名
- 一个与该模式匹配的一次性授权码

## 单机版部署（三容器）

### 1. 准备配置

```bash
# main 分支即单机版；也可以显式指定 -b main
git clone https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
cd /opt/YiYi-media-deploy
cp .env.example .env
chmod 0600 .env
```

单机版默认配置已就绪，只需在 `.env` 填写：

```dotenv
YIYI_SERVER_HOST=<服务器IP或域名>
```

只有公网访问地址与服务器地址不同时，才需要填写 `YIYI_PUBLIC_HOST`。

| 变量 | 怎么填 |
| --- | --- |
| `YIYI_DB_PASSWORD` | 保持 `GENERATE_ON_INSTALL` 由脚本自动生成；已有数据库时必须填原值 |
| `YIYI_REDIS_PASSWORD` | **留空表示不启用 Redis 密码**；填 `GENERATE_ON_INSTALL` 才自动生成 |
| `YIYI_SERVICE_TOKEN` | 保持 `GENERATE_ON_INSTALL` 自动生成；已有部署必须填原值 |
| `YIYI_IMAGE_TAG` | 留空用 `latest`；生产环境建议锁定到不可变版本标签 |
| `YIYI_DATA_DIR` | 留空用部署目录下的 `data/`；可填绝对或相对路径 |

::: warning 单机版没有角色与节点安装变量
单机版不使用 `YIYI_DEPLOY_ROLE`，也没有 Control/User/Media/Edge 角色选择，
`.env` 里**没有**节点安装变量，也**不会生成** `join.env` 或集群中继证书。
:::

### 2. 执行安装脚本

```bash
sudo ./install.sh
```

脚本不接受任何参数，传参直接打印用法并退出。单机版路径上它会：

1. 检查 `.env`、命令行工具、Compose v2 与 daemon
2. 检测本机是否仍是旧一代拓扑，若是则**停止**并要求先走迁移流程
3. 固定写入部署形态 `STANDALONE`；写入 `.deployment-mode` 标记
4. 创建统一数据目录并设置最小必要权限
5. 从授权中心下载授权公钥，**与镜像内置的厂商公钥做一致性校验**，不一致直接失败
6. 在拉取镜像前校验 Compose 解析结果严格为三个服务，且不含高权限配置
7. 先起 PostgreSQL、Redis，再做四个数据库的**幂等存在性检查**（只创建缺失的库）
8. 拉取镜像、启动应用容器并等待健康检查
9. 检查全部内部服务、**两个内置节点**与许可证状态

```bash
# 日常命令（单机版不需要 -f、--profile 或 --env-file）
docker compose ps
docker compose logs --tail=100 yiyi-app
docker compose stop
docker compose start
```

> `install.sh` 会把 `COMPOSE_FILE=compose.yaml` 写进 `.env`。
> 本分支（`main`）只有单机版一套文件；分布式形态在另外两个分支，按固定文件名
> 自动发现 `compose.yaml`；写死这一项可以保证任何调用方式都解析到单机版文件。
> 不要手工删除它。

### 3. 访问并激活

```text
http://<服务器IP或域名>:18080
```

第一个页面是**授权激活页**。输入发布方提供的 `STANDALONE` 一次性授权码，
激活成功后自动跳到创建管理员向导。

### 4. 确认内置节点在线

到后台「节点管理」确认两个内置节点都是「在线」，并显示「随系统部署 / 随主版本升级」：

| 内置节点 | 节点 ID |
| --- | --- |
| Storage | `node-local-storage` |
| Play Agent | `node-local-play-agent` |

单机版的「节点管理」**只能新增手动反代地址**：没有「新增节点」按钮，也不显示节点令牌、
安装命令、卸载与独立升级。服务端同样会拒绝
（`403 NODE_CREATION_DISABLED` / `403 SYSTEM_NODE_IMMUTABLE` / 二进制分发关闭）。

### 5. 数据目录

```text
data/
├── postgres/                       # 四个业务库（PostgreSQL 16）
├── redis/                          # Redis AOF
├── license/{identity,lease}/       # 授权身份与租约
├── config/uploads/                 # 后台上传的文件
├── storage/
│   ├── mount-data/                 # 挂载数据
│   ├── spool/                      # 持久暂存区（必须保留）
│   └── read-cache/                 # 读缓存（可重建）
├── play-agent/{vfs-cache,image-cache}/
└── logs/{config,user,media,gateway,storage,play-agent,license}/
```

单机版同一个 PostgreSQL 实例承载四个数据库：`yiyi_config`、`yiyi_user`、
`yiyi_media`、`yiyi_storage`。首次初始化用 `postgres-init.sql`；**升级旧数据目录时
PostgreSQL 不会重新执行初始化 SQL**，因此安装脚本会在 PostgreSQL 健康后做幂等检查，
只创建缺失的数据库，不覆盖现有库。

### 6. 端口与网络

单机版使用 Compose 私有网络：

- PostgreSQL 在容器内用 `postgres:5432`，Redis 用 `redis:6379`；**都不发布到宿主机**。
- 应用容器内部服务互调用 `127.0.0.1:<端口>`。
- 默认只把前端 `18080` 发布到宿主机。
- Play Agent `19090` **默认只绑定宿主机回环地址**，供宿主机 nginx / Caddy 反代。
- Config、User、Media、Gateway、Storage、License Agent 的端口只在容器内部。

| 端口 | 用途 | 单机版暴露方式 |
| --- | --- | --- |
| `18080` | 前端与用户入口 | 发布到宿主机，对用户开放 |
| `19090` | Play Agent | 默认只绑宿主机回环 |
| `18082` / `18083` / `18084` / `18085` / `18086` / `18088` | 各内部服务 | 仅容器内部 |
| `5432` / `6379` | PostgreSQL / Redis | Compose 私有网络，不发布 |

::: danger 需要远程反代时才改绑定地址
确实要让另一台机器上的反代访问 Play Agent 时，显式修改
`YIYI_PLAY_AGENT_BIND_HOST`，并在防火墙与云安全组上限制来源 IP。
默认的 `127.0.0.1` 是有意为之。
:::

### 7. FUSE 与容器权限

单机版默认关闭主机 FUSE 挂载：聚合容器**不使用 `privileged`**、不授予 `SYS_ADMIN`、
不挂载 `/dev/fuse`。把 Storage 与其它服务放进同一个容器后，为挂载提权会让同一容器内
全部服务共享更高权限。

关闭 FUSE 主机挂载不影响这些能力：**云盘管理、文件浏览、上传下载、媒体同步与刮削照常可用**。

## 分布式部署

::: warning 分布式部署需要 `edition=DISTRIBUTED` 的许可证
部署形态与许可证 Edition **严格一一匹配**。拿单机版许可证激活分布式部署会被拒绝；
此时保留激活、许可证状态、日志和备份能力，不开放业务功能，**不删除任何数据**。
:::

分布式部署的文件**不在本分支**，请切换到对应分支后再按本文档操作：

| 分支 | 形态 | 适用场景 |
| --- | --- | --- |
| `v2-all-in-one` | 控制面**全部同机** | 一台服务器跑控制面，播放/存储用外部节点 |
| `v3-multi-host` | 控制面**按角色多机** | 每类服务各一台机器，可横向拆分 |

两个分支的根目录都只有一份 `compose.yaml` / `install.sh` / `.env.example`，
部署步骤见各分支自己的 `README.md`。下面「分布式部署」一节给出的是**多机形态**
（`v3-multi-host`）的角色划分，便于对照；同机形态无需角色与 `join.env` 分发。

多台服务器需要位于同一私有网络，按 `control` → `user` → `media` → `edge` 顺序安装。
`control`、`user`、`media`、`edge` 是分布式部署**内部**的角色，不是独立部署模式。

| 角色 | 启动的服务 | 数量 |
| --- | --- | --- |
| `control` | `postgres`、`redis`、`license-agent`、`config` | 4 |
| `user` | `license-sync`、`user` | 2 |
| `media` | `license-sync`、`media` | 2 |
| `edge` | `license-sync`、`gateway`、`frontend` | 3 |

### 1. 每台机器准备配置

```bash
git clone -b v3-multi-host https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
cd /opt/YiYi-media-deploy
# 分布式部署请先切换到对应分支：git checkout v2-all-in-one（或 v3-multi-host）
cp .env.example .env
chmod 0600 .env
```

### 2. 安装 control（主服务器，只装一台）

```dotenv
YIYI_DEPLOY_ROLE=control
YIYI_SERVER_HOST=<主服务器内网IP或域名>
YIYI_USER_HOST=<User服务器内网IP或域名>
```

使用外部 PostgreSQL 时，另填 `YIYI_DB_MODE=external` 与数据库地址、端口、凭据。

```bash
sudo ./install.sh
```

安装成功后会生成 `join.env`（`0600`）与 `cluster-relay.crt`（`0644`）。

### 3. 分发 `join.env` 与 `cluster-relay.crt`

把这两个文件安全复制到 `user`、`media`、`edge` 机器的**部署目录根**（不是 `config/` 子目录）：

```bash
scp -p /opt/YiYi-media-deploy/join.env \
       /opt/YiYi-media-deploy/cluster-relay.crt \
       <用户名>@10.0.0.12:/opt/YiYi-media-deploy/
```

::: danger join.env 等同于一份完整的集群凭据
它含数据库口令、服务令牌与集群同步令牌。用加密通道传输，**不要**贴到聊天工具、
不要提交到 Git。安装完成后应从其他机器删除。
:::

### 4. 安装 user、media、edge

每台的 `.env` 中填写：

```dotenv
YIYI_DEPLOY_ROLE=user
YIYI_SERVER_HOST=<本机内网IP或域名>
```

`media`、`edge` 同理，只改角色。每台执行：

```bash
sudo ./install.sh
```

安装完成后删除其他机器上的 `join.env`，访问 `http://<公网IP或域名>:18080` 激活。

### 5. 工作节点

分布式版的 Storage 与 Play Agent 是**外部工作节点**，不由本部署包安装：
登录后在「节点管理」创建节点并按页面引导自助部署，可按授权配额横向扩容。

## 升级

::: danger 安装脚本不会自动生成升级备份
升级前请按 [`OPERATIONS.md`](OPERATIONS.md)「备份」自行完成备份，保留周期自行管理。
:::

### 单机版：整镜像升级

```bash
cd /opt/YiYi-media-deploy
git pull --ff-only              # 部署文件有更新时才需要
docker compose pull
docker compose up -d --remove-orphans --wait
docker compose ps
```

应用容器里的八个服务**同版本、同镜像、一起替换**，内置节点不需要单独升级。

### 分布式：按机器、按服务升级

四台机器各自在自己的部署目录里执行同样的三步。跨机建议顺序：
先 `control`（承载数据库、注册中心与集群许可证 relay），再 `user` / `media`，最后 `edge`。

::: warning pull 不等于升级
`docker compose pull` 只下载镜像，**不会更新正在运行的容器**。
必须再执行 `docker compose up -d --remove-orphans --wait` 才会用新镜像重建容器。
:::

重跑安装脚本同样是一次完整升级：它会重新同步授权公钥、重跑配置预检、
检查所有内部服务、内置节点与许可证状态。

```bash
sudo ./install.sh                  # 单机版
sudo ./install.sh      # 分布式
```

> 安装脚本**不会**自动 `git pull`（从旧版本起已移除）。这样执行 `sudo ./install.sh`
> 就只运行你本机已有的代码，而不会在安装过程中拉取并执行远端的最新代码。

生产环境建议锁定镜像版本：

```dotenv
YIYI_IMAGE_TAG=2026.09.20-101530
```

## 迁移

单机版不通过 profile 启动多个应用容器。如果你的部署是旧一代形态
（一台机器跑多个应用容器，或分布式角色），迁入单机版三容器需要执行受控流程：

```bash
cd /opt/YiYi-media-deploy
./migrate-precheck.sh                       # 只读预检 + 影响报告
```

`migrate-precheck.sh` **默认只读**：不停止、不删除、不修改任何数据。
检测到任一类型节点超过一个时会返回退出码 `3` 并**停止自动迁移**，
要求管理员明确选择保留哪个节点。

完整流程、多节点阻断说明与回滚点见 [`MIGRATION.md`](MIGRATION.md)。

## 安全

- 不要公开或提交 `.env`、`join.env`、`config/cluster-relay.key`、`backups/`、`data/`。
- **许可证公钥（信任根）已固化在服务镜像内**：安装脚本取回的公钥必须与镜像内置的
  厂商公钥一致，否则安装**直接失败**（有意设计，避免产出「安装成功但全站 403」的部署）。
- `YIYI_SERVICE_TOKEN` 在已有部署上**不可重新生成**：切换会导致现有节点鉴权失败。
  恢复旧数据库时安装脚本会强制要求填写原值。
- 单机版的部署形态与许可证 Edition 严格匹配；能力边界始终以签名租约为准，
  改 `.env` 不会扩大授权范围。
- 生产环境应为网页入口配置 HTTPS。

端口矩阵、备份清单与排障见 [`OPERATIONS.md`](OPERATIONS.md)。
