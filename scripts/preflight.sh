#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_deploy_env
role="$(deployment_role)"
validate_role "$role"
command -v docker >/dev/null || { echo "未安装 Docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon 不可用" >&2; exit 1; }

if grep -Eq 'REPLACE_WITH_(DIGEST|RELEASE_VERSION)|GENERATE_ON_INSTALL|example\.invalid|:latest([[:space:]]|$)' "$DEPLOY_DIR/.env"; then
  echo "安装包仍包含发布占位值，请联系发布方提供正式版本" >&2
  exit 1
fi
for key in YIYI_SERVER_HOST YIYI_ADVERTISE_HOST YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_SERVICE_TOKEN YIYI_LICENSE_CLUSTER_TOKEN; do
  value="$(env_value "$DEPLOY_DIR/.env" "$key")"
  [[ -n "$value" && "$value" != REPLACE_* ]] || { echo "缺少 $key" >&2; exit 1; }
done
cluster_token="$(env_value "$DEPLOY_DIR/.env" YIYI_LICENSE_CLUSTER_TOKEN)"
[[ ${#cluster_token} -ge 32 ]] || { echo "YIYI_LICENSE_CLUSTER_TOKEN 长度不足" >&2; exit 1; }

if [[ "$role" != "single" && "$role" != "control" ]]; then
  for key in YIYI_DB_HOST YIYI_REDIS_HOST YIYI_CONFIG_HOST YIYI_LICENSE_SYNC_URL; do
    value="$(env_value "$DEPLOY_DIR/.env" "$key")"
    [[ -n "$value" && "$value" != REPLACE_* ]] || { echo "join.env 缺少 $key" >&2; exit 1; }
  done
fi
if [[ "$role" == "user" || "$role" == "media" || "$role" == "edge" ]]; then
  sync_url="$(env_value "$DEPLOY_DIR/.env" YIYI_LICENSE_SYNC_URL)"
  [[ "$sync_url" == https://* ]] || { echo "许可证同步地址必须使用 HTTPS" >&2; exit 1; }
fi
if [[ "$role" == "storage" && "$(env_value "$DEPLOY_DIR/.env" YIYI_STORAGE_NODE_ID)" == "NODE_NOT_CONFIGURED" ]]; then
  echo "Storage 节点 ID 尚未配置" >&2; exit 1
fi
if [[ "$role" == "play" && "$(env_value "$DEPLOY_DIR/.env" YIYI_PLAY_AGENT_NODE_ID)" == "NODE_NOT_CONFIGURED" ]]; then
  echo "Play Agent 节点 ID 尚未配置" >&2; exit 1
fi
if [[ ! -s "$DEPLOY_DIR/config/license-public.jwk" ]]; then
  echo "安装包缺少 config/license-public.jwk，请联系发布方" >&2
  exit 1
fi
if [[ ! -s "$DEPLOY_DIR/config/cluster-relay.crt" ]]; then
  echo "缺少集群许可证同步 TLS 证书，请重新运行安装脚本" >&2
  exit 1
fi
if [[ ( "$role" == "single" || "$role" == "control" ) && ! -s "$DEPLOY_DIR/config/cluster-relay.key" ]]; then
  echo "主控机缺少集群许可证 Relay TLS 私钥" >&2
  exit 1
fi

python3 - "$DEPLOY_DIR/config/license-public.jwk" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if value.get("kty") != "OKP" or value.get("crv") != "Ed25519" or not value.get("kid") or not value.get("x"):
    raise SystemExit("license-public.jwk 不是有效的 Ed25519 公钥")
if any(key in value for key in ("d", "p", "q", "dp", "dq")):
    raise SystemExit("license-public.jwk 意外包含私钥字段")
PY

compose config -q
images="$(compose config --images)"
while IFS= read -r image; do
  [[ "$image" == *@sha256:* ]] || { echo "镜像未固定 digest: $image" >&2; exit 1; }
done <<< "$images"

if [[ "$role" == "single" || "$role" == "control" ]]; then
  license_server_url="$(env_value "$DEPLOY_DIR/.env" YIYI_LICENSE_SERVER_URL)"
  [[ "$license_server_url" == https://* ]] || { echo "YIYI_LICENSE_SERVER_URL 必须使用 HTTPS" >&2; exit 1; }
fi

echo "预检通过：$role 角色、Compose、公钥和镜像摘要均有效"
