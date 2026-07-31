# 端到端验证记录

验证日期：2026-07-31（UTC+8）  
验证环境：Linux ARM64 / Docker Engine 28 / Docker Compose v2  
测试版本：`e2e-20260731-1`

已验证：

- 一次性激活码成功激活，激活文件随后自动删除。
- License Agent 启动、立即续租和一分钟周期续租正常。
- Config、User、Media、Gateway 均通过 ARM64 Rust/JNI 原生库校验签名租约。
- 授权暂停后四个控制面业务请求均返回 403，健康端点继续可用；恢复后业务限制解除。
- Storage 和 Play 节点在控制面升级、授权暂停和恢复期间均未重启，健康状态保持正常。
- 现有一个 Storage 和一个 Play 节点已占用许可证配额，额外 Storage 节点申请被
  `NODE_LIMIT_REACHED` 拒绝。
- `https://t.190607.xyz` TLS、公共授权 API 和公钥端点正常；公网管理 API 返回 404，管理端只在
  `127.0.0.1:18087` 可达且要求管理 Token。
- 授权中心 PostgreSQL、签名私钥和管理凭据备份已生成并通过校验。

本记录使用本机构建的 ARM64 测试标签。正式向外部客户交付前，仍必须在指定构建机执行多架构发布
脚本，生成 `linux/amd64`、`linux/arm64` manifest digest、SBOM 和 Cosign 签名，然后把正式
`versions.env` 合并进客户 `.env`。测试标签不能代替正式 digest 发布清单。
