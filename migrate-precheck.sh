#!/usr/bin/env bash
#
# YiYi Media 迁移只读预检与影响报告（计划 §13.2、§13.3）。
#
# 适用模式：把现有部署迁入单机版三容器形态之前的**只读**预检。
# 决策依据见 MIGRATION.md。
#
# 本脚本的设计原则：
#   * 默认**只读**：只查询、只统计、只输出报告；不停止、不删除、不修改任何数据；
#   * 迁移前的只读预检必须在旧服务仍运行时执行（§13.2 第 1 步）；
#   * 任何写操作（仅备份）都需要显式参数确认；
#   * **绝不删除客户数据**：本脚本不包含任何 DELETE / DROP / rm 客户数据的路径。
#
# 用法：
#   ./migrate-precheck.sh [选项]
#
# 常用选项：
#   --report FILE              报告输出路径，默认 migration-report-<UTC时间戳>.md
#   --json FILE                额外输出 JSON 摘要（供自动化消费）
#   --postgres-container NAME  指定承载 yiyi_config/yiyi_user/yiyi_media 的容器
#   --storage-postgres-container NAME
#                              指定承载 yiyi_storage 的容器（独立实例时使用）
#   --db-host HOST --db-port N --db-user USER
#                              直接连接可达的 PostgreSQL（不通过容器）
#   --backup                   额外生成一次完整备份（写操作，需再给 --confirm-backup）
#   --confirm-backup           确认执行备份；没有它时 --backup 会被拒绝
#   --help                     显示帮助
#
# 退出码：
#   0  预检完成，且两类节点都各不超过一个（可走 §13.2 自动迁移路径）
#   1  预检失败（环境不满足 / 无法连接数据库）
#   3  检测到多节点，自动迁移必须停止，需要管理员明确选择（§13.3）
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DEPLOY_DIR"

COMPOSE_STANDALONE="$DEPLOY_DIR/compose.yaml"
COMPOSE_DISTRIBUTED="$DEPLOY_DIR/compose.distributed.yaml"
COMPOSE_PROJECT="yiyi"

# 旧一代（同机多容器 / 分布式角色）服务名。出现任意一个即说明是迁移源。
LEGACY_SERVICES="license-agent license-sync config user media gateway frontend"

# 单机版目标内置节点 ID（计划 §7.1）。
EMBEDDED_STORAGE_ID="node-local-storage"
EMBEDDED_PLAY_AGENT_ID="node-local-play-agent"

# 四个业务库（计划 §6）。
DATABASES=(yiyi_config yiyi_user yiyi_media yiyi_storage)

# 需要统计引用的 (库, 表, 列, 人类可读含义)。
# 查询前会用 to_regclass 判断表是否存在，避免在旧版本库结构上直接报错。
NODE_REFERENCE_COLUMNS=(
  "yiyi_media|t_media_central_library_source|node_id|媒体库的存储来源"
  "yiyi_media|t_media_central_sync_item|node_id|媒体同步项"
  "yiyi_media|t_media_central_sync_stream|node_id|媒体同步流"
  "yiyi_media|t_storage_direct_link_cache|node_id|直链缓存"
  "yiyi_media|t_storage_provider_credential|node_id|网盘凭证"
  "yiyi_media|t_storage_provider_credential_account|node_id|网盘凭证账号"
  "yiyi_media|t_media_organizer_node_task|node_id|整理任务节点分片"
  "yiyi_user|t_user_media_source_grant|node_id|用户媒体源授权"
  "yiyi_user|t_playback_traffic_usage_daily|node_id|播放流量统计"
)

# 需要统计的 play-agent 引用列。
PLAY_AGENT_REFERENCE_COLUMNS=(
  "yiyi_user|t_user_emby_session|play_agent_node_id|Emby 会话的播放出口"
  "yiyi_media|t_virtual_library|bound_node_id|虚拟库绑定的播放节点"
)

report_file=""
json_file=""
postgres_container=""
storage_postgres_container=""
db_host=""
db_port=""
db_user=""
do_backup=false
confirm_backup=false

