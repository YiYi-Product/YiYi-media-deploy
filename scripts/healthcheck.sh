#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_deploy_env
role="$(deployment_role)"
failed=0
check() {
  local name="$1" url="$2"
  if curl -fsS --max-time 5 "$url" >/dev/null; then
    printf '%-18s OK\n' "$name"
  else
    printf '%-18s FAIL (%s)\n' "$name" "$url" >&2
    failed=1
  fi
}

case "$role" in
  single)
    check license-agent http://127.0.0.1:18088/v1/status
    check config-license http://127.0.0.1:18085/api/license/status
    check user-license http://127.0.0.1:18082/api/license/status
    check media-license http://127.0.0.1:18083/api/license/status
    check gateway-license http://127.0.0.1:18086/api/license/status
    check frontend http://127.0.0.1:18080/
    if [[ -f "$DEPLOY_DIR/.nodes-enabled" ]]; then
      check storage http://127.0.0.1:18084/api/storage/ping
      check play-agent http://127.0.0.1:19090/health
    fi
    ;;
  control)
    check license-agent http://127.0.0.1:18088/v1/status
    check config-license http://127.0.0.1:18085/api/license/status
    ;;
  user)
    check license-sync http://127.0.0.1:18088/v1/status
    check user-license http://127.0.0.1:18082/api/license/status
    ;;
  media)
    check license-sync http://127.0.0.1:18088/v1/status
    check media-license http://127.0.0.1:18083/api/license/status
    ;;
  edge)
    check license-sync http://127.0.0.1:18088/v1/status
    check gateway-license http://127.0.0.1:18086/api/license/status
    check frontend http://127.0.0.1:18080/
    ;;
  storage) check storage http://127.0.0.1:18084/api/storage/ping ;;
  play) check play-agent http://127.0.0.1:19090/health ;;
esac
exit "$failed"
