#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

if [[ $# -gt 0 ]]; then
  echo "用法：配置 .env 后执行 ./install.sh" >&2
  exit 2
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 0600 .env
  echo "已生成 $DEPLOY_DIR/.env，请完成配置后再次运行 ./install.sh" >&2
  exit 1
fi

for tool in docker openssl curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "未安装 $tool" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "需要 Docker Compose v2" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon 不可用" >&2; exit 1; }

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
    single|control|user|media|edge) return 0 ;;
    *) echo "不支持的部署角色：$1" >&2; return 1 ;;
  esac
}

copy_env_keys() {
  local source_file="$1" target_file="$2" key value
  shift 2
  for key in "$@"; do
    value="$(env_value "$source_file" "$key")"
    [[ -n "$value" ]] || { echo "$source_file 缺少 $key" >&2; return 1; }
    set_env_value "$target_file" "$key" "$value"
  done
}

role="$(env_value .env YIYI_DEPLOY_ROLE)"
role="${role:-single}"
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
if [[ -f .installed || -s .role ]]; then
  installed=true
fi
if [[ -s .role ]]; then
  installed_role="$(tr -d '[:space:]' < .role)"
  [[ "$installed_role" == "$role" ]] || {
    echo "本目录已安装为 $installed_role，不能改为 $role" >&2
    exit 1
  }
fi

if [[ "$installed" == true && -d .git && "${YIYI_INSTALL_REEXEC:-0}" != "1" ]]; then
  old_head="$(git rev-parse HEAD)"
  git pull --ff-only
  new_head="$(git rev-parse HEAD)"
  if [[ "$old_head" != "$new_head" ]]; then
    export YIYI_INSTALL_REEXEC=1
    exec "$DEPLOY_DIR/install.sh"
  fi
fi

profile_args=(--profile "$role")
compose() {
  docker compose --env-file "$DEPLOY_DIR/.env" -f "$DEPLOY_DIR/compose.yaml" "${profile_args[@]}" "$@"
}

cluster_keys=(
  YIYI_DB_HOST YIYI_REDIS_HOST YIYI_CONFIG_HOST YIYI_USER_HOST
  YIYI_DB_USER YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_SERVICE_TOKEN
  YIYI_LICENSE_CLUSTER_TOKEN YIYI_LICENSE_SERVER_URL
  YIYI_LICENSE_SYNC_URL
)

if [[ "$role" != "single" && "$role" != "control" && "$installed" == false ]]; then
  [[ -s join.env ]] || { echo "$role 角色缺少 $DEPLOY_DIR/join.env" >&2; exit 1; }
  [[ -s cluster-relay.crt ]] || { echo "$role 角色缺少 $DEPLOY_DIR/cluster-relay.crt" >&2; exit 1; }
  copy_env_keys join.env .env "${cluster_keys[@]}"
  cp cluster-relay.crt config/cluster-relay.crt
  chmod 0644 config/cluster-relay.crt
fi

set_env_value .env YIYI_DEPLOY_ROLE "$role"
set_env_value .env YIYI_SERVER_HOST "$server_host"
set_env_value .env YIYI_PUBLIC_HOST "$public_host"
set_env_value .env YIYI_ADVERTISE_HOST "$server_host"

generate_secret_if_needed() {
  local key="$1" value
  value="$(env_value .env "$key")"
  if [[ -z "$value" || "$value" == "GENERATE_ON_INSTALL" ]]; then
    set_env_value .env "$key" "$(openssl rand -hex 32)"
  fi
}

generate_relay_certificate() {
  local cert="$DEPLOY_DIR/config/cluster-relay.crt"
  local key="$DEPLOY_DIR/config/cluster-relay.key"
  local san
  [[ -s "$cert" && -s "$key" ]] && return
  if [[ "$server_host" =~ ^[0-9a-fA-F:.]+$ ]]; then san="IP:$server_host"; else san="DNS:$server_host"; fi
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -keyout "$key" -out "$cert" -subj "/CN=$server_host" \
    -addext "subjectAltName=$san" >/dev/null 2>&1
  chown 10001 "$key"
  chmod 0600 "$key"
  chmod 0644 "$cert"
}

