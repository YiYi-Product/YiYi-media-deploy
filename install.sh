#!/usr/bin/env bash
#
# YiYi Media 单机版部署（STANDALONE）安装 / 升级脚本。
#
# 适用模式：单机版部署（三容器：yiyi-app + postgres + redis）。
# 分布式部署请使用 install-distributed.sh 与 compose.distributed.yaml。
#
# 本脚本只处理单机版路径，因此：
#   * 不生成 join.env，不生成集群中继证书 cluster-relay.*；
#   * 不提供 Control / User / Media / Edge 角色选择；
#   * 不写 YIYI_DEPLOY_ROLE，也不使用 YIYI_DEPLOY_ROLE=single 表达旧角色语义。
#
# 它固定写入 YIYI_DEPLOYMENT_MODE=STANDALONE，但**能力边界仍以签名许可证为准**：
# YIYI_DEPLOYMENT_MODE 只用于收窄能力，改它不会扩大授权范围（计划 §3.1、§8.7、§12.2）。
#
# 用法：配置好 .env 后执行 `sudo ./install.sh`。脚本不接受位置参数。
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

COMPOSE_FILE="$DEPLOY_DIR/compose.yaml"
EXPECTED_SERVICES="postgres redis yiyi-app"
# 单机版固定承载的四个业务库（计划 §6）。
YIYI_DATABASES=(yiyi_config yiyi_user yiyi_media yiyi_storage)
# 旧形态（同机多容器 / 分布式角色）的服务名。出现任意一个即说明本目录或本 Compose
# 项目里还留着上一代拓扑，必须先走迁移流程（计划 §13.2、§13.3）。
LEGACY_SERVICES="license-agent license-sync config user media gateway frontend"

