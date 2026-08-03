#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_deploy_env
role="$(deployment_role)"
[[ "$role" == "single" || "$role" == "control" ]] || { echo "数据库和部署身份只在 single/control 主控机备份" >&2; exit 1; }
backup_root="${1:-$DEPLOY_DIR/backups}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$backup_root/$timestamp"
mkdir -p "$target"
umask 077
compose exec -T postgres sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' > "$target/postgres.sql"
compose cp config:/data/uploads/. "$target/config-uploads" >/dev/null 2>&1 || true
compose cp license-agent:/var/lib/yiyi-license/. "$target/license-identity" >/dev/null
cp "$DEPLOY_DIR/.env" "$target/runtime.env"
cp "$DEPLOY_DIR/.role" "$target/role"
cp "$DEPLOY_DIR/config/license-public.jwk" "$target/license-public.jwk"
cp "$DEPLOY_DIR/config/cluster-relay.crt" "$target/cluster-relay.crt"
cp "$DEPLOY_DIR/config/cluster-relay.key" "$target/cluster-relay.key"
chmod -R go-rwx "$target"
echo "备份完成：$target"
echo "其中包含部署私钥和集群运行凭据，请按最高敏感级别保存。"
