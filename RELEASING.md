# 镜像发布约定（客户部署视角）

本文记录**客户部署侧**需要知道的镜像发布约定。发布脚本本身不在本仓库，
它位于 `YiYi-media` 仓库的 `deploy/publish.sh`，本文只描述它对客户部署的影响与要求。

::: warning 本文不执行发布
本仓库的任何脚本都**不构建、不推送、不登录 GHCR**。发布动作在构建机上单独执行，
且需要明确授权。
:::

## 聚合镜像

单机版使用一个聚合镜像：

```text
ghcr.io/yiyi-product/yiyi-media-standalone:${YIYI_IMAGE_TAG:-latest}
```

它同时承载 Config、User、Media、Gateway、Frontend、License Agent、Storage 与
Play Agent 八个组件，与 `postgres`、`redis` 一起构成单机版的三容器拓扑。

分布式部署继续使用按服务拆分的镜像（`yiyi-media-config`、`yiyi-media-user`、
`yiyi-media-media`、`yiyi-media-gateway`、`yiyi-media-frontend`、
`yiyi-media-license-agent` 等），由分布式分支（`v2-all-in-one` / `v3-multi-host`）的 `compose.yaml` 引用。

## 标签约定

| 要求 | 说明 |
| --- | --- |
| 同时发布不可变时间标签与 `latest` | 时间标签形如 `2026.09.20-101530`（UTC），用于锁定与回退；`latest` 是可变标签，仅便于快速试用 |
| 版本锁定由 `YIYI_IMAGE_TAG` 统一控制 | 单机版 Compose 里三个服务的镜像标签都由它派生；留空才回落到 `latest` |
| 生产环境应锁定不可变标签 | 避免 `docker compose pull` 在无预期的情况下切换版本 |

```dotenv
# .env：生产环境建议锁定
YIYI_IMAGE_TAG=2026.09.20-101530
```

## 发布结果记录

一次发布必须记录以下三项，用于追踪与回退：

| 记录项 | 用途 |
| --- | --- |
| 源码提交（commit） | 确认镜像对应的代码版本；不要用未提交的本地代码发布 |
| 镜像摘要（digest，`sha256:...`） | 唯一标识实际发布的产物，不受标签重推影响 |
| 支持的 Edition | 该聚合镜像支持的许可证 Edition（单机版镜像支持 `STANDALONE`） |

::: tip 为什么摘要比标签重要
`latest` 会被覆盖，时间标签理论上也可能被重推。摘要 `sha256:...` 才唯一标识实际产物。
需要精确回退或审计时，以摘要为准。
:::

## 发布与运行分离

::: danger 发布聚合镜像不会自动升级任何运行环境
`publish.sh` 只构建并推送镜像。它**不会**拉取、重启或升级任何正在运行的服务
（容器与 systemd 源码服务都一样）。

升级运行环境是**单独的一次操作**，需要另行确认目标主机、Compose 文件与服务范围。
:::

客户侧的升级动作由客户或运维在自己确认后执行：

```bash
cd /opt/YiYi-media-deploy
docker compose pull
docker compose up -d --remove-orphans --wait
```

::: warning pull 不等于升级
只执行 `docker compose pull` 不会让运行中的容器切换到新镜像，
必须再执行 `up -d --remove-orphans --wait`。
:::

## 发布前检查清单

在构建机上发布聚合镜像前，至少确认：

1. 目标代码已提交并推送到 Git，构建机工作区干净且提交一致；
2. 聚合镜像的 `Dockerfile` 与进程监管配置随代码一起更新；
3. 本次发布同时产出不可变时间标签与 `latest`；
4. 发布后记录源码提交、镜像摘要与支持的 Edition；
5. 单机版与分布式版镜像的 Edition 对应关系没有互相串线；
6. **未经授权，不执行任何运行环境升级。**

## 客户侧可以自行验证的事实

客户不需要访问镜像仓库也能核对部署是否符合契约：

```bash
cd /opt/YiYi-media-deploy

# 解析后的服务列表必须严格是三个
docker compose config --services | sort
# 期望：postgres / redis / yiyi-media

# 实际运行中的镜像与标签
docker compose images

# 部署形态与许可证 Edition 是否匹配（管理员可读）
docker compose exec -T yiyi-media \
  curl -fsS http://127.0.0.1:18085/api/config/deployment/capabilities
```

## 相关文档

- [`README.md`](README.md)：两种部署模式的安装与升级
- [`OPERATIONS.md`](OPERATIONS.md)：备份、回滚与端口
- [`README.md`](README.md)：从旧一代拓扑迁入的步骤