if [[ $# -gt 0 ]]; then
  echo "用法：配置 .env 后执行 ./install.sh（单机版不接受任何参数）" >&2
  echo "分布式部署请使用 ./install-distributed.sh" >&2
  exit 2
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 0600 .env
  echo "已生成 $DEPLOY_DIR/.env，请完成配置后再次运行 ./install.sh" >&2
  exit 1
fi

for tool in docker openssl curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "未安装 $tool" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "需要 Docker Compose v2（docker compose 子命令）" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon 不可用" >&2; exit 1; }
install -d -m 0700 "$DEPLOY_DIR/config"

env_value() {
  local file="$1" key="$2"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

set_env_value() {
  local file="$1" key="$2" value="$3" temp
  temp="$(mktemp "${file}.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    index($0, key "=") == 1 {print key "=" value; found=1; next}
    {print}
    END {if (!found) print key "=" value}
  ' "$file" > "$temp"
  chmod 0600 "$temp"
  mv "$temp" "$file"
}

# ── 本机地址 ────────────────────────────────────────────────────────────────
server_host="$(env_value .env YIYI_SERVER_HOST)"
public_host="$(env_value .env YIYI_PUBLIC_HOST)"
if [[ -z "$server_host" || "$server_host" == REPLACE_* || ! "$server_host" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "请在 .env 中填写不带协议和路径的 YIYI_SERVER_HOST" >&2
  exit 1
fi
if [[ -z "$public_host" || "$public_host" == REPLACE_* ]]; then
  public_host="$server_host"
fi
[[ "$public_host" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "YIYI_PUBLIC_HOST 格式无效" >&2; exit 1; }

# ── 部署模式与历史拓扑检查 ──────────────────────────────────────────────────
installed=false
if [[ -f .installed || -s .deployment-mode ]]; then
  installed=true
fi
if [[ -s .deployment-mode ]]; then
  installed_mode="$(tr -d '[:space:]' < .deployment-mode)"
  if [[ "$installed_mode" != "STANDALONE" ]]; then
    cat >&2 <<EOF
本目录已安装为 ${installed_mode}，不能原地改成单机版。

单机版与分布式版互转必须同时完成许可证 Edition 变更、部署拓扑迁移和数据校验
（计划 §3.1）。只改 .env 或 Compose 文件不会生效，请不要在这里继续。
EOF
    exit 1
  fi
fi

# 旧一代拓扑检测：只看，不做任何破坏性处理。
legacy_reason=""
if [[ -s .role ]]; then
  legacy_reason="部署目录存在旧角色的 .role 文件（$(tr -d '[:space:]' < .role)）"
fi
if [[ -z "$legacy_reason" ]]; then
  legacy_containers="$(docker ps -a \
    --filter "label=com.docker.compose.project=yiyi" \
    --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null || true)"
  for legacy in $LEGACY_SERVICES; do
    if printf '%s\n' "$legacy_containers" | grep -Fxq "$legacy"; then
      legacy_reason="Compose 项目 yiyi 中仍存在旧拓扑容器：$legacy"
      break
    fi
  done
fi

# 旧一代用 Docker 命名卷保存数据。单机版改用统一数据根目录下的绑定挂载，
# 因此这里**只读**列出仍然存在的旧命名卷，提醒操作者按 MIGRATION.md 自行搬运。
# 本脚本不会 docker cp、不会删除卷，也不会覆盖非空的数据目录。
legacy_volumes=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  legacy_volumes="$(docker volume ls \
    --filter "label=com.docker.compose.project=yiyi" \
    --format '{{.Name}}' 2>/dev/null || true)"
fi

migration_confirmed=false
if [[ "${YIYI_MIGRATION_CONFIRMED:-0}" == "1" ]]; then
  migration_confirmed=true
fi
if [[ -n "$legacy_reason" && "$migration_confirmed" != true ]]; then
  cat >&2 <<EOF
检测到本机仍是上一代（同机多容器 / 分布式角色）拓扑：
  $legacy_reason

单机版安装脚本不会替你停掉、删除或改造旧容器：旧容器与旧配置在验收完成前必须保留
（计划 §13.4）。请先执行只读预检并按迁移文档操作：

  ./migrate-precheck.sh            # 只读预检 + 影响报告，不做任何修改
  见 MIGRATION.md                  # 单 Storage + 单 Play 的迁移流程

确认已完成预检、备份，并明确要让三容器聚合形态接管本机后，再执行：

  sudo YIYI_MIGRATION_CONFIRMED=1 ./install.sh

注意：迁移确认后本脚本也**不会**使用 --remove-orphans，
旧容器需要你在验收通过后自行、显式地移除。
EOF
  exit 1
fi
if [[ -n "$legacy_reason" ]]; then
  echo "警告：已确认迁移（YIYI_MIGRATION_CONFIRMED=1），本次不会使用 --remove-orphans。" >&2
  echo "警告：旧拓扑仍在：$legacy_reason" >&2
  echo "警告：请在验收通过前保留旧容器与旧配置，之后手工移除。" >&2
fi

if [[ -n "$legacy_volumes" ]]; then
  cat >&2 <<EOF

检测到旧一代的 Docker 命名卷（数据可能还在里面）：

$(printf '  - %s\n' $legacy_volumes)

单机版改用统一数据根目录下的绑定挂载，**不会**自动搬运这些卷，也不会删除它们。
请按 MIGRATION.md 自行把其中的数据复制到数据目录（旧卷请保留到验收完成之后）：

  docker run --rm -v <卷名>:/from -v "$DEPLOY_DIR/data":/to alpine \\
    sh -c 'cp -a /from/. /to/<目标子目录>/'

EOF
fi
# ── 固定部署模式 ────────────────────────────────────────────────────────────
# 单机版不使用 profile。COMPOSE_PROFILES 写成空值，避免旧 .env 里残留的
# single/control 等值让 docker compose 意外启用别的服务。
#
# COMPOSE_FILE 显式指向单机版 Compose：仓库里同时存在 compose.distributed.yaml，
# 而 `docker compose` 默认按固定文件名自动发现（compose.yaml 优先级最高）。
# 显式写死可以保证任何目录、任何调用方式都只会解析到本文件。
set_env_value .env COMPOSE_FILE "compose.yaml"
set_env_value .env YIYI_DEPLOYMENT_MODE "STANDALONE"
set_env_value .env COMPOSE_PROFILES ""
printf '%s\n' "STANDALONE" > .deployment-mode
chmod 0600 .deployment-mode

# 单机版固定使用内置 PostgreSQL 与 Redis：不提供 external 模式，也不接受角色变量。
# 这些值若被残留，说明 .env 来自分布式部署或上一代配置，继续执行会得到一台
# "看起来装好了、实际连不上数据库"的机器，因此这里显式拒绝而不是静默忽略。
legacy_role="$(env_value .env YIYI_DEPLOY_ROLE)"
if [[ -n "$legacy_role" && "$legacy_role" != "single" && "$legacy_role" != "STANDALONE" ]]; then
  cat >&2 <<EOF
.env 中的 YIYI_DEPLOY_ROLE=$legacy_role 属于分布式部署。

单机版没有 Control/User/Media/Edge 角色选择，也不使用 YIYI_DEPLOY_ROLE。
单机版请使用 .env.example 模板；分布式部署请使用 .env.distributed.example
与 install-distributed.sh。
EOF
  exit 1
fi
if [[ -n "$legacy_role" ]]; then
  echo "提示：.env 中的 YIYI_DEPLOY_ROLE=$legacy_role 在单机版不再使用，已被忽略。" >&2
  echo "提示：它不表达部署模式；单机版的部署形态固定为 STANDALONE。" >&2
fi
db_mode="$(env_value .env YIYI_DB_MODE)"
if [[ -n "$db_mode" && "$db_mode" != "bundled" ]]; then
  cat >&2 <<EOF
.env 中的 YIYI_DB_MODE=$db_mode 在单机版不受支持。

单机版固定使用内置 PostgreSQL 与 Redis，四个业务库由同一个内置实例承载；
不提供 external 模式（计划 §5.3、§6）。
EOF
  exit 1
fi

# ── 镜像标签 ────────────────────────────────────────────────────────────────
image_tag="$(env_value .env YIYI_IMAGE_TAG)"
if [[ -n "$image_tag" ]] && ! [[ "$image_tag" =~ ^[0-9A-Za-z_][0-9A-Za-z._-]{0,127}$ ]]; then
  echo "YIYI_IMAGE_TAG 不是合法的镜像标签：$image_tag" >&2
  exit 1
fi
if [[ -z "$image_tag" ]]; then
  echo "提示：YIYI_IMAGE_TAG 为空，将使用可变的 latest；生产环境建议锁定到不可变版本标签。" >&2
fi

# ── 统一数据根目录 ──────────────────────────────────────────────────────────
data_dir=""
postgres_data_dir=""
postgres_data_existing=false

configure_data_dir() {
  local configured
  configured="$(env_value .env YIYI_DATA_DIR)"
  if [[ -z "$configured" ]]; then
    configured="$DEPLOY_DIR/data"
  elif [[ "$configured" != /* ]]; then
    configured="$DEPLOY_DIR/$configured"
  fi
  configured="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$configured")"
  data_dir="$configured"
  postgres_data_dir="$data_dir/postgres"
  set_env_value .env YIYI_DATA_DIR "$data_dir"
}

# 目录格式：路径|权限|属主。属主留空表示不改（由基础镜像自己在启动时修正）。
# 单机版目录结构见计划 §6。
DATA_LAYOUT=(
  "postgres|0700|"
  "redis|0750|"
  "license/identity|0700|10001:10001"
  "license/lease|0700|10001:10001"
  "config/uploads|0750|10001:10001"
  "storage/mount-data|0750|10001:10001"
  "storage/spool|0750|10001:10001"
  "storage/read-cache|0750|10001:10001"
  "play-agent/vfs-cache|0750|10001:10001"
  "play-agent/image-cache|0750|10001:10001"
  "logs/config|0750|10001:10001"
  "logs/user|0750|10001:10001"
  "logs/media|0750|10001:10001"
  "logs/gateway|0750|10001:10001"
  "logs/storage|0750|10001:10001"
  "logs/play-agent|0750|10001:10001"
  "logs/license|0750|10001:10001"
)

prepare_data_dirs() {
  local spec relative mode owner target
  install -d -m 0750 "$data_dir"
  for spec in "${DATA_LAYOUT[@]}"; do
    IFS='|' read -r relative mode owner <<< "$spec"
    target="$data_dir/$relative"
    # 已存在的目录不动其内容，只补权限；这是升级路径，不能覆盖客户数据。
    install -d -m "$mode" "$target"
    chmod "$mode" "$target"
    if [[ -n "$owner" ]]; then
      if [[ "$(id -u)" != "0" ]]; then
        echo "需要 root 才能把 $target 的属主设为 ${owner}，请使用 sudo 执行本脚本" >&2
        return 1
      fi
      # 只在属主不符时递归修正，避免每次升级都动全量文件。
      if [[ "$(stat -c '%u:%g' "$target" 2>/dev/null || stat -f '%u:%g' "$target")" != "$owner" ]]; then
        chown -R "$owner" "$target"
      fi
    fi
  done
}

validate_postgres_data_dir() {
  local version
  # 目录可能尚未创建（全新安装）：这种情况按"空目录"处理，不要用 find 报错打断安装。
  if [[ -f "$postgres_data_dir/PG_VERSION" ]]; then
    version="$(tr -d '[:space:]' < "$postgres_data_dir/PG_VERSION")"
    [[ "$version" == "16" ]] || {
      echo "PostgreSQL 数据目录版本为 ${version}，当前镜像只支持版本 16：$postgres_data_dir" >&2
      return 1
    }
    postgres_data_existing=true
  elif [[ -d "$postgres_data_dir" ]] && [[ -n "$(find "$postgres_data_dir" -mindepth 1 -print -quit)" ]]; then
    echo "PostgreSQL 数据目录非空但缺少 PG_VERSION：$postgres_data_dir" >&2
    return 1
  fi
}

# ── 凭据 ────────────────────────────────────────────────────────────────────
generate_secret_if_needed() {
  local key="$1" value
  value="$(env_value .env "$key")"
  if [[ -z "$value" || "$value" == "GENERATE_ON_INSTALL" ]]; then
    set_env_value .env "$key" "$(openssl rand -hex 32)"
  fi
}

generate_optional_secret_if_requested() {
  local key="$1" value
  value="$(env_value .env "$key")"
  if [[ "$value" == "GENERATE_ON_INSTALL" ]]; then
    set_env_value .env "$key" "$(openssl rand -hex 32)"
  fi
}

configure_data_dir
validate_postgres_data_dir
prepare_data_dirs

db_user="$(env_value .env YIYI_DB_USER)"
set_env_value .env YIYI_DB_USER "${db_user:-yiyi}"
db_user="$(env_value .env YIYI_DB_USER)"

if [[ "$postgres_data_existing" == true ]]; then
  # 单机版固定使用内置 PostgreSQL，因此数据已存在时口令必须沿用原值：
  # 静默生成新口令会让数据目录里的角色口令与配置不一致，服务全部起不来。
  db_password="$(env_value .env YIYI_DB_PASSWORD)"
  if [[ -z "$db_password" || "$db_password" == "GENERATE_ON_INSTALL" ]]; then
    echo "检测到已有 PostgreSQL 数据，请在 .env 中填写该数据库原有的 YIYI_DB_PASSWORD" >&2
    exit 1
  fi
  # 服务令牌不保存在 data 目录里；恢复旧数据库时静默生成新值会让现有
  # Storage / Play 节点鉴权失败。
  service_token="$(env_value .env YIYI_SERVICE_TOKEN)"
  if [[ -z "$service_token" || "$service_token" == "GENERATE_ON_INSTALL" ]]; then
    echo "检测到已有 PostgreSQL 数据，请在 .env 中填写原部署的 YIYI_SERVICE_TOKEN" >&2
    echo "该 token 不保存在 data 目录；静默生成新值会导致现有 Storage/Play 节点鉴权失败" >&2
    exit 1
  fi
fi
generate_secret_if_needed YIYI_DB_PASSWORD
generate_optional_secret_if_requested YIYI_REDIS_PASSWORD
generate_secret_if_needed YIYI_SERVICE_TOKEN

# ── Compose 调用 ────────────────────────────────────────────────────────────
# 单机版没有 profile，因此不带 --profile。
compose() {
  docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE" "$@"
}

# ── 授权公钥（信任根）同步 ──────────────────────────────────────────────────
#
# 该公钥同时被**硬编码在服务镜像内**（原生验证器与 Java 降级路径），
# 客户端只信任白名单内的公钥。因此本脚本从授权服务器取到的公钥必须与它一致，
# 否则部署起来后所有业务请求都会被许可证过滤器拒绝（全站 403）。
#
# 这里做的是**一致性校验**，不是信任决策：即使 YIYI_LICENSE_SERVER_URL 被指向
# 攻击者服务器、返回了攻击者自签公钥，本检查也会在安装阶段直接失败，
# 而不是产出一个"看似安装成功、实则许可证不可用"的部署。
#
# 轮换签名密钥时：先发布带新公钥白名单的新版本镜像，再更新此处并重新安装。
YIYI_TRUSTED_LICENSE_PUBLIC_KEY="wKWitITf11oh1kRC-6Z05P37xbr1MBbCCUB6CPcAYJs"

sync_license_public_key() {
  local server_url target temp kid fetched
  server_url="$(env_value .env YIYI_LICENSE_SERVER_URL)"
  server_url="${server_url%/}"
  # 默认要求远端 HTTPS 授权中心。
  # 例外：允许 http://127.0.0.1:<port> —— 即客户把自建授权中心跑在**同一台主机**上
  # （本地/内网离线部署的常见形态）。此时到 127.0.0.1 的传输不经过任何网络，
  # 上 TLS 不提供额外机密性，反而要求客户为回环地址签发证书。
  # 注意本函数仍会强校验公钥与镜像内置信任根一致，安全性不依赖传输层。
  local allow_loopback_http=false
  if [[ "$server_url" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]] \
     || [[ "$server_url" =~ ^http://host\.docker\.internal:[0-9]{1,5}$ ]]; then
    allow_loopback_http=true
  fi
  if [[ "$allow_loopback_http" != true && ! "$server_url" =~ ^https://[0-9A-Za-z._-]+(:[0-9]{1,5})?$ ]]; then
    echo "YIYI_LICENSE_SERVER_URL 必须是不带路径的 HTTPS 地址" >&2
    echo "（本机自建授权中心可用 http://127.0.0.1:<端口> 或 http://host.docker.internal:<端口>）" >&2
    return 1
  fi
  target="$DEPLOY_DIR/config/license-public.runtime.jwk"
  temp="$(mktemp "$DEPLOY_DIR/config/license-public.runtime.jwk.XXXXXX")"
  local curl_proto=(--proto '=https' --proto-redir '=https' --tlsv1.2)
  # 本脚本运行在**宿主机**上，而 host.docker.internal 只是 Docker 网络内的别名，
  # 宿主机解析不了它（实测报错 Could not resolve host: host.docker.internal）。
  # 因此这里把它翻译成宿主机可达的 127.0.0.1 再请求；
  # 容器内进程仍用原值（compose 已配 extra_hosts: host-gateway）。
  local host_fetch_url="$server_url"
  if [[ "$allow_loopback_http" == true ]]; then
    host_fetch_url="${server_url/host.docker.internal/127.0.0.1}"
    # 回环地址：TLS 无意义，且客户端通常没有为 127.0.0.1 签发的证书。
    curl_proto=(--proto '=http')
  fi
  if ! curl "${curl_proto[@]}" \
      --fail --silent --show-error "$host_fetch_url/api/v1/public-keys" | \
    python3 -c '
import json, sys
document = json.load(sys.stdin)
keys = document.get("keys")
if not isinstance(keys, list) or not keys:
    raise SystemExit("授权服务器未返回公钥")
key = keys[0]
if key.get("kty") != "OKP" or key.get("crv") != "Ed25519" or not key.get("kid") or not key.get("x"):
    raise SystemExit("授权服务器返回的不是有效 Ed25519 公钥")
if any(name in key for name in ("d", "p", "q", "dp", "dq")):
    raise SystemExit("授权公钥意外包含私钥字段")
json.dump(key, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
' > "$temp"; then
    rm -f "$temp"
    return 1
  fi
  fetched="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["x"])' "$temp")"
  if [[ "$fetched" != "$YIYI_TRUSTED_LICENSE_PUBLIC_KEY" ]]; then
    rm -f "$temp"
    cat >&2 <<EOF
授权服务器返回的公钥不受当前版本信任，已中止安装。

  授权服务器：$server_url
  返回公钥  ：$fetched
  期望公钥  ：$YIYI_TRUSTED_LICENSE_PUBLIC_KEY

服务镜像只信任内置的厂商公钥。若不中止，部署完成后所有业务请求都会被
许可证过滤器以 403 拒绝（表现为"安装成功但全站不可用"）。

请确认 YIYI_LICENSE_SERVER_URL 指向正确的授权服务器；
若厂商确实轮换了签名密钥，需要先升级到包含新公钥白名单的镜像版本。
EOF
    return 1
  fi
  chmod 0644 "$temp"
  mv "$temp" "$target"
  kid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kid"])' "$target")"
  echo "授权公钥已同步并校验：$kid"
}

# ── 拉取镜像前校验 Compose 与 Edition 配置（计划 §12.2）─────────────────────
preflight() {
  if grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.*(GENERATE_ON_INSTALL|example\.invalid)' .env; then
    echo "配置仍包含占位值" >&2
    return 1
  fi

  local key value resolved
  for key in YIYI_SERVER_HOST YIYI_DB_USER YIYI_DB_PASSWORD YIYI_SERVICE_TOKEN YIYI_LICENSE_SERVER_URL; do
    value="$(env_value .env "$key")"
    [[ -n "$value" && "$value" != REPLACE_* ]] || { echo "缺少 $key" >&2; return 1; }
  done
  [[ -s config/license-public.runtime.jwk ]] || { echo "授权公钥缺失" >&2; return 1; }

  # Compose 语法与插值。
  compose config -q || { echo "compose.yaml 解析失败" >&2; return 1; }
  resolved="$(compose config)"

  # 单机版解析后必须严格只有三个服务（计划 §12.1、§16 验收标准 1）。
  local actual_services
  actual_services="$(compose config --services | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
  if [[ "$actual_services" != "$EXPECTED_SERVICES" ]]; then
    cat >&2 <<EOF
单机版 Compose 解析后的服务列表不符合三容器拓扑。

  期望：$EXPECTED_SERVICES
  实际：$actual_services

请确认使用的是本仓库的 compose.yaml（分布式部署用 compose.distributed.yaml），
并且没有通过 COMPOSE_FILE / COMPOSE_PROFILES 混入其它服务。
EOF
    return 1
  fi

  # 单机版不允许高权限：不给聚合容器 privileged / SYS_ADMIN / /dev/fuse（计划 §3.4、§11）。
  if printf '%s\n' "$resolved" | grep -Eq '^[[:space:]]*privileged:[[:space:]]*true'; then
    echo "单机版 Compose 不允许 privileged: true" >&2
    return 1
  fi
  if printf '%s\n' "$resolved" | grep -Eq '^[[:space:]]*cap_add:'; then
    echo "单机版 Compose 不允许添加 capability（含 SYS_ADMIN）" >&2
    return 1
  fi
  if printf '%s\n' "$resolved" | grep -Eq '^[[:space:]]*devices:' || printf '%s\n' "$resolved" | grep -q '/dev/fuse'; then
    echo "单机版 Compose 不允许挂载 /dev/fuse" >&2
    return 1
  fi

  # 部署形态必须固定为 STANDALONE；它只收窄能力，真正的授权边界是签名租约。
  if ! printf '%s\n' "$resolved" | grep -Eq '^[[:space:]]*YIYI_DEPLOYMENT_MODE:[[:space:]]*"?STANDALONE"?[[:space:]]*$'; then
    echo "compose.yaml 未固定 YIYI_DEPLOYMENT_MODE=STANDALONE" >&2
    return 1
  fi

  # 应用容器必须同时提供两组变量：
  #   * SPRING_DATASOURCE_* / REDIS_* 是各服务最终读取的名字；
  #   * YIYI_DB_USER、YIYI_DB_PASSWORD、YIYI_REDIS_PASSWORD、YIYI_IMAGE_TAG
  #     是聚合镜像内进程监管器拼接 per-service 配置时的占位符来源。
  # 少给后者不会让容器起不来，但会让内置服务用空口令/错库启动，
  # 属于"看起来装好了、实际不可用"的故障，因此在拉镜像前就拦下。
  local required_var
  for required_var in YIYI_DB_USER YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_IMAGE_TAG \
                      SPRING_DATASOURCE_URL SPRING_DATASOURCE_USERNAME SPRING_DATASOURCE_PASSWORD \
                      REDIS_HOST REDIS_PORT YIYI_SERVICE_TOKEN YIYI_LICENSE_SERVER_URL LOG_DIR; do
    if ! printf '%s\n' "$resolved" | grep -Eq "^[[:space:]]*${required_var}:"; then
      echo "compose.yaml 未向 yiyi-app 提供 ${required_var}，聚合镜像无法正确启动内部服务" >&2
      return 1
    fi
  done
}

# ── 容器内探测 ──────────────────────────────────────────────────────────────
# 单机版默认只发布 18080 与回环 19090，其余端口只在容器内部，
# 因此所有内部探测都必须在 yiyi-app 容器里执行。
container_curl() {
  local url="$1"; shift
  compose exec -T yiyi-app curl -fsS --max-time 10 "$@" "$url" >/dev/null
}

# 需要管理员/服务令牌的接口。令牌通过 curl 配置文件走 stdin，
# 不出现在命令行参数里（避免进入宿主机与容器的进程列表）。
container_curl_with_token() {
  local url="$1" token="$2" body
  body="$(printf 'header = "X-Admin-Token: %s"\n' "$token" \
    | compose exec -T yiyi-app curl -fsS --max-time 10 -K - "$url" 2>/dev/null || true)"
  [[ -n "$body" ]] || return 1
  printf '%s' "$body"
}

check_services() {
  local failures=0
  local -a checks=(
    "license-agent|http://127.0.0.1:18088/health"
    "config|http://127.0.0.1:18085/actuator/health"
    "user|http://127.0.0.1:18082/actuator/health"
    "media|http://127.0.0.1:18083/actuator/health"
    "storage|http://127.0.0.1:18084/actuator/health"
    "gateway|http://127.0.0.1:18086/actuator/health"
    "play-agent|http://127.0.0.1:19090/health"
    "frontend|http://127.0.0.1:18080/"
  )
  local item name url
  for item in "${checks[@]}"; do
    IFS='|' read -r name url <<< "$item"
    if container_curl "$url"; then
      echo "  内部服务正常：$name"
    else
      echo "  内部服务不可用：${name}（${url}）" >&2
      failures=$((failures + 1))
    fi
  done
  return "$failures"
}

# 两个内置节点必须在线（计划 §7.1、§16 验收标准 2）。
# 镜像自带的聚合健康检查（HEALTHCHECK）已经覆盖这一项；这里再显式核对一次，
# 便于在失败时直接指出是哪个内置节点缺失。
EMBEDDED_NODE_IDS="node-local-storage node-local-play-agent"

check_embedded_nodes() {
  local token body missing node_id
  token="$(env_value .env YIYI_SERVICE_TOKEN)"
  if ! body="$(container_curl_with_token "http://127.0.0.1:18085/api/config/nodes" "$token")"; then
    echo "  无法直接读取受管节点列表；改由镜像自带的聚合健康检查结果判定（见下方容器健康状态）" >&2
    return 2
  fi
  missing="$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    nodes = json.load(sys.stdin).get("nodes") or []
except Exception:
    print("PARSE_ERROR")
    raise SystemExit(0)
online = {node.get("nodeId") for node in nodes if node.get("status") == "ONLINE"}
for node_id in ("node-local-storage", "node-local-play-agent"):
    if node_id not in online:
        print(node_id)
')"
  if [[ "$missing" == "PARSE_ERROR" ]]; then
    echo "  受管节点列表返回内容无法解析" >&2
    return 2
  fi
  if [[ -n "$missing" ]]; then
    for node_id in $missing; do
      echo "  内置节点未在线：$node_id" >&2
    done
    return 1
  fi
  for node_id in $EMBEDDED_NODE_IDS; do
    echo "  内置节点在线：$node_id"
  done
  return 0
}

# 容器健康状态。聚合镜像的 HEALTHCHECK 逐一确认全部内部服务与两个内置节点，
# 因此 healthy 是"业务链路真的可用"的强判据（计划 §5.2、§16）。
check_container_health() {
  local container_id status
  container_id="$(compose ps -q yiyi-app)"
  [[ -n "$container_id" ]] || { echo "yiyi-app 容器不存在" >&2; return 1; }
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
  case "$status" in
    healthy) echo "  yiyi-app 容器健康状态：healthy"; return 0 ;;
    none) echo "  yiyi-app 未定义 HEALTHCHECK，无法据此判定" >&2; return 2 ;;
    *)
      echo "  yiyi-app 容器健康状态：$status" >&2
      docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' "$container_id" >&2 || true
      return 1
      ;;
  esac
}

# 许可证状态（计划 §8.7、§12.2）。
#
# /api/license/status 在许可证无效时**仍返回 HTTP 200**（状态在响应体里），
# 所以只判断 HTTP 码会把"许可证不可用"误判为安装成功。
check_license() {
  local token body state edition
  token="$(env_value .env YIYI_SERVICE_TOKEN)"
  if ! body="$(container_curl_with_token "http://127.0.0.1:18085/api/license/status" "$token")"; then
    body="$(compose exec -T yiyi-app curl -fsS --max-time 10 http://127.0.0.1:18085/api/license/status 2>/dev/null || true)"
  fi
  [[ -n "$body" ]] || { echo "许可证状态接口不可达" >&2; return 1; }

  state="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("state", ""))
except Exception:
    print("")' 2>/dev/null)"
  edition="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    value = json.load(sys.stdin).get("edition")
    print("" if value is None else value)
except Exception:
    print("")' 2>/dev/null)"

  case "$state" in
    UNACTIVATED)
      echo "  许可证状态：UNACTIVATED（全新安装的正常状态；请在网页激活 STANDALONE 授权码）"
      return 0
      ;;
    ACTIVE|GRACE) ;;
    *)
      echo "  许可证不可用（state=${state:-无法解析}）：$body" >&2
      return 1
      ;;
  esac

  if [[ -z "$edition" || "$edition" == "null" ]]; then
    echo "  许可证状态：${state}（租约未声明 edition）" >&2
    return 1
  fi
  if [[ "$edition" != "STANDALONE" ]]; then
    cat >&2 <<EOF
  许可证 Edition 与部署形态不匹配：edition=${edition}，deploymentMode=STANDALONE

单机版聚合镜像只接受 edition=STANDALONE 的许可证（计划 §8.7）。
部署与数据均未被改动，但业务功能不会开放。请向发布方申请单机版授权码，
或在明确授权后按 MIGRATION.md 迁移到分布式部署。
EOF
    return 1
  fi
  echo "  许可证状态：${state}，Edition=STANDALONE（与部署形态匹配）"
  return 0
}

healthcheck() {
  local failures=0 result
  echo "检查 yiyi-app 容器内的全部内部服务："
  check_services || failures=$((failures + $?))
  echo "检查两个内置节点："
  check_embedded_nodes || {
    result=$?
    # 2 表示无法直接读取列表（例如接口鉴权变化），此时以容器健康状态为准。
    if [[ "$result" == "1" ]]; then
      failures=$((failures + 1))
    fi
  }
  echo "检查聚合容器健康状态："
  check_container_health || {
    result=$?
    if [[ "$result" == "1" ]]; then
      failures=$((failures + 1))
    fi
  }
  echo "检查许可证状态："
  check_license || failures=$((failures + 1))
  return "$failures"
}

# ── 四个数据库的幂等存在性检查（计划 §6、§12.2）────────────────────────────
#
# 首次初始化由 postgres-init.sql 建库；升级旧数据目录时 PostgreSQL **不会**
# 重新执行初始化 SQL，因此这里在 PostgreSQL 健康后逐个检查，只创建缺失的库，
# 绝不覆盖或删除已有数据库。
ensure_databases() {
  local db existing created=0
  for db in "${YIYI_DATABASES[@]}"; do
    if ! existing="$(compose exec -T postgres \
        psql -U "$db_user" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" 2>/dev/null)"; then
      echo "无法查询 PostgreSQL 数据库列表" >&2
      return 1
    fi
    if [[ "$(printf '%s' "$existing" | tr -d '[:space:]')" == "1" ]]; then
      echo "  数据库已存在：$db"
      continue
    fi
    if ! compose exec -T postgres \
        psql -v ON_ERROR_STOP=1 -U "$db_user" -d postgres -c "CREATE DATABASE \"$db\"" >/dev/null; then
      echo "创建数据库失败：$db" >&2
      return 1
    fi
    echo "  已创建缺失数据库：$db"
    created=$((created + 1))
  done
  echo "四个业务库检查完成（新建 $created 个）"
}


# ── 迁移：沿用原有 Storage / Play Agent 节点 ID（计划 §7.2、§13.2）────────────
#
# 单机版内置节点的默认 ID 是 node-local-storage / node-local-play-agent。
# 但既有部署的节点 ID 是随机生成的，而 media 库里大量记录用 node_id 引用它
# （媒体源、用户线路授权、手动反代归属、历史任务）。若直接用默认 ID 新建内置节点，
# 原节点记录会永远离线，且这些引用全部失联。
#
# 因此这里在**启动应用容器之前**读取现有受管节点，把原有的唯一节点 ID 写进
# .env 供内置节点沿用。只读查询 + 写 .env，不修改任何节点数据；
# 真正的标记动作由 Config 的 EmbeddedNodeInitializer 幂等完成。
adopt_legacy_embedded_node_ids() {
  local storage_id play_id count_storage count_play
  # 只查数据库；库还不存在（全新安装）时直接返回。
  count_storage="$(query_managed_node_count YiYi-control-storage 2>/dev/null || echo 0)"
  count_play="$(query_managed_node_count YiYi-play-agent 2>/dev/null || echo 0)"
  if [[ "${count_storage:-0}" == "0" && "${count_play:-0}" == "0" ]]; then
    return 0
  fi

  if [[ "${count_storage:-0}" -gt 1 || "${count_play:-0}" -gt 1 ]]; then
    cat >&2 <<EOF
检测到同一服务类型存在多个节点，不能自动迁移（计划 §13.3）：

  Storage   节点数：${count_storage:-0}
  Play Agent 节点数：${count_play:-0}

请先运行 ./migrate-precheck.sh 生成影响报告，由管理员明确选择保留哪一个节点，
再把 YIYI_EMBEDDED_STORAGE_NODE_ID / YIYI_EMBEDDED_PLAY_AGENT_NODE_ID 手动填成
被选中的节点 ID 后重新执行本脚本。未选中的节点会保留记录，不会被删除。
EOF
    return 1
  fi

  storage_id="$(query_single_managed_node_id YiYi-control-storage 2>/dev/null || true)"
  play_id="$(query_single_managed_node_id YiYi-play-agent 2>/dev/null || true)"
  if [[ -n "$storage_id" ]]; then
    set_env_value .env YIYI_EMBEDDED_STORAGE_NODE_ID "$storage_id"
    echo "  沿用原 Storage 节点 ID：$storage_id"
  fi
  if [[ -n "$play_id" ]]; then
    set_env_value .env YIYI_EMBEDDED_PLAY_AGENT_NODE_ID "$play_id"
    echo "  沿用原 Play Agent 节点 ID：$play_id"
  fi
  return 0
}

# 读取受管节点表的查询助手。表不存在（尚未迁移）时返回 0 / 空，
# 让全新安装路径不受影响。
query_managed_node_count() {
  compose exec -T postgres psql -U "$db_user" -d yiyi_config -tAc \
    "SELECT count(*) FROM t_config_managed_node WHERE service_name='$1'" 2>/dev/null \
    | tr -d '[:space:]'
}

query_single_managed_node_id() {
  compose exec -T postgres psql -U "$db_user" -d yiyi_config -tAc \
    "SELECT node_id FROM t_config_managed_node WHERE service_name='$1' ORDER BY created_at LIMIT 1" 2>/dev/null \
    | tr -d '[:space:]'
}

# ── 主流程 ──────────────────────────────────────────────────────────────────

# 这里**不再**自动 `git pull`。
#
# 旧版本在已安装环境会先拉取远端最新代码、再以 root 重新执行安装脚本。
# 那等于"执行一次 ./install.sh 就同意运行远端当前任意代码"：
# 一旦远端仓库或推送凭据被攻破，攻击者无需接触本机即可取得 root 执行权。
#
# 文档化的升级流程本来就要求先手动 `git pull --ff-only` 再执行本脚本
# （见 README「升级」与 OPERATIONS），因此自动拉取只是多余的高风险行为。
# 现改为显式提示，由操作者自行决定何时更新代码。
if [[ "$installed" == true && -d .git ]]; then
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "提示：部署目录存在未提交的本地改动，升级前请自行确认。" >&2
  fi
  echo "提示：如需升级部署文件，请先手动执行 git pull --ff-only 再运行本脚本。" >&2
fi

if [[ "$installed" == true ]]; then
  echo "正在升级单机版部署（STANDALONE）"
fi
sync_license_public_key
preflight

# 拉取镜像。离线/内网（air-gapped）环境可设置 YIYI_SKIP_PULL=1 使用本机已有镜像；
# 此时镜像必须已经导入本机，脚本会在启动后由健康检查验证实际可用性。
if [[ "${YIYI_SKIP_PULL:-0}" == "1" ]]; then
  echo "已跳过镜像拉取（YIYI_SKIP_PULL=1），使用本机已有镜像"
else
  compose pull
fi

# 先只起基础设施，再补齐数据库，最后起应用容器：
# 这样四个库在 Flyway 启动前就已就绪，升级旧数据目录也不会漏库。
compose up -d postgres redis --wait --wait-timeout 300
ensure_databases

# 迁移场景：沿用原有节点 ID，避免媒体源引用与线路授权失联。
if [[ -n "$legacy_reason" ]]; then
  echo "正在检查是否需要沿用原有节点 ID"
  adopt_legacy_embedded_node_ids
fi

if [[ -n "$legacy_reason" ]]; then
  # 迁移路径：保留旧容器，因此不加 --remove-orphans（计划 §13.4）。
  compose up -d --wait --wait-timeout 900
else
  compose up -d --remove-orphans --wait --wait-timeout 900
fi

healthcheck

touch .installed
chmod 0600 .installed

cat <<EOF

单机版部署完成：yiyi-app + postgres + redis 三个容器。

  网页入口：http://$public_host:18080
  首次使用直接在网页输入发布方提供的 STANDALONE 一次性授权码激活。

  Play Agent 默认只绑定宿主机 127.0.0.1:19090，供本机 nginx / Caddy 反代。
  其余应用端口只在容器内部，PostgreSQL 与 Redis 不发布到宿主机。

  日常命令（无需 -f 或 --profile）：
    docker compose ps
    docker compose logs --tail=100 yiyi-app

  备份、回滚与迁移见 README.md、OPERATIONS.md 与 MIGRATION.md。
EOF

if [[ -n "$legacy_reason" ]]; then
  cat <<EOF

注意：本次是在保留旧拓扑的前提下启动单机版（${legacy_reason}）。
请按 MIGRATION.md 完成验证后，再**手工**移除旧容器与旧进程；
本脚本没有删除任何旧容器或旧数据。
EOF
fi
