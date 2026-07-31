#!/usr/bin/env bash
# Postgres 容器首次启动时（pgdata 为空）自动创建 yiyi_* 数据库。
# 表结构由各服务启动时通过 Flyway 自动迁移。
set -e

for db in yiyi_config yiyi_user yiyi_media yiyi_storage; do
  echo "[init] creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d postgres <<-SQL
    SELECT 'CREATE DATABASE "$db"'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
SQL
done
