#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_deploy_env
role="$(deployment_role)"
[[ "$role" == "single" || "$role" == "control" ]] || { echo "只能在 single/control 主控机恢复数据库" >&2; exit 1; }
backup_dir="${1:-}"
if [[ -z "$backup_dir" || ! -s "$backup_dir/postgres.sql" ]]; then
  echo "用法: $0 /path/to/backup-directory" >&2; exit 1
fi
printf "恢复会覆盖当前数据库。输入 RESTORE 继续: " >&2
read -r confirmation
[[ "$confirmation" == "RESTORE" ]] || { echo "已取消"; exit 1; }

if [[ -s "$backup_dir/cluster-relay.crt" && -s "$backup_dir/cluster-relay.key" ]]; then
  cp "$backup_dir/cluster-relay.crt" "$DEPLOY_DIR/config/cluster-relay.crt"
  cp "$backup_dir/cluster-relay.key" "$DEPLOY_DIR/config/cluster-relay.key"
  chmod 0644 "$DEPLOY_DIR/config/cluster-relay.crt"
  chown 10001 "$DEPLOY_DIR/config/cluster-relay.key"
  chmod 0600 "$DEPLOY_DIR/config/cluster-relay.key"
fi

compose stop
compose up -d postgres redis license-agent
if [[ -d "$backup_dir/license-identity" ]]; then
  compose stop license-agent
  tar -C "$backup_dir/license-identity" -cf - . | \
    compose run --rm --no-deps -T --user 0 --entrypoint sh license-agent -c \
      'tar -C /var/lib/yiyi-license -xf - && chown -R 10001 /var/lib/yiyi-license'
  compose up -d license-agent
fi
compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres' < "$backup_dir/postgres.sql"
if [[ -d "$backup_dir/config-uploads" ]]; then
  compose cp "$backup_dir/config-uploads/." config:/data/uploads/
fi
compose up -d --wait --wait-timeout 300
"$DEPLOY_DIR/scripts/healthcheck.sh"
