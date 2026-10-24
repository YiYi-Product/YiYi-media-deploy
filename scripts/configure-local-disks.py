#!/usr/bin/env python3
"""Generate the standalone Compose bind mounts from YIYI_LOCAL_DISK_MOUNTS."""
import json
import os
from pathlib import Path
import sys
import tempfile


# Additional mounts must not hide the application, its configuration or managed data.
PROTECTED_TARGETS = (
    "/data", "/etc", "/opt", "/usr", "/var", "/run", "/proc", "/sys",
    "/dev", "/bin", "/sbin", "/lib", "/lib64", "/app", "/root",
)


def parse_mounts(raw):
    raw = raw.strip()
    # The installer reads literal dotenv values; accept the usual whole-value quotes.
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        raw = raw[1:-1]
    mounts = []
    targets = set()
    for item in raw.split():
        parts = item.split(":")
        if len(parts) > 3 or any(not part for part in parts):
            raise ValueError(f"挂载格式无效：{item}；使用 /宿主目录[:/容器目录[:ro|rw]]")
        source = parts[0]
        target = parts[1] if len(parts) >= 2 else source
        mode = parts[2] if len(parts) == 3 else "rw"
        if mode not in ("ro", "rw"):
            raise ValueError(f"挂载选项只支持 ro 或 rw：{item}")
        if not source.startswith("/") or not target.startswith("/"):
            raise ValueError(f"本地磁盘挂载必须使用绝对路径：{item}")
        # Collapse // as well, so validation matches Docker's mount target semantics.
        source = "/" + os.path.normpath(source).lstrip("/")
        target = "/" + os.path.normpath(target).lstrip("/")
        if os.path.realpath(source) == "/" or target == "/":
            raise ValueError("本地磁盘挂载不能使用根目录 /")
        if not Path(source).is_dir():
            raise ValueError(f"宿主机目录不存在或不是目录：{source}；请检查路径，不会自动创建空目录")
        if target == "/tmp" or any(target == path or target.startswith(path + "/") for path in PROTECTED_TARGETS):
            raise ValueError(f"容器目标目录覆盖了应用或系统目录：{target}；请改用 /media/xxx 等独立路径")
        if target in targets:
            raise ValueError(f"容器目标目录重复：{target}")
        targets.add(target)
        mounts.append({"type": "bind", "source": source, "target": target,
                       "read_only": mode == "ro", "bind": {"create_host_path": False}})
    for mount in mounts:
        if any(mount["target"].startswith(other + "/")
               for other in targets):
            raise ValueError(f"容器目标目录不能互相嵌套：{mount['target']}")
    return mounts


def write_override(path, mounts):
    # JSON is YAML-compatible; escape dollars to prevent Compose interpreting path text.
    volumes = [dict(mount, source=mount["source"].replace("$", "$$"),
                    target=mount["target"].replace("$", "$$")) for mount in mounts]
    document = {"services": {"yiyi-media": {"volumes": volumes}}}
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(document, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    try:
        mounts = parse_mounts(sys.argv[2])
        write_override(Path(sys.argv[1]), mounts)
    except (ValueError, OSError) as error:
        print(f"YIYI_LOCAL_DISK_MOUNTS 配置错误：{error}", file=sys.stderr)
        return 1
    if mounts:
        print(f"已配置 {len(mounts)} 个本地磁盘目录：")
        for mount in mounts:
            print(f"  {mount['source']} → {mount['target']} ({'ro' if mount['read_only'] else 'rw'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
