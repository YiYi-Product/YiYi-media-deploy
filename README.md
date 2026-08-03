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
git clone https://github.com/leG09/YiYi-deploy.git /opt/YiYi-deploy
cd /opt/YiYi-deploy
sudo ./install.sh single --host <服务器IP或域名>
```

安装完成后访问：

```text
http://<服务器IP或域名>:18080
```

按照页面提示输入发布方提供的一次性授权码，即可继续初始化系统。

## 部署 Storage 和 Play 节点

Storage 和 Play 节点由网页自助部署：

1. 登录 YiYi。
2. 进入“节点管理”。
3. 创建 Storage 或 Play 节点。
4. 复制页面生成的命令。
5. 在准备运行节点的服务器上粘贴执行。

节点可以与主服务安装在同一台服务器，也可以安装在其他服务器。

## 多服务器部署

多台服务器需要位于同一私有网络，并按下面的顺序安装：

| 顺序 | 角色 | 用途 |
|---|---|---|
| 1 | `control` | 主服务器，只安装一台 |
| 2 | `user` | 用户服务 |
| 3 | `media` | 媒体服务 |
| 4 | `edge` | 网页入口 |

先在每台服务器执行：

```bash
git clone https://github.com/leG09/YiYi-deploy.git /opt/YiYi-deploy
cd /opt/YiYi-deploy
```

### 1. 安装主服务器

在主服务器执行：

```bash
cd /opt/YiYi-deploy
sudo ./install.sh control --host <主服务器IP或者域名>
```

安装完成后会生成 `join.env` 和 `cluster-relay.crt`。将这两个文件通过安全方式复制到其他服务器的同一目录。

### 2. 安装其他服务器

在其他服务器根据用途执行其中一个命令：

```bash
# 用户服务
sudo ./install.sh user --host <本机内网IP> --join <join.env路径>

# 媒体服务
sudo ./install.sh media --host <本机内网IP> --join <join.env路径>

# 网页入口
sudo ./install.sh edge --host <本机内网IP> --public-host <公网IP或域名> --join <join.env路径>
```

安装完成后删除其他服务器上的 `join.env`。访问下面的地址并输入一次性授权码：

```text
http://<公网IP或域名>:18080
```

Storage 和 Play 节点仍然在网页“节点管理”中创建和部署。

## 常用命令

在 `/opt/YiYi-deploy` 目录执行：

```bash
sudo ./yiyi.sh status     # 查看运行状态
sudo ./yiyi.sh check      # 检查服务
sudo ./yiyi.sh logs       # 查看日志
sudo ./yiyi.sh update     # 更新
sudo ./yiyi.sh restart    # 重启
sudo ./yiyi.sh stop       # 停止
sudo ./yiyi.sh start      # 启动
```

备份、恢复、端口和故障处理见 [OPERATIONS.md](OPERATIONS.md)。
