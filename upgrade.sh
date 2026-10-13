#!/usr/bin/env bash
#
# YiYi Media 分布式·控制面同机（v2-all-in-one）**一键升级**。
#
#   cd /opt/YiYi-media-deploy && ./upgrade.sh [--tag <镜像标签>] [--backup-dir <目录>]
#
# 依次完成：
#   1. 预检（分支、.env、已安装、磁盘空间）
#   2. 更新部署文件（git pull --ff-only，然后以新版本的本脚本重新执行）
#   3. 拉取新镜像（控制面 6 个；需要账号迁移时再加单机版聚合镜像，仅借用其中的迁移工具）
#   4. 备份：pg_dump 四个业务库 + .env / config / 授权目录，并逐个 pg_restore --list 校验
#   5. 账号模型统一的离线迁移（仅旧数据需要；见下）
#   6. ./install.sh：重建控制面容器、健康检查、许可证检查
#   7. 升级**本机上**的 Storage / Play Agent 节点（远程节点给出操作提示）
#   8. 汇总验证
#
# 任何一步失败都会停止；第 5、6 步失败时自动把数据库恢复到第 4 步的备份，
# 并用升级前的镜像拉起旧版控制面与旧版 Storage 节点。
#
# 为什么必须走本脚本而不是直接 `docker compose pull && up -d`：
#   新版 storage 的数据库迁移 V540/V546 会清空并删除旧表 t_storage_provider，
#   旧版本里配置的网盘账号必须在此之前由离线迁移搬进 media 的账号资产表。
#   直接 up 会让**新版 storage 节点**一启动就把这些账号清掉。
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"
EXPECTED_BRANCH=v2-all-in-one
YIYI_DATABASES=(yiyi_config yiyi_user yiyi_media yiyi_storage)
APP_SERVICES=(config user media gateway frontend)

usage() {
  cat <<'EOF'
用法：./upgrade.sh [选项]

  --tag <标签>           升级到指定镜像标签（写入 .env 的 YIYI_IMAGE_TAG）；不填则沿用 .env 现值
  --backup-dir <目录>    备份根目录，默认 <部署目录>/backups
  --check                只读预检：报告待更新提交、节点分布、是否需要账号迁移，不做任何改动
  --skip-git-pull        不更新部署文件（离线或已手动更新时）
  --skip-nodes           不自动升级本机节点
  --remote-storage-stopped
                         存在**远程** Storage 节点且需要账号迁移时，确认已人工停掉它们
  -y, --yes              不再交互确认
EOF
}

tag="" backup_root="" check_only=false skip_pull=false skip_nodes=false remote_storage_stopped=false assume_yes=false
original_args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:?--tag 需要参数}"; shift 2 ;;
    --backup-dir) backup_root="${2:?--backup-dir 需要参数}"; shift 2 ;;
    --check) check_only=true; shift ;;
    --skip-git-pull) skip_pull=true; shift ;;
    --skip-nodes) skip_nodes=true; shift ;;
    --remote-storage-stopped) remote_storage_stopped=true; shift ;;
    -y|--yes) assume_yes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

