# 启用 Telegram Bot

安装 YiYi 后，站点管理员需要配置机器人，普通用户直接私聊 Bot 发送 `/start` 即可使用。
**只填写 Webhook 密钥不会自动接通 Bot**；还需要 Bot Token 和公网 HTTPS 回调地址。

## 第 1 步：创建机器人并准备网络

1. 在 Telegram 找到官方 `@BotFather`，发送 `/newbot`，按提示创建 Bot，保存 Token 和用户名。
2. 为 YiYi 配置公网 HTTPS 域名，确保 `/api/auth/telegram/webhook` 能转发到 YiYi 的 Web 入口，且不被登录页、验证码或浏览器挑战拦截。
3. 确保运行 user 服务的主机能访问 `api.telegram.org`。出站需要代理时，在「系统配置 → 网络与代理」里为「Telegram Bot」选择代理。代理只影响出站请求，公网回调仍须可达。

同一个 Bot 只使用一个 Webhook 地址，测试与正式站点应分别创建 Bot，避免相互覆盖。

## 第 2 步：填写 .env

在部署目录的 `.env` 填写以下变量；真实凭据只保存在该文件中，权限保持 `0600`。

| 变量 | 填写内容 |
| --- | --- |
| `YIYI_TELEGRAM_BOT_TOKEN` | BotFather 提供的 Bot Token |
| `YIYI_TELEGRAM_BOT_USERNAME` | Bot 用户名，不带 `@` |
| `YIYI_TELEGRAM_WEBHOOK_SECRET` | 自行设置的随机密钥，使用英文字母、数字、下划线或连字符，长度 1–256 字符；建议至少 32 字符 |
| `YIYI_TELEGRAM_WEBHOOK_URL` | 完整公网回调地址，例如 `https://media.example.com/api/auth/telegram/webhook` |

`YIYI_TELEGRAM_MINIAPP_URL` 用于 Mini App，不是 Webhook 回调地址，不能代替 `YIYI_TELEGRAM_WEBHOOK_URL`。

三个部署版本的配置位置：

| 部署分支 | 在哪台机器填写 | 接收配置的服务 |
| --- | --- | --- |
| `main`（单机版） | 单机版服务器 | `yiyi-media` 容器中的 user 服务 |
| `v2-all-in-one`（控制面同机） | 控制面服务器 | `user` |
| `v3-multi-host`（按角色多机） | **user 角色主机** | `user`；回调 URL 仍填写经 edge 对外提供的 HTTPS 域名 |

## 第 3 步：启动并自动注册

新安装时，在配置完 `.env` 后按本部署版本的安装步骤运行 `sudo ./install.sh`。
user 服务启动时会同步命令菜单，并使用上面的地址和密钥向 Telegram 注册 Webhook，订阅命令、按钮和群成员变更等事件，无需额外在浏览器注册。

已有部署应保留原 `.env` 和数据，使用包含上述变量的新版部署文件。若只是修改 Telegram 配置，且当前镜像已支持启动时注册，可在部署目录按对应版本执行以下一条命令，让容器重新读取环境变量：

```bash
# main：单机版服务器
sudo docker compose -p yiyi up -d --no-deps --force-recreate yiyi-media
```

```bash
# v2-all-in-one：控制面服务器；v3-multi-host：user 角色主机
sudo docker compose -p yiyi up -d --no-deps --force-recreate user
```

以上操作会短暂中断对应服务。单纯 `docker compose restart` 不会重新读取修改后的 `.env`。
如果同时升级镜像，请按本版本的升级指南操作，不要用上述配置重建命令代替升级流程。

首次安装时，先在网页完成 YiYi 许可证激活和管理员初始化，再验证 Bot。
v3 的 user 先于 edge 启动时，回调可能暂时不可达；等 edge 和 HTTPS 入口就绪后再验证。

## 第 4 步：发送 /start 验证

在 Telegram 私聊 Bot，发送 `/start`，收到个人面板才表示收发链路已经接通。
注册成功只表示 Telegram 接受了配置，不能代替实际命令验证。

群管理功能还需把 Bot 加入群并设为管理员，根据需要授予删除消息、限制成员等权限。
在后台「用户管理 → 强制绑定」填写 Telegram 群组 ID；只有需要强制入群时才开启对应策略。

## 旧部署：在浏览器手动注册

旧部署文件尚未接入 `YIYI_TELEGRAM_WEBHOOK_URL`，或需要手动修复注册时，可以使用下面的链接。
前提是服务已经加载了正确的 Bot Token 和 Webhook 密钥；手动注册不能代替服务端配置。

在自己电脑上替换以下占位符并去掉尖括号，再把整行粘贴到浏览器地址栏打开：

```text
https://api.telegram.org/bot<BOT_TOKEN>/setWebhook?url=https://<站点域名>/api/auth/telegram/webhook&secret_token=<WEBHOOK_SECRET>&allowed_updates=%5B%22message%22%2C%22callback_query%22%2C%22inline_query%22%2C%22chat_member%22%2C%22my_chat_member%22%2C%22edited_message%22%5D
```

- `<BOT_TOKEN>`：`.env` 中的 `YIYI_TELEGRAM_BOT_TOKEN`。
- `<站点域名>`：YiYi 的公网域名，不带协议和路径；例如 `media.example.com`。
- `<WEBHOOK_SECRET>`：与 `.env` 中的 `YIYI_TELEGRAM_WEBHOOK_SECRET` 完全一致。

返回 `"ok": true` 表示注册成功，然后发送 `/start` 验证。
完整链接含 Token 和密钥，会留在浏览器历史中；不要分享、截图或粘贴到工单中。

每个 Bot 通常只需手动注册一次，重启不需要重复；更换域名、密钥或 Bot 后需重新注册。
配置自动注册后，服务会在每次启动时同步配置。

## 无响应时检查什么

可以在自己浏览器中打开以下地址查看 Telegram 的投递状态，同样不要分享含 Token 的完整链接：

```text
https://api.telegram.org/bot<BOT_TOKEN>/getWebhookInfo
```

| 现象 | 检查与处理 |
| --- | --- |
| `url` 为空或指向旧站点 | 注册未完成或被其他实例覆盖，按上面的步骤重新注册 |
| `pending_update_count` 持续增加 | Telegram 无法顺利投递，结合 `last_error_date` 和 `last_error_message` 检查公网 HTTPS、反代和服务状态 |
| 回调返回 401 | 核对注册的 `secret_token` 与 user 实际加载的密钥，改配置后重建对应容器并重新注册 |
| 回调返回 503 | 检查 user 是否配置 Webhook 密钥 |
| 回调返回 403 | 先检查 YiYi 许可证状态和入口访问限制 |
| 没有积压但 Bot 仍不回复 | 检查 Bot Token、user 日志和 Telegram 出站网络；需要时配置出站代理 |
| 群成员变更收不到 | 确认 Bot 是群管理员，重新注册时带齐上例中的 `allowed_updates` |

`last_error_message` 可能保留历史错误，应结合错误时间、积压是否增长和实际 `/start` 回复判断。
自动注册失败只会记录告警，安装成功或容器健康不代表 Bot 已接通。

接口参数见 [Telegram 官方文档](https://core.telegram.org/bots/api#setwebhook)。
