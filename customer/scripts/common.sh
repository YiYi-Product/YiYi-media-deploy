#!/usr/bin/env bash
set -euo pipefail

CUSTOMER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILES=(-f "$CUSTOMER_DIR/compose.yaml" -f "$CUSTOMER_DIR/compose.node.yaml")

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$CUSTOMER_DIR/.env" "${COMPOSE_FILES[@]}" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose --env-file "$CUSTOMER_DIR/.env" "${COMPOSE_FILES[@]}" "$@"
  else
    echo "需要 Docker Compose v2" >&2
    return 1
  fi
}

require_customer_env() {
  if [[ ! -f "$CUSTOMER_DIR/.env" ]]; then
    echo "缺少 $CUSTOMER_DIR/.env，请先复制 .env.example 并填写" >&2
    exit 1
  fi
}
