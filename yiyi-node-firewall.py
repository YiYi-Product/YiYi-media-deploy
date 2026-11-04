#!/usr/bin/env python3
"""Add source-restricted YiYi node rules to an active UFW or firewalld.

Default: read-only preview. No packages, firewall activation, reloads or services.
Requires Linux, Python >= 3.8, root for firewall inspection; no third-party modules.
"""
import argparse
import copy
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

STATE_DIR = Path('/var/lib/yiyi-node-firewall')
STATE_FILE = STATE_DIR / 'state.json'
TAG = 'yiyi-node-fw-v1'


class Error(Exception):
    pass


def run(args, query=False):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=dict(os.environ, LC_ALL='C'))
    if result.returncode and not (query and result.returncode == 1):
        raise Error('{}: {}'.format(shlex.join(args), result.stderr.strip() or result.stdout.strip()))
    return result


def address(value):
    try:
        if '%' in value or '/' in value:
            raise ValueError()
        ip = ipaddress.ip_address(value)
        if ip.is_unspecified or ip.is_multicast or ip.is_loopback or ip.is_link_local:
            raise ValueError()
        return str(ip)
    except ValueError:
        raise argparse.ArgumentTypeError('请填写单个对端 IPv4/IPv6 地址（不接受网段、域名或回环地址）')


def port(value):
    if not value.isdigit() or not 1 <= int(value) <= 65535:
        raise argparse.ArgumentTypeError('端口必须在 1–65535 之间')
    return int(value)


