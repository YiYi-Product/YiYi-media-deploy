# YiYi 客户 Docker 部署手册

本目录是第三方唯一受支持的交付方式。客户只运行发布方签名并固定摘要的 Docker 镜像；
不提供源码构建、裸 JAR 或裸二进制部署。License Server 和签名私钥不包含在本交付包中。
Java 控制面镜像内置按 CPU 架构构建的 Rust 原生许可证验证库；缺少、替换或加载失败时控制面
进入许可证不可用状态，不会退回 Java 验签。Storage 和 Play Agent 是受控节点，不在节点本地
重复执行商业许可证校验；节点身份、服务令牌和 Config 节点配额仍然强制执行。

## 1. 支持范围

- Linux x86_64/arm64，Docker Engine 24+，Docker Compose v2。
- 所有 YiYi 镜像必须来自同一架构发布清单，禁止混用 amd64/arm64 镜像或手工替换镜像内 `.so`。
- 一期标准拓扑为单台 Docker 主机：控制面、一个 Storage 和一个 Play Agent。
- 数据库、Redis 和内部 Java 服务只监听本机；对外开放 `18080`（Web）、`18084`
  （Storage，确有需要时）和 `19090`（播放）。
- 多主机、Kubernetes、离线长期运行和源码部署不在本手册支持范围内。

## 2. 发布方应交付的材料

1. 本目录的只读副本。
2. 每个镜像的 `repository@sha256:digest` 清单和发布签名/证明。
3. Ed25519 公钥文件 `license-public.jwk`，只含 `kty/crv/kid/x`，不含私钥字段。
4. 一次性激活码。激活码与镜像仓库凭据必须通过不同的安全渠道交付。
5. 私有 GHCR 的最小只读账号或短期 token。仓库权限只解决镜像拉取，运行授权由许可证独立控制。

客户在合并 `versions.env` 前应使用发布方 Cosign 公钥验证 `versions.env.sig`，并按发布说明验证各
镜像 digest 和 SBOM attestation。摘要清单签名有效不代表激活码可以公开传输。

## 3. 主机准备

```bash
sudo install -d -m 0700 /opt/yiyi
sudo cp -a customer/. /opt/yiyi/
cd /opt/yiyi
cp .env.example .env
mkdir -p config
install -m 0644 /secure/source/license-public.jwk config/license-public.jwk
```

编辑 `.env`：

- 把所有 YiYi 镜像替换为发布清单中的完整 digest，禁止 `latest`。
- 设置服务器固定 IP/DNS、授权服务器 HTTPS URL、两个节点 ID。
- 数据库密码和服务令牌分别使用随机值；服务令牌至少 32 个随机字节。
- 不要把 `.env`、激活码或仓库 token 发到工单、聊天群或版本库。

生成随机值的示例（结果只写入本机密码管理器）：

```bash
openssl rand -base64 36
```

登录私有仓库时从标准输入传入 token：

```bash
read -r -s GHCR_TOKEN
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u '<只读账号>' --password-stdin
unset GHCR_TOKEN
```

## 4. 预检与激活

```bash
chmod 700 scripts/*.sh
./scripts/preflight.sh
docker compose --env-file .env -f compose.yaml pull
./scripts/activate.sh
```

`activate.sh` 以不回显方式读取一次性激活码，通过容器标准输入写入权限为 `0600` 的部署身份卷。
License Agent 激活成功后会立即删除该文件。激活码不会出现在命令参数、Compose 环境变量或 URL 中。

## 5. 启动控制面

```bash
docker compose --env-file .env -f compose.yaml up -d
./scripts/healthcheck.sh --control-only
```

浏览器访问 `http://<YIYI_SERVER_HOST>:18080`。首次登录后，在“节点管理”中使用 `.env`
预先设置的两个 node ID 创建：

- `YIYI_STORAGE_NODE_ID`：服务类型 `YiYi-control-storage`。
- `YIYI_PLAY_AGENT_NODE_ID`：服务类型 `YiYi-play-agent`。

创建动作会在线向 License Server 原子占用许可证节点名额；达到配额或授权服务器不可达时不会创建。

## 6. 启动数据节点

```bash
docker compose --env-file .env -f compose.yaml -f compose.node.yaml pull
docker compose --env-file .env -f compose.yaml -f compose.node.yaml up -d
./scripts/healthcheck.sh
```

Config、Gateway、User 和 Media 会独立验证签名租约。License Agent 停止、租约被篡改或许可证
被撤销时，控制面业务请求进入受限模式，不再注册、调度或向节点下发有效业务。Storage 和 Play
Agent 继续保留节点身份与服务间鉴权，但不挂载许可证租约；系统不会删除数据库或文件。

## 7. 防火墙与 TLS

- 入站默认拒绝，仅按实际需要放行 `22/tcp`、`18080/tcp`、`18084/tcp`、`19090/tcp`。
- 不要放行 `5432`、`6379`、`18082`、`18083`、`18085`、`18086`、`18088`。
- 正式对外服务应在 `18080`/`19090` 前放置 TLS 反向代理，只开放 `443`。
- 主机必须能通过 HTTPS 访问 `YIYI_LICENSE_SERVER_URL`，并保持 NTP 时间同步。

## 8. 验收

```bash
./scripts/healthcheck.sh
docker compose --env-file .env -f compose.yaml -f compose.node.yaml ps
```

验收标准：所有服务为 healthy；四个控制面许可证状态端点均为 `ACTIVE`（短时断网时可为
`GRACE`）；Storage/Play 节点健康且已注册；未开放内部数据库和控制面端口；重启 Docker 后
部署 ID 保持不变。

备份、恢复、升级、回滚、许可证迁移和故障处理见 `OPERATIONS.md`。
