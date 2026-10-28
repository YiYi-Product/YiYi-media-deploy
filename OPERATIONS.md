# YiYi Media 运维说明

本文覆盖两种部署模式的日常运维。**每节都标明适用模式**：

- **单机版部署**（`STANDALONE`）：`yiyi-media` + `postgres` + `redis` 三个容器
- **分布式部署**（`DISTRIBUTED`）：控制面按 `control` / `user` / `media` / `edge` 角色拆分

## 安装与常用命令

### 单机版部署

```bash
cd /opt/YiYi-media-deploy
sudo ./install.sh
```

单机版不使用 Compose profile，因此在部署目录可以直接执行：

```bash
docker compose ps
docker compose stop
docker compose start
docker compose restart
docker compose down
docker compose up -d
docker compose logs --tail=100 yiyi-media
```

::: warning 从 `yiyi-app` 改名后首次升级要清理孤儿容器
应用服务名已改为 `yiyi-media`（容器名 `YiYi-media`）。旧容器会成为孤儿并占着容器名，
此时直接 `docker compose up -d` 会报容器名冲突。用
`docker compose up -d --remove-orphans`，或直接跑 `sudo ./install.sh`。
上面的 `docker compose down` 先执行也能避免该问题。
:::

### 分布式部署

```bash
cd /opt/YiYi-media-deploy
sudo ./install.sh
```

分布式分支的 `install.sh` 会把本机角色写进 `.env` 的 `COMPOSE_PROFILES`，
并把 `COMPOSE_FILE` 写为 `compose.yaml`，因此同样可以直接执行上面的
`docker compose` 命令。跨机升级建议顺序：`control` → `user` / `media` → `edge`。

::: warning 两个安装脚本都会在 .env 里写死 COMPOSE_FILE
本分支只有单机版 `compose.yaml`，分布式形态在 `v2-all-in-one` / `v3-multi-host` 分支，
而 `docker compose` 会按固定文件名自动发现 `compose.yaml`。
安装脚本因此显式写入 `COMPOSE_FILE`，保证在部署目录里直接执行
`docker compose ps` 时解析到与当前模式匹配的那个文件。

不要手工删除或改错这一项，否则分布式部署可能意外解析到单机版三容器文件。
:::

安装脚本不会自动生成数据备份。

## 数据目录与权限

所有持久化数据默认位于部署目录下的 `data`，可通过 `.env` 的 `YIYI_DATA_DIR`
指定其他根目录（相对路径以部署目录为基准）。

### 单机版部署

```text
data/
├── postgres/                       # PostgreSQL 16 数据目录（四个业务库）
├── redis/                          # Redis AOF
├── license/{identity,lease}/       # 授权身份与租约
├── config/uploads/                 # 后台上传文件
├── storage/{mount-data,spool,read-cache}/
├── play-agent/{vfs-cache,image-cache}/
└── logs/{config,user,media,gateway,storage,play-agent,license}/
```

其中两个目录可以**单独放到别的磁盘**（用于独立大盘 / SSD），留空则保持在
数据根目录内：

| 变量 | 默认位置 | 常见用途 |
| --- | --- | --- |
| `YIYI_STORAGE_MOUNT_DIR` | `<YIYI_DATA_DIR>/storage/mount-data` | 挂载文件夹体量大，放独立大盘或 NAS |
| `YIYI_PLAY_AGENT_VFS_CACHE_DIR` | `<YIYI_DATA_DIR>/play-agent/vfs-cache` | 缓存读写频繁，放 SSD |

两者互相独立，只改一个不影响另一个。安装脚本会创建目录、把属主设为
`10001:10001`（已存在的目录只补权限、不动内容），并拒绝指向 `/` 或数据根目录
（含其祖先）这类会破坏目录布局的取值。

### 额外本地媒体目录（单机版）

在 `.env` 设置 `YIYI_LOCAL_DISK_MOUNTS="/vol1/1000/Movies /vol2/1000/TV"`，
重跑 `sudo ./install.sh` 后，两个目录在容器中保持原路径，供网页「本地磁盘」使用。
支持 `/宿主目录:/容器目录:ro` 只读映射，默认读写；路径必须存在且不能包含空格。
不会自动改已有目录的属主或权限，容器实际运行用户必须有相应访问权限，安装时会显示 UID/GID 并验证。