def arguments(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--role', required=True, choices=['control', 'storage', 'play'], help='本机角色')
    p.add_argument('--node-ip', action='append', default=[], type=address, help='控制面允许的节点 IP，可重复')
    p.add_argument('--control-ip', action='append', default=[], type=address, help='节点允许的控制面 IP，可重复')
    p.add_argument('--play-ip', action='append', default=[], type=address, help='存储机允许的播放节点 IP，可重复')
    p.add_argument('--all-ports', action='store_true', help='放行指定对端 IP 的全部端口与协议；不向其他来源开放')
    p.add_argument('--peer-ip', action='append', default=[], type=address, help='--all-ports 模式的对端 IP，可重复')
    for name, default in [('user', 18082), ('media', 18083), ('config', 18085), ('storage', 18084), ('play', 19090)]:
        p.add_argument('--{}-port'.format(name), type=port, default=default)
    p.add_argument('--backend', choices=['auto', 'ufw', 'firewalld'], default='auto')
    p.add_argument('--zone', help='firewalld 目标 zone，必须显式指定')
    modes = p.add_mutually_exclusive_group()
    modes.add_argument('--dry-run', action='store_true', help='只读预览（默认）')
    modes.add_argument('--apply', action='store_true', help='添加并保存规则')
    modes.add_argument('--remove', action='store_true', help='撤销参数选中的、由本脚本新增的规则')
    a = p.parse_args(argv)
    if a.all_ports:
        if not (a.peer_ip or a.node_ip or a.control_ip or a.play_ip):
            p.error('--all-ports 必须指定至少一个对端 IP')
        return a
    if a.peer_ip:
        p.error('--peer-ip 必须与 --all-ports 一起使用')
    valid = {'control': (bool(a.node_ip), not a.control_ip and not a.play_ip),
             'storage': (bool(a.control_ip or a.play_ip), not a.node_ip),
             'play': (bool(a.control_ip), not a.node_ip and not a.play_ip)}
    if not all(valid[a.role]):
        p.error('control 使用 --node-ip；storage 使用 --control-ip 和/或 --play-ip；play 只使用 --control-ip')
    return a


def plan(a):
    if a.all_ports:
        pairs = [(ip, 0) for ip in a.peer_ip + a.node_ip + a.control_ip + a.play_ip]
    elif a.role == 'control':
        pairs = [(ip, port) for ip in a.node_ip for port in [a.user_port, a.media_port, a.config_port]]
    elif a.role == 'storage':
        pairs = [(ip, a.storage_port) for ip in a.control_ip + a.play_ip]
    else:
        pairs = [(ip, a.play_port) for ip in a.control_ip]
    return [dict(role=a.role, ip=ip, port=p) for ip, p in sorted(set(pairs))]


def detect(a):
    ufw = shutil.which('ufw') and run(['ufw', 'status']).stdout.startswith('Status: active')
    firewalld = False
    if shutil.which('firewall-cmd'):
        status = subprocess.run(['firewall-cmd', '--state'], text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=dict(os.environ, LC_ALL='C'))
        firewalld = status.returncode == 0 and status.stdout.strip() == 'running'
    if ufw and firewalld:
        raise Error('UFW 与 firewalld 同时启用，请先确认唯一管理器；未改动任何规则。')
    backend = 'ufw' if ufw else 'firewalld' if firewalld else None
    if not backend:
        raise Error('未检测到已启用的 UFW/firewalld。不会启用防火墙；原生 nftables/iptables 和云安全组需单独处理。')
    if a.backend not in ('auto', backend):
        raise Error('指定的防火墙未启用。')
    if backend == 'firewalld':
        if not a.zone:
            raise Error('firewalld 必须用 --zone 指定目标 zone；先运行 firewall-cmd --get-active-zones。')
        if a.zone not in run(['firewall-cmd', '--get-zones']).stdout.split():
            raise Error('指定的 firewalld zone 不存在。')
        if a.zone not in run(['firewall-cmd', '--permanent', '--get-zones']).stdout.split():
            raise Error('指定 zone 尚未持久化；请先由管理员确认 zone 配置。')
    elif a.zone:
        raise Error('--zone 仅适用于 firewalld。')
    if backend == 'ufw' and any(':' in r['ip'] for r in plan(a)):
        if not re.search(r'^IPV6\s*=\s*[\"\']?yes', Path('/etc/default/ufw').read_text(), re.M):
            raise Error('UFW 未启用 IPv6，不能添加 IPv6 规则。')
    return backend


def tag(r):
    return '{}-{}-{}-{}'.format(TAG, r['role'], r['ip'], r['port'])


def ufw_matches(r):
    matches = []
    for line in run(['ufw', 'status', 'numbered']).stdout.splitlines():
        body, _, comment = line.partition('#')
        m = re.match(r'^\[\s*(\d+)\]\s+(Anywhere|\d+/tcp)(?:\s+\(v6\))?\s+ALLOW IN\s+(\S+)\s*$', body.strip())
        if not m or (0 if m[2] == 'Anywhere' else int(m[2].split('/')[0])) != r['port']:
            continue
        try:
            network = ipaddress.ip_network(m[3], strict=False)
            same = network.num_addresses == 1 and network.network_address == ipaddress.ip_address(r['ip'])
        except ValueError:
            same = False
        if same:
            matches.append((m[1], comment.strip() == tag(r)))
    return matches


def rich_rule(r):
    family = 'ipv6' if ':' in r['ip'] else 'ipv4'
    if r['port'] == 0:
        return 'rule family="{}" priority="-100" source address="{}" accept'.format(family, r['ip'])
    return 'rule family="{}" priority="-100" source address="{}" port port="{}" protocol="tcp" accept'.format(family, r['ip'], r['port'])


def ufw_add_command(r):
    if r['port'] == 0:
        return ['ufw', 'insert', '1', 'allow', 'from', r['ip'], 'comment', tag(r)]
    return ['ufw', 'insert', '1', 'allow', 'proto', 'tcp', 'from', r['ip'], 'to', 'any', 'port', str(r['port']), 'comment', tag(r)]


def firewall_command(r, action):
    args = ['firewall-cmd']
    if r['kind'] == 'permanent':
        args.append('--permanent')
    return args + ['--zone=' + r['zone'], '--{}-rich-rule={}'.format(action, rich_rule(r))]


def exists(r):
    if r['backend'] == 'ufw':
        return any(owned for _, owned in ufw_matches(r))
    return run(firewall_command(r, 'query'), query=True).returncode == 0


def change(r, add):
    if r['backend'] == 'ufw':
        if add:
            args = ufw_add_command(r)
        else:
            matches = [number for number, owned in ufw_matches(r) if owned]
            if not matches:
                return
            args = ['ufw', '--force', 'delete', matches[0]]
    else:
        args = firewall_command(r, 'add' if add else 'remove')
    print('+', shlex.join(args), flush=True)
    run(args)


def read_state():
    if not STATE_FILE.exists():
        return []
    try:
        value = json.loads(STATE_FILE.read_text())
        if value['version'] != 1 or not isinstance(value['rules'], list):
            raise ValueError()
        return value['rules']
    except (ValueError, KeyError, TypeError):
        raise Error('规则记录文件格式错误，请人工检查 ' + str(STATE_FILE))


def save_state(rules):
    fd, name = tempfile.mkstemp(prefix='state-', dir=STATE_DIR)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(dict(version=1, rules=rules), f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, STATE_FILE)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def transaction(rules, remove):
    original = read_state()
    state = copy.deepcopy(original)
    completed = []
    try:
        for r in rules:
            if remove:
                if r not in state:
                    print('保留：非本脚本新增', r['ip'], r['port'], r['kind'])
                    continue
                if exists(r):
                    change(r, False)
                    completed.append((r, False))
                state.remove(r)
            else:
                # Never adopt or change an administrator's existing rule.
                present = bool(ufw_matches(r)) if r['backend'] == 'ufw' else exists(r)
                if present:
                    print('已有规则，跳过（仍需验证规则顺序与实际连通性）：', r['ip'], r['port'], r['kind'])
                    continue
                change(r, True)
                completed.append((r, True))
                if r not in state:
                    state.append(r)
        save_state(state)
    except (Exception, KeyboardInterrupt) as exc:
        failures = []
        for r, added in reversed(completed):
            try:
                change(r, not added)
            except (Exception, KeyboardInterrupt):
                failures.append(r)
        if failures:
            # Keep incomplete additions discoverable for a later --remove retry.
            recovery = copy.deepcopy(original)
            for r in failures:
                if r not in recovery:
                    recovery.append(r)
            save_state(recovery)
            raise Error('执行失败且部分回滚失败；请检查 {} 与防火墙实况：{}'.format(STATE_FILE, exc))
        raise Error('执行失败，本次已完成的变更已撤销：' + str(exc))


def main(argv=None):
    a = arguments(argv)
    pairs = plan(a)
    print('本机角色：{}；仅处理指定来源入站，不配置客户端公网播放入口。'.format(a.role))
    for r in pairs:
        print('  来源 {} -> 本机 {}'.format(r['ip'], '全部端口及协议' if r['port'] == 0 else 'TCP {}'.format(r['port'])))
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise Error('请在目标 Linux 主机使用 sudo python3 运行；不加 --apply 时仅预览。')
    backend = detect(a)
    rules = []
    for r in pairs:
        for kind in (['ufw'] if backend == 'ufw' else ['runtime', 'permanent']):
            rules.append(dict(r, backend=backend, zone=a.zone or '', kind=kind))
    print('防火墙：' + backend + ('，zone=' + a.zone if a.zone else ''))
    if not a.apply and not a.remove:
        for r in rules:
            cmd = (ufw_add_command(r)
                   if backend == 'ufw' else firewall_command(r, 'add'))
            print('预览：', shlex.join(cmd))
        print('未写入文件或规则。确认 IP/端口/zone 后加 --apply；撤销使用相同参数加 --remove。')
        return
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE_DIR / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        transaction(rules, a.remove)
    print('已完成。只处理记录中的规则；未启停服务。请从实际调用方验证，并同步检查云安全组。')


if __name__ == '__main__':
    try:
        main()
    except (Error, OSError) as exc:
        print('错误：' + str(exc), file=sys.stderr)
        sys.exit(1)
