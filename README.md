# YiYi Media Docker 部署

本仓库用于部署 YiYi Media。产品有**两种部署模式**，模式决定能力边界（由签名租约里的
`edition` 强制）；每种模式下的**部署方式**决定装在几台机器上。三种部署方式各占一个
**Git 分支**，每个分支根目录都是一套完整部署文件，可直接
`docker compose pull && docker compose up -d`：

| 部署方式 | 分支 | 部署模式 | 拓扑 | 对应许可证 |
| --- | --- | --- | --- | --- |
| **单机版部署** | `main` | `STANDALONE` | 一台服务器，**三个容器**：`YiYi-media` + `-postgres` + `-redis` | `edition=STANDALONE` |
| **分布式 · 控制面同机** | `v2-all-in-one` | `DISTRIBUTED` | 一台服务器跑全部控制面（6 个应用服务），工作节点在外部 | `edition=DISTRIBUTED` |
| **分布式 · 按角色多机** | `v3-multi-host` | `DISTRIBUTED` | 控制面按 `control` / `user` / `media` / `edge` 拆到多台（同一私网） | `edition=DISTRIBUTED` |

先回答一个问题：**需要外部工作节点（多台 Storage / Play Agent）吗？**

- **不需要** → 用单机版（本分支）。三容器起步最省事，内置 Storage 与 Play Agent
  （`node-local-storage` / `node-local-play-agent`）随主应用安装、启动和升级，
  不需要安装任何节点；代价是**不能加节点扩容**。
- **需要** → 用分布式。控制面只占一台机器就选 `v2-all-in-one`，要拆到多台就选
  `v3-multi-host`。两种方式共用同一套控制面与同一份许可证，可以互相演进。

> 本文每一节都会标明适用哪种部署方式。本分支（`main`）**只有单机版**文件；
> 分布式方式的部署步骤见对应分支的 `README.md`，本文另有一节做对照说明。

> **换机迁移**有两条路径：复制 `data/license/` 沿用原部署身份（推荐，不占新名额），
> 或在「系统配置 → 授权与迁移」自助反激活并取得一次性迁移码。
> 区别、停机顺序与注意事项见 [`OPERATIONS.md`](OPERATIONS.md) 的「换机迁移」。

> 容器名与 Compose 服务名不是一回事：`docker compose` 用**服务名**
> （`yiyi-media` / `postgres` / `redis`），`docker exec` 等直接用 `docker` 的命令用**容器名**。

::: danger 跨模式不能靠换分支完成
不允许只改 `.env`、Compose 文件或角色变量在**两种模式**之间切换。
单机版 ↔ 分布式要同时完成许可证 Edition 变更、部署拓扑迁移与数据校验，
必须走授权的专用版本升级操作；仅把分支切到 `v2-all-in-one` / `v3-multi-host`
不会生效，只会得到一个能力被收窄的部署。
:::

::: tip 两种分布式方式之间可以自由演进
`v2-all-in-one` ↔ `v3-multi-host` 属于**同一模式**（都是 `DISTRIBUTED`），
共用同一份许可证与同一份数据，不需要授权升级，也不需要迁移数据。
控制面压力变大时从同机拆到多机即可。
:::

## 仓库文件一览

本分支（`main`）只有单机版一套文件，根目录可直接 `docker compose pull && docker compose up -d`：

| 文件 | 说明 |
| --- | --- |
| `compose.yaml` | 三容器 Compose，解析后**严格只有** `yiyi-media`、`postgres`、`redis` 三个服务 |
| `install.sh` | 安装 / 升级脚本 |
| `.env.example` | 环境变量模板 |
| `postgres-init.sql` | 首次初始化时创建四个业务库 |
| `OPERATIONS.md` | 升级、备份、端口与安全 |
| `RELEASING.md` | 镜像发布说明（内部） |

::: tip 容器名与服务名不是一回事
`docker compose` 的命令与日志过滤用**服务名**（`yiyi-media` / `postgres` / `redis`），
`docker exec`、`docker inspect` 等直接用 `docker` 的命令用**容器名**
（`YiYi-media` / `YiYi-media-postgres` / `YiYi-media-redis`）。
:::

::: warning 从 `yiyi-app` 升级上来的部署：不要直接 `docker compose up -d`
应用服务名已由 `yiyi-app` 改名为 `yiyi-media`（容器名同步由 `YiYi-media-standalone`
改为 `YiYi-media`）。升级后旧容器会成为**孤儿容器**，而它仍占着容器名，直接
`docker compose up -d` 会报：

```text
Error response from daemon: Conflict. The container name "/YiYi-media" is already in use
```

两种正确做法，任选其一：

```bash
sudo ./install.sh                 # 推荐：脚本内部用 --remove-orphans 清理旧容器
docker compose up -d --remove-orphans   # 手工升级时必须显式加这个参数
```

