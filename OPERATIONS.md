# YiYi 运维说明

## 更新

单台服务器执行：

```bash
cd /opt/YiYi-media-deploy
sudo ./yiyi.sh update
```

多服务器建议按以下顺序逐台更新：

1. Control
2. User、Media
3. Edge

Storage 和 Play 节点请在网页“节点管理”中升级。

## 备份

单台部署在当前服务器执行；多服务器部署在 Control 服务器执行：

```bash
cd /opt/YiYi-media-deploy
sudo ./yiyi.sh backup /secure/yiyi-backups
```

请将备份文件保存在安全位置，并定期复制到其他服务器或对象存储。

## 恢复

恢复会覆盖现有数据，请先停止业务操作并确认备份目录正确：

```bash
cd /opt/YiYi-media-deploy
sudo ./yiyi.sh restore /secure/yiyi-backups/<备份目录名>
```

按终端提示输入确认内容。恢复完成后运行：

```bash
sudo ./yiyi.sh check
```

## 网络端口

单台部署通常只需要允许用户访问 `18080`。

多服务器部署还需要在服务器私有网络内放行：

| 端口 | 用途 |
|---|---|
| `5432` | 数据库 |
| `6379` | 缓存 |
| `18085` | 集群通信 |
| `18089` | 集群通信 |

不要把以上四个端口开放到公网。Storage 和 Play 的端口按照网页生成的部署命令及实际访问需求设置。

## 安全注意事项

- 不要公开或提交 `.env`、`join.env`、`config/cluster-relay.key` 和备份目录。
- `join.env` 只用于其他服务器加入集群，安装完成后应从其他服务器删除。
- 生产环境建议为网页入口配置 HTTPS。

## 出现问题时

先执行：

```bash
cd /opt/YiYi-media-deploy
sudo ./yiyi.sh check
sudo ./yiyi.sh status
```

查看日志：

```bash
sudo ./yiyi.sh logs
```

需要提交诊断信息时执行：

```bash
sudo ./yiyi.sh diagnostics
```

如果页面提示授权暂停、撤销、过期或无效，请联系发布方处理。
