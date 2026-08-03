#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_deploy_env
compose up -d license-agent
printf "请输入一次性激活码（输入不回显）: " >&2
IFS= read -r -s activation_code
printf "\n" >&2
if [[ ${#activation_code} -lt 24 ]]; then
  echo "激活码格式无效" >&2
  exit 1
fi
printf '%s\n' "$activation_code" | compose exec -T license-agent sh -c \
  'umask 077; dd of=/var/lib/yiyi-license/activation-code status=none'
unset activation_code
compose restart license-agent >/dev/null

for _ in $(seq 1 30); do
  state="$(curl -fsS http://127.0.0.1:18088/v1/status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))' 2>/dev/null || true)"
  if [[ "$state" == "ACTIVE" || "$state" == "GRACE" ]]; then
    echo "激活成功，当前许可证状态：$state"
    exit 0
  fi
  sleep 1
done
echo "激活未在 30 秒内完成，请运行 ./yiyi.sh diagnostics 并联系发布方" >&2
exit 1