脚本自动生成 `compose.local-disks.yaml`，并维护
`COMPOSE_FILE=compose.yaml:compose.local-disks.yaml`，日常 Compose 命令也会加载。
修改或清空参数后重跑安装，旧映射会被替换；不会删除宿主机文件。

### 分布式部署

| 角色 | `data/` 下的内容 |
| --- | --- |
| `control` | `postgres/`（`external` 模式下不创建）、`redis/`、`config/uploads/`、`license/{identity,lease}/`、`logs/config/` |
| `user` | `license/{sync-state,lease}/`、`logs/user/` |
| `media` | `license/{sync-state,lease}/`、`logs/media/` |
| `edge` | `license/{sync-state,lease}/`、`logs/gateway/` |

### 权限

安装脚本按最小必要权限创建目录并修正属主：

- `postgres`、`license/{identity,lease}`：`0700`
- 其余数据与日志目录：`0750`，属主为容器内的 `yiyi` 用户（UID 10001）

`storage`、`play-agent`、`logs` 的挂载根目录与子目录都需要归 `10001:10001` 所有；
只有检测到目录属主不匹配时才递归修正。拉取镜像后，脚本会以容器用户实际创建并删除
临时文件验证读写权限；NAS ACL、只读挂载等问题会显示对应的容器目录。

迁移或复制物理数据库目录前**必须停止 PostgreSQL**，并确认 `PG_VERSION` 为 `16`。
日常数据库备份应使用 `pg_dump` / `pg_dumpall`，**不要**直接复制运行中的数据库目录。

## 升级

### 通用前提

日常备份由用户管理。单机版使用安装脚本升级（账号模型迁移会自动备份）：

```bash
cd /opt/YiYi-media-deploy
sudo ./install.sh
docker compose ps
```

需要更新部署文件时先执行 `git pull --ff-only`。账号模型升级不得绕过安装脚本；
自动备份位于数据目录的 `account-upgrade.*`，保留用于恢复，详见 [账号自动升级](CLOUD_ACCOUNT_UPGRADE.md)。

### 单机版：整镜像升级

单机版的八个内部服务同版本、同镜像、一起替换，内置节点没有独立升级步骤。

如果绑定网盘时报 `CREDENTIAL_KEY_UNAVAILABLE`，先更新 `main` 分支的部署文件，再运行
`sudo ./install.sh`。脚本会为缺失的 `YIYI_CREDENTIAL_MASTER_KEY` 生成 Base64 编码的 32 字节密钥，
保存在权限为 `600` 的 `.env` 中，并重建应用容器。仅拉取镜像或重启旧容器不会补齐此配置。

已有有效密钥会校验并保留，不会重新生成。旧版 64 位十六进制值会在数据库就绪后安全检查：
优先恢复旧容器的有效密钥；只有所有已知加密字段都为空时才初始化新密钥。
检查范围包括云盘凭据、转存分享、Emby API Key 与 MoviePilot 回调密钥。
若原 `.env` 丢失且数据库已有加密凭据，必须恢复原密钥；
新密钥无法解密旧数据。不要将密钥或完整 `.env` 贴到日志和反馈信息中。

### 单机版：首次安装中断

保留 `.env` 与全部数据目录，修复错误后重新运行 `sudo ./install.sh`。
不要删除正在运行的 PostgreSQL 的数据目录。`.installed` 只在安装验收成功后写入。

PostgreSQL 健康检查使用 TCP，安装脚本还会执行带密码的 TCP SQL 查询，
避免首次初始化临时数据库提前报告就绪。查询就绪后只补建缺失的业务库；
并发建库失败时会重新确认数据库是否已经存在，真正的创建错误仍会中止安装。

NAS 慢盘首次执行 Flyway 并顺序启动八个服务时，可能超过镜像默认的 5 分钟宽限期。
Compose 将应用的 `healthcheck.start_period` 延长到 12 分钟，健康检查命令保持镜像原值；
服务提前就绪会立即通过，持续失败仍由安装的 900 秒超时收口。