usage() {
  cat <<'EOF'
YiYi Media 迁移只读预检与影响报告（计划 §13.2、§13.3）。

适用模式：把现有部署迁入单机版三容器形态之前的**只读**预检。决策依据见 MIGRATION.md。

设计原则：
  * 默认**只读**：只查询、只统计、只输出报告；不停止、不删除、不修改任何数据；
  * 只读预检必须在旧服务仍运行时执行（§13.2 第 1 步）；
  * 写操作（仅可选备份）需要显式参数确认；
  * **绝不删除客户数据**：本脚本不包含任何 DELETE / DROP / rm 客户数据的路径。

用法：
  ./migrate-precheck.sh [选项]

选项：
  --report FILE                报告输出路径，默认 migration-report-<UTC时间戳>.md
  --json FILE                  额外输出 JSON 摘要（供自动化消费）
  --postgres-container NAME    承载 yiyi_config / yiyi_user / yiyi_media 的容器
  --storage-postgres-container NAME
                               承载 yiyi_storage 的容器（独立实例时使用）
  --db-host HOST --db-port N --db-user USER
                               直接连接可达的 PostgreSQL（不通过容器）
  --backup                     额外生成一次完整备份（写操作）
  --confirm-backup             确认执行备份；没有它时 --backup 会被拒绝
  --help                       显示本帮助

退出码：
  0  预检完成，两类节点都各不超过一个（可走 §13.2 迁移路径）
  1  预检失败，或数据库不可达导致节点数量无法判定
  3  检测到任一类型节点超过一个，自动迁移必须停止（§13.3）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) report_file="${2:?--report 需要一个路径}"; shift 2 ;;
    --json) json_file="${2:?--json 需要一个路径}"; shift 2 ;;
    --postgres-container) postgres_container="${2:?}"; shift 2 ;;
    --storage-postgres-container) storage_postgres_container="${2:?}"; shift 2 ;;
    --db-host) db_host="${2:?}"; shift 2 ;;
    --db-port) db_port="${2:?}"; shift 2 ;;
    --db-user) db_user="${2:?}"; shift 2 ;;
    --backup) do_backup=true; shift ;;
    --confirm-backup) confirm_backup=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "未知选项：$1" >&2
      echo "执行 ./migrate-precheck.sh --help 查看用法。" >&2
      exit 2
      ;;
  esac
done

if [[ "$do_backup" == true && "$confirm_backup" != true ]]; then
  cat >&2 <<'EOF'
--backup 是写操作，必须显式确认。

备份只会新建文件，不会修改或删除任何现有数据。确认要执行时再加 --confirm-backup：

  ./migrate-precheck.sh --backup --confirm-backup
EOF
  exit 2
fi

timestamp="$(date -u +%Y%m%d-%H%M%S)"
[[ -n "$report_file" ]] || report_file="$DEPLOY_DIR/migration-report-$timestamp.md"

# ── 只读查询封装 ────────────────────────────────────────────────────────────
#
# 三种连接方式，优先级：
#   1) --db-host 指定的可达实例（psql 直连）
#   2) --postgres-container / 自动探测到的容器（docker exec）
#   3) 若都没有，则跳过数据库统计并明确标注"未采集"。
psql_client=""
if command -v psql >/dev/null 2>&1; then
  psql_client="psql"
fi

container_exec_sql() {
  local container="$1" database="$2" sql="$3"
  docker exec -i "$container" \
    psql -v ON_ERROR_STOP=1 -U "$db_user" -d "$database" -tAc "$sql" 2>/dev/null
}

direct_sql() {
  local database="$1" sql="$2"
  PGPASSWORD="${YIYI_DB_PASSWORD:-}" psql -v ON_ERROR_STOP=1 \
    -h "$db_host" -p "$db_port" -U "$db_user" -d "$database" -tAc "$sql" 2>/dev/null
}

sql_count() {
  local database="$1" sql="$2"
  if [[ -n "$db_host" ]]; then
    direct_sql "$database" "$sql"
  elif [[ -n "$postgres_container" ]]; then
    container_exec_sql "$postgres_container" "$database" "$sql"
  else
    return 1
  fi
}

