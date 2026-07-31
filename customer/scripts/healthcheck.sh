#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_customer_env
scope="${1:-all}"
if [[ "$scope" != "all" && "$scope" != "--control-only" ]]; then
  echo "用法: $0 [--control-only]" >&2
  exit 2
fi
failed=0
check() {
  local name="$1" url="$2"
  if curl -fsS --max-time 5 "$url" >/dev/null; then
    printf '%-16s OK\n' "$name"
  else
    printf '%-16s FAIL (%s)\n' "$name" "$url" >&2
    failed=1
  fi
}

check license-agent http://127.0.0.1:18088/v1/status
check config-license http://127.0.0.1:18085/api/license/status
check user-license http://127.0.0.1:18082/api/license/status
check media-license http://127.0.0.1:18083/api/license/status
check gateway-license http://127.0.0.1:18086/api/license/status
check frontend http://127.0.0.1:18080/
if [[ "$scope" == "all" ]]; then
  check storage http://127.0.0.1:18084/api/storage/ping
  check play-agent http://127.0.0.1:19090/health
fi
exit "$failed"
