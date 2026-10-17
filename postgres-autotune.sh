#!/usr/bin/env bash
# PostgreSQL 按机器自动调参（容器入口包装）。
#
# 每次容器启动时读取容器实际可用的内存与 CPU（优先 cgroup 限额，否则宿主机），算出
# shared_buffers / work_mem 等参数，以 `-c` 形式交给官方入口 docker-entrypoint.sh。
# 机器扩容、迁移后重启容器即自动生效，不需要手工改配置。
#
# - 未设内存限额时视为与其它服务共用宿主机，按较保守的比例取用；设了限额则视为专用。
# - 命令行参数优先级高于 postgresql.conf 与 ALTER SYSTEM；需要手工管理参数时在 .env 里设
#   YIYI_PG_AUTOTUNE=false 关闭本脚本，官方镜像行为完全不变。
# - YIYI_PG_AUTOTUNE_PRINT=1 只打印计算结果不启动（排障用）；
#   YIYI_PG_TUNE_MEMORY_MB / YIYI_PG_TUNE_CPUS 仅用于覆盖探测值做验证。
set -euo pipefail

log() { echo "[yiyi-pg-autotune] $*" >&2; }

detect_memory_mb() {
  local host_kb limit_bytes limit_mb host_mb
  host_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  host_mb=$((host_kb / 1024))
  limit_bytes=""
  if [ -r /sys/fs/cgroup/memory.max ]; then
    limit_bytes=$(cat /sys/fs/cgroup/memory.max)
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    limit_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
  fi
  if [[ "$limit_bytes" =~ ^[0-9]+$ ]]; then
    limit_mb=$((limit_bytes / 1024 / 1024))
    if [ "$limit_mb" -gt 0 ] && [ "$limit_mb" -lt "$host_mb" ]; then
      echo "$limit_mb limited"
      return
    fi
  fi
  echo "$host_mb shared"
}

detect_cpus() {
  local cpus quota="" period=""
  cpus=$(nproc 2>/dev/null || echo 1)
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    # cgroup v1：未限额时 quota 为 -1，下面的数字校验会自然跳过。
    quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  fi
  if [ -n "${quota:-}" ]; then
    if [[ "${quota:-}" =~ ^[0-9]+$ ]] && [[ "${period:-}" =~ ^[0-9]+$ ]] && [ "$period" -gt 0 ]; then
      local limited=$(((quota + period - 1) / period))
      if [ "$limited" -ge 1 ] && [ "$limited" -lt "$cpus" ]; then
        cpus=$limited
      fi
    fi
  fi
  echo "$cpus"
}

# 所有块设备都不是机械盘时按 SSD 调整随机读代价；探测不到就保持官方默认。
storage_is_ssd() {
  local found=0 f
  for f in /sys/block/*/queue/rotational; do
    [ -r "$f" ] || continue
    case "$f" in */loop*|*/ram*|*/zram*|*/sr*|*/fd*) continue ;; esac
    found=1
    [ "$(cat "$f")" = "0" ] || return 1
  done
  [ "$found" = "1" ]
}

clamp() { # value min max
  local v=$1
  [ "$v" -lt "$2" ] && v=$2
  [ "$v" -gt "$3" ] && v=$3
  echo "$v"
}

tune_args() {
  local mem_mb mode cpus
  read -r mem_mb mode <<< "$(detect_memory_mb)"
  mem_mb=${YIYI_PG_TUNE_MEMORY_MB:-$mem_mb}
  cpus=${YIYI_PG_TUNE_CPUS:-$(detect_cpus)}
  local max_conn=${YIYI_PG_MAX_CONNECTIONS:-100}

  # 共用宿主机时只拿 15%（上限 8GB），给应用 JVM 与其它业务留足内存；专用容器按常规 25%。
  local sb_pct=15 sb_cap=8192
  if [ "$mode" = "limited" ]; then sb_pct=25; sb_cap=16384; fi
  local shared_buffers=$(clamp $((mem_mb * sb_pct / 100)) 128 "$sb_cap")
  local effective_cache=$(clamp $((mem_mb * 50 / 100)) 512 1048576)
  # 剩余内存的 1/4 分给排序 / 哈希：按每连接 2 个并发算子估算，限制在 4MB–64MB。
  local work_mem=$(clamp $(((mem_mb - shared_buffers) * 1024 / 4 / (max_conn * 2))) 4096 65536)
  local maintenance=$(clamp $((mem_mb * 5 / 100)) 64 1024)
  local per_gather=$(clamp $((cpus / 4)) 1 4)
  local workers=$(clamp "$cpus" 2 64)
  local worker_procs=$(clamp "$cpus" 8 64)

  local args=(
    -c "shared_buffers=${shared_buffers}MB"
    -c "effective_cache_size=${effective_cache}MB"
    -c "work_mem=${work_mem}kB"
    -c "maintenance_work_mem=${maintenance}MB"
    -c "max_worker_processes=${worker_procs}"
    -c "max_parallel_workers=${workers}"
    -c "max_parallel_workers_per_gather=${per_gather}"
    -c "max_parallel_maintenance_workers=${per_gather}"
    -c "max_wal_size=2GB"
    -c "checkpoint_completion_target=0.9"
  )
  if storage_is_ssd; then
    args+=(-c "random_page_cost=1.1" -c "effective_io_concurrency=200")
  fi
  log "memory=${mem_mb}MB (${mode}) cpus=${cpus} -> ${args[*]}"
  printf '%s\n' "${args[@]}"
}

if [ "${YIYI_PG_AUTOTUNE:-true}" = "false" ] || [ "${1:-}" != "postgres" ]; then
  [ "${YIYI_PG_AUTOTUNE:-true}" = "false" ] && log "disabled by YIYI_PG_AUTOTUNE=false"
  exec docker-entrypoint.sh "$@"
fi

mapfile -t TUNED < <(tune_args)
if [ "${YIYI_PG_AUTOTUNE_PRINT:-0}" = "1" ]; then
  printf '%s\n' "${TUNED[@]}"
  exit 0
fi
# 调优参数放在用户参数之前：compose 里额外写的 -c 出现在后面，后者优先。
exec docker-entrypoint.sh "$1" "${TUNED[@]}" "${@:2}"
