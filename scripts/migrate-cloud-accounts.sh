#!/usr/bin/env bash
# Sourced by install.sh; customer still executes only install.sh.
set -euo pipefail

account_upgrade_stop_application() {
  compose stop yiyi-media || return 1
  # A renamed yiyi-app service can be an orphan of the current Compose file.
  local container project service
  for container in YiYi-media YiYi-media-standalone; do
    project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || true)"
    [[ -n "$project" ]] || continue
    service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container" 2>/dev/null || true)"
    if [[ "$project" != yiyi || ( "$service" != yiyi-media && "$service" != yiyi-app ) ]]; then
      echo '同名容器不属于本单机部署，已中止迁移。' >&2
      return 1
    fi
    docker stop "$container" >/dev/null || return 1
  done
}

account_upgrade_key_valid() {
  printf '%s' "$1" | python3 -c 'import base64,sys; sys.exit(0 if len(base64.b64decode(sys.stdin.read(),validate=True)) == 32 else 1)' 2>/dev/null
}

account_upgrade_ensure_key() {
  local value table present count spec column recovered=""
  value="$(env_value "$DEPLOY_DIR/.env" YIYI_CREDENTIAL_MASTER_KEY)"
  if account_upgrade_key_valid "$value"; then
    return 0
  fi
  # 只自动处理缺失值和旧版随机生成的十六进制值，手填的其它错误仍需恢复原值。
  if [[ -n "$value" && "$value" != GENERATE_ON_INSTALL && ! "$value" =~ ^[0-9a-f]{64}$ ]]; then
    echo '凭据主密钥格式无效，升级已中止；不会覆盖已有值。' >&2
    return 1
  fi
  # 优先恢复旧容器里的有效密钥；不向终端或进程参数输出凭据。
  local container project service candidate
  for container in YiYi-media YiYi-media-standalone; do
    project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || true)"
    service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container" 2>/dev/null || true)"
    [[ "$project" == yiyi && ( "$service" == yiyi-media || "$service" == yiyi-app ) ]] || continue
    candidate="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null | awk 'index($0,"YIYI_CREDENTIAL_MASTER_KEY=")==1 {sub(/^[^=]*=/, "");print;exit}' || true)"
    if account_upgrade_key_valid "$candidate"; then
      recovered="$candidate"
      break
    fi
  done
  if [[ -z "$recovered" ]]; then
    # 包括云盘、转存分享、Emby 与 MoviePilot；任意一处有密文都不能换密钥。
    for spec in t_cloud_account_asset_credential:encrypted_payload t_user_cloud_credential:encrypted_payload \
                t_cloud_transfer_job:export_value t_pool_export_reference:export_value \
                t_media_emby_connection:encrypted_api_key t_media_moviepilot_connection:encrypted_callback_key; do
      table="${spec%:*}"; column="${spec#*:}"
      present="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_media \
        -c "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='$table' AND column_name='$column');")" || return 1
      if [[ "$present" == t ]]; then
        count="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_media \
          -c "SELECT count(*) FROM $table WHERE $column IS NOT NULL AND $column <> ''; ")" || return 1
        [[ "$count" =~ ^[0-9]+$ ]] || return 1
        if [[ "$count" != 0 ]]; then
          echo '已有加密数据但原主密钥缺失或无效，已安全中止；请恢复原密钥，不会生成新密钥覆盖。' >&2
          return 1
        fi
      elif [[ "$present" != f ]]; then return 1; fi
    done
    recovered="$(openssl rand -base64 32)" || return 1
    echo '已确认没有加密数据，初始化 Base64 凭据主密钥（已有有效密钥始终保留）。'
  else
    echo '已从原应用容器恢复凭据主密钥。'
  fi
  account_upgrade_key_valid "$recovered" || return 1
  set_env_value "$DEPLOY_DIR/.env" YIYI_CREDENTIAL_MASTER_KEY "$recovered"
  chmod 0600 "$DEPLOY_DIR/.env"
}