if [[ "$role" == "single" || "$role" == "control" ]]; then
  db_user="$(env_value .env YIYI_DB_USER)"
  set_env_value .env YIYI_DB_USER "${db_user:-yiyi}"
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
  user_host="$(env_value .env YIYI_USER_HOST)"
  [[ "$user_host" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "Control 角色必须填写 YIYI_USER_HOST" >&2; exit 1; }
  set_env_value .env YIYI_DB_HOST "$server_host"
  set_env_value .env YIYI_REDIS_HOST "$server_host"
  set_env_value .env YIYI_CONFIG_HOST "$server_host"
  set_env_value .env YIYI_INFRA_BIND_HOST "$server_host"
  set_env_value .env YIYI_LICENSE_RELAY_LISTEN 0.0.0.0:18089
  set_env_value .env YIYI_LICENSE_SYNC_URL "https://$server_host:18089/v1/lease"
fi

sync_license_public_key() {
  local server_url target temp kid
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
  chmod 0644 "$temp"
  mv "$temp" "$target"
  kid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kid"])' "$target")"
  echo "授权公钥已同步：$kid"
}

preflight() {
  if grep -Eq 'GENERATE_ON_INSTALL|example\.invalid' .env; then
    echo "配置仍包含占位值" >&2
    return 1
  fi
  local key value cluster_token
  for key in YIYI_SERVER_HOST YIYI_ADVERTISE_HOST YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_SERVICE_TOKEN YIYI_LICENSE_CLUSTER_TOKEN; do
    value="$(env_value .env "$key")"
    [[ -n "$value" && "$value" != REPLACE_* ]] || { echo "缺少 $key" >&2; return 1; }
  done
  cluster_token="$(env_value .env YIYI_LICENSE_CLUSTER_TOKEN)"
  [[ ${#cluster_token} -ge 32 ]] || { echo "YIYI_LICENSE_CLUSTER_TOKEN 长度不足" >&2; return 1; }
  [[ -s config/license-public.runtime.jwk ]] || { echo "授权公钥缺失" >&2; return 1; }
  [[ -s config/cluster-relay.crt ]] || { echo "集群同步证书缺失" >&2; return 1; }
  if [[ "$role" == "single" || "$role" == "control" ]]; then
    [[ -s config/cluster-relay.key ]] || { echo "集群同步私钥缺失" >&2; return 1; }
  fi
  compose config -q
}

create_backup() {
  local timestamp target
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$DEPLOY_DIR/backups/$timestamp"
  mkdir -p "$target"
  umask 077
  compose exec -T postgres sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' > "$target/postgres.sql"
  compose cp config:/data/uploads/. "$target/config-uploads" >/dev/null 2>&1 || true
  compose cp license-agent:/var/lib/yiyi-license/. "$target/license-identity" >/dev/null
  cp .env "$target/runtime.env"
  cp .role "$target/role"
  cp config/license-public.runtime.jwk "$target/license-public.jwk"
  cp config/cluster-relay.crt "$target/cluster-relay.crt"
  cp config/cluster-relay.key "$target/cluster-relay.key"
  chmod -R go-rwx "$target"
  echo "升级前备份已生成：$target"
}

export_join() {
  umask 077
  {
    echo "# YiYi 集群加入配置；导入后应删除。"
    local key
    for key in "${cluster_keys[@]}"; do
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

healthcheck() {
  case "$role" in
    single)
      check_endpoint license-agent http://127.0.0.1:18088/v1/status
      check_endpoint config http://127.0.0.1:18085/api/license/status
      check_endpoint user http://127.0.0.1:18082/api/license/status
      check_endpoint media http://127.0.0.1:18083/api/license/status
      check_endpoint gateway http://127.0.0.1:18086/api/license/status
      check_endpoint frontend http://127.0.0.1:18080/
      ;;
    control)
      check_endpoint license-agent http://127.0.0.1:18088/v1/status
      check_endpoint config http://127.0.0.1:18085/api/license/status
      ;;
    user)
      check_endpoint license-sync http://127.0.0.1:18088/v1/status
      check_endpoint user http://127.0.0.1:18082/api/license/status
      ;;
    media)
      check_endpoint license-sync http://127.0.0.1:18088/v1/status
      check_endpoint media http://127.0.0.1:18083/api/license/status
      ;;
    edge)
      check_endpoint license-sync http://127.0.0.1:18088/v1/status
      check_endpoint gateway http://127.0.0.1:18086/api/license/status
      check_endpoint frontend http://127.0.0.1:18080/
      ;;
  esac
}

if [[ "$installed" == true ]]; then
  echo "正在升级 $role"
fi
sync_license_public_key
preflight

if [[ "$installed" == true && ( "$role" == "single" || "$role" == "control" ) ]]; then
  create_backup
fi

compose pull
compose up -d --remove-orphans --wait --wait-timeout 300
healthcheck

printf '%s\n' "$role" > .role
chmod 0600 .role
touch .installed
chmod 0600 .installed

if [[ "$role" == "control" ]]; then
  export_join
  echo "已生成 join.env 和 cluster-relay.crt，请通过安全方式复制到其他节点。"
elif [[ "$role" == "single" || "$role" == "edge" ]]; then
  echo "完成，请访问 http://$public_host:18080；首次使用直接在网页激活。"
else
  echo "$role 完成。"
fi