### 分布式：按机器、按服务升级

四台机器各自执行同样的三步。升级 `control` 期间集群授权同步会中断，建议安排维护窗口。
`storage` 与 `play-agent` 二进制内置在 `config` 镜像里，升级 `config` 后，
已安装的外部节点仍需在「节点管理」里再做一次远程升级。

重跑安装脚本同样是一次完整升级（会重新同步授权公钥并检查许可证状态）：

```bash
sudo ./install.sh                  # 单机版
sudo ./install.sh      # 分布式
```

::: warning 不允许通过改配置切换 Edition
单机版与分布式版互转**不是升级**，必须走授权的专用版本升级操作并完成拓扑迁移：
改用对应分支（`v2-all-in-one` / `v3-multi-host`）的部署文件。
只改 `.env`、Compose 文件或角色变量不会生效。
:::

## 备份

::: danger 不要直接复制运行中的数据库目录
日常备份用 `pg_dump` / `pg_dumpall`。物理目录只在迁移或复制时动，且必须先停库。
:::

### 数据库

**单机版**备份四个库：

```bash
cd /opt/YiYi-media-deploy
set -a; . ./.env; set +a          # 让当前 shell 读到 YIYI_DB_USER
mkdir -p backups
for db in yiyi_config yiyi_user yiyi_media yiyi_storage; do
  docker compose exec -T postgres \
    pg_dump -U "$YIYI_DB_USER" -Fc "$db" \
    > "backups/${db}-$(date -u +%Y%m%d-%H%M%S).dump"
done
chmod 0600 backups/*.dump
```

**分布式版**在 `control` 上备份 `yiyi_config`、`yiyi_user`、`yiyi_media` 三个库；
`external` 模式到外部 PostgreSQL 主机上做同样操作。`yiyi_storage` 由 Storage 工作节点
自己的部署配置管理，按它实际所在的实例备份。

连角色与授权一起导出时用 `pg_dumpall`：

```bash
docker compose exec -T postgres pg_dumpall -U "$YIYI_DB_USER" \
  > "backups/all-$(date -u +%Y%m%d-%H%M%S).sql"
chmod 0600 backups/all-*.sql
```

### 备份清单

| 对象 | 位置 | 说明 | 要备份吗 |
| --- | --- | --- | --- |
| 数据库 | `data/postgres` | 单机版四个库 / 分布式按角色 | 用 `pg_dump`，**不要拷目录** |
| 后台上传文件 | `data/config/uploads` | Logo 等上传物 | 要 |
| 部署身份 | `data/license/identity` | 授权代理身份 | **要**，丢了要找发布方重新绑定 |
| 租约 | `data/license/lease` | 当前授权状态 | 要 |
| 同步态 | `data/license/sync-state` | 仅分布式 `user` / `media` / `edge` | 要 |
| Storage 挂载数据 | `data/storage/mount-data` | 单机版内置节点 | 要 |
| Storage **spool** | `data/storage/spool` | 可能有尚未上传完成的文件 | **必须保留** |
| Storage 读缓存 | `data/storage/read-cache` | 可重建的缓存 | 按恢复策略选择 |
| Play Agent 缓存 | `data/play-agent/{vfs-cache,image-cache}` | 可重建的缓存 | 按恢复策略选择 |
| 配置 | `.env` | 含全部凭据 | 要，权限 `0600` |
| 集群证书 | `config/cluster-relay.crt`、`.key` | 仅分布式 `control` | 要；`.key` **绝不可提交或公开** |
| 授权公钥 | `config/license-public.runtime.jwk` | 安装脚本可重新同步 | 非必需 |
| 待提交迁移码 | `data/license/pending-deactivation.json` | 已生成但尚未提交的迁移码；权限 `0600` | 若要继续迁移则要，否则可删 |
| Redis AOF | `data/redis` | 缓存 | 不必 |
| 日志 | `data/logs/<service>` | 各服务日志 | 按需 |

::: warning 缓存目录与必须保留的数据要分开
`read-cache`、`vfs-cache`、`image-cache` 都是**可重建的缓存**；
`spool` 里可能有尚未上传完成的文件，属于**必须保留**的数据。
不要把两者混为一类处理。
:::

