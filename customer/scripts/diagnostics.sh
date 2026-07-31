#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_customer_env
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$CUSTOMER_DIR/diagnostics-$timestamp"
mkdir -p "$target"
umask 077
compose ps > "$target/compose-ps.txt"
compose config --images > "$target/images.txt"
compose logs --no-color --tail 300 2>&1 \
  | sed -E 's/(activationCode|password|token|secret)([=:" ]+)[^ ,"}]+/\1\2[REDACTED]/Ig' \
  > "$target/logs-redacted.txt"
curl -fsS http://127.0.0.1:18088/v1/status > "$target/license-status.json" 2>/dev/null || true
tar -C "$CUSTOMER_DIR" -czf "$target.tar.gz" "$(basename "$target")"
echo "诊断包已生成：$target.tar.gz"
echo "发送前仍请人工检查是否包含业务数据或其他敏感信息。"