`docker compose down` 也可先清掉旧容器再起。数据都在 `data/` 绑定挂载里，改名不影响数据。
:::

> 分布式方式（`v2-all-in-one` / `v3-multi-host`）的文件在各自分支的根目录，
> 同名文件是另一套内容。本仓库**不含**外部 Storage / Play Agent 服务。

## 准备工作

- Linux 服务器（单机版与控制面同机都是 1 台；按角色多机至少 4 台，且在同一私有网络）
- Docker Engine 与 Docker Compose v2（`docker compose` 子命令可用）
- `openssl`、`curl`、`python3`（安装脚本启动即检查，缺一个直接退出）
- 服务器 IP 或已解析的域名（不带 `http://` 前缀与路径）
- 一个与部署模式匹配的一次性授权码
- 出站网络：能访问 `YIYI_LICENSE_SERVER_URL` 指向的授权中心（HTTPS）

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
| `YIYI_NODE_TOKEN` | 保持 `GENERATE_ON_INSTALL`；脚本自动生成并持久化，用于节点平面鉴权 |
| `YIYI_IMAGE_TAG` | 留空用 `latest`；生产环境建议锁定到不可变版本标签 |
| `YIYI_DATA_DIR` | 留空用部署目录下的 `data/`；可填绝对或相对路径 |
| `YIYI_STORAGE_MOUNT_DIR` | 可选。**挂载文件夹**（Storage 挂载数据根）改放别的盘时填，如 `/mnt/big/yiyi-mounts`；留空 = `<YIYI_DATA_DIR>/storage/mount-data` |
| `YIYI_PLAY_AGENT_VFS_CACHE_DIR` | 可选。**VFS 内容缓存**改放更快的盘时填，如 `/mnt/ssd/yiyi-vfs`；留空 = `<YIYI_DATA_DIR>/play-agent/vfs-cache` |

::: warning 单机版没有角色与节点安装变量
单机版不使用 `YIYI_DEPLOY_ROLE`，也没有 Control/User/Media/Edge 角色选择，
`.env` 里**没有**节点安装变量，也**不会生成** `join.env` 或集群中继证书。

单机版固定使用内置 PostgreSQL 与 Redis，**不提供** `YIYI_DB_MODE=external`
（该变量与 `YIYI_REDIS_MODE` 只属于分布式方式）。若在 `.env` 里把
`YIYI_DB_MODE` 设为非 `bundled`，安装脚本会直接报错退出。
:::

### 2. 执行安装脚本

```bash
sudo ./install.sh
```

脚本不接受任何参数，传参直接打印用法并退出。单机版路径上它会：

1. 检查 `.env`、命令行工具、Compose v2 与 daemon
2. 检测本机是否仍是旧一代拓扑，若是则**停止**并要求先备份、保留旧部署
3. 固定写入部署形态 `STANDALONE`；写入 `.deployment-mode` 标记
4. 创建统一数据目录并设置最小必要权限；若设置了
   `YIYI_STORAGE_MOUNT_DIR` / `YIYI_PLAY_AGENT_VFS_CACHE_DIR`，
   一并创建、授权并校验（拒绝指向 `/` 或数据根目录）
5. 从授权中心下载授权公钥，**与镜像内置的厂商公钥做一致性校验**，不一致直接失败
6. 在拉取镜像前校验 Compose 解析结果严格为三个服务，且不含高权限配置
7. 先起 PostgreSQL、Redis，再做四个数据库的**幂等存在性检查**（只创建缺失的库）
8. 拉取镜像、启动应用容器并等待健康检查
9. 检查全部内部服务、**两个内置节点**与许可证状态

```bash
# 日常命令（单机版不需要 -f、--profile 或 --env-file）
docker compose ps
docker compose logs --tail=100 yiyi-media
docker compose stop
docker compose start
```

> `install.sh` 会把 `COMPOSE_FILE=compose.yaml` 写进 `.env`，保证任何调用方式
> 都解析到本分支的 Compose 文件。该变量由脚本维护，不要手工删除。

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

::: tip 节点 ID 可以不是 `node-local-*`
从旧部署迁入单机版时，安装脚本会**沿用原有的节点 ID** 并写进
`YIYI_EMBEDDED_STORAGE_NODE_ID` / `YIYI_EMBEDDED_PLAY_AGENT_NODE_ID`，
这样媒体源引用、用户播放线路授权与历史任务关联都不会失联。全新安装才用默认 ID。
:::

内置节点的**对外地址可以编辑**：用自己的 Caddy / nginx 反代时，到「节点管理」
把对外地址改成反代域名与端口（例如 `https` + `443`），用户播放线路就会下发该地址。
**监听端口**由应用容器固定（Play Agent 为 `19090`），页面上不提供该输入框。

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