account_upgrade_restart_old() {
  if [[ -n "${account_upgrade_old_image:-}" ]]; then
    printf 'services:\n  yiyi-media:\n    image: %s\n' "$account_upgrade_old_image" >"$account_upgrade_backup/rollback.yaml"
    chmod 0600 "$account_upgrade_backup/rollback.yaml"
    compose -f "$account_upgrade_backup/rollback.yaml" up -d --no-deps --force-recreate --remove-orphans yiyi-media
  fi
}

account_upgrade_prepare() {
  local exists configured version_exists version=0 marker
  if [[ -n "${legacy_reason:-}" ]]; then
    echo '账号自动迁移只支持现有单机部署；不能同时执行分布式拓扑切换。' >&2
    return 1
  fi
  if [[ -f "$DEPLOY_DIR/.account-upgrade-backup" ]]; then
    IFS= read -r account_upgrade_backup <"$DEPLOY_DIR/.account-upgrade-backup"
    [[ "$account_upgrade_backup" == "$data_dir"/account-upgrade.* && -d "$account_upgrade_backup" ]] || return 1
    IFS= read -r account_upgrade_old_image <"$account_upgrade_backup/old-image"
    [[ -z "$account_upgrade_old_image" || "$account_upgrade_old_image" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    local saved_database
    for saved_database in "${YIYI_DATABASES[@]}"; do
      [[ -s "$account_upgrade_backup/$saved_database.dump" ]] || return 1
    done
    account_upgrade_backup_ready=true
  fi
  exists="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_storage \
    -c "SELECT to_regclass('public.t_storage_provider') IS NOT NULL;")"
  [[ "$exists" == f ]] && return 0
  [[ "$exists" == t ]] || return 1
  marker="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_storage \
    -c "SELECT to_regclass('yiyi_account_upgrade.state') IS NOT NULL;")"
  if [[ "$marker" == t ]]; then
    local phase
    phase="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_storage \
      -c "SELECT stage FROM yiyi_account_upgrade.state WHERE id=1;")"
    [[ "$phase" == COMPLETED ]] && return 0
    # An interrupted migration must never be treated as a new installation.
    echo '检测到未完成的迁移，将从数据库检查点续跑。'
  fi
  configured="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_storage \
    -c "SELECT count(*) FROM t_storage_provider WHERE enabled IS TRUE OR NULLIF(trim(root_path),'') IS NOT NULL OR COALESCE(NULLIF(trim(config_json),''),'{}') NOT IN ('{}','null');")"
  [[ "$configured" =~ ^[0-9]+$ ]] || return 1
  # Old structure can have durable data even without enabled providers. Do not skip its migration.
  version_exists="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_storage \
    -c "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL;")"
  if [[ "$version_exists" == t ]]; then
    version="$(compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d yiyi_storage \
      -c "SELECT COALESCE(max(version::integer),0) FROM flyway_schema_history WHERE success AND version ~ '^[0-9]+$';")"
  fi
  [[ "$version" =~ ^[0-9]+$ ]] || return 1
  if (( configured == 0 && version >= 544 )) && [[ "$marker" != t ]]; then return 0; fi
  # Verify candidate capability before stopping the old application. No workers/Flyway are started here.
  compose run --rm --no-deps --entrypoint /usr/bin/test yiyi-media -f /opt/yiyi/migrate_cloud_accounts.py >/dev/null
  if [[ "${account_upgrade_backup_ready:-false}" == true ]]; then
    account_upgrade_stop_application || return 1
    if ! compose run --rm --no-deps --entrypoint python3 yiyi-media /opt/yiyi/migrate_cloud_accounts.py; then
      account_upgrade_rollback
      return 1
    fi
    return 0
  fi
  account_upgrade_old_image="$(docker inspect --format '{{.Image}}' YiYi-media 2>/dev/null || true)"
  if [[ -z "$account_upgrade_old_image" ]]; then
    account_upgrade_old_image="$(docker inspect --format '{{.Image}}' YiYi-media-standalone 2>/dev/null || true)"
  fi
  account_upgrade_backup="$(mktemp -d "$data_dir/account-upgrade.XXXXXXXX")"
  chmod 0700 "$account_upgrade_backup"
  cp "$DEPLOY_DIR/.env" "$account_upgrade_backup/deployment.env"
  chmod 0600 "$account_upgrade_backup/deployment.env"
  account_upgrade_stop_application || return 1
  local database
  for database in "${YIYI_DATABASES[@]}"; do
    if ! compose exec -T postgres pg_dump -Fc -U "$db_user" -d "$database" >"$account_upgrade_backup/$database.dump"; then
      echo '自动备份失败；恢复旧应用，新版应用不会启动。' >&2
      account_upgrade_restart_old
      return 1
    fi
    chmod 0600 "$account_upgrade_backup/$database.dump"
    if ! compose exec -T postgres pg_restore --list <"$account_upgrade_backup/$database.dump" >/dev/null 2>/dev/null; then
      account_upgrade_restart_old
      return 1
    fi
  done
  echo "已创建受限权限的升级备份：$account_upgrade_backup"
  printf '%s\n' "$account_upgrade_old_image" >"$account_upgrade_backup/old-image"
  chmod 0600 "$account_upgrade_backup/old-image"
  printf '%s\n' "$account_upgrade_backup" >"$DEPLOY_DIR/.account-upgrade-backup"
  chmod 0600 "$DEPLOY_DIR/.account-upgrade-backup"
  account_upgrade_backup_ready=true
  if ! compose run --rm --no-deps --entrypoint python3 yiyi-media /opt/yiyi/migrate_cloud_accounts.py; then
    account_upgrade_rollback
    return 1
  fi
}

account_upgrade_rollback() {
  [[ "${account_upgrade_backup_ready:-false}" == true ]] || return 0
  echo '升级未完成，正在恢复升级前数据库与旧应用。' >&2
  account_upgrade_stop_application || return 1
  local database
  for database in "${YIYI_DATABASES[@]}"; do
    # Restoring with --clean alone leaves new tables/FKs not present in the old dump.
    # Recreate ONLY the four stopped application databases before restoring the full set.
    [[ "$database" =~ ^yiyi_(config|user|media|storage)$ ]] || return 1
    if ! compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d postgres \
      -c "DROP DATABASE IF EXISTS $database WITH (FORCE);" >/dev/null 2>/dev/null; then return 1; fi
    if ! compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U "$db_user" -d postgres \
      -c "CREATE DATABASE $database;" >/dev/null 2>/dev/null; then return 1; fi
    if ! compose exec -T postgres pg_restore --exit-on-error --clean --if-exists -U "$db_user" -d "$database" \
      <"$account_upgrade_backup/$database.dump" >/dev/null 2>/dev/null; then
      echo '自动恢复失败，已保持应用停止并保留全部备份。' >&2
      return 1
    fi
  done
  cp "$account_upgrade_backup/deployment.env" "$DEPLOY_DIR/.env" || return 1
  chmod 0600 "$DEPLOY_DIR/.env" || return 1
  account_upgrade_restart_old || return 1
  account_upgrade_commit
  echo '备份已保留；本次安装返回失败，不标记为升级成功。' >&2
}

account_upgrade_commit() {
  # Keep the recoverable dumps; remove only the installer checkpoint pointer.
  if [[ -f "$DEPLOY_DIR/.account-upgrade-backup" ]]; then
    rm "$DEPLOY_DIR/.account-upgrade-backup"
  fi
  account_upgrade_backup_ready=false
}

account_upgrade_exit() {
  local result="$?"
  trap - EXIT
  if (( result != 0 )) && [[ "${account_upgrade_backup_ready:-false}" == true ]]; then
    account_upgrade_rollback || echo '自动恢复未完成，应用保持停止，受限权限的备份与检查点已保留。' >&2
  fi
  exit "$result"
}
