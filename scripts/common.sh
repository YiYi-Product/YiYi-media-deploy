#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

deployment_role() {
  if [[ -s "$DEPLOY_DIR/.role" ]]; then
    tr -d '[:space:]' < "$DEPLOY_DIR/.role"
  else
    printf 'single\n'
  fi
}

validate_role() {
  case "$1" in
    single|control|user|media|edge|storage|play) return 0 ;;
    *) echo "不支持的部署角色：$1" >&2; return 1 ;;
  esac
}

compose() {
  local role profile_args
  role="$(deployment_role)"
  validate_role "$role"
  profile_args=(--profile "$role")
  if [[ "$role" == "single" && -f "$DEPLOY_DIR/.nodes-enabled" ]]; then
    profile_args+=(--profile single-nodes)
  fi
  if docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$DEPLOY_DIR/.env" -f "$DEPLOY_DIR/compose.yaml" "${profile_args[@]}" "$@"
  else
    echo "需要 Docker Compose v2" >&2
    return 1
  fi
}

compose_for_role() {
  local role="$1"
  shift
  docker compose --env-file "$DEPLOY_DIR/.env" -f "$DEPLOY_DIR/compose.yaml" --profile "$role" "$@"
}

require_deploy_env() {
  if [[ ! -f "$DEPLOY_DIR/.env" || ! -f "$DEPLOY_DIR/.role" ]]; then
    echo "尚未安装，请先运行 ./install.sh <角色>" >&2
    exit 1
  fi
}

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

copy_env_keys() {
  local source_file="$1" target_file="$2" key value
  shift 2
  for key in "$@"; do
    value="$(env_value "$source_file" "$key")"
    [[ -n "$value" ]] || { echo "配置文件缺少 $key" >&2; return 1; }
    set_env_value "$target_file" "$key" "$value"
  done
}

cluster_keys() {
  printf '%s\n' \
    YIYI_DB_HOST YIYI_REDIS_HOST YIYI_CONFIG_HOST YIYI_USER_HOST \
    YIYI_DB_USER YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_SERVICE_TOKEN \
    YIYI_LICENSE_CLUSTER_TOKEN YIYI_LICENSE_SYNC_URL YIYI_LICENSE_SYNC_INTERVAL \
    YIYI_DB_PORT YIYI_REDIS_PORT
}

sync_release_config() {
  local key value
  local release_keys=(
    YIYI_RELEASE_VERSION YIYI_LICENSE_SERVER_URL YIYI_LICENSE_RENEW_INTERVAL
    YIYI_CONFIG_IMAGE YIYI_USER_IMAGE YIYI_MEDIA_IMAGE YIYI_GATEWAY_IMAGE
    YIYI_FRONTEND_IMAGE YIYI_STORAGE_IMAGE YIYI_PLAY_AGENT_IMAGE
    YIYI_LICENSE_AGENT_IMAGE YIYI_POSTGRES_IMAGE YIYI_REDIS_IMAGE
  )
  for key in "${release_keys[@]}"; do
    value="$(env_value "$DEPLOY_DIR/.env.example" "$key")"
    [[ -n "$value" ]] || { echo ".env.example 缺少 $key" >&2; return 1; }
    set_env_value "$DEPLOY_DIR/.env" "$key" "$value"
  done
}