::: warning 数据库里没有节点工作目录的内容
单机版虽然只有一个 PostgreSQL 实例，但 Storage 的挂载数据、spool 与缓存是
**文件系统数据**，不在 `data/postgres` 里。只备份数据库无法恢复它们。
:::

### 换机迁移：两条路径怎么选

产品不绑定硬件，换服务器有两条路径。**先判断该用哪条**：

| 路径 | 适用 | 是否占新名额 | 关键要求 |
| --- | --- | --- | --- |
| **复制身份目录** | 旧机器可正常操作，愿意整机迁移 | 否，沿用同一部署身份 | 先停旧机；两台机器不可长期同时运行 |
| **自助反激活** | 新机器作为全新部署重新安装 | 会释放旧名额、新部署重新占用 | 旧机器能登录后台且旧部署私钥仍在 |

**优先考虑复制身份目录**：把 `data/license/`（身份 + 租约）随其他数据一起复制即可，
不需要反激活，也不会因为「部署数量上限」卡住。

复制身份目录的停机顺序：

1. 停旧机器的服务（`docker compose stop`），确认它不再续租；
2. 复制 `data/`（至少含 `data/license/`）到新机器；
3. 在新机器 `docker compose up -d`，确认 `curl -fsS http://127.0.0.1:18085/api/license/status` 为 `ACTIVE`；
4. 确认新机器续租正常后再处理旧机器。

::: danger 不能让两台机器长期同时运行
复制身份目录后，两台机器持有**同一个部署私钥**。同时长期运行会让授权中心看到同一部署
反复从两个来源续租。请务必先停旧机。
:::

自助反激活在「系统配置 → 授权与迁移」里完成，**仅完整管理员**可操作，两阶段：

1. 生成迁移码并复制/下载保存——**此时授权中心状态不变**，本机继续正常运行；
2. 勾选已保存并输入确认词后提交——**本机业务立即停止**，名额与节点占用立即释放。

然后在新机器首次激活页输入迁移码。迁移码**只能用一次**、默认 24 小时有效。

::: warning 三种「停用」状态不要混淆
| 状态 | 含义 | 处理 |
| --- | --- | --- |
| `DEACTIVATED` | **只有这台机器**让出了名额，许可证仍有效 | 用迁移码在新机器激活 |
| `CONFLICTED` | 同一份授权**在多台机器上同时运行**，被服务端自动阻断 | 停掉多余的机器，再联系发布方解除阻断 |
| `REVOKED` | **整份许可证**被发布方撤销 | 需发布方处理 |

旧机器损坏或丢失时无法自助反激活（没有私钥可证明身份），请联系发布方走人工流程。
:::

::: danger 两台机器不能同时运行同一份授权
把 `data/license/` 复制到新机器后，两台机器持有**同一份部署身份**。授权中心会在检测到
两个启动会话的时间区间重叠时，把这份身份标记为冲突，**两台机器一起停止业务**。

顺序必须是**先停旧机、再起新机**。反过来做（先起新机再停旧机）只要旧机多续租一次就会被判定并发，
即使你打算稍后就停掉它。

被阻断后：停掉多余的机器、只保留一台，再联系发布方在管理台解除阻断。
**数据不会被删除。**
:::

### 配置与授权状态一起打包

```bash
cd /opt/YiYi-media-deploy
tar -czf "backups/yiyi-files-$(date -u +%Y%m%d-%H%M%S).tar.gz" \
  .env config data/config/uploads data/license data/storage
chmod 0600 backups/yiyi-files-*.tar.gz
```

::: danger 这个归档含全部凭据与私钥
`.env` 里有数据库口令、服务令牌、节点令牌（分布式版还有集群同步令牌），
`config/cluster-relay.key` 是集群同步私钥。归档权限设 `0600`，
存到部署机之外的安全位置，不要放进任何仓库或共享目录。
:::

### 恢复

```bash
cd /opt/YiYi-media-deploy
set -a; . ./.env; set +a

docker compose exec -T postgres \
  pg_restore -U "$YIYI_DB_USER" -d yiyi_media --clean --if-exists \
  < backups/yiyi_media-<时间戳>.dump
```

