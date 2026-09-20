# YiYi Media 迁移方案

本文覆盖三类迁移动作，全部涉及**数据**，因此每一步都写明前置条件与回滚点：

1. 全新安装（单机版三容器）
2. 现有「单 Storage + 单 Play」部署迁入单机版
3. 多节点部署的处理方式（**停止自动迁移**，人工决策）

::: danger 适用模式先看清楚
本文的迁移目标是**单机版部署（`STANDALONE`，三容器）**。

单机版与分布式版互转**不是升级**，必须同时完成许可证 Edition 变更、部署拓扑迁移与
数据校验。只改 `.env`、Compose 文件或角色变量不会生效，也不允许原地切换。

- 单机版安装与升级：`README.md`、`OPERATIONS.md`
- 分布式部署安装：`README.md`「分布式部署」一节

本文只修改本文档所列步骤涉及的**客户侧部署文件与数据**，不涉及 `YiYi-media` 源码仓库。
:::

## 零、只读预检工具

`migrate-precheck.sh` 是配套的只读预检与影响报告工具。它**默认只读**：
只查询、只统计、只输出报告，不停止、不删除、不修改任何数据。

```bash
cd /opt/YiYi-media-deploy

# 只读预检（旧服务保持运行，这是迁移的第 1 步）
./migrate-precheck.sh

# 指定报告路径，并额外输出 JSON 摘要
./migrate-precheck.sh --report ./migration-report.md --json ./migration-report.json
```

脚本退出码：

| 退出码 | 含义 |
| --- | --- |
| `0` | 预检完成，两类节点都各不超过一个，可走 §13.2 迁移路径 |
| `1` | 预检失败，或数据库不可达导致节点数量无法判定 |
| `3` | **任一类型节点超过一个，自动迁移必须停止** |

它输出这些内容：

- 当前拓扑（Docker daemon 是否可用、检测到的旧拓扑服务、数据目录结构、`PG_VERSION`）
- 受管节点清单（Storage / Play Agent 各多少个，分别是哪些节点 ID）
- 影响面统计（媒体源、用户授权、手动反代、任务引用数量）
- 结论与下一步

::: warning 预检本身也会用到数据库
没有可用连接时，脚本会**如实标注"未采集"**并返回 `1`，而不会猜测节点数量。
请让旧服务保持运行，或显式给出 `--db-host` / `--postgres-container`。
:::

| 选项 | 用途 |
| --- | --- |
| `--report FILE` | 报告输出路径，默认 `migration-report-<UTC时间戳>.md` |
| `--json FILE` | 额外输出 JSON 摘要，供自动化消费 |
| `--postgres-container NAME` | 承载 `yiyi_config` / `yiyi_user` / `yiyi_media` 的容器 |
| `--storage-postgres-container NAME` | 承载 `yiyi_storage` 的容器（独立实例时使用） |
| `--db-host` / `--db-port` / `--db-user` | 直连可达的 PostgreSQL，不通过容器 |
| `--backup` `--confirm-backup` | 额外生成一次备份（**写操作**，必须显式确认） |

::: danger 备份是唯一的写操作，且也需要显式确认
只给 `--backup` 而不给 `--confirm-backup` 会被直接拒绝。备份只**新建文件**，
不改动、不删除任何源数据。脚本中**没有任何** `DELETE` / `DROP` / 删除客户数据的路径。
:::

## 一、全新安装（§13.1）

适合没有历史数据的新机器。全套流程见 `README.md`，这里只列顺序与验收点。

1. 生成配置和安全凭据：`cp .env.example .env && chmod 0600 .env`，填写 `YIYI_SERVER_HOST`。
2. 启动 PostgreSQL、Redis、应用容器：`sudo ./install.sh`。
   脚本会创建统一数据目录、确认四个数据库存在、在拉镜像前校验 Compose 与 Edition 配置。
3. 激活 `STANDALONE` 许可证：浏览器打开 `http://<地址>:18080`，输入一次性授权码。
4. Config 创建两个内置节点并同步授权占用。
5. 页面验证 Storage（`node-local-storage`）与 Play Agent（`node-local-play-agent`）在线。
6. 用户按需添加手动反代地址（单机版「节点管理」唯一可新增的项目）。

验收：

```bash
cd /opt/YiYi-media-deploy
docker compose ps          # 恰好三个服务：yiyi-app、postgres、redis
docker compose exec -T yiyi-app curl -fsS http://127.0.0.1:18084/api/storage/ping
docker compose exec -T yiyi-app curl -fsS http://127.0.0.1:19090/health
```