sql_count_storage() {
  local database="$1" sql="$2"
  if [[ -n "$storage_postgres_container" ]]; then
    container_exec_sql "$storage_postgres_container" "$database" "$sql"
  elif [[ -n "$db_host" && -z "$postgres_container" ]]; then
    direct_sql "$database" "$sql"
  else
    sql_count "$database" "$sql"
  fi
}

# 表存在才统计，避免旧库结构差异导致失败。
table_count() {
  local database="$1" table="$2" column="$3" where="${4:-}"
  local sql
  sql="SELECT CASE WHEN to_regclass('public.${table}') IS NULL THEN 'NA'"
  sql+=" ELSE COALESCE((SELECT COUNT(*) FROM ${table}"
  sql+=" WHERE ${column} IS NOT NULL${where:+ AND ${where}}), 0)::text END"
  if [[ "$database" == "yiyi_storage" ]]; then
    sql_count_storage "$database" "$sql"
  else
    sql_count "$database" "$sql"
  fi
}

# ── 采集：容器与旧拓扑 ──────────────────────────────────────────────────────
legacy_found=()
legacy_containers=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  legacy_containers="$(docker ps -a \
    --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
    --format '{{.Label "com.docker.compose.service"}}|{{.Names}}|{{.Status}}' 2>/dev/null || true)"
  local_services="$(printf '%s\n' "$legacy_containers" | cut -d'|' -f1 | sed '/^$/d' | LC_ALL=C sort -u)"
  for legacy in $LEGACY_SERVICES; do
    if printf '%s\n' "$local_services" | grep -Fxq "$legacy"; then
      legacy_found+=("$legacy")
    fi
  done
  docker_available=true
else
  docker_available=false
fi

# Docker 不可用时如实标注，并说明改用哪种静态检查替代。
docker_note=""
if [[ "$docker_available" != true ]]; then
  docker_note="Docker daemon 不可用：跳过容器与命名卷探测，仅做文件与数据库统计（如可连接）。"
fi

# ── 采集：数据目录 ──────────────────────────────────────────────────────────
data_dir="$(awk -F= '$1 == "YIYI_DATA_DIR" {sub(/^[^=]*=/, ""); print; exit}' .env 2>/dev/null || true)"
if [[ -z "$data_dir" ]]; then
  data_dir="$DEPLOY_DIR/data"