::: danger 恢复是覆盖操作
`--clean --if-exists` 会先删除目标库里已存在的对象再重建。恢复到错误的库、
或用旧转储覆盖新数据，都会造成不可逆的数据丢失。执行前确认库名与转储时间。
:::

## 回滚

| 层级 | 回滚方式 |
| --- | --- |
| 应用镜像 | 把 `YIYI_IMAGE_TAG` 改回旧版本标签，`pull` + `up -d --wait` |
| 数据库结构 | 表结构迁移只向前推进，**没有自动降级**；用升级前的 `pg_dump` 恢复 |
| 配置 | `.env` 每次改前留一份带日期副本，权限 `0600` |
| 部署文件 | `git status` / `git diff` 看清改动后人工还原 |
| Edition / 部署模式 | **不可原地切换**，需改用对应分支的部署文件并走迁移流程 |

::: danger 禁止用破坏性命令回滚
`git reset --hard`、`git clean -fdx`、`docker system prune`、`docker volume prune`、
`docker compose down -v`、`rm -rf data/`、`docker restart $(docker ps -q)`
都**不得**用于回滚。它们要么丢掉本地改动与凭据文件，要么影响本机上与本项目无关的业务。
:::

::: warning 镜像与数据库要一起回滚
新版本镜像可能已推进过表结构。只把镜像换回旧标签而不恢复数据库，旧代码可能读不懂新表结构。
:::

## 网络端口

### 单机版部署

只需允许用户访问 `18080`。

| 端口 | 用途 | 暴露方式 |
| --- | --- | --- |
| `18080` | 前端与用户入口 | 发布到宿主机，对用户开放 |
| `19090` | Play Agent | 默认只绑宿主机 `127.0.0.1`，供本机反代 |
| `5432` / `6379` | PostgreSQL / Redis | Compose 私有网络，**不发布** |
| `18082` / `18083` / `18084` / `18085` / `18086` / `18088` | 各内部服务 | **仅容器内部** |

端口冲突在单机版表现为容器创建失败（端口已被占用），而不是健康检查不过。

如果需要 psql 排障，用容器内客户端，不要对外发布数据库端口：

```bash
docker compose exec postgres psql -U "$YIYI_DB_USER" -d yiyi_config
```

### 分布式部署

除各机器自己的 `18080`（仅 `edge`）外，**私网内**还要放行：

| 端口 | 用途 | 方向 |
| --- | --- | --- |
| `5432` | 数据库 | `user` / `media` → `control` |
| `6379` | 缓存 | `user` / `media` → `control` |
| `18085` | 集群通信 / 注册中心 | 各角色与全部工作节点 → `control` |
| `18089` | 集群许可证同步 relay | `user` / `media` / `edge` 的 license-sync → `control` |

::: danger 这四个端口绝不可开放到公网
`5432`、`6379`、`18085`、`18089` 一旦对公网可达，等于把数据库、缓存、注册中心与
许可证分发口全部暴露。除宿主机防火墙外，还要检查云厂商安全组。

同样不要对公网开放的还有 `18088`（授权代理，必须保持只绑 `127.0.0.1`）与
`18082` / `18083` / `18086`（控制面内部服务）。
:::

### 关于 host 网络

分布式 Compose 里 config、user、media、gateway、frontend、license-agent、license-sync
都是 `network_mode: host`，没有 `ports:` 段。此时 `docker port` 输出为空是**正常现象**，
收紧访问范围只能靠宿主机防火墙与云安全组。

单机版不使用 host 网络：全部服务在容器内通过 `127.0.0.1` 互调，
数据库与缓存在 Compose 私有网络上通过服务名互访。

## 安全

- 不要公开或提交 `.env`、`join.env`、`config/cluster-relay.key`、`backups/`、`data/`。
- **许可证公钥（信任根）已固化在服务镜像内**：安装脚本从 `YIYI_LICENSE_SERVER_URL`
  取回的公钥必须与镜像内置的厂商公钥一致，否则安装会**直接失败**（这是有意设计，
  避免产出「安装成功但全站 403」的部署）。厂商轮换签名密钥时，需先升级到包含新公钥
  白名单的镜像版本，再更新安装脚本中的 `YIYI_TRUSTED_LICENSE_PUBLIC_KEY`。
