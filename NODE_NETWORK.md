# 分布式节点：防火墙与连通性排查

适用于 `v2-all-in-one`：一台机器运行控制面，另外两台分别运行播放节点和存储节点。
先确认每条连接的发起方，再按来源 IP 放行目标端口。SSH 登录成功只说明管理端口可达。

## 1. 安装前准备

记录三台机器的实际出口 IP、SSH 端口、节点监听端口，以及播放客户端使用的域名。
以下命令假设节点使用默认端口；自定义端口时要同时替换防火墙规则与测试地址。

控制面上核对部署方式：

```bash
cd /opt/YiYi-media-deploy  # 换成你的实际部署目录
git branch --show-current
docker compose -p yiyi config --services
```

分支应为 `v2-all-in-one`。外部节点不属于这份 Compose，需分别在节点机检查。
存储节点使用本机数据库时，不需要开放控制面的数据库端口。

## 2. 最小访问清单

下面都是 TCP 端口，规则加在**目标机器**上。若出口经过 NAT，来源白名单应填写目标端实际看到的出口 IP。

| 发起方 | 目标机器 | 目标端口 | 用途 |
| --- | --- | --- | --- |
| 播放节点、存储节点 | 控制面 | `18085` | 安装、注册、心跳、服务发现 |
| 播放节点、存储节点 | 控制面 | `18082`、`18083` | 用户校验、元数据与变更回调 |
| 控制面 | 存储节点 | `18084` | 健康检查、文件管理与任务 |
| 播放节点 | 存储节点 | `18084` | 本地硬盘资源回源 |
| 控制面 | 播放节点 | `19090` | 健康检查与任务查询 |
| 播放客户端 | 播放入口 | HTTPS `443`，或实际直连端口 | 登录与播放 |

使用同机反向代理时，反代通过回环访问播放服务，客户端只需要访问反代入口。
若客户端直连播放节点，才需要对客户端放行 `19090`。
只有要对外提供 WebDAV 时，才另行配置客户端到存储服务的入口。

`18086` 是控制面内部网关端口，以上外部节点链路不需要它。`18088` 保持回环监听。
`5432`、`6379` 不属于这套拓扑的节点互访清单；不要为了节点上线一起开放。

## 3. 使用节点防火墙脚本

### 按节点 IP 放行全部端口

需要让已知节点之间完全互访时，使用 `--all-ports`，重复 `--peer-ip` 列出允许的对端实际出口 IP。
此模式放行这些来源的所有入站端口与协议；其他公网来源继续遵循原防火墙规则。
在每台启用了 UFW/firewalld 的机器上执行，并排除本机 IP：

```bash
# 示例：在存储机允许控制面与两台播放机；请替换实际 IP
sudo python3 ./yiyi-node-firewall.py --role storage --all-ports \
  --peer-ip 203.0.113.10 --peer-ip 203.0.113.20 --peer-ip 203.0.113.21
sudo python3 ./yiyi-node-firewall.py --role storage --all-ports \
  --peer-ip 203.0.113.10 --peer-ip 203.0.113.20 --peer-ip 203.0.113.21 --apply
```

在控制面、播放机分别改用 `--role control`、`--role play` 并列出其对端。
firewalld 仍需指定 `--zone`。撤销时保留 `--all-ports`、同一角色/IP/zone，将 `--apply` 换成 `--remove`；
只撤销本模式记录的规则，原有按端口规则保留。不加 `--all-ports` 时继续按下文的必要端口清单放行。

**每增加一台播放机，都要更新每台实际回源存储机的来源白名单。**
只在控制面放行注册端口，并不会自动允许该播放机读取存储资源。
存储 `18084` 超时先核对实际播放机来源 IP；已有来源放行仍超时的，继续查网络路径与请求取消原因。

### 获取脚本与前提

脚本随本仓库的 `v2-all-in-one` 分支提供，文件是仓库根目录的
[`yiyi-node-firewall.py`](yiyi-node-firewall.py)，不依赖文档站下载或控制面镜像升级。
需要 Python 3.8 或更高版本，使用 `sudo python3` 运行。脚本无需节点令牌或管理员密码，
不会安装依赖、启用防火墙、重启服务、清空规则或修改云安全组。

在控制面部署目录核对文件与帮助：

```bash
python3 ./yiyi-node-firewall.py --help
```

节点机不必克隆整份部署仓库。你可以从本机已有的部署目录复制单个脚本到节点机：

```bash
NODE_IP=203.0.113.20
NODE_SSH_PORT=22  # 换成节点实际 SSH 端口
scp -P "$NODE_SSH_PORT" ./yiyi-node-firewall.py "root@$NODE_IP:/root/yiyi-node-firewall.py"
```

随后 SSH 登录节点，在 `/root` 下执行对应命令。使用其他登录用户时，改为该用户可写目录。
下文命令均假定脚本已放在当前目录。不要从其他分支复制安装脚本或 Compose 文件。

