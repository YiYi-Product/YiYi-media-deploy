#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_customer_env
backup_root="${1:-$CUSTOMER_DIR/backups}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$backup_root/$timestamp"
mkdir -p "$target"
umask 077
compose exec -T postgres sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' > "$target/postgres.sql"
compose cp config:/data/uploads/. "$target/config-uploads" >/dev/null 2>&1 || true
compose cp license-agent:/var/lib/yiyi-license/. "$target/license-identity" >/dev/null
cp "$CUSTOMER_DIR/.env" "$target/runtime.env"
cp "$CUSTOMER_DIR/config/license-public.jwk" "$target/license-public.jwk"
chmod -R go-rwx "$target"
echo "备份完成：$target"
echo "其中包含部署私钥和运行凭据，请按最高敏感级别保存。"