- `YIYI_SERVICE_TOKEN` 在已有部署上**不可重新生成**：切换会导致控制面服务间鉴权失效。
  恢复旧数据库时安装脚本会强制要求填写原值。
- `YIYI_NODE_TOKEN` 由安装脚本自动生成并持久化，与服务令牌独立；升级时不要删除已有值。
- 单机版默认关闭主机 FUSE 挂载，聚合容器不使用 `privileged`、不授予 `SYS_ADMIN`、
  不挂载 `/dev/fuse`。显式配置 `YIYI_FUSE_ENABLED=true` 后，安装脚本仅放行
  FUSE 所需的 `SYS_ADMIN` 和 `/dev/fuse`，始终拒绝 `privileged`。准备目录与关闭步骤见
  [README](README.md#可选开启-fuse-主机挂载)。
- `YIYI_MFA_SECRET_KEY`（管理员 MFA / TOTP 的加密密钥）由安装脚本生成，**必须是 32 字节 base64**。
  误填十六进制或长度不对时，服务会打「不是合法 base64 / 长度不对」并**降级为不可用**
  （管理员绑定验证器返回 503「服务端未配置 MFA 密钥」）。这个值丢失后已绑定用户的验证器无法解密：
  在「安全审计 → 概览 → 管理员 MFA 状态」里逐个「重置 MFA」让对方重新绑定即可恢复；
  轮换时先把旧值填进 `YIYI_MFA_SECRET_KEY_PREVIOUS`，跑完批量重加密（`POST /api/auth/admin/security/mfa/reencrypt`）
  再摘掉旧值。
- `YIYI_TRUSTED_PROXY_ADDRESSES`：前面有 Caddy / Cloudflare 时填其出口地址（逗号分隔）。
  不填时事件里记录的是**前置代理的地址**，「安全审计 → 概览 → 安全基线自检」里的
  「真实客户端 IP」会一直是 WARN，攻击源排行也会把代理地址当成攻击来源。
- `YIYI_SETUP_TOKEN` 只在首次初始化管理员时用（`/api/auth/setup/init` 的 `X-YiYi-Setup-Token` 头，
  常量时间比较）。初始化完成后建议从 `.env` 移除并重启 user 服务，让初始化入口彻底关闭。
- 生产环境应为网页入口配置 HTTPS。

## 安装脚本的许可证校验

`install.sh` 结束时检查各项状态，其中许可证部分解析
`/api/license/status` 的 **`state` 字段**，并读取 `edition`：

| 结果 | 含义 |
| --- | --- |
| `UNACTIVATED` | 全新安装的正常状态；请在网页激活 |
| `ACTIVE` / `GRACE` 且 `edition=STANDALONE` | 通过 |
| `ACTIVE` / `GRACE` 但 `edition` 不是 `STANDALONE` | 部署形态与 Edition 不匹配，**不通过** |
| `DEACTIVATED` | 本机已反激活，**不通过**（换机迁移的中间态，需在新机器用迁移码激活） |
| `CONFLICTED` | 检测到多机并发使用、已被自动阻断，**不通过**（停掉多余机器后联系发布方解除） |
| 其它状态 | 许可证不可用，**不通过** |

> 注意：该接口在许可证无效时**仍返回 HTTP 200**（状态在响应体内）。
> 因此不能只判断 HTTP 码——旧版本脚本正是这样，会把"许可证不可用"误报为安装成功。
> 如果你在自定义健康检查，请同样解析 `state` 与 `edition`。

部署形态与 Edition **严格一一匹配**：单机聚合镜像只接受 `edition=STANDALONE`。
不匹配时系统保留激活、许可证状态、日志和备份能力，不开放业务功能，**不删除任何数据**。

## 相关文档

- [`README.md`](README.md)：两种部署模式的安装入口
- [`README.md`](README.md)：从旧一代拓扑迁入的步骤与注意事项
