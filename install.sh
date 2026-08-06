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
set_env_value .env COMPOSE_PROFILES "$role"
set_env_value .env YIYI_SERVER_HOST "$server_host"
set_env_value .env YIYI_PUBLIC_HOST "$public_host"
set_env_value .env YIYI_ADVERTISE_HOST "$server_host"

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
    single)
      register_data_mount postgres /var/lib/postgresql/data postgres 0700
      register_data_mount redis /data redis 0750
      register_data_mount license-agent /var/lib/yiyi-license license/identity 0700 10001
      register_data_mount license-agent /var/run/yiyi-license license/lease 0700 10001
      register_data_mount config /data/uploads config/uploads 0750 10001
      register_data_mount config /data/logs logs/config 0750 10001
      register_data_mount user /data/logs logs/user 0750
      register_data_mount media /data/logs logs/media 0750
      register_data_mount gateway /data/logs logs/gateway 0750
      ;;
    control)
      register_data_mount postgres /var/lib/postgresql/data postgres 0700
      register_data_mount redis /data redis 0750
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
      echo "PostgreSQL 数据目录版本为 $version，当前镜像只支持版本 16：$postgres_data_dir" >&2
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

if [[ "$role" == "single" || "$role" == "control" ]]; then
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
      echo "该 token 不保存在 data 目录；静默生成新值会导致现有 Storage/Play 节点鉴权失败" >&2
      exit 1
    fi
  fi
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
  if grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.*(GENERATE_ON_INSTALL|example\.invalid)' .env; then
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
      echo "目标数据目录已有内容，不能自动覆盖旧命名卷 $mount_name：$target" >&2
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
        echo "旧 PostgreSQL 数据版本为 $version，当前镜像只支持版本 16，正在恢复原服务" >&2
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

compose pull

if [[ "$installed" == true ]]; then
  migrate_legacy_named_volumes
fi

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
