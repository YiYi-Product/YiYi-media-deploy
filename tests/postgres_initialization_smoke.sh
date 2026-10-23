#!/usr/bin/env bash
# Optional Docker regression: only creates its own temporary container and tmpfs data.
set -euo pipefail
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/yiyi-pg-init-test.XXXXXX")"
test_container="yiyi-install-pg-test-$$"
cleanup() {
  docker rm -f "$test_container" >/dev/null 2>&1 || true
  rm -rf "$test_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 0700 "$test_dir"
(
  umask 077
  printf 'POSTGRES_USER=yiyi\nPOSTGRES_PASSWORD=' > "$test_dir/test.env"
  openssl rand -hex 32 >> "$test_dir/test.env"
)
cat > "$test_dir/20-slow-init.sh" <<'INIT'
#!/bin/sh
set -e
touch /tmp/yiyi-init-started
sleep 15
for db in yiyi_config yiyi_user yiyi_media yiyi_storage; do
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE $db" >/dev/null
done
touch /tmp/yiyi-init-finished
INIT
chmod 0755 "$test_dir/20-slow-init.sh"
# The postgres UID must traverse the bind source; test.env stays mode 0600.
chmod 0711 "$test_dir"
python3 - "$DEPLOY_DIR/install.sh" "$test_dir/helpers.sh" <<'PY'
import re, sys
from pathlib import Path
script = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text('\n'.join(
    re.search(rf'^{name}\(\) \{{.*?^\}}', script, re.M | re.S).group()
    for name in ('postgres_query', 'wait_for_postgres', 'ensure_databases')) + '\n')
PY
docker run -d --name "$test_container" --tmpfs /var/lib/postgresql/data \
  --env-file "$test_dir/test.env" \
  -v "$test_dir/20-slow-init.sh:/docker-entrypoint-initdb.d/20-slow-init.sh:ro" \
  --health-cmd='pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres' \
  --health-interval=1s --health-timeout=2s --health-retries=90 postgres:16.4 >/dev/null
for ((attempt=1; attempt<=90; attempt++)); do
  if docker exec "$test_container" test -f /tmp/yiyi-init-started; then break; fi
  sleep 1
done
docker exec "$test_container" test -f /tmp/yiyi-init-started
docker exec "$test_container" pg_isready -U yiyi -d postgres >/dev/null
if docker exec "$test_container" pg_isready -h 127.0.0.1 -U yiyi -d postgres >/dev/null; then
  echo 'FAIL: temporary PostgreSQL unexpectedly accepts TCP' >&2
  exit 1
fi
echo 'PASS: initialization accepts Unix socket connections before TCP is ready'
source "$test_dir/helpers.sh"
compose() {
  [[ "$1 $2 $3" == 'exec -T postgres' ]]
  shift 3
  docker exec "$test_container" "$@"
}
YIYI_DATABASES=(yiyi_config yiyi_user yiyi_media yiyi_storage)
wait_for_postgres
docker exec "$test_container" test -f /tmp/yiyi-init-finished
ensure_databases
echo 'PASS: initialization finished before SQL checks; no duplicate database creation'
