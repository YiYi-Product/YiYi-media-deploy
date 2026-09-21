#!/usr/bin/env bash
#
# YiYi Media 分布式部署（DISTRIBUTED）—— **多机形态** 安装 / 升级脚本。
#
# 适用模式：控制面按 control / user / media / edge 角色**拆分到多台机器**，
# 存储与播放能力由外部工作节点提供（工作节点不由本脚本安装，在网页
# 「节点管理」新增后用页面给出的一键命令部署）。
#
# 三种部署形态（各占一个 Git 分支）：
#   * main（v1-standalone）：yiyi-app + postgres + redis 三容器，节点内置；
#   * v2-all-in-one：控制面 8 个服务全在同一台机器，工作节点在外部；
#   * v3-multi-host（本分支）：控制面按角色分散到多台机器。
#
# control、user、media、edge 是分布式部署**内部**的角色，不是独立部署模式
# （计划 §3.1）。脚本不接受 single 角色：那是上一代的旧口径；
# 控制面全在一台机器请用 v2-all-in-one 分支。
#
# 许可证要求：edition=DISTRIBUTED。
#
# 用法：配置好 .env 后执行 `sudo ./install.sh`。脚本不接受位置参数。
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

COMPOSE_FILE="$DEPLOY_DIR/compose.yaml"

if [[ $# -gt 0 ]]; then
  echo "用法：配置 .env 后执行 ./install.sh" >&2
  echo "控制面全在一台机器请用 v2-all-in-one 分支；单机版请用 main 分支" >&2
  exit 2
fi

if [[ ! -f .env ]]; then
    cp .env.example .env
  chmod 0600 .env
  echo "已从 .env.example 生成 $DEPLOY_DIR/.env。" >&2
  echo "请填写 YIYI_DEPLOY_ROLE、YIYI_SERVER_HOST 等必填项后再次运行 ./install.sh" >&2
  exit 1
fi

for tool in docker openssl curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "未安装 $tool" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "需要 Docker Compose v2" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon 不可用" >&2; exit 1; }
install -d -m 0700 "$DEPLOY_DIR/config"

env_value() {
  local file="$1" key="$2"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

set_env_value() {
  local file="$1" key="$2" value="$3" temp
  temp="$(mktemp "${file}.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    index($0, key "=") == 1 {print key "=" value; found=1; next}
    {print}
    END {if (!found) print key "=" value}
  ' "$file" > "$temp"
  chmod 0600 "$temp"
  mv "$temp" "$file"
}

validate_role() {
  case "$1" in
    control|user|media|edge) return 0 ;;
    single)
      echo "single 不是分布式部署角色，也不是独立部署模式。" >&2
      echo "单机版请改用三容器聚合部署：cp .env.example .env && sudo ./install.sh" >&2
      return 1
      ;;
    *) echo "不支持的部署角色：$1" >&2; return 1 ;;
  esac
}

copy_env_keys() {
  local source_file="$1" target_file="$2" key value
  shift 2
  for key in "$@"; do
    grep -q "^${key}=" "$source_file" || { echo "$source_file 缺少 $key" >&2; return 1; }
    value="$(env_value "$source_file" "$key")"
    if [[ "$key" != "YIYI_REDIS_PASSWORD" && -z "$value" ]]; then
      echo "$source_file 缺少 $key" >&2
      return 1
    fi
    set_env_value "$target_file" "$key" "$value"
  done
}

role="$(env_value .env YIYI_DEPLOY_ROLE)"
if [[ -z "$role" ]]; then
  echo "请在 .env 中设置 YIYI_DEPLOY_ROLE（control / user / media / edge）" >&2
  exit 1