其中两个目录可以**单独放到别的磁盘**（留空则保持在数据根目录内，行为不变）：

| 目录 | 变量 | 常见用途 |
| --- | --- | --- |
| `storage/mount-data/` | `YIYI_STORAGE_MOUNT_DIR` | 挂载文件夹体量大，放独立大盘或 NAS |
| `play-agent/vfs-cache/` | `YIYI_PLAY_AGENT_VFS_CACHE_DIR` | 播放缓存读写频繁，放 SSD |

两者**互相独立**，只改一个不影响另一个。安装脚本会创建目录并把属主设为
`10001:10001`（已存在的目录只补权限、不动内容）；指向 `/` 或数据根目录这类
会破坏布局的取值会被直接拒绝。

单机版同一个 PostgreSQL 实例承载四个数据库：`yiyi_config`、`yiyi_user`、
`yiyi_media`、`yiyi_storage`。首次初始化用 `postgres-init.sql`；**升级旧数据目录时
PostgreSQL 不会重新执行初始化 SQL**，因此安装脚本会在 PostgreSQL 健康后做幂等检查，
只创建缺失的数据库，不覆盖现有库。

备份清单见 [`OPERATIONS.md`](OPERATIONS.md)：四个业务库、许可证身份、上传文件与
Storage 持久化目录是必须项；`read-cache`、`vfs-cache`、`image-cache` 是可重建的缓存。

### 6. 端口与网络

单机版使用 Compose 私有网络：

- PostgreSQL 在容器内用 `postgres:5432`，Redis 用 `redis:6379`；**都不发布到宿主机**。
- 应用容器内部服务互调用 `127.0.0.1:<端口>`。
- 默认把前端 `18080` 与 Play Agent `19090` 发布到宿主机。
- Config、User、Media、Gateway、Storage、License Agent 的端口只在容器内部。

| 端口 | 用途 | 单机版暴露方式 |
| --- | --- | --- |
| `18080` | 前端与用户入口 | 发布到宿主机，对用户开放 |
| `19090` | Play Agent（播放客户端直连） | 默认对 `0.0.0.0` 发布 |
| `18082` / `18083` / `18084` / `18085` / `18086` / `18088` | 各内部服务 | 仅容器内部 |
| `5432` / `6379` | PostgreSQL / Redis | Compose 私有网络，不发布 |

::: danger 对外开放 19090 时请限制来源
`19090` 是播放客户端**直连**端口，默认对 `0.0.0.0` 发布，不做反代也能用。
部署在公网时应以防火墙或安全组限制来源；若前面有 Caddy / nginx 反代，
可把 `YIYI_PLAY_AGENT_BIND_HOST` 改成 `127.0.0.1` 只让本机反代访问，
并在「节点管理」把该节点的**对外地址**改成反代域名与端口。
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

分布式部署的文件**不在本分支**，请切换到对应分支后再按该分支的 `README.md` 操作：

| 分支 | 形态 | 控制面 | 适用场景 |
| --- | --- | --- | --- |
| `v2-all-in-one` | 控制面**全部同机** | 6 个应用服务都在一台机器，**不需要角色变量、不需要 `join.env`** | 一台服务器起步；播放/存储用外部节点 |
| `v3-multi-host` | 控制面**按角色多机** | 每类角色各一台机器（同一私网），需要分发 `join.env` 与中继证书 | 控制面本身要分散 |

两个分支的根目录都只有一份 `compose.yaml` / `install.sh` / `.env.example`：

```bash
# 控制面同机（推荐起步）
git clone -b v2-all-in-one https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
# 或按角色多机
git clone -b v3-multi-host https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
```

::: tip 不确定选哪个就先同机
两种方式共用同一套控制面与同一份许可证，工作节点也通用。控制面压力大了再按下面
「多机形态」的步骤拆开，不需要改许可证、也不需要迁移数据。
:::

同机形态下，数据库与缓存可以用 `YIYI_DB_MODE` / `YIYI_REDIS_MODE` **独立**选择
自带或用你现有的实例（可组成「外部数据库 + 自带 Redis」），本机容器数在 6～8 个之间。