elif [[ "$data_dir" != /* ]]; then
  data_dir="$DEPLOY_DIR/$data_dir"
fi
postgres_data_dir="$data_dir/postgres"

pg_version=""
if [[ -f "$postgres_data_dir/PG_VERSION" ]]; then
  pg_version="$(tr -d '[:space:]' < "$postgres_data_dir/PG_VERSION")"
fi

data_dir_entries=""
if [[ -d "$data_dir" ]]; then
  data_dir_entries="$(find "$data_dir" -mindepth 1 -maxdepth 2 -type d -print 2>/dev/null \
    | sed "s|^$data_dir/||" | LC_ALL=C sort || true)"
fi

# 旧一代数据目录标记（用于区分"已迁入单机版"与"仍是旧形态"）。
license_identity_present=false
storage_data_present=false
play_agent_cache_present=false
[[ -d "$data_dir/license/identity" ]] && license_identity_present=true
[[ -d "$data_dir/storage" ]] && storage_data_present=true
[[ -d "$data_dir/play-agent" ]] && play_agent_cache_present=true

# ── 采集：数据库 ────────────────────────────────────────────────────────────
declare -a node_rows=()
declare -a ref_rows=()
declare -a play_rows=()

if [[ -z "$db_user" ]]; then
  db_user="$(awk -F= '$1 == "YIYI_DB_USER" {sub(/^[^=]*=/, ""); print; exit}' .env 2>/dev/null || true)"
  db_user="${db_user:-yiyi}"
fi

db_reachable=false
db_note=""
if [[ -n "$db_host" ]]; then
  db_port="${db_port:-5432}"
  db_note="直连 PostgreSQL ${db_host}:${db_port}（用户 ${db_user}）"
elif [[ -n "$postgres_container" ]]; then
  db_note="通过容器 $postgres_container 执行 psql"
elif [[ "$docker_available" == true ]]; then
  detected="$(docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
    --filter "label=com.docker.compose.service=postgres" --format '{{.Names}}' 2>/dev/null | head -1)"
  if [[ -n "$detected" ]]; then
    postgres_container="$detected"
    db_note="自动探测到 PostgreSQL 容器 $detected"
  fi
fi

# 判断数据库是否可达：能读到 yiyi* 库清单即认为可达。
if [[ -n "$db_host" || -n "$postgres_container" ]]; then
  existing_dbs="$(sql_count postgres "SELECT datname FROM pg_database WHERE datname LIKE 'yiyi%' ORDER BY datname" || true)"
  if [[ -n "$existing_dbs" ]]; then
    db_reachable=true
  fi
fi
if [[ "$db_reachable" != true ]]; then
  db_note="${db_note:+${db_note}；}数据库统计未采集（只读预检要求旧服务仍在运行，"
  db_note+="或显式给出 --db-host / --postgres-container）"
fi

# 受管节点清单：迁移的关键输入（计划 §7.2、§13.2、§13.3）。
node_total=0
storage_nodes=0
play_agent_nodes=0
node_list_raw=""
if [[ "$db_reachable" == true ]]; then
  node_list_raw="$(sql_count yiyi_config "
    SELECT node_id || '|' || COALESCE(service_name,'') || '|' || COALESCE(enabled::text,'')
    FROM t_config_managed_node
    WHERE to_regclass('public.t_config_managed_node') IS NOT NULL
    ORDER BY service_name, node_id" || true)"
  while IFS='|' read -r node_id service_name enabled; do
    [[ -n "$node_id" ]] || continue
    node_total=$((node_total + 1))
    case "$service_name" in
      YiYi-control-storage) storage_nodes=$((storage_nodes + 1)) ;;
      YiYi-play-agent)      play_agent_nodes=$((play_agent_nodes + 1)) ;;
    esac
    node_rows+=("$node_id|$service_name|${enabled:-true}")
  done <<< "$node_list_raw"
fi

# 引用统计。
if [[ "$db_reachable" == true ]]; then
  for spec in "${NODE_REFERENCE_COLUMNS[@]}"; do
    IFS='|' read -r database table column label <<< "$spec"
    count="$(table_count "$database" "$table" "$column" || true)"
    [[ -n "$count" ]] || count="NA"
    ref_rows+=("$label|$database.$table.$column|$count")
  done
  for spec in "${PLAY_AGENT_REFERENCE_COLUMNS[@]}"; do
    IFS='|' read -r database table column label <<< "$spec"
    count="$(table_count "$database" "$table" "$column" || true)"
    [[ -n "$count" ]] || count="NA"
    play_rows+=("$label|$database.$table.$column|$count")
  done
fi

# 手动反代地址（两种模式共有能力，迁移时必须完整保留）。
manual_endpoint_count="NA"
if [[ "$db_reachable" == true ]]; then
  manual_endpoint_count="$(sql_count yiyi_config "
    SELECT CASE WHEN to_regclass('public.t_config_manual_play_agent_endpoint') IS NULL THEN 'NA'
    ELSE (SELECT COUNT(*) FROM t_config_manual_play_agent_endpoint)::text END" || true)"
  [[ -n "$manual_endpoint_count" ]] || manual_endpoint_count="NA"
fi

# ── 判定 ────────────────────────────────────────────────────────────────────
decision="PROCEED"
decision_reason="两类节点都各不超过一个，可按 §13.2 走迁移流程（仍需完整备份与人工验证）。"
if [[ "$db_reachable" == true ]]; then
  if (( storage_nodes > 1 || play_agent_nodes > 1 )); then
    decision="STOP_MULTI_NODE"
    decision_reason="检测到任一类型超过一个节点，自动迁移必须停止（§13.3）。"
  elif (( node_total == 0 )); then
    decision="NO_NODES"
    decision_reason="未检测到任何受管节点：这更像全新安装，而不是迁移；请确认是否用错部署目录。"
  fi
else
  decision="UNKNOWN"
  decision_reason="未能连接旧数据库，节点数量无法判定；请让旧服务保持运行后重跑本预检。"
fi

# 结论下方的醒目提示。必须是纯文本（不做命令替换），否则会被当作命令执行。
decision_callout=""
case "$decision" in
  STOP_MULTI_NODE)
    decision_callout="> **自动迁移已停止（§13.3）。** 必须先由管理员明确选择保留哪个 Storage 与哪个
> Play Agent，再按 MIGRATION.md 的多节点流程处理。未选中的节点先禁用并保留记录，
> **不立即删除**。本期不做多个 Storage 数据库的自动合并，也不做多节点媒体库引用的自动重写。"
    ;;
  UNKNOWN)
    decision_callout="> 请让旧服务保持运行（只读预检本就是迁移第 1 步），或显式提供
> --db-host / --postgres-container 后重新执行本脚本，再据报告决策。"
    ;;
  NO_NODES)
    decision_callout="> 未检测到受管节点。若这确实是迁移场景，请确认旧数据库连接是否正确；
> 若这是全新安装，直接按 README.md 的单机版安装流程执行即可。"
    ;;
  PROCEED)
    decision_callout="> 可继续，但**先做完整备份**，并且旧容器与旧配置在验收完成前必须保留（§13.4）。"
    ;;
esac

# ── 写报告 ──────────────────────────────────────────────────────────────────
emit_report() {
  cat <<EOF
# YiYi Media 迁移影响报告（只读预检）

- 生成时间（UTC）：$timestamp
- 部署目录：\`$DEPLOY_DIR\`
- 预检脚本：\`migrate-precheck.sh\`（默认只读，不修改任何数据）

> 本报告只描述现状与影响面，**不执行任何迁移动作**，也不会删除任何数据。
> 迁移步骤与回滚点见 \`MIGRATION.md\`。

## 一、结论

| 项目 | 结果 |
| --- | --- |
| 迁移判定 | **$decision** |
| 说明 | $decision_reason |

$decision_callout

## 二、当前拓扑

| 项目 | 值 |
| --- | --- |
| Docker daemon | $(if [[ "$docker_available" == true ]]; then echo "可用"; else echo "不可用"; fi) |
| 检测到的旧拓扑服务 | $(if [[ ${#legacy_found[@]} -gt 0 ]]; then printf '%s ' "${legacy_found[@]}"; else echo "无"; fi) |
| 数据根目录 | \`$data_dir\` |
| PostgreSQL 数据目录版本 | ${pg_version:-未检测到（可能未使用内置 PostgreSQL）} |
| 许可证身份目录 | $(if [[ "$license_identity_present" == true ]]; then echo "存在（备份必须包含）"; else echo "未检测到"; fi) |
| Storage 数据目录 | $(if [[ "$storage_data_present" == true ]]; then echo "存在"; else echo "未检测到"; fi) |
| Play Agent 缓存目录 | $(if [[ "$play_agent_cache_present" == true ]]; then echo "存在"; else echo "未检测到"; fi) |

EOF

  if [[ -n "$docker_note" ]]; then
    echo "> $docker_note"
    echo
  fi

  if [[ -n "$legacy_containers" ]]; then
    echo "### 容器清单（Compose 项目 ${COMPOSE_PROJECT}）"
    echo
    echo "| 服务 | 容器 | 状态 |"
    echo "| --- | --- | --- |"
    while IFS='|' read -r service name status; do
      [[ -n "$service" ]] || continue
      echo "| \`$service\` | \`$name\` | $status |"
    done <<< "$legacy_containers"
    echo
  fi

  if [[ -n "$data_dir_entries" ]]; then
    echo "### 数据目录（前两层）"
    echo
    echo '```text'
    printf '%s\n' "$data_dir_entries"
    echo '```'
    echo
  fi

  cat <<EOF
## 三、受管节点（迁移的关键输入）

数据库采集：$db_note

| 类型 | 数量 |
| --- | ---: |
| Storage 节点（\`YiYi-control-storage\`） | $(if [[ "$db_reachable" == true ]]; then echo "$storage_nodes"; else echo "未采集"; fi) |
| Play Agent 节点（\`YiYi-play-agent\`） | $(if [[ "$db_reachable" == true ]]; then echo "$play_agent_nodes"; else echo "未采集"; fi) |
| 受管节点合计 | $(if [[ "$db_reachable" == true ]]; then echo "$node_total"; else echo "未采集"; fi) |
| 手动反代地址 | $(if [[ "$manual_endpoint_count" == "NA" ]]; then echo "未采集"; else echo "$manual_endpoint_count"; fi) |

EOF

  if [[ ${#node_rows[@]} -gt 0 ]]; then
    echo "| 节点 ID | 服务 | 当前启用 | 迁移建议 |"
    echo "| --- | --- | --- | --- |"
    for row in "${node_rows[@]}"; do
      IFS='|' read -r node_id service_name enabled <<< "$row"
      case "$service_name" in
        YiYi-control-storage)
          if (( storage_nodes > 1 )); then
            hint="**多节点：需管理员选择保留哪一个**，未选中的先禁用并保留记录"
          else
            hint="沿用原节点 ID；单机版内置 Storage 的固定 ID 是 \`$EMBEDDED_STORAGE_ID\`"
          fi
          ;;
        YiYi-play-agent)
          if (( play_agent_nodes > 1 )); then
            hint="**多节点：需管理员选择保留哪一个**，未选中的先禁用并保留记录"
          else
            hint="沿用原节点 ID；单机版内置 Play Agent 的固定 ID 是 \`$EMBEDDED_PLAY_AGENT_ID\`"
          fi
          ;;
        *)
          hint="非内置类型：按 §13.3 人工确认，不自动删除"
          ;;
      esac
      echo "| \`$node_id\` | \`$service_name\` | ${enabled:-true} | $hint |"
    done
    echo
  fi

  cat <<'EOF'
> **节点 ID 是迁移成功与否的核心（计划 §7.2、§13.2）。**
> 媒体源、用户播放线路授权、手动反代地址与历史任务都通过节点 ID 关联；
> 迁移的目标是**沿用原 ID**，而不是新建节点。ID 一旦改变，这些引用会全部失联。

## 四、影响面统计

以下计数是"如果选错保留节点会失联的引用数量"，用于评估人工决策的影响范围。

EOF

  if [[ ${#ref_rows[@]} -gt 0 ]]; then
    echo "| 引用对象 | 位置 | 记录数 |"
    echo "| --- | --- | ---: |"
    for row in "${ref_rows[@]}"; do
      IFS='|' read -r label location count <<< "$row"
      echo "| $label | \`$location\` | $count |"
    done
    echo
  else
    echo "_Storage 引用统计未采集：${db_note}_"
    echo
  fi
  if [[ ${#play_rows[@]} -gt 0 ]]; then
    echo "| 播放出口引用 | 位置 | 记录数 |"
    echo "| --- | --- | ---: |"
    for row in "${play_rows[@]}"; do
      IFS='|' read -r label location count <<< "$row"
      echo "| $label | \`$location\` | $count |"
    done
    echo
  fi

  cat <<'EOF'
> `NA` 表示该表在当前版本中不存在（旧版本库结构差异），不是 0。
> 计数为只读统计，不写入数据库。

## 五、下一步

1. **完整备份**（迁移前必须做，见 `OPERATIONS.md`「备份」）：
   四个数据库、`data/license/`、`data/config/uploads/`、Storage 持久化数据目录。
   `read-cache`、`vfs-cache`、`image-cache` 属可重建缓存，可按恢复策略选择；
   `storage/spool/` 里可能有尚未上传完成的文件，**必须保留**，不能与缓存混为一类。
2. **多节点时先做人工选择**，不要继续自动迁移。
3. 按 `MIGRATION.md` 的对应流程执行；旧容器与旧配置在验收完成前**保留**。
4. 只有验证通过后才移除旧容器/进程，并且**手工**执行，不用破坏性清理命令。
EOF
}

emit_report > "$report_file"
chmod 0600 "$report_file"

# ── JSON 摘要 ───────────────────────────────────────────────────────────────
if [[ -n "$json_file" ]]; then
  python3 - "$json_file" <<PY
import json, sys

def to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

summary = {
    "generatedAtUtc": "$timestamp",
    "deployDir": "$DEPLOY_DIR",
    "decision": "$decision",
    "databasesReachable": $(if [[ "$db_reachable" == true ]]; then echo "True"; else echo "False"; fi),
    "dockerAvailable": $(if [[ "$docker_available" == true ]]; then echo "True"; else echo "False"; fi),
    "legacyServices": [$(if [[ ${#legacy_found[@]} -gt 0 ]]; then printf '"%s",' "${legacy_found[@]}" | sed 's/,$//'; fi)],
    "storageNodes": to_int("$storage_nodes"),
    "playAgentNodes": to_int("$play_agent_nodes"),
    "managedNodesTotal": to_int("$node_total"),
    "manualEndpoints": to_int("$manual_endpoint_count"),
    "postgresDataVersion": "$pg_version" or None,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(summary, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
  chmod 0600 "$json_file"
fi

# ── 可选备份（写操作，已显式确认）───────────────────────────────────────────
if [[ "$do_backup" == true ]]; then
  backup_dir="$DEPLOY_DIR/backups/$timestamp"
  umask 077
  install -d -m 0700 "$backup_dir"
  echo "开始备份到 ${backup_dir}（只新建文件，不修改源数据）"

  if [[ "$db_reachable" == true ]]; then
    for db in "${DATABASES[@]}"; do
      exists="$(sql_count postgres "SELECT 1 FROM pg_database WHERE datname='$db'" || true)"
      [[ "$(printf '%s' "$exists" | tr -d '[:space:]')" == "1" ]] || {
        echo "  跳过不存在的库：$db"
        continue
      }
      if [[ -n "$db_host" ]]; then
        PGPASSWORD="${YIYI_DB_PASSWORD:-}" pg_dump -h "$db_host" -p "$db_port" \
          -U "$db_user" -Fc "$db" > "$backup_dir/${db}.dump"
      else
        docker exec -i "$postgres_container" pg_dump -U "$db_user" -Fc "$db" \
          > "$backup_dir/${db}.dump"
      fi
      chmod 0600 "$backup_dir/${db}.dump"
      echo "  已备份数据库：$db"
    done
  else
    echo "  未连接数据库，跳过数据库备份（需旧服务运行或显式给出连接方式）" >&2
  fi

  # 文件类备份：仅打包必须保留的内容，缓存目录单独说明不强制。
  for relative in license config/uploads data/env; do
    source_path="$data_dir/${relative#data/}"
    [[ -e "$source_path" ]] || continue
    tar -czf "$backup_dir/$(echo "$relative" | tr '/' '-').tar.gz" -C "$(dirname "$source_path")" "$(basename "$source_path")"
    chmod 0600 "$backup_dir/$(echo "$relative" | tr '/' '-').tar.gz"
    echo "  已备份目录：$source_path"
  done

  if [[ -f "$DEPLOY_DIR/.env" ]]; then
    cp -p "$DEPLOY_DIR/.env" "$backup_dir/env.copy"
    chmod 0600 "$backup_dir/env.copy"
    echo "  已备份配置：.env（含凭据，0600）"
  fi

  cat <<EOF

备份完成：$backup_dir

注意：缓存目录（storage/read-cache、play-agent/vfs-cache、play-agent/image-cache）
是可按恢复策略选择是否备份的；storage/spool 属于必须保留的数据，不能与缓存混为一类。
磁盘数据量较大时请自行对 storage/ 做完整副本。
EOF
fi

echo "预检完成，报告已写入：$report_file"
[[ -n "$json_file" ]] && echo "JSON 摘要：$json_file"

case "$decision" in
  PROCEED) exit 0 ;;
  STOP_MULTI_NODE) exit 3 ;;
  *) exit 1 ;;
esac
