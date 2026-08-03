#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_deploy_env
role="$(deployment_role)"
if [[ "$role" == "single" || "$role" == "control" ]]; then
  "$DEPLOY_DIR/scripts/backup.sh"
fi
sync_release_config
"$DEPLOY_DIR/scripts/preflight.sh"
compose pull
compose up -d --remove-orphans --wait --wait-timeout 300
"$DEPLOY_DIR/scripts/healthcheck.sh"
echo "$role 角色升级完成。"
