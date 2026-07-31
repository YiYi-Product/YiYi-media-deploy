# 客户 Docker 部署包

客户需要下载的文件统一位于 `customer/`：

- `compose.yaml`：控制面、数据库、Redis 与 License Agent。
- `compose.node.yaml`：Storage/Play Docker 节点。
- `.env.example`：客户环境变量模板。
- `versions.env.example`：发布方镜像摘要模板。
- `config/license-public.jwk`：发布方许可证验签公钥（部署验证完成后生成）。
- `scripts/`：预检、激活、健康检查、备份、恢复、升级和诊断脚本。
- `DEPLOYMENT.md`、`OPERATIONS.md`：部署与运维手册。

客户使用前应把目录完整复制到目标机 `/opt/yiyi`，验证发布签名和镜像 digest，创建 `.env`，然后按照
`customer/DEPLOYMENT.md` 操作。不要向客户提供本服务器根目录的 `.env`、`data/`、`backups/`，也不要
提供授权中心的私钥、管理 Token、激活 Pepper 或数据库备份。

本仓库根目录的 `docker-compose.yml` 与 `docker-compose.license.yml` 用于当前服务器原地升级测试，
不属于新客户的标准部署入口。
