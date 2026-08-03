#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DEPLOY_DIR/scripts/common.sh"
cd "$DEPLOY_DIR"

usage() {
  cat <<'EOF'
用法: sudo ./yiyi.sh <命令>

  start                     启动本机角色服务
  stop                      停止本机角色服务（不删除数据）
  restart [服务名]          重启本机服务
  status                    查看本机容器状态
  check                     检查本机角色健康状态
  update                    更新部署文件和镜像
  backup [目录]             备份数据和配置
  restore <备份目录>        恢复数据和配置
  logs [服务名]             查看日志
  diagnostics               生成脱敏诊断包
EOF
}

command_name="${1:-help}"
shift || true

case "$command_name" in
  start)
    require_deploy_env
    compose up -d --wait --wait-timeout 300
    ;;
  stop)
    require_deploy_env
    compose down
    ;;
  restart)
    require_deploy_env
    compose restart "$@"
    ;;
  status)
    require_deploy_env
    compose ps
    ;;
  check)
    "$DEPLOY_DIR/scripts/healthcheck.sh"
    ;;
  nodes)
    require_deploy_env
    [[ "$(deployment_role)" == "single" ]] || { echo "nodes 命令只用于单机模式；分布式请在新服务器安装 storage/play 角色" >&2; exit 1; }
    storage_id="$(env_value .env YIYI_STORAGE_NODE_ID)"
    play_id="$(env_value .env YIYI_PLAY_AGENT_NODE_ID)"
    if [[ "$storage_id" == "NODE_NOT_CONFIGURED" || "$play_id" == "NODE_NOT_CONFIGURED" ]]; then
      echo "请先在网页创建 Storage 和 Play Agent，并把两个节点 ID 写入 .env" >&2
      exit 1
    fi
    touch .nodes-enabled
    chmod 0600 .nodes-enabled
    compose pull storage play-agent
    compose up -d --wait --wait-timeout 300 storage play-agent
    "$DEPLOY_DIR/scripts/healthcheck.sh"
    ;;
  activate)
    role="$(deployment_role)"
    [[ "$role" == "single" || "$role" == "control" ]] || { echo "只能在 single/control 主控服务器激活" >&2; exit 1; }
    "$DEPLOY_DIR/scripts/activate.sh"
    ;;
  export-join)
    require_deploy_env
    [[ "$(deployment_role)" == "control" ]] || { echo "只有 control 主控角色可以导出 join.env" >&2; exit 1; }
    target="${1:-$DEPLOY_DIR/join.env}"
    umask 077
    {
      echo "# YiYi 集群加入配置；包含生产凭据，必须通过安全渠道传输并在导入后删除。"
      while IFS= read -r key; do
        printf '%s=%s\n' "$key" "$(env_value "$DEPLOY_DIR/.env" "$key")"
      done < <(cluster_keys)
    } > "$target"
    chmod 0600 "$target"
    cp "$DEPLOY_DIR/config/cluster-relay.crt" "$(dirname "$target")/cluster-relay.crt"
    chmod 0644 "$(dirname "$target")/cluster-relay.crt"
    echo "集群加入配置已生成：$target"
    echo "请把 join.env 和同目录 cluster-relay.crt 一起传输；join.env 导入后应删除。"
    ;;
  update)
    require_deploy_env
    if [[ -d .git ]]; then git pull --ff-only; fi
    "$DEPLOY_DIR/scripts/upgrade.sh"
    ;;
  backup)
    "$DEPLOY_DIR/scripts/backup.sh" "$@"
    ;;
  restore)
    "$DEPLOY_DIR/scripts/restore.sh" "$@"
    ;;
  logs)
    require_deploy_env
    compose logs --tail 200 -f "$@"
    ;;
  diagnostics)
    "$DEPLOY_DIR/scripts/diagnostics.sh"
    ;;
  help|-h|--help)
    usage
    ;;
  *) usage >&2; exit 2 ;;
esac
