# YiYi 运维说明

## 安装

首次安装执行：

```bash
cd /opt/YiYi-media-deploy
sudo ./install.sh
```

安装脚本不会自动生成数据备份。

安装后 `.env` 中的 `COMPOSE_PROFILES` 会自动匹配当前部署角色，因此在部署目录
可以直接使用 `docker compose ps`、`docker compose stop`、`docker compose start`、
`docker compose restart`、`docker compose down` 和 `docker compose up -d`。

所有持久化数据默认位于部署目录下的 `data`，包括 PostgreSQL、Redis、上传文件、
许可证状态和服务日志。可以在 `.env` 中通过 `YIYI_DATA_DIR` 指定其他数据根目录；
相对路径以部署目录为基准。迁移或复制物理数据库目录前必须停止 PostgreSQL，并
确认 `PG_VERSION` 为 `16`。日常数据库备份应使用 PostgreSQL 的 `pg_dump` 或
`pg_dumpall`，不要直接复制运行中的数据库目录。

## 升级

升级前由用户自行完成数据备份，然后执行：

```bash
cd /opt/YiYi-media-deploy
docker compose pull
docker compose up -d --remove-orphans --wait
docker compose ps
```

`docker compose pull` 只下载镜像，不会更新正在运行的容器。需要更新部署文件时，
先执行 `git pull --ff-only`。

授权激活、节点创建和授权状态管理均在 YiYi 网页中完成。

## 网络端口

单机部署通常只需要允许用户访问 `18080`。

分布式部署还需要在私有网络内放行：

| 端口 | 用途 |
|---|---|
| `5432` | 数据库 |
| `6379` | 缓存 |
| `18085` | 集群通信 |
| `18089` | 集群许可证同步 |

不要把上述四个端口开放到公网。

## 安全

- 不要公开或提交 `.env`、`join.env`、`config/cluster-relay.key` 和 `backups/`。
- `join.env` 只用于其他服务器加入集群，安装完成后应从其他服务器删除。
- 生产环境应为网页入口配置 HTTPS。