env_value() {
  awk -F= -v key="$2" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$1"
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
compose() {
  docker compose --env-file "$DEPLOY_DIR/.env" -f "$DEPLOY_DIR/compose.yaml" "$@"
}
# 节点令牌、口令会出现在节点脚本输出里：一律打码后再显示 / 落日志。
redact() {
  sed -E 's/(token=)[^&"'"'"' ]+/\1***/g; s/((TOKEN|PASSWORD|SECRET|MASTER_KEY)[A-Z_]*=)[^ "'"'"']+/\1***/g'
}

# ── 1. 预检 ────────────────────────────────────────────────────────────────
step "1/8 预检"
[[ $EUID -eq 0 ]] || die "请用 root 执行"
for tool in docker git curl python3 openssl flock; do
  command -v "$tool" >/dev/null 2>&1 || die "未安装 $tool"
done
docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2"
exec 9>"$DEPLOY_DIR/.upgrade.lock"
flock -n 9 || die "另一个升级正在运行"
[[ -f .env ]] || die "缺少 .env：这台机器还没装过，请执行 ./install.sh"
[[ -f .installed || -s .role ]] || die "未检测到已安装标记，请执行 ./install.sh 完成首次安装"
if [[ -s .deployment-mode && "$(tr -d '[:space:]' < .deployment-mode)" != DISTRIBUTED ]]; then
  die "本目录安装的是 $(tr -d '[:space:]' < .deployment-mode)，不能用分布式升级脚本"
fi
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$branch" == "$EXPECTED_BRANCH" ]] || die "部署目录当前分支是 ${branch:-未知}，期望 $EXPECTED_BRANCH"
db_mode="$(env_value .env YIYI_DB_MODE)"; db_mode="${db_mode:-bundled}"
db_user="$(env_value .env YIYI_DB_USER)"
service_token="$(env_value .env YIYI_SERVICE_TOKEN)"
[[ -n "$service_token" && "$service_token" != GENERATE_ON_INSTALL ]] \
  || die ".env 的 YIYI_SERVICE_TOKEN 为空或是占位值：已有部署必须填原值"
data_dir="$(env_value .env YIYI_DATA_DIR)"; data_dir="${data_dir:-$DEPLOY_DIR/data}"
[[ "$data_dir" == /* ]] || data_dir="$DEPLOY_DIR/$data_dir"
backup_root="${backup_root:-$DEPLOY_DIR/backups}"
ok "分支 $branch，数据库 $db_mode，数据目录 $data_dir"

# ── 2. 更新部署文件 ────────────────────────────────────────────────────────
if [[ "$check_only" == true ]]; then
  step "2/8 部署文件（只读）"
  git fetch --quiet origin "$EXPECTED_BRANCH" || warn "git fetch 失败"
  pending="$(git log --oneline "HEAD..origin/$EXPECTED_BRANCH" 2>/dev/null || true)"
  if [[ -n "$pending" ]]; then echo "  待更新提交："; printf '    %s\n' "${pending//$'\n'/$'\n'    }"; else ok "部署文件已是最新"; fi
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || warn "部署目录有未提交改动，正式升级会拒绝执行"
elif [[ "$skip_pull" == false ]]; then
  step "2/8 更新部署文件"
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    git status --short --untracked-files=no >&2
    die "部署目录有未提交的改动（见上），按约定不覆盖；处理后重试，或用 --skip-git-pull"
  fi
  before="$(git rev-parse HEAD)"
  git fetch --quiet origin "$EXPECTED_BRANCH"
  git merge --ff-only --quiet "origin/$EXPECTED_BRANCH" || die "无法快进到 origin/$EXPECTED_BRANCH"
  after="$(git rev-parse HEAD)"
  if [[ "$before" != "$after" ]]; then
    ok "部署文件 ${before:0:7} → ${after:0:7}，用新版脚本继续"
    flock -u 9
    exec "$DEPLOY_DIR/upgrade.sh" --skip-git-pull "${original_args[@]}"
  fi
  ok "部署文件已是最新（${after:0:7}）"
else
  step "2/8 更新部署文件（已跳过）"
fi

if [[ -n "$tag" ]]; then
  [[ "$tag" =~ ^[0-9A-Za-z._-]+$ ]] || die "镜像标签格式无效：$tag"
  [[ "$check_only" == true ]] || set_env_value .env YIYI_IMAGE_TAG "$tag"
fi
image_tag="${tag:-$(env_value .env YIYI_IMAGE_TAG)}"; image_tag="${image_tag:-latest}"
[[ "$image_tag" == latest ]] && warn "YIYI_IMAGE_TAG 未锁定，跟随 latest；建议 --tag <版本> 锁定以便回滚"

# 旧库常带 "collation version mismatch" 告警（宿主 glibc 变化所致，与升级无关），只滤掉这几行。
quiet_collation() { grep -vE 'collation version|^DETAIL:  The database was created|^HINT:  Rebuild all objects' >&2 || true; }
db_psql() {
  local database="$1" statement="$2" host port
  if [[ "$db_mode" == bundled ]]; then
    compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d "$database" -c "$statement" 2> >(quiet_collation)
  else
    host="$(env_value .env YIYI_DB_HOST)"; port="$(env_value .env YIYI_DB_PORT)"
    PGPASSWORD="$(env_value .env YIYI_DB_PASSWORD)" docker run --rm -i --network host -e PGPASSWORD postgres:16.4 \
      psql -X -qAt -v ON_ERROR_STOP=1 -h "$host" -p "${port:-5432}" -U "$db_user" -d "$database" -c "$statement"
  fi
}
pg_tool() { # pg_dump / pg_restore，stdin/stdout 透传
  local tool="$1"; shift
  if [[ "$db_mode" == bundled ]]; then
    compose exec -T postgres "$tool" -U "$db_user" "$@"
  else
    PGPASSWORD="$(env_value .env YIYI_DB_PASSWORD)" docker run --rm -i --network host -e PGPASSWORD postgres:16.4 \
      "$tool" -h "$(env_value .env YIYI_DB_HOST)" -p "$(env_value .env YIYI_DB_PORT)" -U "$db_user" "$@"
  fi
}
if [[ "$db_mode" == bundled && "$check_only" != true ]]; then
  compose up -d --wait --wait-timeout 120 postgres redis >/dev/null
fi
db_psql yiyi_config "SELECT 1" >/dev/null || die "数据库不可达"

# ── 节点清单：哪些在本机、哪些在远程 ─────────────────────────────────────────
# 本机节点 = 同名 Docker 容器或同名 systemd 单元（节点管理生成的部署脚本固定用 nodeId 命名）。
mapfile -t managed_nodes < <(db_psql yiyi_config \
  "SELECT node_id || '|' || service_name FROM t_config_managed_node WHERE enabled ORDER BY service_name, node_id")
node_kind() { # 输出 docker / binary / remote
  local id="$1"
  if docker inspect "$id" >/dev/null 2>&1; then echo docker
  elif [[ -f "/etc/systemd/system/$id.service" ]]; then echo binary
  else echo remote; fi
}
storage_nodes=() local_storage=() remote_storage=()
for entry in "${managed_nodes[@]}"; do
  IFS='|' read -r id service <<< "$entry"
  [[ "$service" == YiYi-control-storage ]] || continue
  storage_nodes+=("$id")
  if [[ "$(node_kind "$id")" == remote ]]; then remote_storage+=("$id"); else local_storage+=("$id"); fi
done
ok "受管节点 ${#managed_nodes[@]} 个（Storage ${#storage_nodes[@]}，其中远程 ${#remote_storage[@]}）"

# ── 是否需要账号迁移 ──────────────────────────────────────────────────────
legacy="$(db_psql yiyi_storage "SELECT to_regclass('public.t_storage_provider') IS NOT NULL;")"
need_account_upgrade=false
if [[ "$legacy" == t ]]; then
  stage=""
  if [[ "$(db_psql yiyi_storage "SELECT to_regclass('yiyi_account_upgrade.state') IS NOT NULL;")" == t ]]; then
    stage="$(db_psql yiyi_storage "SELECT stage FROM yiyi_account_upgrade.state WHERE id=1;")"
  fi
  [[ "$stage" == COMPLETED ]] || need_account_upgrade=true
fi
if [[ "$need_account_upgrade" == true ]]; then
  providers="$(db_psql yiyi_storage "SELECT count(*) FROM t_storage_provider;")"
  warn "检测到旧版网盘账号（t_storage_provider ${providers} 行）：本次升级会先做账号离线迁移"
  (( ${#storage_nodes[@]} == 1 )) || [[ "$check_only" == true ]] || die "账号迁移要求恰好 1 个 Storage 节点（当前 ${#storage_nodes[@]} 个），请联系厂商"
  if (( ${#remote_storage[@]} > 0 )) && [[ "$remote_storage_stopped" != true && "$check_only" != true ]]; then
    die "Storage 节点 ${remote_storage[*]} 在远程主机上：请先在那台机器停掉它（docker stop / systemctl stop），再加 --remote-storage-stopped 重跑"
  fi
  migrate_image="ghcr.io/yiyi-product/yiyi-media-standalone:$image_tag"
fi

if [[ "$check_only" == true ]]; then
  for entry in "${managed_nodes[@]}"; do
    IFS='|' read -r id service <<< "$entry"
    printf '  节点 %-20s %-22s %s\n' "$id" "$service" "$(node_kind "$id")"
  done
  key="$(env_value .env YIYI_CREDENTIAL_MASTER_KEY)"
  [[ -n "$key" && "$key" != GENERATE_ON_INSTALL ]] && ok "云盘凭据主密钥已配置" || warn "云盘凭据主密钥未配置：升级时会在确认库内无加密凭据后自动生成"
  [[ "$need_account_upgrade" == true ]] && warn "需要账号迁移（Storage 节点：${storage_nodes[*]:-无}；远程：${remote_storage[*]:-无}）" || ok "不需要账号迁移"
  echo "  目标镜像标签：$image_tag    磁盘剩余：$(df -Ph "$DEPLOY_DIR" | awk 'NR==2 {print $4}')"
  exit 0
fi

free_kb="$(df -Pk "$DEPLOY_DIR" | awk 'NR==2 {print $4}')"
(( free_kb > 5 * 1024 * 1024 )) || die "部署目录所在磁盘剩余不足 5G，备份与新镜像放不下"

if [[ "$assume_yes" != true ]]; then
  echo
  echo "即将升级到镜像标签 $image_tag。升级期间站点会中断数分钟。"
  [[ "$need_account_upgrade" == true ]] && echo "将停止控制面与 Storage 节点 ${storage_nodes[*]}，执行网盘账号离线迁移。"
  read -r -p "继续？[y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "已取消"
fi

# ── 3. 拉取镜像 ────────────────────────────────────────────────────────────
step "3/8 拉取镜像（$image_tag）"
declare -A old_images=()
for service in license-agent "${APP_SERVICES[@]}"; do
  cid="$(compose ps -a -q "$service" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] && old_images[$service]="$(docker inspect --format '{{.Image}}' "$cid")"
done
compose pull license-agent "${APP_SERVICES[@]}"
if [[ "$need_account_upgrade" == true ]]; then
  docker pull "$migrate_image"
  docker run --rm --entrypoint /usr/bin/test "$migrate_image" -f /opt/yiyi/migrate_cloud_accounts.py \
    || die "$migrate_image 不含账号迁移工具，请确认镜像标签"
fi
ok "镜像就绪"

# ── 4. 备份 ────────────────────────────────────────────────────────────────
step "4/8 备份"
backup="$backup_root/pre-upgrade-$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$backup"
for database in "${YIYI_DATABASES[@]}"; do
  pg_tool pg_dump -Fc -d "$database" > "$backup/$database.dump"
  chmod 0600 "$backup/$database.dump"
  pg_tool pg_restore --list < "$backup/$database.dump" >/dev/null || die "$database 备份校验失败"
done
tar_items=(.env config)
[[ -d "$data_dir/license" ]] && tar_items+=("$data_dir/license")
[[ -d "$data_dir/config/uploads" ]] && tar_items+=("$data_dir/config/uploads")
tar czf "$backup/deploy-files.tar.gz" "${tar_items[@]}" 2>/dev/null
chmod 0600 "$backup/deploy-files.tar.gz"
for service in "${!old_images[@]}"; do printf '%s=%s\n' "$service" "${old_images[$service]}"; done > "$backup/old-images"
git rev-parse HEAD > "$backup/deploy-commit"
chmod 0600 "$backup/old-images" "$backup/deploy-commit"
ok "备份完成：$backup（$(du -sh "$backup" | cut -f1)）"

# ── 回滚：恢复数据库 + 旧镜像 + 旧 Storage 节点 ────────────────────────────
rollback_armed=false
stopped_nodes=()
rollback() {
  [[ "$rollback_armed" == true ]] || return 0
  rollback_armed=false
  warn "升级失败，正在恢复到升级前状态（备份：$backup）"
  compose stop "${APP_SERVICES[@]}" >/dev/null 2>&1 || true
  local database ok_restore=true
  for database in "${YIYI_DATABASES[@]}"; do
    # --clean 不会删掉新版本新增的表 / 外键，所以整库重建：先恢复到旁边的新库，成功后才换掉原库，
    # 任何一步失败原库都还在。新库用 template0：宿主 glibc 升级后 template1 常带
    # "collation version mismatch"，PostgreSQL 16 会直接拒绝以它为模板建库（生产 HK1 实测）。
    if ! db_psql postgres "DROP DATABASE IF EXISTS ${database}_rollback WITH (FORCE);" >/dev/null \
      || ! db_psql postgres "CREATE DATABASE ${database}_rollback TEMPLATE template0;" >/dev/null \
      || ! pg_tool pg_restore --exit-on-error -d "${database}_rollback" < "$backup/$database.dump" >/dev/null 2>&1 \
      || ! db_psql postgres "DROP DATABASE $database WITH (FORCE);" >/dev/null \
      || ! db_psql postgres "ALTER DATABASE ${database}_rollback RENAME TO $database;" >/dev/null; then
      ok_restore=false; break
    fi
  done
  if [[ "$ok_restore" != true ]]; then
    warn "数据库自动恢复失败：控制面保持停止，请人工用 $backup 里的 dump 恢复"
    return 1
  fi
  cp "$backup/.env.before" .env 2>/dev/null || true
  local override="$backup/rollback.yaml" service
  {
    echo "services:"
    for service in "${!old_images[@]}"; do
      printf '  %s:\n    image: %s\n' "$service" "${old_images[$service]}"
    done
  } > "$override"
  if (( ${#old_images[@]} > 0 )); then
    compose -f "$override" up -d --no-deps --force-recreate "${!old_images[@]}" || warn "旧版控制面启动失败"
  else
    warn "未记录到升级前的容器镜像，控制面保持停止；请按 $backup/deploy-commit 人工回退"
  fi
  for id in "${stopped_nodes[@]}"; do
    case "$(node_kind "$id")" in
      docker) docker start "$id" >/dev/null || warn "节点 $id 启动失败" ;;
      binary) systemctl start "$id" || warn "节点 $id 启动失败" ;;
    esac
  done
  warn "已恢复为升级前版本；备份保留在 $backup"
}
trap 'rc=$?; if (( rc != 0 )); then rollback || true; fi; exit $rc' EXIT
cp .env "$backup/.env.before"; chmod 0600 "$backup/.env.before"

# ── 5. 账号离线迁移 ────────────────────────────────────────────────────────
if [[ "$need_account_upgrade" == true ]]; then
  step "5/8 网盘账号离线迁移"
  rollback_armed=true
  compose stop "${APP_SERVICES[@]}"
  for id in "${local_storage[@]}"; do
    case "$(node_kind "$id")" in
      docker) docker stop "$id" >/dev/null ;;
      binary) systemctl stop "$id" ;;
    esac
    stopped_nodes+=("$id")
    ok "已停止 Storage 节点 $id"
  done
  # 迁移工具要用 media 的加密主密钥把旧凭据加密进账号资产表：先确保 .env 里有它。
  # install.sh 里有同一套「库里已有加密凭据就绝不生成新密钥」的保护。
  key="$(env_value .env YIYI_CREDENTIAL_MASTER_KEY)"
  if [[ -z "$key" || "$key" == GENERATE_ON_INSTALL ]]; then
    for table in t_cloud_account_asset_credential t_user_cloud_credential; do
      if [[ "$(db_psql yiyi_media "SELECT to_regclass('public.$table') IS NOT NULL;")" == t ]] \
        && [[ "$(db_psql yiyi_media "SELECT count(*) FROM $table;")" != 0 ]]; then
        die "库里已有加密凭据但 .env 缺少 YIYI_CREDENTIAL_MASTER_KEY，不能生成新密钥"
      fi
    done
    set_env_value .env YIYI_CREDENTIAL_MASTER_KEY "$(openssl rand -base64 32)"
    ok "已生成云盘凭据主密钥（写入 .env）"
  fi
  envfile="$(mktemp "$backup/migrate.env.XXXXXX")"
  chmod 0600 "$envfile"
  db_host="$(env_value .env YIYI_DB_HOST)"; db_port="$(env_value .env YIYI_DB_PORT)"
  {
    echo "YIYI_DB_HOST=${db_host:-127.0.0.1}"
    echo "YIYI_DB_PORT=${db_port:-5432}"
    echo "YIYI_DB_USER=$db_user"
    echo "YIYI_DB_PASSWORD=$(env_value .env YIYI_DB_PASSWORD)"
    echo "YIYI_CREDENTIAL_MASTER_KEY=$(env_value .env YIYI_CREDENTIAL_MASTER_KEY)"
    echo "YIYI_EMBEDDED_STORAGE_NODE_ID=${storage_nodes[0]}"
  } > "$envfile"
  rc=0
  docker run --rm --network host --env-file "$envfile" --entrypoint python3 \
    "$migrate_image" /opt/yiyi/migrate_cloud_accounts.py || rc=$?
  rm -f "$envfile"
  (( rc == 0 )) || die "账号迁移失败（输出已按设计脱敏）"
  ok "账号迁移完成"
else
  step "5/8 网盘账号离线迁移（无旧数据，跳过）"
fi

# ── 6. 重建控制面 ──────────────────────────────────────────────────────────
step "6/8 重建控制面（install.sh）"
rollback_armed=true
YIYI_CALLED_BY_UPGRADE=1 ./install.sh 2>&1 | tee "$backup/install.log"
[[ "${PIPESTATUS[0]}" == 0 ]] || die "install.sh 失败，日志：$backup/install.log"
rollback_armed=false   # 控制面已用新版本跑起来，后面的节点升级失败不回滚数据库
ok "控制面已是新版本"

# ── 7. 升级节点 ────────────────────────────────────────────────────────────
step "7/8 升级节点"
remote_nodes=() failed_nodes=()
base_url="http://127.0.0.1:18085/api/config/nodes/install"
if [[ "$skip_nodes" == true ]]; then
  warn "已按 --skip-nodes 跳过；Storage 节点在升级前必须保持停止（旧版不能用新库）"
else
  for entry in "${managed_nodes[@]}"; do
    IFS='|' read -r id service <<< "$entry"
    kind="$(node_kind "$id")"
    if [[ "$kind" == remote ]]; then remote_nodes+=("$id ($service)"); continue; fi
    node_token="$(db_psql yiyi_config "SELECT token FROM t_config_managed_node WHERE node_id='$id'")"
    script="$(mktemp "$backup/node-$id.XXXXXX.sh")"; chmod 0600 "$script"
    # URL 含节点令牌：经 stdin 交给 curl，不出现在命令行参数（ps）里。
    if ! printf 'url = "%s/%s/upgrade-%s"\n' "$base_url" "$node_token" "$kind" \
        | curl -fsS --max-time 30 --config - -o "$script"; then
      failed_nodes+=("$id"); rm -f "$script"; warn "$id 取升级脚本失败"; continue
    fi
    log="$backup/node-$id.log"
    if bash "$script" 2>&1 | redact | tee "$log" | tail -n 3; [[ "${PIPESTATUS[0]}" == 0 ]]; then
      ok "$id（$service，$kind）升级完成"
    else
      failed_nodes+=("$id"); warn "$id 升级失败，日志：$log"
    fi
    rm -f "$script"
  done
fi

# ── 8. 验证 ────────────────────────────────────────────────────────────────
step "8/8 验证"
compose ps --format 'table {{.Service}}\t{{.Status}}'
license="$(curl -fsS --max-time 5 http://127.0.0.1:18085/api/license/status \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)"
[[ "$license" == ACTIVE || "$license" == GRACE ]] && ok "许可证 $license" || warn "许可证状态：${license:-不可达}"
sleep 20
alive="$(db_psql yiyi_config "SELECT service_name || ' ' || host || ':' || port || ' ' || CASE WHEN expires_at > now() THEN 'online' ELSE 'OFFLINE' END FROM t_config_service_instance ORDER BY 1" 2>/dev/null || true)"
[[ -n "$alive" ]] && printf '  %s\n' "${alive//$'\n'/$'\n'  }"
unauthorized="$(docker logs --since 2m "$(compose ps -q config)" 2>&1 | grep -ciE '401 Unauthorized|unauthorized' || true)"
(( unauthorized == 0 )) && ok "config 近 2 分钟无 401" || warn "config 近 2 分钟出现 $unauthorized 条 401：检查节点是否已升级"

echo
echo "升级完成。镜像标签：$image_tag    备份：$backup"
if (( ${#remote_nodes[@]} > 0 )); then
  echo
  echo "以下节点在其它主机上，请在网页「节点管理」逐个点「一键远程升级」"
  echo "（检测失败时用节点详情里的「完整安装命令」到节点主机上执行）："
  printf '  - %s\n' "${remote_nodes[@]}"
fi
if (( ${#failed_nodes[@]} > 0 )); then
  echo
  warn "这些本机节点自动升级失败：${failed_nodes[*]}（日志在 $backup/node-*.log）"
  exit 3
fi
