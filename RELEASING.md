# 镜像发布约定（v2 分布式部署）

本文说明 `v2-all-in-one` 分支的镜像选择与升级方式。发布脚本位于
`YiYi-media` 源码仓库的 `deploy/publish.sh`；本部署仓库只负责拉取和运行镜像，
不构建、不推送镜像，也不登录 GHCR。

## 本分支使用的镜像

本分支的部署模式为 `DISTRIBUTED`，控制面使用六个独立应用镜像：

| Compose 服务 | 镜像仓库 |
| --- | --- |
| `config` | `ghcr.io/yiyi-product/yiyi-media-config` |
| `user` | `ghcr.io/yiyi-product/yiyi-media-user` |
| `media` | `ghcr.io/yiyi-product/yiyi-media-media` |
| `gateway` | `ghcr.io/yiyi-product/yiyi-media-gateway` |
| `frontend` | `ghcr.io/yiyi-product/yiyi-media-frontend` |
| `license-agent` | `ghcr.io/yiyi-product/yiyi-media-license-agent` |

使用自带数据库和缓存时，另有 `postgres`、`redis` 两个基础服务。
`YIYI_IMAGE_TAG` 只控制上述六个应用镜像，不控制 PostgreSQL 或 Redis 版本。

Storage、Play Agent 是外部工作节点，在网页「节点管理」中部署和升级，
不属于本分支的 Compose 服务。

单机版 `main` 分支使用聚合镜像 `ghcr.io/yiyi-product/yiyi-media-standalone`，
要求许可证 Edition 为 `STANDALONE`。本分支要求 `DISTRIBUTED`，不能用聚合镜像替换控制面。

## 标签约定

| 约定 | 说明 |
| --- | --- |
| 时间标签与 `latest` | 发布通常同时生成时间标签和 `latest`；简化发布入口的时间标签按北京时间生成，形如 `2026.10.15-202443` |
| 默认使用 `latest` | `.env.example` 默认 `YIYI_IMAGE_TAG=latest`；Compose 在该变量为空时也回落到 `latest` |
| 升级脚本默认跟随 `latest` | `./upgrade.sh` 不沿用 `.env` 中的旧标签；完成备份后，在重建控制面前将目标标签写入 `.env` |
| 指定版本仍可选 | `./upgrade.sh --tag <标签>` 使用指定标签；该标签必须仍在镜像仓库中存在 |
| 各服务可分别发布 | 单独发布 `media` 只更新 media 镜像及其 `latest`；各服务的 `latest` 不一定对应同一批次 |

```dotenv
# .env：默认跟随各应用镜像的最新发布
YIYI_IMAGE_TAG=latest
```

历史标签可能被清理，不要把已删除的时间标签写入升级命令。为追踪实际运行版本，
应保留各服务的镜像摘要；`latest` 是可变标签，不能单独用它确定某次发布的产物。

## 升级到最新版本

在已有的 v2 部署目录执行：

```bash
cd /opt/YiYi-media-deploy  # 换成实际部署目录，例如 /opt/YiYi
git pull --ff-only
./upgrade.sh --check
./upgrade.sh
```

脚本需要 root 权限，普通用户执行时加 `sudo`。`--check` 仅做预检，不改写镜像标签，
不升级服务。正式升级会确认操作、拉取镜像、备份数据库与配置，按需迁移旧网盘账号，
再重建控制面并处理本机工作节点；远程节点会给出后续操作提示。
完整步骤见 [UPGRADE.md](UPGRADE.md)。

需要指定仍存在的标签时，六个应用镜像都必须有该标签；仅发布部分服务的批次标签
不能直接用于整组升级。预检和正式升级都传入同一标签：

```bash
./upgrade.sh --check --tag <标签>
./upgrade.sh --tag <标签>
```

不要跳过升级脚本直接执行 `docker compose pull && docker compose up -d`：
旧网盘账号必须在新版 Storage 启动前完成迁移，否则可能丢失账号配置。
单独执行 `docker compose pull` 只下载镜像，不会更新正在运行的容器。

升级前的 `.env`、数据库与旧镜像 ID 会保存在脚本打印的备份目录。
迁移或重建控制面失败时，脚本使用这些备份和本地旧镜像自动回滚，
不依赖重新拉取已删除的历史标签。升级成功后的人工回滚见 [UPGRADE.md](UPGRADE.md)。

## 发布与运行分离

构建机上的 `deploy/publish.sh` 只构建、验收并推送镜像，不会更新任何正在运行的服务。
运行环境升级是独立操作，需要确认目标主机和服务范围后执行。

发布方应记录以下信息：

| 记录项 | 用途 |
| --- | --- |
| 源码提交（commit） | 确认镜像对应的代码版本 |
| 本批次发布的服务与时间标签 | 区分整批发布与部分服务发布 |
| 各镜像摘要（digest，`sha256:...`） | 唯一标识实际产物，供审计与回滚核对 |
| 部署模式与许可证 Edition | 确认单机版 `STANDALONE` 与分布式版 `DISTRIBUTED` 对应正确 |

## 客户侧验证

在实际部署目录执行：

```bash
# 查看解析后的服务与镜像；使用自带数据库和缓存时共有八个服务
# 六个应用镜像默认应使用 :latest
# 外部工作节点不会出现在这里
docker compose config --services
docker compose config --images

# 查看实际容器状态和镜像
docker compose ps
docker compose images
```

如果仍出现旧标签，检查 `.env` 的 `YIYI_IMAGE_TAG`，以及自定义 Compose 文件中的
`image:` 覆盖项。升级脚本显式使用本目录的 `compose.yaml`；直接执行 Compose 命令时，
还要检查自动加载的 `compose.override.yaml` 或 `COMPOSE_FILE` 是否指向旧镜像。

## 相关文档

- [README.md](README.md)：本分支的安装与部署结构
- [UPGRADE.md](UPGRADE.md)：升级、账号迁移和回滚
- [OPERATIONS.md](OPERATIONS.md)：日常运维与备份