支持**已启用的 UFW 或 firewalld**，自动检测管理器。不带操作参数时只读预览，
加 `--apply` 才实际添加并保存规则。已有的相同来源/端口规则会跳过，不会接管。
原生 nftables/iptables、多套管理器同时启用时会报错退出，请由维护该防火墙的人按第 2 节清单处理。

### 第一步：在控制面允许新节点

每增加一台播放或存储节点，在控制面执行一次。只填写**新节点的实际出口 IP**：

```bash
NODE_IP=203.0.113.20
sudo python3 ./yiyi-node-firewall.py --role control --node-ip "$NODE_IP"
# 核对预览中的来源 IP 和端口后执行
sudo python3 ./yiyi-node-firewall.py --role control --node-ip "$NODE_IP" --apply
```

一次添加多台时，重复 `--node-ip`。默认仅放行 TCP `18082/18083/18085`。

### 第二步：在存储机允许控制面和播放机

新装存储节点，或增加需要从这台存储机读取硬盘资源的播放节点时，在存储机执行：

```bash
CONTROL_IP=203.0.113.10
PLAY_IP=203.0.113.20
sudo python3 ./yiyi-node-firewall.py --role storage --control-ip "$CONTROL_IP" --play-ip "$PLAY_IP"
sudo python3 ./yiyi-node-firewall.py --role storage --control-ip "$CONTROL_IP" --play-ip "$PLAY_IP" --apply
```

仅放行两者到本机 TCP `18084`。有多台播放机时重复 `--play-ip`；有多台存储机时在每台存储机执行。

存储节点已经部署、这次只新增播放机时，可以只指定新播放机：

```bash
sudo python3 ./yiyi-node-firewall.py --role storage --play-ip 203.0.113.21
sudo python3 ./yiyi-node-firewall.py --role storage --play-ip 203.0.113.21 --apply
```

### 第三步：在播放机允许控制面

```bash
CONTROL_IP=203.0.113.10
sudo python3 ./yiyi-node-firewall.py --role play --control-ip "$CONTROL_IP"
sudo python3 ./yiyi-node-firewall.py --role play --control-ip "$CONTROL_IP" --apply
```

仅放行控制面到 TCP `19090`。播放客户端的 HTTPS 或直连入口仍需按实际拓扑配置；
脚本不会向任意公网来源开放播放端口。

### firewalld 与自定义端口

firewalld 必须先确认接口或来源实际归属的 zone，再给上述每条命令加上 `--zone <实际zone>`：

```bash
sudo firewall-cmd --get-active-zones
sudo python3 ./yiyi-node-firewall.py --role play --control-ip 203.0.113.10 --zone public
sudo python3 ./yiyi-node-firewall.py --role play --control-ip 203.0.113.10 --zone public --apply
```

上面的 `public` 只是示例，要与实际接收该流量的 zone 一致。
脚本同时更新运行时与永久配置，不执行全局 reload。规则使用优先级 `-100` 的按来源放行；
UFW 新规则插在规则列表开头。配置前要核对来源 IP，因为这些规则会优先于后面的拒绝规则匹配。

自定义端口使用 `--user-port`、`--media-port`、`--config-port`、`--storage-port`、`--play-port`。
例如播放节点实际监听 `19091`，则在播放机命令末尾加 `--play-port 19091`。
脚本接受单个 IPv4 或 IPv6 地址，不接受域名或网段；它只处理入站规则，出站限制需另外核对。

### 撤销与验证

重复执行 `--apply` 不会重复添加规则。撤销时使用**同一角色、IP、端口和 zone**，将 `--apply` 换成 `--remove`：

```bash
sudo python3 ./yiyi-node-firewall.py --role control --node-ip 203.0.113.20 --remove
# 只撤销存储机上的某台播放机访问，不影响控制面和其他播放机
sudo python3 ./yiyi-node-firewall.py --role storage --play-ip 203.0.113.21 --remove
```

记录保存在目标机 `/var/lib/yiyi-node-firewall/state.json`，请保留。
`--remove` 只撤销记录中由本脚本新增的规则，保留管理员原有规则；执行报错时会尝试撤销本次已完成的变更。
如果提示回滚失败，按记录文件和终端输出检查实际规则，不要直接清空防火墙。

添加规则后，按第 4 节从真实调用方验证，并检查云安全组。
已有规则被跳过时仍要检查其命中顺序，脚本成功退出不代表业务链路已验收。

### 手动配置 UFW

先查看现有规则并保留 SSH 会话：

```bash
sudo ufw status verbose
sudo ufw status numbered
```

以下示例只用于**已经启用 UFW** 的主机。先将示例 IP 替换为实际出口 IP。
不要直接在使用其他防火墙的机器上启用 UFW，也不要清空规则或关闭防火墙。

控制面执行：

```bash
PLAY_IP=203.0.113.20
STORAGE_IP=203.0.113.30
for NODE_IP in "$PLAY_IP" "$STORAGE_IP"; do
  for PORT in 18082 18083 18085; do
    sudo ufw allow proto tcp from "$NODE_IP" to any port "$PORT" comment 'YiYi node'
  done
done
```

