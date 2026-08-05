# YiYi Docker 部署

本仓库用于部署 YiYi，支持单台服务器和多台服务器。

## 准备工作

- 一台或多台 64 位 Linux 服务器
- Docker 和 Docker Compose v2
- 服务器 IP 或已解析的域名

推荐先使用单台服务器部署。需要分散服务器负载时，再使用多服务器部署。

## 单台服务器部署

在服务器执行：

```bash
git clone https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
cd /opt/YiYi-media-deploy
cp .env.example .env
chmod 0600 .env
```

单机部署默认角色、授权地址和镜像均已配置，只需在 `.env` 填写：

```dotenv
YIYI_SERVER_HOST=<服务器IP或域名>
```

只有公网访问地址与服务器地址不同时，才需要填写 `YIYI_PUBLIC_HOST`。
`YIYI_DB_USER`、`YIYI_DB_PASSWORD` 和 `YIYI_REDIS_PASSWORD` 已在模板中保留；
密码保持 `GENERATE_ON_INSTALL` 即可由脚本自动生成，也可以在安装前自行设置。

然后执行：

```bash
sudo ./install.sh
```

安装脚本会直接读取 `.env`，并自动下载和验证 Ed25519 公钥。

安装完成后访问：

```text
http://<服务器IP或域名>:18080
```

按照页面提示输入发布方提供的一次性授权码，即可继续初始化系统。

## 部署 Storage 和 Play 节点

Storage 和 Play 节点不由本部署包安装。用户登录 YiYi 后进入“节点管理”，
创建节点并按页面引导自助部署即可。

## 多服务器部署

多台服务器需要位于同一私有网络，并按下面的顺序安装：

| 顺序 | 角色 | 用途 |
|---|---|---|
| 1 | `control` | 主服务器，只安装一台 |
| 2 | `user` | 用户服务 |
| 3 | `media` | 媒体服务 |
| 4 | `edge` | 网页入口 |

每台服务器都使用同一个安装命令。先准备配置：

```bash
git clone https://github.com/YiYi-Product/YiYi-media-deploy.git /opt/YiYi-media-deploy
cd /opt/YiYi-media-deploy
cp .env.example .env
chmod 0600 .env
```

### 1. 安装主服务器

在主服务器的 `.env` 中设置：

```dotenv
YIYI_DEPLOY_ROLE=control
YIYI_SERVER_HOST=<主服务器内网IP或域名>
YIYI_USER_HOST=<User服务器内网IP或域名>
```

执行：

```bash
sudo ./install.sh
```

安装完成后会生成 `join.env` 和 `cluster-relay.crt`。将这两个文件通过安全方式复制到其他服务器的同一目录。

### 2. 安装其他服务器

将主服务器生成的 `join.env` 和 `cluster-relay.crt` 安全复制到其他
服务器的 `/opt/YiYi-media-deploy/` 目录。在各服务器的 `.env` 中填写：

```dotenv
YIYI_DEPLOY_ROLE=<user、media或edge>
YIYI_SERVER_HOST=<本机内网IP或域名>
YIYI_PUBLIC_HOST=<edge的公网IP或域名>
```

每台服务器执行相同命令：

```bash
sudo ./install.sh
```

安装完成后删除其他服务器上的 `join.env`。访问下面的地址并输入一次性授权码：

```text
http://<公网IP或域名>:18080
```

Storage 和 Play 节点仍然在网页“节点管理”中创建和部署。

## 升级

安装和升级使用同一个命令。已安装环境会自动拉取部署仓库更新、
备份主控数据、拉取所有 YiYi 镜像的 `latest` 版本并执行健康检查：

```bash
sudo ./install.sh
```

首次授权和后续授权状态均在网页中处理，不需要命令行激活。
端口和安全说明见 [OPERATIONS.md](OPERATIONS.md)。