## 二、现有「单 Storage + 单 Play」部署迁入单机版（§13.2）

适用前提：**Storage 与 Play Agent 各只有一个**。任一类型超过一个时走第三节。

### 前置条件

| 项目 | 要求 |
| --- | --- |
| 节点数量 | Storage、Play Agent **各恰好一个**（由 `migrate-precheck.sh` 判定） |
| 授权 | 已取得 `edition=STANDALONE` 的一次性授权码 |
| 备份 | 四个数据库、`data/license/`、上传目录、Storage 持久化目录已完整备份 |
| 停机窗口 | 迁移需要停旧服务；数据量越大停机越久 |
| 目标拓扑 | 目标机（可与旧机同机或新机）已能运行 `yiyi-app + postgres + redis` |

::: warning 节点 ID 是迁移的核心（计划 §7.2）
媒体源的 `nodeId`、用户播放线路授权、手动反代地址背后的节点授权关系、
历史任务与操作日志关联，全都通过节点 ID 串起来。

迁移的目标是**沿用原节点 ID**，而不是新建节点。ID 一旦改变，这些引用会全部失联。
:::

### 步骤

**第 1 步：只读预检（旧服务保持运行）**

```bash
cd /opt/YiYi-media-deploy
./migrate-precheck.sh --report ./migration-report.md
```

确认结论为 `PROCEED`，并记下报告里的两个既有节点 ID。若得到 `STOP_MULTI_NODE`，
停止，转第三节。

**第 2 步：停止旧应用及外置节点，保留 PostgreSQL / Redis 与全部数据**

只停服务，**不要** `down -v`，也不要删除任何数据目录或命名卷。

```bash
# 旧形态（同机多容器）示例：只停业务服务
# 分布式分支的 compose.yaml 用 profile 区分角色：
docker compose --profile <旧角色> stop

# 外置节点：在节点机上停对应进程或容器
```

::: danger 不要用破坏性命令
不得使用 `docker system prune`、`docker volume prune`、`docker compose down -v`、
`rm -rf` 等命令来完成停机或清理。旧容器与旧配置在验收完成前必须保留（§13.4）。
:::

**第 3 步：完整备份**

备份清单与命令见 `OPERATIONS.md`「备份」。至少覆盖：

- 四个数据库（`pg_dump`，**不要**直接拷运行中的数据库目录）
- `data/license/`（部署身份，丢了要找发布方重新绑定）
- `data/config/uploads/`
- Storage 持久化目录（`mount-data`、`spool`、`read-cache`）

也可以直接用预检脚本的可选备份：

```bash
./migrate-precheck.sh --backup --confirm-backup
```

::: warning 缓存与必须保留的数据不能混为一类
`read-cache`、`vfs-cache`、`image-cache` 是可重建缓存，可按恢复策略选择是否备份；
`storage/spool/` 里可能有**尚未上传完成**的文件，属于必须保留的数据。
:::

**第 4 步：把旧节点提升为内置节点（沿用原节点 ID）**

这是整个迁移最关键、也最容易做错的一步。单机版的内置节点由 Config 幂等创建，
固定 ID 是 `node-local-storage` 与 `node-local-play-agent`；但迁移场景要**沿用原 ID**，
才能保住宿主引用（媒体源的 `nodeId`、用户播放线路授权、手动反代背后的节点授权关系、
历史任务与操作日志关联）。

系统提供**只读影响报告 + 显式确认的提升接口**，不要手工改数据库：

```bash
# 1) 只读影响报告：确认两类节点各不超过一个，并给出可沿用的候选 ID
curl -fsS -H "Authorization: Bearer <管理员会话>" \
  http://127.0.0.1:18085/api/config/deployment/legacy-nodes/report

# 2) 按报告给出的候选 ID 显式确认提升（每个服务类型各执行一次）
curl -fsS -X POST -H "Authorization: Bearer <管理员会话>" \
  -H 'Content-Type: application/json' \
  -d '{"service":"YiYi-control-storage","nodeId":"<报告中的候选 ID>"}' \
  http://127.0.0.1:18085/api/config/deployment/legacy-nodes/promote
```

- **保留原 `node_id` 不变**：提升只改身份标记，不改 ID。
- 内置节点的注册校验以 `EMBEDDED` / `system_managed` 标记为准，不要求 ID 等于固定值。
- 传入的 `nodeId` 必须与报告中的唯一候选一致；节点清单变化时接口会拒绝，
  避免按过期报告改错节点。