存储机执行：

```bash
CONTROL_IP=203.0.113.10
PLAY_IP=203.0.113.20
sudo ufw allow proto tcp from "$CONTROL_IP" to any port 18084 comment 'YiYi control'
sudo ufw allow proto tcp from "$PLAY_IP" to any port 18084 comment 'YiYi playback source'
```

播放机若已启用 UFW，执行：

```bash
CONTROL_IP=203.0.113.10
sudo ufw allow proto tcp from "$CONTROL_IP" to any port 19090 comment 'YiYi control'
```

这最后一条只解决控制面访问。播放客户端走 HTTPS 反代还是直连，应按实际入口单独配置。
若已有靠前的显式拒绝规则，新增规则可能仍被挡住；检查编号和命中顺序后处理具体冲突。
云厂商安全组也需允许相同方向的连接，主机放行不能替代安全组放行。

规则添加后立即生效并由 UFW 保存，无需重启应用或 Docker。
需要撤销本次新增规则时，在对应命令的 `ufw allow` 前改为 `ufw delete allow`，保持其余参数相同。
不要删除原先已有的同名规则。

## 4. 从实际调用方验证

不要只从自己的电脑测，也不要只在目标机测 `127.0.0.1`。

两个节点上分别执行：

```bash
CONTROL_IP=203.0.113.10
for PORT in 18082 18083 18085; do
  curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 -o /dev/null \
    -w "端口 $PORT：HTTP %{http_code}，耗时 %{time_total}s\n" \
    "http://$CONTROL_IP:$PORT/actuator/health"
done
```

控制面和播放节点上分别测试存储机：

```bash
STORAGE_IP=203.0.113.30
curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 \
  "http://$STORAGE_IP:18084/api/storage/ping"
```

控制面上测试播放机：

```bash
PLAY_IP=203.0.113.20
curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 "http://$PLAY_IP:19090/health"
```

健康检查通过后，在「节点管理」确认两类节点持续在线，再验证文件浏览与一次真实播放。
健康检查成功不代表节点凭据一定正确，也不代表硬盘路径已经映射进存储容器。

## 5. 根据现象定位

| 现象 | 下一步 |
| --- | --- |
| 立即 `Connection refused` | 查看目标机 `ss -lntp`，确认进程、监听端口与绑定地址；也检查显式 REJECT 规则 |
| 一直超时 | 检查目标机防火墙、安全组、来源出口 IP、路由和回程 |
| 返回 HTTP `401` / `403` | TCP 与 HTTP 已通；核对节点注册凭据和节点平面凭据，继续开放端口不能解决鉴权失败 |
| 健康检查成功，但文件浏览或播放失败 | 检查节点凭据、播放机到存储机的 `18084`，以及存储容器的磁盘映射 |
| 节点注册成功，稍后又离线 | 检查连续心跳和双向连通性，不能只凭一次 `curl` 判定正常 |
| SSH 很稳定，业务端口偶发超时 | 对实际业务端口连续采样，并检查两端丢包与路由；SSH 使用不同端口，不能证明业务链路稳定 |

间歇故障可以在实际调用方重复测试，记录连接与总耗时：

```bash
TARGET_URL=http://203.0.113.10:18085/actuator/health
for N in $(seq 1 15); do
  date -u '+%FT%TZ'
  curl --noproxy '*' -sS --connect-timeout 3 --max-time 5 -o /dev/null \
    -w 'HTTP %{http_code} connect=%{time_connect}s total=%{time_total}s\n' "$TARGET_URL"
  sleep 1
done
```

如果来源白名单正确且时通时断，保留连续采样结果，交给主机或网络服务商定位路径问题。
不要用关闭防火墙或放开全部端口代替定位。

节点凭据只保留在各机器自己的受限环境文件中。重新安装时使用「节点管理」生成的完整命令，
不要把完整安装链接、令牌、环境文件或未脱敏日志贴进公开文档。

## 6. 三机排查实例：单次可达，连续心跳仍失败

一次控制面、播放、存储分机部署中，两个节点的来源白名单已完整配置，带节点凭据的只读请求也能成功。
但连续各测 15 次时，控制面访问存储节点成功 15 次，访问播放节点只成功 8 次；
播放节点访问控制面的注册中心成功 11 次。

进一步检查发现，播放机到默认网关 20 次 Ping 全部成功，到控制面 10 次中丢失 4 次。
节点日志也出现注册超时。这里的下一步是让网络服务商检查公网去回程，或验证替代线路；
增加重复放行规则无法解决这种间歇性故障。

这些短时采样只证明当时存在故障，不代表长期丢包率。调整线路后仍需重新连续测试和实际播放验收。

## 相关文档

- [v2 部署入口](README.md)
- [日常运维](OPERATIONS.md)
- [升级、备份与回滚](UPGRADE.md)

## 维护与验证

脚本不需要额外 Python 包。防火墙行为测试使用模拟命令，不修改运行机器的规则：

```bash
python3 -m unittest discover -s tests -p 'test_node_firewall.py' -v
```
