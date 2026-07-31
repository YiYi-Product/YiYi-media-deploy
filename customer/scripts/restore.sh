#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_customer_env
backup_dir="${1:-}"
if [[ -z "$backup_dir" || ! -s "$backup_dir/postgres.sql" ]]; then
  echo "用法: $0 /path/to/backup-directory" >&2
  exit 1
fi
printf "恢复会覆盖当前数据库。输入 RESTORE 继续: " >&2
read -r confirmation
[[ "$confirmation" == "RESTORE" ]] || { echo "已取消"; exit 1; }

compose stop frontend gateway media user config storage play-agent
compose up -d postgres redis
compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres' < "$backup_dir/postgres.sql"
if [[ -d "$backup_dir/config-uploads" ]]; then
  compose cp "$backup_dir/config-uploads/." config:/data/uploads/
fi
compose up -d
"$CUSTOMER_DIR/scripts/healthcheck.sh"