fi
validate_role "$role"
server_host="$(env_value .env YIYI_SERVER_HOST)"
public_host="$(env_value .env YIYI_PUBLIC_HOST)"
if [[ -z "$server_host" || "$server_host" == REPLACE_* || ! "$server_host" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "请在 .env 中填写不带协议和路径的 YIYI_SERVER_HOST" >&2
  exit 1
fi
if [[ -z "$public_host" || "$public_host" == REPLACE_* ]]; then
  public_host="$server_host"
fi
[[ "$public_host" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "YIYI_PUBLIC_HOST 格式无效" >&2; exit 1; }

installed=false
if [[ -f .installed || -s .deployment-mode ]]; then
  installed=true
fi
if [[ -s .deployment-mode ]]; then
  installed_mode="$(tr -d '[:space:]' < .deployment-mode)"
  if [[ "$installed_mode" != "DISTRIBUTED" ]]; then
    cat >&2 <<EOF
本目录已安装为 ${installed_mode}，不能原地改成分布式版。

单机版与分布式版互转必须同时完成许可证 Edition 变更、部署拓扑迁移和数据校验
（计划 §3.1）。只改 .env 或 Compose 文件不会生效。
EOF
    exit 1
  fi
fi
if [[ -s .role ]]; then
  installed_role="$(tr -d '[:space:]' < .role)"
  [[ "$installed_role" == "$role" ]] || {
    echo "本目录已安装为 ${installed_role}，不能改为 $role" >&2
    exit 1
  }
fi

# 这里**不再**自动 `git pull`。
#
# 旧版本在已安装环境会先拉取远端最新代码、再以 root 重新执行安装脚本。
# 那等于"执行一次 ./install.sh 就同意运行远端当前任意代码"：
# 一旦远端仓库或推送凭据被攻破，攻击者无需接触本机即可取得 root 执行权。
#
# 文档化的升级流程本来就要求先手动 `git pull --ff-only` 再执行本脚本
# （见 README「升级」与 OPERATIONS），因此自动拉取只是多余的高风险行为。
# 现改为显式提示，由操作者自行决定何时更新代码。
if [[ "$installed" == true && -d .git ]]; then
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "提示：部署目录存在未提交的本地改动，升级前请自行确认。" >&2
  fi
  echo "提示：如需升级部署文件，请先手动执行 git pull --ff-only 再运行本脚本。" >&2
fi

cluster_keys=(
  YIYI_DB_HOST YIYI_REDIS_HOST YIYI_CONFIG_HOST YIYI_USER_HOST
  YIYI_DB_USER YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_SERVICE_TOKEN YIYI_NODE_TOKEN
  YIYI_LICENSE_CLUSTER_TOKEN YIYI_LICENSE_SERVER_URL
  YIYI_LICENSE_SYNC_URL
)
cluster_optional_keys=(YIYI_DB_MODE YIYI_DB_PORT YIYI_REDIS_MODE YIYI_REDIS_PORT)

if [[ "$role" != "control" ]]; then
  if [[ "$installed" == false ]]; then
    [[ -s join.env ]] || { echo "$role 角色缺少 $DEPLOY_DIR/join.env" >&2; exit 1; }
  fi
  if [[ -s join.env ]]; then
    [[ -s cluster-relay.crt ]] || { echo "$role 角色缺少 $DEPLOY_DIR/cluster-relay.crt" >&2; exit 1; }
    copy_env_keys join.env .env "${cluster_keys[@]}"
    for key in "${cluster_optional_keys[@]}"; do
      if grep -q "^${key}=" join.env; then
        set_env_value .env "$key" "$(env_value join.env "$key")"
      fi
    done
    cp cluster-relay.crt config/cluster-relay.crt
    chmod 0644 config/cluster-relay.crt
  fi
  node_token="$(env_value .env YIYI_NODE_TOKEN)"
  if [[ -z "$node_token" || "$node_token" == "GENERATE_ON_INSTALL" ]]; then
    echo "$role 角色缺少 YIYI_NODE_TOKEN；请从 control 重新复制 join.env 后再升级" >&2
    exit 1
  fi
fi

set_env_value .env YIYI_DEPLOY_ROLE "$role"
set_env_value .env YIYI_DEPLOYMENT_MODE "DISTRIBUTED"
set_env_value .env YIYI_SERVER_HOST "$server_host"
set_env_value .env YIYI_PUBLIC_HOST "$public_host"
set_env_value .env YIYI_ADVERTISE_HOST "$server_host"

db_mode="$(env_value .env YIYI_DB_MODE)"
db_mode="${db_mode:-bundled}"
case "$db_mode" in
  bundled|external) ;;
  *) echo "YIYI_DB_MODE 只支持 bundled 或 external" >&2; exit 1 ;;
esac
db_port="$(env_value .env YIYI_DB_PORT)"
db_port="${db_port:-5432}"
[[ "$db_port" =~ ^[0-9]+$ ]] && ((db_port >= 1 && db_port <= 65535)) || {
  echo "YIYI_DB_PORT 必须是 1-65535 之间的端口" >&2
  exit 1
}
set_env_value .env YIYI_DB_MODE "$db_mode"
set_env_value .env YIYI_DB_PORT "$db_port"

if [[ "$role" == "control" && "$db_mode" == "external" ]]; then
  db_host="$(env_value .env YIYI_DB_HOST)"
  [[ "$db_host" =~ ^[0-9A-Za-z._-]+$ ]] || {
    echo "external 模式必须填写不带协议和端口的 YIYI_DB_HOST" >&2
    exit 1
  }
  db_user="$(env_value .env YIYI_DB_USER)"
  [[ -n "$db_user" ]] || {
    echo "external 模式必须填写外部 PostgreSQL 的 YIYI_DB_USER" >&2
    exit 1
  }
  db_password="$(env_value .env YIYI_DB_PASSWORD)"
  [[ -n "$db_password" && "$db_password" != "GENERATE_ON_INSTALL" ]] || {
    echo "external 模式必须填写外部 PostgreSQL 的 YIYI_DB_PASSWORD" >&2
    exit 1
  }
fi

# Redis 与数据库**独立**选择：允许「外部数据库 + 自带 Redis」等任意组合。
redis_mode="$(env_value .env YIYI_REDIS_MODE)"
redis_mode="${redis_mode:-bundled}"
case "$redis_mode" in
  bundled|external) ;;
  *) echo "YIYI_REDIS_MODE 只支持 bundled 或 external" >&2; exit 1 ;;