**下面各节针对多机形态**（`v3-multi-host`）。多台服务器需要位于同一私有网络，
按 `control` → `user` → `media` → `edge` 顺序安装。
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
cp .env.example .env
chmod 0600 .env
```

### 2. 安装 control（主服务器，只装一台）

```dotenv
YIYI_DEPLOY_ROLE=control
YIYI_SERVER_HOST=<主服务器内网IP或域名>
YIYI_USER_HOST=<User服务器内网IP或域名>
```

使用外部 PostgreSQL 或 Redis 时，另填 `YIYI_DB_MODE=external` / `YIYI_REDIS_MODE=external`
与相应的地址、端口、凭据（两者独立选择）。

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
它含数据库口令、服务令牌、节点令牌与集群同步令牌。用加密通道传输，**不要**贴到聊天工具、
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
登录后在「节点管理」创建节点，把页面给出的一行命令复制到目标机执行即可，
可按授权配额横向扩容。同机形态同样如此——控制面只占一台机器，工作节点照旧在外部。

::: warning 工作节点要能访问 config 的 18085
节点在别的机器上，因此 `18085`（注册中心）必须对它们可达（私网或 VPN）。
**不要**把 `18085` 直接暴露到公网。节点数量受许可证 `maxStorageNodes` /
`maxPlayAgentNodes` 限制，超限时新增会被拒绝并返回 `409 LICENSE_NODE_QUOTA_EXCEEDED`。
:::

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

按角色多机时，每台机器各自在自己的部署目录里执行同样的三步。跨机建议顺序：
先 `control`（承载数据库、注册中心与集群许可证 relay），再 `user` / `media`，最后 `edge`。

控制面同机时就是**一条命令**：在本机部署目录里 `docker compose pull && docker compose up -d`
即可，不需要跨机顺序。工作节点（Storage / Play Agent）各自独立升级，与控制面版本解耦。

::: warning pull 不等于升级
`docker compose pull` 只下载镜像，**不会更新正在运行的容器**。
必须再执行 `docker compose up -d --remove-orphans --wait` 才会用新镜像重建容器。
:::

重跑安装脚本同样是一次完整升级：它会重新同步授权公钥、重跑配置预检、
检查所有内部服务、内置节点与许可证状态。

```bash
cd /opt/YiYi-media-deploy
sudo ./install.sh
```

分布式方式同理，在每台机器的部署目录里执行同一条命令（先切到对应分支）。

> 安装脚本**不会**自动 `git pull`（从旧版本起已移除）。这样执行 `sudo ./install.sh`
> 就只运行你本机已有的代码，而不会在安装过程中拉取并执行远端的最新代码。

生产环境建议锁定镜像版本：

```dotenv
YIYI_IMAGE_TAG=2026.09.20-101530
```

## 从旧一代拓扑迁入

单机版不通过 profile 启动多个应用容器。如果你的部署是旧一代形态
（一台机器跑多个应用容器，或分布式角色），本脚本**不会**替你停掉、删除或改造旧容器：
旧容器与旧配置在验收完成前必须保留。

请按以下顺序操作：

1. **备份**：导出各业务库（四个库）、上传目录与许可证状态目录；
2. **保留旧部署**：不要删除旧容器、旧命名卷与旧 `.env`；
3. **确认迁移**：明确要让三容器聚合形态接管本机后执行
   ```bash
   sudo YIYI_MIGRATION_CONFIRMED=1 ./install.sh
   ```
4. **验收**：确认新部署功能正常后，再**手工**移除旧容器与旧进程。

迁移路径启动容器时**不加** `--remove-orphans`，因此旧容器会被保留下来供你回滚；
正常安装路径仍会用它清理本项目内已失效的容器。两条路径都**不会删除你的数据**。

::: warning 节点数量
同一服务类型（Storage / Play Agent）存在**多个**节点时不支持自动沿用节点 ID。
需要由管理员选择保留哪一个，并把选中的节点 ID 写入
`YIYI_EMBEDDED_STORAGE_NODE_ID` / `YIYI_EMBEDDED_PLAY_AGENT_NODE_ID` 后重新执行脚本。
未选中的节点记录会保留，不会被删除。
:::

注意：`YiYi-media-deploy` 仓库不再随附迁移预检脚本，请以本节的步骤为准。

## 安全

- 不要公开或提交 `.env`、`join.env`、`config/cluster-relay.key`、`backups/`、`data/`。
- **许可证公钥（信任根）已固化在服务镜像内**：安装脚本取回的公钥必须与镜像内置的
  厂商公钥一致，否则安装**直接失败**（有意设计，避免产出「安装成功但全站 403」的部署）。
- `YIYI_SERVICE_TOKEN` 在已有部署上**不可重新生成**：切换会导致控制面服务间鉴权失效。
  恢复旧数据库时安装脚本会强制要求填写原值。
- `YIYI_NODE_TOKEN` 与服务令牌独立；安装脚本会自动生成并复用已有值，不要手工删除或改回服务令牌。
- 单机版的部署形态与许可证 Edition 严格匹配；能力边界始终以签名租约为准，
  改 `.env` 不会扩大授权范围。
- 生产环境应为网页入口配置 HTTPS。

端口矩阵、备份清单与排障见 [`OPERATIONS.md`](OPERATIONS.md)。
