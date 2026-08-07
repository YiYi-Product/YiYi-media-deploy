# YiYi Docker 部署

本仓库用于部署 YiYi，支持单台服务器和多台服务器。

## 准备工作

- 一台或多台 64 位 Linux 服务器
- Docker 和 Docker Compose v2
- 服务器 IP 或已解析的域名

推荐先使用单台服务器部署。需要分散服务器负载时，再使用多服务器部署。

## 单台服务器部署

在服务器执行：

```bash
git clone https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
cd /opt/YiYi-media-deploy
cp .env.example .env
chmod 0600 .env
```

单机部署默认角色、授权地址和镜像均已配置，只需在 `.env` 填写：

```dotenv
YIYI_SERVER_HOST=<服务器IP或域名>
```

只有公网访问地址与服务器地址不同时，才需要填写 `YIYI_PUBLIC_HOST`。
`YIYI_DB_USER`、`YIYI_DB_PASSWORD`、`YIYI_REDIS_PASSWORD` 和 `YIYI_SERVICE_TOKEN` 已在模板中保留。
数据库密码保持 `GENERATE_ON_INSTALL` 即可由脚本自动生成，也可以在安装前自行设置。
Redis 密码留空表示不启用密码；也可以自行设置，或填写 `GENERATE_ON_INSTALL` 让脚本自动生成。
Service Token 保持 `GENERATE_ON_INSTALL` 时会生成高熵随机值，也可以在首次安装前自行指定。

如需让 `config`、`user` 和 `media` 使用同一个外部 PostgreSQL，在 `.env` 中设置：

```dotenv
YIYI_DB_MODE=external
YIYI_DB_HOST=<PostgreSQL服务器IP或域名>
YIYI_DB_PORT=5432
YIYI_DB_USER=<数据库用户>
YIYI_DB_PASSWORD=<数据库密码>
```

外部 PostgreSQL 必须预先创建 `yiyi_config`、`yiyi_user` 和 `yiyi_media` 三个数据库，
并授权上述用户连接和建表。`yiyi_storage` 仍由 Storage 节点自己的部署配置管理。
使用 external 模式时安装脚本不会启动内置 PostgreSQL，也不会操作本地 PostgreSQL 数据目录。
从 bundled 切换到 external 前，必须自行迁移上述三个数据库；安装脚本不会复制数据库内容。
该模式只替换 PostgreSQL，Redis 仍按当前部署角色安装：单机使用本机 Redis，分布式节点共用 Control 的 Redis。
现有分布式部署切换数据库时，先在 Control 更新配置并运行安装脚本，再把新生成的
`join.env` 和 `cluster-relay.crt` 复制到 User、Media 服务器并分别运行安装脚本；成功后删除各节点的 `join.env`。

所有持久化数据默认保存在部署目录下的 `data`，包括 PostgreSQL、Redis、上传文件、
许可证运行状态和服务日志。主要目录如下：

```text
data/
├── postgres/
├── redis/
├── config/uploads/
├── license/{identity,lease,sync-state}/
└── logs/{config,user,media,gateway}/
```

如需放到独立磁盘或目录，在 `.env` 中设置数据根目录（相对路径以部署目录为基准）：

```dotenv
YIYI_DATA_DIR=/var/lib/yiyi
```

若 `data/postgres` 已包含 PostgreSQL 16 数据，安装脚本会直接使用；此时必须在
`.env` 中填写原数据库的 `YIYI_DB_USER`、`YIYI_DB_PASSWORD` 和原部署的
`YIYI_SERVICE_TOKEN`。全局 service token 不保存在 `data` 目录；恢复旧数据库时
若静默生成新值，现有 Storage/Play 节点将无法通过服务鉴权。旧版安装使用的全部
Docker 命名卷会在首次升级时统一迁移，迁移完成后仍保留原卷以便回退。

然后执行：

```bash
sudo ./install.sh
```

安装脚本会直接读取 `.env`，并自动下载和验证 Ed25519 公钥。

安装完成后访问：

```text
http://<服务器IP或域名>:18080
```

按照页面提示输入发布方提供的一次性授权码，即可继续初始化系统。

## 部署 Storage 和 Play 节点

Storage 和 Play 节点不由本部署包安装。用户登录 YiYi 后进入“节点管理”，
创建节点并按页面引导自助部署即可。

## 多服务器部署

多台服务器需要位于同一私有网络，并按下面的顺序安装：

| 顺序 | 角色 | 用途 |
|---|---|---|
| 1 | `control` | 主服务器，只安装一台 |
| 2 | `user` | 用户服务 |
| 3 | `media` | 媒体服务 |
| 4 | `edge` | 网页入口 |

每台服务器都使用同一个安装命令。先准备配置：

```bash
git clone https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
cd /opt/YiYi-media-deploy
cp .env.example .env
chmod 0600 .env
```

### 1. 安装主服务器

在主服务器的 `.env` 中设置：

```dotenv
YIYI_DEPLOY_ROLE=control
YIYI_SERVER_HOST=<主服务器内网IP或域名>
YIYI_USER_HOST=<User服务器内网IP或域名>
```

如需使用外部 PostgreSQL，同时填写前述 `YIYI_DB_MODE=external`、数据库地址、端口和凭据。
Control 会连接外部数据库，并通过 `join.env` 将数据库连接配置传给 User 和 Media 服务器。

执行：

```bash
sudo ./install.sh
```

安装完成后会生成 `join.env` 和 `cluster-relay.crt`。将这两个文件通过安全方式复制到其他服务器的同一目录。

### 2. 安装其他服务器

将主服务器生成的 `join.env` 和 `cluster-relay.crt` 安全复制到其他
服务器的 `/opt/YiYi-media-deploy/` 目录。在各服务器的 `.env` 中填写：

```dotenv
YIYI_DEPLOY_ROLE=<user、media或edge>
YIYI_SERVER_HOST=<本机内网IP或域名>
YIYI_PUBLIC_HOST=<edge的公网IP或域名>
```

每台服务器执行相同命令：

```bash
sudo ./install.sh
```

安装完成后删除其他服务器上的 `join.env`。访问下面的地址并输入一次性授权码：

```text
http://<公网IP或域名>:18080
```

Storage 和 Play 节点仍然在网页“节点管理”中创建和部署。

## 升级

升级前请根据自身备份策略备份 `data` 目录或数据库。拉取新镜像后必须重新创建
容器，单独执行 `docker compose pull` 不会让运行中的容器切换到新镜像：

```bash
cd /opt/YiYi-media-deploy
docker compose pull
docker compose up -d --remove-orphans --wait
docker compose ps
```

需要更新部署文件时，先执行 `git pull --ff-only`，再执行上述命令。安装脚本不再
自动生成升级备份，数据备份和保留周期由用户自行管理。

首次授权和后续授权状态均在网页中处理，不需要命令行激活。
端口和安全说明见 [OPERATIONS.md](OPERATIONS.md)。

## 常用管理命令

安装脚本会把部署角色写入 `.env` 的 `COMPOSE_PROFILES`。在部署目录中可以直接执行：

```bash
docker compose ps
docker compose stop
docker compose start
docker compose restart
docker compose down
docker compose up -d
```

上述命令会自动使用当前角色，不需要手动添加 `--profile`、`--env-file` 或 `-f`。
