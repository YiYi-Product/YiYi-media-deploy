#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_customer_env
command -v docker >/dev/null || { echo "未安装 Docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon 不可用" >&2; exit 1; }

if grep -Eq 'REPLACE_|example\.invalid|:latest([[:space:]]|$)' "$CUSTOMER_DIR/.env"; then
  echo ".env 仍包含占位值或 latest 标签" >&2
  exit 1
fi
if [[ ! -s "$CUSTOMER_DIR/config/license-public.jwk" ]]; then
  echo "缺少发布方提供的 config/license-public.jwk" >&2
  exit 1
fi

python3 - "$CUSTOMER_DIR/config/license-public.jwk" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
required = {"kty": "OKP", "crv": "Ed25519"}
if any(value.get(k) != v for k, v in required.items()) or not value.get("kid") or not value.get("x"):
    raise SystemExit("license-public.jwk 不是有效的 Ed25519 公钥")
if any(key in value for key in ("d", "p", "q", "dp", "dq")):
    raise SystemExit("license-public.jwk 意外包含私钥字段")
PY

compose config -q
images="$(compose config --images)"
while IFS= read -r image; do
  [[ "$image" == *@sha256:* ]] || { echo "镜像未固定 digest: $image" >&2; exit 1; }
done <<< "$images"

license_server_url="$(awk -F= '$1 == "YIYI_LICENSE_SERVER_URL" {sub(/^[^=]*=/, ""); print; exit}' "$CUSTOMER_DIR/.env")"
if [[ "$license_server_url" != https://* ]]; then
  echo "YIYI_LICENSE_SERVER_URL 必须使用 HTTPS" >&2
  exit 1
fi

echo "预检通过：Compose 语法、公钥和镜像摘要均有效"
