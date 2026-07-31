#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_customer_env
"$CUSTOMER_DIR/scripts/preflight.sh"
"$CUSTOMER_DIR/scripts/backup.sh"
compose pull
compose up -d --remove-orphans
"$CUSTOMER_DIR/scripts/healthcheck.sh"
echo "升级完成。保留升级前 .env 与备份目录，以便按 OPERATIONS.md 回滚。"
