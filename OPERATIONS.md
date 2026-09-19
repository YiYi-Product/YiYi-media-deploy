# YiYi Media 运维说明

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

授权激活、节点创建和授权状态管理均在 YiYi Media 网页中完成。

## 网络端口

单机部署通常只需要允许用户访问 `18080`。

分布式部署还需要在私有网络内放行：

| 端口 | 用途 | 默认监听 |
|---|---|---|
| `5432` | 数据库 | 仅 `127.0.0.1`（可用 `YIYI_INFRA_BIND_HOST` 调整） |
| `6379` | 缓存 | 仅 `127.0.0.1`（同上） |
| `18085` | 集群通信 | `0.0.0.0` |
| `18089` | 集群许可证同步 | 仅 control 角色，`0.0.0.0` |

不要把 `5432`、`6379`、`18089` 开放到公网。

### 关于 18082–18086 的监听地址

`config`(18085)、`user`(18082)、`media`(18083)、`gateway`(18086) 默认监听 `0.0.0.0`。
这是**节点架构的要求**，不是配置疏漏：

- Storage 节点与 Play 节点部署在**其他主机**上，需要经 `http://<本机地址>:18085`
  注册并拉取调度任务；把 config 收窄到 `127.0.0.1` 会导致这些节点**无法注册**。
- 因此这些端口的安全性**不能依赖"端口不可见"**，而是依赖：

| 防护 | 说明 |
|---|---|
| 服务令牌 | `/api/internal/**` 与注册中心写操作强制校验，未配置时 fail-closed |
| 节点专属令牌 | 注册中心写入绑定到具体受管节点 |
| 管理员校验 | 管理接口要求管理员身份，服务令牌不能替代 |
| 内网隔离 | 建议用安全组/防火墙限制来源 IP，仅放行可信节点 |

若部署环境允许（例如所有节点都在同一内网且不跨公网），可以用防火墙把
`18082`–`18086` 限制为**仅节点来源 IP 可访问**，这是比改监听地址更可控的做法。

服务之间的调用为明文 HTTP，令牌通过请求头传递。请确保节点与本机之间的网络
链路可信（内网或专线），不要在公网直接暴露这些端口。

## 安全

- 不要公开或提交 `.env`、`join.env`、`config/cluster-relay.key` 和 `backups/`。
- `join.env` 只用于其他服务器加入集群，安装完成后应从其他服务器删除。
- **许可证公钥（信任根）已固化在服务镜像内**：安装脚本从 `YIYI_LICENSE_SERVER_URL`
  取回的公钥必须与镜像内置的厂商公钥一致，否则安装会**直接失败**（这是有意设计，
  避免产出一个"安装成功但全站 403"的部署）。厂商轮换签名密钥时，需先升级到包含
  新公钥白名单的镜像版本，再更新安装脚本中的 `YIYI_TRUSTED_LICENSE_PUBLIC_KEY`。
- `YIYI_SERVICE_TOKEN` 在已有部署上**不可重新生成**：切换会导致现有 Storage/Play
  节点鉴权失败。恢复旧数据库时安装脚本会强制要求填写原值。
- 生产环境应为网页入口配置 HTTPS。

## 安装脚本的许可证校验

`install.sh` 结束时会对每个服务检查 `/api/license/status` 的 **`state` 字段**
（`ACTIVE` 或 `GRACE` 视为正常）。

> 注意：该接口在许可证无效时**仍返回 HTTP 200**（状态在响应体内）。
> 因此不能只判断 HTTP 码——旧版本脚本正是这样，会把"许可证不可用"误报为安装成功。
> 如果你在自定义健康检查，请同样解析 `state`。

