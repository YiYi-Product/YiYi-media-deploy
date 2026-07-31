# YiYi 客户运维手册

## 日常检查

```bash
cd /opt/yiyi
./scripts/healthcheck.sh
docker compose --env-file .env -f compose.yaml -f compose.node.yaml ps
```

许可证状态含义：

- `ACTIVE`：正常。
- `GRACE`：授权服务器暂时不可达，处于有限断网宽限；立即检查 DNS、TLS、出口和系统时间。
- `SUSPENDED` / `REVOKED` / `EXPIRED`：业务受限，请联系发布方。
- `INVALID`：租约、公钥或文件被破坏/替换，禁止尝试绕过，先生成诊断包。
- `LICENSE_NATIVE_UNAVAILABLE/ERROR`：镜像架构错误、原生验证库缺失/损坏或 JNI 加载失败；先核对
  官方镜像 digest 和主机 CPU 架构，不要从其他版本复制 `.so`。

## 备份

```bash
./scripts/backup.sh /secure/yiyi-backups
```

备份包含 PostgreSQL、上传文件、`.env` 和部署 Ed25519 私钥，等同于生产凭据。应加密、限制访问并
执行异机保留。至少每周做一次恢复演练。Redis 为可重建缓存，不作为恢复依据。

## 恢复

```bash
./scripts/restore.sh /secure/yiyi-backups/20260731T000000Z
```

恢复是覆盖性操作，脚本要求交互输入 `RESTORE`。恢复旧主机的部署身份到新主机前，先停止旧主机，
并由发布方确认迁移；不得同时运行复制出的两个部署。

## 升级

1. 从发布方获取新的 digest 清单、签名和变更说明。
2. 校验签名后，只替换 `.env` 中的镜像 digest 和 `YIYI_RELEASE_VERSION`。
3. 运行：

```bash
./scripts/upgrade.sh
```

脚本依次做预检、备份、拉取、滚动重建和健康检查。不要直接改为 `latest`，不要运行来源不明的镜像。

## 回滚

1. 保留失败版本的诊断包。
2. 恢复升级前 `.env`（旧 digest）。
3. 如果数据库迁移明确不向后兼容，先用升级前备份执行恢复；否则不要盲目回滚数据库。
4. 执行：

```bash
docker compose --env-file .env -f compose.yaml -f compose.node.yaml pull
docker compose --env-file .env -f compose.yaml -f compose.node.yaml up -d --remove-orphans
./scripts/healthcheck.sh
```

## 许可证迁移

标准迁移流程：

1. 备份旧主机并完整停止 YiYi。
2. 把加密备份恢复到新主机，部署身份卷必须整体迁移。
3. 保持同一 `license-public.jwk` 和镜像版本，启动 License Agent 验证续租。
4. 若无法迁移部署身份，由发布方在管理端停用旧 deployment，再签发新的激活码。

停用旧部署会释放控制面和节点名额；许可证撤销是不可逆操作，不能用于普通迁移。

## 许可证服务器短时不可达

已有有效租约会按合同策略进入 `GRACE`，默认建议值为 72 小时。宽限期间不允许新增节点；恢复网络后
License Agent 会自动续租。不要通过修改系统时间、租约文件或公钥延长宽限，这会进入 `INVALID` 或
`CLOCK_SKEW`。

## 故障诊断

```bash
./scripts/diagnostics.sh
```

脚本收集容器状态、镜像摘要、最近日志和许可证状态，并做基础敏感字段脱敏。发送前必须人工检查。
不要直接发送 `.env`、数据库备份、`license_identity` 卷、激活码或仓库 token。

## 卸载

普通停止不会删除数据：

```bash
docker compose --env-file .env -f compose.yaml -f compose.node.yaml down
```

不要使用 `down -v`。如合同结束需要彻底销毁，应先由发布方停用部署、保留合规备份，再由双方确认
具体卷清单后单独执行；本交付包不提供自动删库脚本。