::: warning 未标记的内置节点会导致启动失败
单机版的注册中心只接受**已标记为内置**的 Storage / Play Agent 注册。
如果原节点记录仍是 `EXTERNAL`，聚合容器里的 Storage 与 Play Agent 会注册被拒，
表现为「容器起来了，但两个内置节点一直离线」。

Config **不会**自动把历史 `EXTERNAL` 记录提升为内置节点：提升会改变节点的生命周期语义
（此后不能删除、卸载或独立升级），必须由管理员明确确认。
:::

::: danger 多节点场景请勿手工挑一个改标记
任一类型存在多个节点时，影响报告会返回 `MULTIPLE_NODES_BLOCKED`，
提升接口也会直接拒绝。必须先由管理员明确选择保留哪一个，
未选中的节点先禁用并保留记录，**不要删除**。
:::

历史外置节点记录会被保留在数据库里用于迁移与审计，**不会**被自动删除。

**第 5 步：迁移 Storage 数据库**

原 Storage 若使用独立 PostgreSQL，把它的 `yiyi_storage` 库导入目标实例：

```bash
# 在旧实例上导出
pg_dump -Fc -d yiyi_storage > yiyi_storage.dump

# 在目标实例上恢复到 yiyi_storage 库
pg_restore --clean --if-exists -d yiyi_storage yiyi_storage.dump
```

::: danger 恢复是覆盖操作
`--clean --if-exists` 会先删除目标库里已存在的对象再重建。执行前确认库名与转储时间。
:::

**第 6 步：迁移 Storage 数据与 Play Agent 缓存配置**

按目标目录结构（计划 §6）放置文件，属主与权限沿用安装脚本建立的值：

| 来源 | 目标 |
| --- | --- |
| 旧 Storage 挂载数据 | `<data>/storage/mount-data/` |
| 旧 Storage spool | `<data>/storage/spool/`（**必须迁移**） |
| 旧 Storage 读缓存 | `<data>/storage/read-cache/`（可重建，按策略） |
| 旧 Play Agent VFS 缓存 | `<data>/play-agent/vfs-cache/` |
| 旧 Play Agent 图片缓存 | `<data>/play-agent/image-cache/` |

用 `rsync -aHAX` 保留权限、属主与硬链接；不要用普通 `cp -r`。

**第 7 步：启动聚合应用容器，等待全部 Flyway 完成**

```bash
cd /opt/YiYi-media-deploy
sudo YIYI_MIGRATION_CONFIRMED=1 ./install.sh
```

`YIYI_MIGRATION_CONFIRMED=1` 是**唯一**的迁移确认开关，作用是让安装脚本在检测到本机
仍有旧拓扑容器时继续执行；它**不会**删除旧容器。为保护回滚能力，该路径下安装脚本
**不使用 `--remove-orphans`**。

单一 `up --wait` 的等待上限较长（900s），因为迁移场景下 Flyway 首次迁移可能较慢。

**第 8 步：验证**

- [ ] `docker compose ps` 恰好三个服务，且 `yiyi-app` 为 `healthy`
- [ ] 节点管理里两个内置节点都是「在线」，且**节点 ID 与迁移前一致**
- [ ] 媒体源能正常同步，没有出现大量失联来源
- [ ] 用户播放线路授权仍然有效
- [ ] 手动反代地址状态正常，入口令牌与迁移前一致
- [ ] 文件浏览、上传下载、媒体同步与刮削可用
- [ ] 云盘管理正常（FUSE 主机挂载默认关闭不影响这些能力）
- [ ] 许可证状态为 `ACTIVE` / `GRACE`，且 `Edition=STANDALONE`

**第 9 步：仅在验证成功后移除旧容器 / 进程**

确认验收通过后，**手工**移除旧容器与旧进程。安装脚本不会替你删除任何东西。

::: danger 移除前先确认备份可用
先确认升级前的备份能恢复，再移除旧容器。移除旧容器不影响已保留的旧数据目录与
旧命名卷，但保留它们是回滚的最后一道保险。
:::

## 三、多节点部署（§13.3）

::: danger 检测到任一类型超过一个节点时，自动迁移停止
`migrate-precheck.sh` 会返回退出码 `3` 并给出 `STOP_MULTI_NODE` 结论。此时：