esac
redis_port="$(env_value .env YIYI_REDIS_PORT)"
redis_port="${redis_port:-6379}"
[[ "$redis_port" =~ ^[0-9]+$ ]] && ((redis_port >= 1 && redis_port <= 65535)) || {
  echo "YIYI_REDIS_PORT 必须是 1-65535 之间的端口" >&2
  exit 1
}
set_env_value .env YIYI_REDIS_MODE "$redis_mode"
set_env_value .env YIYI_REDIS_PORT "$redis_port"
if [[ "$role" == "control" && "$redis_mode" == "external" ]]; then
  redis_host="$(env_value .env YIYI_REDIS_HOST)"
  [[ "$redis_host" =~ ^[0-9A-Za-z._-]+$ ]] || {
    echo "YIYI_REDIS_MODE=external 时必须填写不带协议和端口的 YIYI_REDIS_HOST" >&2
    exit 1
  }
fi

profile_args=(--profile "$role")
postgres_replicas=1
if [[ "$role" == "control" && "$db_mode" == "external" ]]; then
  postgres_replicas=0
fi
# Redis 独立判定（与 postgres 互不影响）
redis_replicas=1
if [[ "$role" == "control" && "$redis_mode" == "external" ]]; then
  redis_replicas=0
fi
set_env_value .env COMPOSE_PROFILES "$role"
# 仓库里同时存在单机版的 compose.yaml，而 `docker compose` 会按固定文件名自动发现
# 它。必须显式指定分布式 Compose 文件，否则在部署目录里直接执行 `docker compose ps`
# 会错误地解析到单机版三容器文件。
set_env_value .env COMPOSE_FILE "compose.yaml"
set_env_value .env YIYI_POSTGRES_REPLICAS "$postgres_replicas"
set_env_value .env YIYI_REDIS_REPLICAS "$redis_replicas"

