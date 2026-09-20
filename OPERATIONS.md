# YiYi Media 运维说明

本文覆盖两种部署模式的日常运维。**每节都标明适用模式**：

- **单机版部署**（`STANDALONE`）：`yiyi-app` + `postgres` + `redis` 三个容器
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
docker compose logs --tail=100 yiyi-app
```

### 分布式部署

```bash
cd /opt/YiYi-media-deploy
sudo ./install.sh
```

`install.sh` 会把本机角色写进 `.env` 的 `COMPOSE_PROFILES`，
并把 `COMPOSE_FILE` 写为 `compose.yaml`，因此同样可以直接执行上面的
`docker compose` 命令。跨机升级建议顺序：`control` → `user` / `media` → `edge`。

::: warning 两个安装脚本都会在 .env 里写死 COMPOSE_FILE
本分支只有 `compose.yaml`（按角色 profile 拆分），
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

首次安装会递归修正属主；之后升级只改顶层目录，避免动到客户文件。

迁移或复制物理数据库目录前**必须停止 PostgreSQL**，并确认 `PG_VERSION` 为 `16`。
日常数据库备份应使用 `pg_dump` / `pg_dumpall`，**不要**直接复制运行中的数据库目录。

## 升级

### 通用前提

升级前由用户自行完成数据备份，然后执行：

```bash
cd /opt/YiYi-media-deploy
docker compose pull
docker compose up -d --remove-orphans --wait
docker compose ps
```

`docker compose pull` 只下载镜像，**不会更新正在运行的容器**。需要更新部署文件时，
先执行 `git pull --ff-only`。

### 单机版：整镜像升级

单机版的八个内部服务同版本、同镜像、一起替换，内置节点没有独立升级步骤。

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
单机版与分布式版互转**不是升级**，必须走授权的专用版本升级操作并完成拓扑迁移，
改 `.env`、Compose 文件或角色变量都不会改变部署模式；三种形态各占一个 Git 分支。
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

### 配置与授权状态一起打包

```bash
cd /opt/YiYi-media-deploy
tar -czf "backups/yiyi-files-$(date -u +%Y%m%d-%H%M%S).tar.gz" \
  .env config data/config/uploads data/license data/storage
chmod 0600 backups/yiyi-files-*.tar.gz
```

::: danger 这个归档含全部凭据与私钥
`.env` 里有数据库口令、服务令牌（分布式版还有集群同步令牌），
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
| Edition / 部署模式 | **不可原地切换**，需换用对应的 Git 分支并走迁移流程 |

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
- `YIYI_SERVICE_TOKEN` 在已有部署上**不可重新生成**：切换会导致现有节点鉴权失败。
  恢复旧数据库时安装脚本会强制要求填写原值。
- 单机版默认关闭主机 FUSE 挂载，聚合容器不使用 `privileged`、不授予 `SYS_ADMIN`、
  不挂载 `/dev/fuse`。`install.sh` 会把这几项作为 preflight 硬校验。
- 生产环境应为网页入口配置 HTTPS。

## 安装脚本的许可证校验

`install.sh` 结束时检查各项状态，其中许可证部分解析
`/api/license/status` 的 **`state` 字段**，并读取 `edition`：

| 结果 | 含义 |
| --- | --- |
| `UNACTIVATED` | 全新安装的正常状态；请在网页激活 |
| `ACTIVE` / `GRACE` 且 `edition=STANDALONE` | 通过 |
| `ACTIVE` / `GRACE` 但 `edition` 不是 `STANDALONE` | 部署形态与 Edition 不匹配，**不通过** |
| 其它状态 | 许可证不可用，**不通过** |

> 注意：该接口在许可证无效时**仍返回 HTTP 200**（状态在响应体内）。
> 因此不能只判断 HTTP 码——旧版本脚本正是这样，会把"许可证不可用"误报为安装成功。
> 如果你在自定义健康检查，请同样解析 `state` 与 `edition`。

部署形态与 Edition **严格一一匹配**：单机聚合镜像只接受 `edition=STANDALONE`。
不匹配时系统保留激活、许可证状态、日志和备份能力，不开放业务功能，**不删除任何数据**。

## 相关文档

- [`README.md`](README.md)：两种部署模式的安装入口
- [`README.md`](README.md)：本分支形态、角色划分与部署步骤