1. **管理员必须明确选择**保留哪个 Storage 与哪个 Play Agent；
2. 迁移工具先生成影响报告：媒体源、用户授权、手动反代和任务引用数量；
3. 未选中的节点**先禁用并保留记录，不立即删除**；
4. 如需合并多个 Storage 数据库，**另立专项迁移方案**，不纳入本期自动流程。
:::

预检脚本的影响报告已经按节点列出「如果选错会失联的引用数量」。决策时至少看这四类：

| 影响面 | 报告中的位置 |
| --- | --- |
| 媒体源 | 媒体库的存储来源、媒体同步项与流 |
| 用户授权 | 用户媒体源授权、播放流量统计 |
| 手动反代 | 手动反代地址数量 |
| 任务引用 | 整理任务节点分片、直链缓存、网盘凭证 |

选定后的处理原则：

- 保留目标：沿用原节点 ID 并标记为 `EMBEDDED`，按第二节后半段继续。
- 未选中的节点：**先禁用**（`enabled = false`），保留全部记录与数据，
  便于后续审计或人工回溯。不要删除。
- 多个 Storage 数据库的合并、多节点媒体库引用的重写：本期不做。

## 四、回滚（§13.4）

### 原则

- **升级前必须备份**数据库与持久化目录。没有备份就没有回滚。
- **旧应用容器和配置在验收完成前保留。**
- 镜像可以回退到旧标签，但**数据库 Flyway 不保证降级**：若新版本写入不兼容结构，
  应使用升级前的备份恢复。
- **安装脚本不得用破坏性 Git 或 Docker 清理命令完成回滚。**

::: danger 明确禁止的回滚手段
- `git reset --hard`、强制切换分支
- `git clean -fdx`
- `docker system prune`、`docker volume prune`
- `docker compose down -v`、`rm -rf data/`
- `docker restart $(docker ps -q)`

这些命令要么会丢掉本地改动与凭据文件，要么会影响本机上与本项目无关的其它业务。
:::

### 分层回滚

| 层级 | 回滚方式 |
| --- | --- |
| 部署文件 | `git status` / `git diff` 看清改动，用 `git log --oneline` 找到上一个提交后人工还原；不要 `reset --hard` |
| 应用镜像 | 把 `YIYI_IMAGE_TAG` 改回旧版本标签，`docker compose pull` + `up -d --wait` |
| 数据库结构 | **没有自动降级**。回到旧镜像前，先用升级前的 `pg_dump` 恢复数据库 |
| 配置 | `.env` 每次改前留一份带日期的副本，权限保持 `0600` |
| 迁移回滚 | 恢复升级前的数据库转储与 `data/license/`，回到旧部署继续运行 |

::: warning 镜像与数据库要一起回滚
新版本镜像可能已经推进过表结构，数据库比旧镜像新。只把镜像换回旧标签而不恢复数据库，
旧代码可能读不懂新表结构。
:::

```bash
# 例：把聚合镜像钉回一个具体版本标签
# 1. 编辑 .env，把 YIYI_IMAGE_TAG 改成旧版本标签
# 2. 生效
cd /opt/YiYi-media-deploy
docker compose pull
docker compose up -d --remove-orphans --wait
docker compose ps
```

### 部署文件回滚示例

```bash
cd /opt/YiYi-media-deploy
git status --short --branch
git diff -- compose.yaml install.sh
git log --oneline -10
# 用 git checkout <提交号> -- <文件> 或手工编辑还原，再重建容器
```

## 五、单机版升级为分布式版（不属于本文自动流程）

单机版升级为分布式版必须走**授权的专用版本升级操作**，本文不提供自动工具：

1. 在管理台执行「升级为分布式版」或调用 `POST /api/admin/licenses/{id}/edition`，
   获得新的 `edition=DISTRIBUTED` 签名租约与审计记录；
2. `GET /api/config/deployment/capabilities` 应显示 `edition=DISTRIBUTED`；
3. 按分布式部署顺序安装 `control` → `user` → `media` → `edge`；
4. 迁移四个数据库，并把原内置节点在目标机上**真正部署为外部工作节点**，
   沿用原节点 ID；
5. 验证通过后才停用旧单机版部署。

**不支持**自动从分布式版降级为单机版。

## 相关文档

- [`README.md`](README.md)：单机版与分布式版安装入口
- [`OPERATIONS.md`](OPERATIONS.md)：升级、备份、端口与安全
- [`migrate-precheck.sh`](migrate-precheck.sh)：本节的只读预检工具
