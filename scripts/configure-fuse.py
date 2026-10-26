#!/usr/bin/env python3
"""Generate and validate the opt-in standalone FUSE Compose configuration."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


def normalize_enabled(raw):
    value = raw.strip().strip("\"'").lower()
    if value not in ("", "false", "true"):
        raise ValueError("YIYI_FUSE_ENABLED 只支持 true 或 false")
    return value == "true"


def configuration(enabled, directory):
    service = {"environment": {"STORAGE_MOUNT_ENABLED": str(enabled).lower()}}
    if enabled:
        service.update({
            "cap_add": ["SYS_ADMIN"],
            "devices": ["/dev/fuse:/dev/fuse:rwm"],
            "security_opt": ["apparmor:unconfined"],
            "volumes": [{"type": "bind", "source": directory.replace("$", "$$"),
                         "target": "/mnt/yiyi", "bind": {"propagation": "rshared",
                                                        "create_host_path": False}}],
        })
    return {"services": {"yiyi-media": service}}


def check_host(directory):
    if not sys.platform.startswith("linux"):
        raise ValueError("FUSE 主机挂载仅支持原生 Linux Docker 主机")
    if not Path("/dev/fuse").exists() or not stat.S_ISCHR(os.stat("/dev/fuse").st_mode):
        raise ValueError("宿主机缺少 /dev/fuse；安装 fuse3 并执行 modprobe fuse 后重试")
    if not directory.startswith("/") or os.path.realpath(directory) == "/" or not Path(directory).is_dir():
        raise ValueError("YIYI_FUSE_MOUNT_DIR 必须是已存在的绝对目录，不能使用根目录")
    result = subprocess.run(["findmnt", "-n", "-o", "PROPAGATION", "--target", directory],
                            capture_output=True, text=True, check=True)
    if "shared" not in result.stdout.strip().split(","):
        raise ValueError("FUSE 挂载目录必须具有 shared 传播属性；请按部署文档先设置 bind mount 和 mount --make-rshared")


def validate(document):
    services = document["services"]
    for name, service in services.items():
        if service.get("privileged"):
            raise ValueError("单机版 Compose 不允许 privileged: true")
        caps = service.get("cap_add", [])
        devices = service.get("devices", [])
        if name != "yiyi-media":
            if caps or devices:
                raise ValueError("仅应用容器允许 FUSE 权限")
            continue
        if caps != ["SYS_ADMIN"]:
            raise ValueError("FUSE 仅允许 SYS_ADMIN capability")
        if len(devices) != 1 or devices[0] != {
            "source": "/dev/fuse", "target": "/dev/fuse", "permissions": "rwm"
        }:
            raise ValueError("FUSE 仅允许 /dev/fuse 设备")
        if str(service.get("environment", {}).get("STORAGE_MOUNT_ENABLED")).lower() != "true":
            raise ValueError("FUSE 开关未传入应用容器")
        mounts = [v for v in service.get("volumes", []) if v.get("target") == "/mnt/yiyi"]
        if len(mounts) != 1 or mounts[0].get("bind", {}).get("propagation") != "rshared":
            raise ValueError("FUSE 目录未配置 rshared 传播")


def main():
    try:
        if sys.argv[1] == "--validate":
            validate(json.load(sys.stdin))
            return 0
        path = Path(sys.argv[1])
        enabled = normalize_enabled(sys.argv[2])
        directory = os.path.normpath(sys.argv[3].strip().strip("\"'") or "/mnt/yiyi")
        if enabled:
            check_host(directory)
            local_path = path.parent / "compose.local-disks.yaml"
            if local_path.exists():
                local = json.loads(local_path.read_text())["services"]["yiyi-media"]["volumes"]
                for mount in local:
                    target = mount["target"]
                    if target == "/mnt" or target == "/mnt/yiyi" or target.startswith("/mnt/yiyi/"):
                        raise ValueError("本地磁盘目录不能与 FUSE 目录 /mnt/yiyi 重叠")
        # Atomic replacement also removes all FUSE privileges when disabled on the next install.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
                temporary = Path(stream.name)
                json.dump(configuration(enabled, directory), stream, indent=2)
                stream.write("\n")
            os.replace(temporary, path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        if enabled:
            print("已启用 FUSE：聚合容器共享 SYS_ADMIN 权限，挂载目录 /mnt/yiyi → " + directory)
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        print("FUSE 配置错误：" + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