compose() {
  docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE" "${profile_args[@]}" "$@"
}

data_mount_specs=()
postgres_data_existing=false

register_data_mount() {
  local service="$1" destination="$2" relative="$3" mode="$4" owner="${5:-}" target
  target="$data_dir/$relative"
  mkdir -p "$target"
  chmod "$mode" "$target"
  if [[ -n "$owner" ]]; then
    if [[ "$installed" == false ]]; then
      chown -R "$owner" "$target"
    else
      chown "$owner" "$target"
    fi
  fi
  data_mount_specs+=("$service|$destination|$target")
}

configure_data_dir() {
  local configured
  configured="$(env_value .env YIYI_DATA_DIR)"
  if [[ -z "$configured" ]]; then
    configured="$DEPLOY_DIR/data"
  elif [[ "$configured" != /* ]]; then
    configured="$DEPLOY_DIR/$configured"
  fi
  configured="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$configured")"
  data_dir="$configured"
  postgres_data_dir="$data_dir/postgres"
  set_env_value .env YIYI_DATA_DIR "$data_dir"

  mkdir -p "$data_dir"
  case "$role" in
    control)
      if [[ "$db_mode" == "bundled" ]]; then
        register_data_mount postgres /var/lib/postgresql/data postgres 0700
      fi
      # Redis 数据目录只在本机自带 redis 时才需要；用外部 Redis 时不创建。
      if [[ "$redis_mode" == "bundled" ]]; then
        register_data_mount redis /data redis 0750
      fi
      register_data_mount license-agent /var/lib/yiyi-license license/identity 0700 10001
      register_data_mount license-agent /var/run/yiyi-license license/lease 0700 10001
      register_data_mount config /data/uploads config/uploads 0750 10001
      register_data_mount config /data/logs logs/config 0750 10001
      ;;
    user)
      register_data_mount license-sync /var/lib/yiyi-license-sync license/sync-state 0700 10001
      register_data_mount license-sync /var/run/yiyi-license license/lease 0700 10001
      register_data_mount user /data/logs logs/user 0750
      ;;
    media)
      register_data_mount license-sync /var/lib/yiyi-license-sync license/sync-state 0700 10001
      register_data_mount license-sync /var/run/yiyi-license license/lease 0700 10001
      register_data_mount media /data/logs logs/media 0750
      ;;
    edge)
      register_data_mount license-sync /var/lib/yiyi-license-sync license/sync-state 0700 10001
      register_data_mount license-sync /var/run/yiyi-license license/lease 0700 10001
      register_data_mount gateway /data/logs logs/gateway 0750
      ;;
  esac
}

validate_postgres_data_dir() {
  local version
  if [[ -f "$postgres_data_dir/PG_VERSION" ]]; then
    version="$(tr -d '[:space:]' < "$postgres_data_dir/PG_VERSION")"
    [[ "$version" == "16" ]] || {
      echo "PostgreSQL 数据目录版本为 ${version}，当前镜像只支持版本 16：$postgres_data_dir" >&2
      return 1
    }
    postgres_data_existing=true
  elif [[ -n "$(find "$postgres_data_dir" -mindepth 1 -print -quit)" ]]; then
    echo "PostgreSQL 数据目录非空但缺少 PG_VERSION：$postgres_data_dir" >&2
    return 1
  fi
}

configure_data_dir

generate_secret_if_needed() {
  local key="$1" value
  value="$(env_value .env "$key")"
  if [[ -z "$value" || "$value" == "GENERATE_ON_INSTALL" ]]; then
    set_env_value .env "$key" "$(openssl rand -hex 32)"
  fi
}

generate_optional_secret_if_requested() {
  local key="$1" value
  value="$(env_value .env "$key")"
  if [[ "$value" == "GENERATE_ON_INSTALL" ]]; then
    set_env_value .env "$key" "$(openssl rand -hex 32)"
  fi
}

generate_relay_certificate() {
  local cert="$DEPLOY_DIR/config/cluster-relay.crt"
  local key="$DEPLOY_DIR/config/cluster-relay.key"
  local cert_temp key_temp san
  [[ -s "$cert" && -s "$key" ]] && return
  if [[ "$server_host" =~ ^[0-9a-fA-F:.]+$ ]]; then san="IP:$server_host"; else san="DNS:$server_host"; fi
  cert_temp="$(mktemp "$DEPLOY_DIR/config/cluster-relay.crt.XXXXXX")"
  key_temp="$(mktemp "$DEPLOY_DIR/config/cluster-relay.key.XXXXXX")"
  if ! openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
      -keyout "$key_temp" -out "$cert_temp" -subj "/CN=$server_host" \
      -addext "subjectAltName=$san" >/dev/null 2>&1; then
    rm -f "$cert_temp" "$key_temp"
    echo "生成集群同步证书失败，请检查 OpenSSL 和服务器地址：$server_host" >&2
    return 1
  fi
  mv "$cert_temp" "$cert"
  mv "$key_temp" "$key"
  chown 10001 "$key"
  chmod 0600 "$key"
  chmod 0644 "$cert"
}

if [[ "$role" == "control" ]]; then
  if [[ "$db_mode" == "bundled" ]]; then
    validate_postgres_data_dir
    db_user="$(env_value .env YIYI_DB_USER)"
    set_env_value .env YIYI_DB_USER "${db_user:-yiyi}"
    if [[ "$postgres_data_existing" == true ]]; then
      db_password="$(env_value .env YIYI_DB_PASSWORD)"
      if [[ -z "$db_password" || "$db_password" == "GENERATE_ON_INSTALL" ]]; then
        echo "检测到已有 PostgreSQL 数据，请在 .env 中填写该数据库原有的 YIYI_DB_PASSWORD" >&2
        exit 1
      fi
      service_token="$(env_value .env YIYI_SERVICE_TOKEN)"
      if [[ -z "$service_token" || "$service_token" == "GENERATE_ON_INSTALL" ]]; then
        echo "检测到已有 PostgreSQL 数据，请在 .env 中填写原部署的 YIYI_SERVICE_TOKEN" >&2
        echo "该 token 不保存在 data 目录；静默生成新值会导致控制面服务间鉴权失效" >&2
        exit 1
      fi
    fi
    generate_secret_if_needed YIYI_DB_PASSWORD
  fi
  generate_optional_secret_if_requested YIYI_REDIS_PASSWORD
  generate_secret_if_needed YIYI_SERVICE_TOKEN
  generate_secret_if_needed YIYI_NODE_TOKEN
  generate_secret_if_needed YIYI_LICENSE_CLUSTER_TOKEN
  generate_relay_certificate
fi

if [[ "$role" == "control" ]]; then
  user_host="$(env_value .env YIYI_USER_HOST)"
  [[ "$user_host" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "Control 角色必须填写 YIYI_USER_HOST" >&2; exit 1; }
  if [[ "$db_mode" == "bundled" ]]; then
    set_env_value .env YIYI_DB_HOST "$server_host"
  fi
  # Redis 独立：bundled 指本机容器，external 保留用户填写的外部地址。
  if [[ "$redis_mode" == "bundled" ]]; then
    set_env_value .env YIYI_REDIS_HOST "$server_host"
  fi
  set_env_value .env YIYI_CONFIG_HOST "$server_host"
  set_env_value .env YIYI_INFRA_BIND_HOST "$server_host"
  set_env_value .env YIYI_LICENSE_RELAY_LISTEN 0.0.0.0:18089
  set_env_value .env YIYI_LICENSE_SYNC_URL "https://$server_host:18089/v1/lease"
fi

# 厂商许可证签名公钥（信任根）。
#
# 该公钥同时被**硬编码在服务镜像内**（原生验证器与 Java 降级路径），
# 客户端只信任白名单内的公钥。因此本脚本从授权服务器取到的公钥必须与它一致，
# 否则部署起来后所有业务请求都会被许可证过滤器拒绝（全站 403）。
#
# 这里做的是**一致性校验**，不是信任决策：即使 YIYI_LICENSE_SERVER_URL 被指向
# 攻击者服务器、返回了攻击者自签公钥，本检查也会在安装阶段直接失败，
# 而不是产出一个"看似安装成功、实则许可证不可用"的部署。
#
# 轮换签名密钥时：先发布带新公钥白名单的新版本镜像，再更新此处并重新安装。
YIYI_TRUSTED_LICENSE_PUBLIC_KEY="wKWitITf11oh1kRC-6Z05P37xbr1MBbCCUB6CPcAYJs"

sync_license_public_key() {
  local server_url target temp kid fetched
  server_url="$(env_value .env YIYI_LICENSE_SERVER_URL)"
  server_url="${server_url%/}"
  [[ "$server_url" =~ ^https://[0-9A-Za-z._-]+(:[0-9]{1,5})?$ ]] || {
    echo "YIYI_LICENSE_SERVER_URL 必须是不带路径的 HTTPS 地址" >&2
    return 1
  }
  target="$DEPLOY_DIR/config/license-public.runtime.jwk"
  temp="$(mktemp "$DEPLOY_DIR/config/license-public.runtime.jwk.XXXXXX")"
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --fail --silent --show-error "$server_url/api/v1/public-keys" | \
    python3 -c '
import json, sys
document = json.load(sys.stdin)
keys = document.get("keys")
if not isinstance(keys, list) or not keys:
    raise SystemExit("授权服务器未返回公钥")
key = keys[0]
if key.get("kty") != "OKP" or key.get("crv") != "Ed25519" or not key.get("kid") or not key.get("x"):
    raise SystemExit("授权服务器返回的不是有效 Ed25519 公钥")
if any(name in key for name in ("d", "p", "q", "dp", "dq")):
    raise SystemExit("授权公钥意外包含私钥字段")
json.dump(key, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
' > "$temp"; then
    rm -f "$temp"
    return 1
  fi
  fetched="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["x"])' "$temp")"
  if [[ "$fetched" != "$YIYI_TRUSTED_LICENSE_PUBLIC_KEY" ]]; then
    rm -f "$temp"
    cat >&2 <<EOF
授权服务器返回的公钥不受当前版本信任，已中止安装。

  授权服务器：$server_url
  返回公钥  ：$fetched
  期望公钥  ：$YIYI_TRUSTED_LICENSE_PUBLIC_KEY

服务镜像只信任内置的厂商公钥。若不中止，部署完成后所有业务请求都会被
许可证过滤器以 403 拒绝（表现为"安装成功但全站不可用"）。

请确认 YIYI_LICENSE_SERVER_URL 指向正确的授权服务器；
若厂商确实轮换了签名密钥，需要先升级到包含新公钥白名单的镜像版本。
EOF
    return 1
  fi
  chmod 0644 "$temp"
  mv "$temp" "$target"
  kid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kid"])' "$target")"
  echo "授权公钥已同步并校验：$kid"
}

preflight() {
  if grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.*(GENERATE_ON_INSTALL|example\.invalid)' .env; then
    echo "配置仍包含占位值" >&2
    return 1
  fi
  local key value cluster_token
  for key in YIYI_SERVER_HOST YIYI_ADVERTISE_HOST YIYI_DB_HOST YIYI_DB_PORT YIYI_DB_USER YIYI_DB_PASSWORD YIYI_SERVICE_TOKEN YIYI_NODE_TOKEN YIYI_LICENSE_CLUSTER_TOKEN; do
    value="$(env_value .env "$key")"
    [[ -n "$value" && "$value" != REPLACE_* ]] || { echo "缺少 $key" >&2; return 1; }
  done
  cluster_token="$(env_value .env YIYI_LICENSE_CLUSTER_TOKEN)"
  [[ ${#cluster_token} -ge 32 ]] || { echo "YIYI_LICENSE_CLUSTER_TOKEN 长度不足" >&2; return 1; }
  [[ -s config/license-public.runtime.jwk ]] || { echo "授权公钥缺失" >&2; return 1; }
  [[ -s config/cluster-relay.crt ]] || { echo "集群同步证书缺失" >&2; return 1; }
  if [[ "$role" == "control" ]]; then
    [[ -s config/cluster-relay.key ]] || { echo "集群同步私钥缺失" >&2; return 1; }
  fi
  compose config -q

  # 分布式 Compose 不允许把三容器聚合服务混进来。
  local actual_services
  actual_services="$(compose config --services | tr '\n' ' ')"
  if printf '%s' "$actual_services" | grep -qw "yiyi-app"; then
    echo "分布式 Compose 不应包含 yiyi-app（单机版聚合服务）" >&2
    return 1
  fi
}

migrate_legacy_named_volumes() {
  local spec service destination target container_id mount_info mount_type mount_name
  local migration_dir version index
  local -a container_ids=() destinations=() targets=() volume_names=() migration_dirs=()
  [[ "$installed" == true ]] || return 0

  for spec in "${data_mount_specs[@]}"; do
    IFS='|' read -r service destination target <<< "$spec"
    container_id="$(compose ps -a -q "$service")"
    [[ -n "$container_id" ]] || continue
    mount_info="$(docker inspect --format '{{json .Mounts}}' "$container_id" | python3 -c '
import json, sys
destination = sys.argv[1]
for mount in json.load(sys.stdin):
    if mount.get("Destination") == destination:
        print(f"{mount.get('"'"'Type'"'"', '')}|{mount.get('"'"'Name'"'"', '')}")
        break
' "$destination")"
    IFS='|' read -r mount_type mount_name <<< "$mount_info"
    [[ "$mount_type" == "volume" ]] || continue
    if [[ -n "$(find "$target" -mindepth 1 -print -quit)" ]]; then
      if [[ -f .named-volumes-migrated ]] && grep -Fxq "$mount_name" .named-volumes-migrated; then
        continue
      fi
      echo "目标数据目录已有内容，不能自动覆盖旧命名卷 ${mount_name}：$target" >&2
      return 1
    fi
    container_ids+=("$container_id")
    destinations+=("$destination")
    targets+=("$target")
    volume_names+=("$mount_name")
  done

  [[ ${#container_ids[@]} -gt 0 ]] || return 0
  echo "检测到 ${#container_ids[@]} 个旧数据卷，正在迁移到 $data_dir"
  compose stop

  for ((index=0; index<${#container_ids[@]}; index++)); do
    migration_dir="$(mktemp -d "${targets[$index]}.migrate.XXXXXX")"
    chmod 0700 "$migration_dir"
    migration_dirs+=("$migration_dir")
    if ! docker cp -a "${container_ids[$index]}:${destinations[$index]}/." "$migration_dir"; then
      echo "复制旧命名卷 ${volume_names[$index]} 失败；临时目录保留在 $migration_dir" >&2
      compose start || true
      return 1
    fi
    if [[ "${destinations[$index]}" == "/var/lib/postgresql/data" ]]; then
      [[ -f "$migration_dir/PG_VERSION" ]] || {
        echo "旧 PostgreSQL 数据缺少 PG_VERSION，正在恢复原服务" >&2
        compose start || true
        return 1
      }
      version="$(tr -d '[:space:]' < "$migration_dir/PG_VERSION")"
      [[ "$version" == "16" ]] || {
        echo "旧 PostgreSQL 数据版本为 ${version}，当前镜像只支持版本 16，正在恢复原服务" >&2
        compose start || true
        return 1
      }
    fi
  done

  for ((index=0; index<${#targets[@]}; index++)); do
    rmdir "${targets[$index]}"
    mv "${migration_dirs[$index]}" "${targets[$index]}"
  done
  printf '%s\n' "${volume_names[@]}" > .named-volumes-migrated
  chmod 0600 .named-volumes-migrated
  echo "旧数据卷迁移完成；原命名卷均已保留，可用于回退。"
}

export_join() {
  umask 077
  {
    echo "# YiYi Media 集群加入配置；导入后应删除。"
    local key
    for key in "${cluster_keys[@]}" "${cluster_optional_keys[@]}"; do
      printf '%s=%s\n' "$key" "$(env_value .env "$key")"
    done
  } > join.env
  chmod 0600 join.env
  cp config/cluster-relay.crt cluster-relay.crt
  chmod 0644 cluster-relay.crt
}

check_endpoint() {
  local name="$1" url="$2"
  curl -fsS --max-time 5 "$url" >/dev/null || { echo "$name 健康检查失败：$url" >&2; return 1; }
}

# 许可证状态检查。
#
# /api/license/status 在许可证无效时**仍返回 HTTP 200**（状态在响应体的 state 字段），
# 所以只判断 HTTP 码会把"许可证不可用"误判为安装成功——用户看到的是
# "安装完成"，实际所有业务请求都被许可证过滤器 403。
# 这里解析 state：ACTIVE（正常）与 GRACE（断网宽限期）视为可用。
check_license_endpoint() {
  local name="$1" url="$2" body state
  body="$(curl -fsS --max-time 5 "$url" 2>/dev/null)" || {
    echo "$name 许可证接口不可达：$url" >&2
    return 1
  }
  state="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("state", ""))
except Exception:
    print("")' 2>/dev/null)"
  case "$state" in
    ACTIVE|GRACE) return 0 ;;
    *)
      echo "$name 许可证不可用（state=${state:-无法解析}）：$url" >&2
      printf '  %s\n' "$body" >&2
      return 1
      ;;
  esac
}

healthcheck() {
  case "$role" in
    control)
      check_endpoint license-agent http://127.0.0.1:18088/v1/status
      check_license_endpoint config http://127.0.0.1:18085/api/license/status
      ;;
    user)
      check_endpoint license-sync http://127.0.0.1:18088/v1/status
      check_license_endpoint user http://127.0.0.1:18082/api/license/status
      ;;
    media)
      check_endpoint license-sync http://127.0.0.1:18088/v1/status
      check_license_endpoint media http://127.0.0.1:18083/api/license/status
      ;;
    edge)
      check_endpoint license-sync http://127.0.0.1:18088/v1/status
      check_license_endpoint gateway http://127.0.0.1:18086/api/license/status
      check_endpoint frontend http://127.0.0.1:18080/
      ;;
  esac
}

if [[ "$installed" == true ]]; then
  echo "正在升级分布式部署角色 $role"
fi
sync_license_public_key
preflight

compose pull

if [[ "$installed" == true ]]; then
  migrate_legacy_named_volumes
fi

compose up -d --remove-orphans --wait --wait-timeout 300
healthcheck

printf '%s\n' "$role" > .role
chmod 0600 .role
printf '%s\n' "DISTRIBUTED" > .deployment-mode
chmod 0600 .deployment-mode
touch .installed
chmod 0600 .installed

if [[ "$role" == "control" ]]; then
  export_join
  echo "已生成 join.env 和 cluster-relay.crt，请通过安全方式复制到其他节点。"
elif [[ "$role" == "edge" ]]; then
  echo "完成，请访问 http://$public_host:18080；首次使用直接在网页激活。"
else
  echo "$role 完成。"
fi
