#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DEPLOY_DIR/scripts/common.sh"

usage() {
  cat <<'EOF'
用法：
  sudo ./install.sh single  --host <本机IP或域名>
  sudo ./install.sh control --host <主控机内网IP>
  sudo ./install.sh edge    --host <本机内网IP> --public-host <公网域名> --join <join.env>
  sudo ./install.sh user    --host <本机内网IP> --join <join.env>
  sudo ./install.sh media   --host <本机内网IP> --join <join.env>
EOF
}

role="single"
if [[ $# -gt 0 && "$1" != --* ]]; then
  role="$1"
  shift
fi
validate_role "$role" || { usage >&2; exit 2; }

server_host=""
public_host=""
join_file=""
node_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) server_host="${2:-}"; shift 2 ;;
    --public-host) public_host="${2:-}"; shift 2 ;;
    --join) join_file="${2:-}"; shift 2 ;;
    --node-id) node_id="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for tool in docker openssl curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "未安装 $tool" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "需要 Docker Compose v2" >&2; exit 1; }

if [[ -z "$server_host" || ! "$server_host" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "请通过 --host 填写不带协议和路径、且能被其他服务器访问的本机地址" >&2
  exit 1
fi
public_host="${public_host:-$server_host}"
if [[ ! "$public_host" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "--public-host 不得包含协议或路径" >&2
  exit 1
fi

cd "$DEPLOY_DIR"
if [[ -s .role && "$(deployment_role)" != "$role" ]]; then
  echo "本目录已安装为 $(deployment_role) 角色，不能直接改成 $role；请使用新的部署目录" >&2
  exit 1
fi
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 0600 .env
fi
printf '%s\n' "$role" > .role
chmod 0600 .role

generate_relay_certificate() {
  local cert="$DEPLOY_DIR/config/cluster-relay.crt" key="$DEPLOY_DIR/config/cluster-relay.key" san
  [[ -s "$cert" && -s "$key" ]] && return
  if [[ "$server_host" =~ ^[0-9a-fA-F:.]+$ ]]; then san="IP:$server_host"; else san="DNS:$server_host"; fi
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -keyout "$key" -out "$cert" -subj "/CN=$server_host" \
    -addext "subjectAltName=$san" >/dev/null 2>&1
  chown 10001 "$key"
  chmod 0600 "$key"
  chmod 0644 "$cert"
}

cluster_key_list=(
  YIYI_DB_HOST YIYI_REDIS_HOST YIYI_CONFIG_HOST YIYI_USER_HOST
  YIYI_DB_USER YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_SERVICE_TOKEN
  YIYI_LICENSE_CLUSTER_TOKEN YIYI_LICENSE_SYNC_URL YIYI_LICENSE_SYNC_INTERVAL
  YIYI_DB_PORT YIYI_REDIS_PORT
)

if [[ "$role" != "single" && "$role" != "control" ]]; then
  [[ -f "$join_file" ]] || { echo "$role 角色必须通过 --join 指定主控机生成的 join.env" >&2; exit 1; }
  copy_env_keys "$join_file" .env "${cluster_key_list[@]}"
  relay_cert="$(cd "$(dirname "$join_file")" && pwd)/cluster-relay.crt"
  [[ -s "$relay_cert" ]] || { echo "join.env 同目录缺少 cluster-relay.crt" >&2; exit 1; }
  cp "$relay_cert" "$DEPLOY_DIR/config/cluster-relay.crt"
  chmod 0644 "$DEPLOY_DIR/config/cluster-relay.crt"
fi

set_env_value .env YIYI_SERVER_HOST "$server_host"
set_env_value .env YIYI_PUBLIC_HOST "$public_host"
set_env_value .env YIYI_ADVERTISE_HOST "$server_host"

generate_secret_if_needed() {
  local key="$1"
  if [[ "$(env_value .env "$key")" == "GENERATE_ON_INSTALL" ]]; then
    set_env_value .env "$key" "$(openssl rand -hex 32)"
  fi
}

if [[ "$role" == "single" || "$role" == "control" ]]; then
  generate_secret_if_needed YIYI_DB_PASSWORD
  generate_secret_if_needed YIYI_REDIS_PASSWORD
  generate_secret_if_needed YIYI_SERVICE_TOKEN
  generate_secret_if_needed YIYI_LICENSE_CLUSTER_TOKEN
  generate_relay_certificate
fi

if [[ "$role" == "single" ]]; then
  set_env_value .env YIYI_DB_HOST 127.0.0.1
  set_env_value .env YIYI_REDIS_HOST 127.0.0.1
  set_env_value .env YIYI_CONFIG_HOST 127.0.0.1
  set_env_value .env YIYI_USER_HOST 127.0.0.1
  set_env_value .env YIYI_INFRA_BIND_HOST 127.0.0.1
  set_env_value .env YIYI_LICENSE_RELAY_LISTEN ""
elif [[ "$role" == "control" ]]; then
  set_env_value .env YIYI_DB_HOST "$server_host"
  set_env_value .env YIYI_REDIS_HOST "$server_host"
  set_env_value .env YIYI_CONFIG_HOST "$server_host"
  set_env_value .env YIYI_INFRA_BIND_HOST "$server_host"
  set_env_value .env YIYI_LICENSE_RELAY_LISTEN 0.0.0.0:18089
  set_env_value .env YIYI_LICENSE_SYNC_URL "https://$server_host:18089/v1/lease"
fi

if [[ "$role" == "storage" ]]; then
  [[ -n "$node_id" ]] || { echo "storage 角色必须通过 --node-id 指定在控制面创建的节点 ID" >&2; exit 1; }
  [[ "$node_id" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "Storage 节点 ID 格式无效" >&2; exit 1; }
  set_env_value .env YIYI_STORAGE_NODE_ID "$node_id"
elif [[ "$role" == "play" ]]; then
  [[ -n "$node_id" ]] || { echo "play 角色必须通过 --node-id 指定在控制面创建的节点 ID" >&2; exit 1; }
  [[ "$node_id" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "Play 节点 ID 格式无效" >&2; exit 1; }
  set_env_value .env YIYI_PLAY_AGENT_NODE_ID "$node_id"
fi

echo "[1/3] 检查 $role 角色配置"
"$DEPLOY_DIR/scripts/preflight.sh"
echo "[2/3] 拉取固定版本镜像"
compose pull
echo "[3/3] 启动 $role 角色服务"
compose up -d --wait --wait-timeout 300

case "$role" in
  single)
    echo "安装完成，请访问 http://$public_host:18080 并在网页输入一次性授权码。"
    ;;
  control)
    "$DEPLOY_DIR/yiyi.sh" export-join "$DEPLOY_DIR/join.env"
    echo "主控服务安装完成。请通过安全渠道把 $DEPLOY_DIR/join.env 传给其他服务器，再安装 edge/user/media 等角色。"
    ;;
  edge)
    echo "边缘入口安装完成，请访问 http://$public_host:18080；主控尚未激活时网页会显示授权码输入页面。"
    ;;
  *)
    echo "$role 角色安装完成。"
    ;;
esac
