#!/usr/bin/env python3
import json
import math
import os
import re
import subprocess
import urllib.error
from pathlib import Path
from urllib.request import Request, urlopen

REPO_SCRIPT = Path('/root/github/VPSBox/vpsbox.sh')
REPORT_JSON = Path('/root/github/VPSBox/tcp_compare_report.json')
REPORT_MD = Path('/root/github/VPSBox/tcp_compare_report.md')

SCENARIOS = [
    {"name":"low-latency-small-mem","local_bw":100,"vps_bw":1000,"latency":30,"mem":256,"ramp":0.5,"cc":"bbr","ecn":0},
    {"name":"low-latency-high-mem","local_bw":1000,"vps_bw":1000,"latency":40,"mem":4096,"ramp":0.5,"cc":"bbr","ecn":0},
    {"name":"120ms-boundary","local_bw":300,"vps_bw":1000,"latency":120,"mem":1024,"ramp":0.5,"cc":"bbr","ecn":0},
    {"name":"high-latency-mid-mem","local_bw":200,"vps_bw":1000,"latency":180,"mem":1024,"ramp":0.5,"cc":"bbr","ecn":0},
    {"name":"high-latency-high-mem","local_bw":500,"vps_bw":1000,"latency":350,"mem":4096,"ramp":0.5,"cc":"bbr","ecn":0},
    {"name":"very-high-latency","local_bw":100,"vps_bw":1000,"latency":800,"mem":2048,"ramp":0.5,"cc":"bbr","ecn":0},
    {"name":"clamp-low-inputs","local_bw":1,"vps_bw":1,"latency":1,"mem":64,"ramp":0.1,"cc":"bbr","ecn":0},
    {"name":"clamp-high-inputs","local_bw":100000,"vps_bw":1,"latency":2000,"mem":32768,"ramp":1.0,"cc":"bbr","ecn":0},
]

OMNITT_META = "https://www.omnitt.com/tcp-optimizer (currently returns 404 shell with TCP optimizer metadata only; no public generator UI/API/output exposed)"


def clamp(x, lo, hi):
    return min(max(x, lo), hi)


def sigmoid(x, steepness=4.0, midpoint=0.3):
    return 1.0 / (1.0 + math.exp(-steepness * (x - midpoint)))


def piecewise(x, points):
    if x <= points[0][0]:
        return points[0][1]
    for i in range(1, len(points)):
        x0, y0 = points[i - 1]
        x1, y1 = points[i]
        if x <= x1:
            if x1 == x0:
                return y1
            return y0 + (y1 - y0) * ((x - x0) / (x1 - x0))
    return points[-1][1]


def qtheory(e, service, utilization):
    return service / (1 - min(utilization, 0.95)) * e


def tcpcong(x, mode, scale):
    if mode == 'slow_start':
        return min(scale * (1 + 0.5 * x), scale + 10 * x)
    return scale + 0.1 * x


def memory_cap(target, mem_mb, frac):
    return min(target, int(1024 * mem_mb * 1024 * frac))


def clamp_tcp_window_scale(value):
    return int(clamp(value, -31, 31))


def clamp_kernel_buffer(value):
    return int(clamp(math.floor(value), 4096, 1073741824))


def clamp_tcp_triplet(min_value, default_value, max_value):
    min_value = clamp_kernel_buffer(min_value)
    default_value = clamp_kernel_buffer(default_value)
    max_value = clamp_kernel_buffer(max_value)
    if default_value < min_value:
        default_value = min_value
    if max_value < default_value:
        max_value = default_value
    return f'{min_value} {default_value} {max_value}'


def small_mem_buffer_cap(mem_mb):
    if mem_mb <= 64:
        return 8 * 1024 * 1024
    if mem_mb <= 128:
        return 16 * 1024 * 1024
    if mem_mb <= 256:
        return 32 * 1024 * 1024
    if mem_mb <= 512:
        return 64 * 1024 * 1024
    return 128 * 1024 * 1024


def medium_mem_buffer_cap(latency_ms, mem_mb):
    if mem_mb <= 1024:
        return 128 * 1024 * 1024 if latency_ms > 900 else 96 * 1024 * 1024 if latency_ms > 650 else 64 * 1024 * 1024
    if mem_mb <= 2048:
        return 256 * 1024 * 1024 if latency_ms > 1100 else 192 * 1024 * 1024 if latency_ms > 800 else 128 * 1024 * 1024
    if mem_mb <= 4096:
        return 384 * 1024 * 1024 if latency_ms > 1300 else 320 * 1024 * 1024 if latency_ms > 900 else 224 * 1024 * 1024
    if mem_mb <= 8192:
        return 640 * 1024 * 1024 if latency_ms > 1300 else 512 * 1024 * 1024 if latency_ms > 900 else 384 * 1024 * 1024
    if mem_mb <= 32768:
        return 768 * 1024 * 1024 if latency_ms > 1300 else 640 * 1024 * 1024 if latency_ms > 900 else 512 * 1024 * 1024
    return 896 * 1024 * 1024 if latency_ms > 1300 else 768 * 1024 * 1024


def tuned_min_free_kbytes(mem_mb, target_kbytes, high_latency=False):
    floor = 16384 if mem_mb <= 64 else 24576 if mem_mb <= 128 else 32768 if mem_mb <= 256 else 49152 if mem_mb <= 512 else 65536
    ceiling = int(mem_mb * (384 if mem_mb <= 128 else 320 if mem_mb <= 256 else 256 if mem_mb <= 512 else 192 if mem_mb <= 1024 else 160))
    if high_latency:
        ceiling = int(ceiling * 1.15)
    ceiling = max(floor, min(1048576, ceiling))
    return int(clamp(target_kbytes, floor, ceiling))


def current_vpsbox_profile(local_bw, vps_bw, latency, mem, ramp, cc, ecn):
    base = {
        'kernel.pid_max': 65535,
        'kernel.panic': 1,
        'kernel.sysrq': 1,
        'kernel.core_pattern': 'core_%e',
        'kernel.printk': '3 4 1 3',
        'kernel.numa_balancing': 0,
        'kernel.sched_autogroup_enabled': 0,
        'vm.panic_on_oom': 1,
        'vm.overcommit_memory': 1,
        'vm.vfs_cache_pressure': 100,
        'vm.dirty_expire_centisecs': 3000,
        'vm.dirty_writeback_centisecs': 500,
        'net.ipv4.tcp_fastopen': 3,
        'net.ipv4.tcp_timestamps': 1,
        'net.ipv4.tcp_tw_reuse': 1,
        'net.ipv4.tcp_fin_timeout': 10,
        'net.ipv4.tcp_slow_start_after_idle': 0,
        'net.ipv4.tcp_max_tw_buckets': 32768,
        'net.ipv4.tcp_sack': 1,
        'net.ipv4.tcp_mtu_probing': 1,
        'net.ipv4.tcp_congestion_control': cc,
        'net.ipv4.tcp_window_scaling': 1,
        'net.ipv4.tcp_moderate_rcvbuf': 1,
        'net.ipv4.tcp_abort_on_overflow': 0,
        'net.ipv4.tcp_stdurg': 0,
        'net.ipv4.tcp_rfc1337': 0,
        'net.ipv4.tcp_syncookies': 1,
        'net.ipv4.tcp_ecn': ecn,
        'net.ipv4.ip_forward': 0,
        'net.ipv4.ip_local_port_range': '1024 65535',
        'net.ipv4.ip_no_pmtu_disc': 0,
        'net.ipv4.route.gc_timeout': 100,
        'net.ipv4.neigh.default.gc_stale_time': 120,
        'net.ipv4.conf.all.accept_redirects': 0,
        'net.ipv4.conf.default.accept_redirects': 0,
        'net.ipv4.conf.all.secure_redirects': 0,
        'net.ipv4.conf.default.secure_redirects': 0,
        'net.ipv4.conf.all.accept_source_route': 0,
        'net.ipv4.conf.default.accept_source_route': 0,
        'net.ipv4.conf.all.forwarding': 0,
        'net.ipv4.conf.default.forwarding': 0,
        'net.ipv4.conf.all.rp_filter': 1,
        'net.ipv4.conf.default.rp_filter': 1,
        'net.ipv4.conf.all.arp_announce': 2,
        'net.ipv4.conf.default.arp_announce': 2,
        'net.ipv4.conf.all.arp_ignore': 1,
        'net.ipv4.conf.default.arp_ignore': 1,
    }
    if latency <= 120:
        mode = '低延迟画像'
        qdisc = 'cake'
        responsiveness = 2.0
        jitter_tolerance = 0.3
        burst_handling = 0.7
        memory_efficiency = 1.0
        buffer_aggression = 0.8
        queue_pref = 0.8
        conn_density = 1.2
        win_base = 1.2
        latency_sensitivity = 1.5
        win_max = 4
        if mem <= 256:
            responsiveness = 2.5
            jitter_tolerance = 0.2
            burst_handling = 0.5
            memory_efficiency = 0.8
            buffer_aggression = 0.6
            queue_pref = 0.6
            conn_density = 1.0
            win_base = 1.0
            win_max = 3
        elif mem <= 512:
            responsiveness = 2.2
            jitter_tolerance = 0.25
            burst_handling = 0.6
            memory_efficiency = 0.9
            buffer_aggression = 0.7
        elif mem > 1024:
            responsiveness = 1.8
            jitter_tolerance = 0.4
            burst_handling = 0.9
            memory_efficiency = 1.2
            buffer_aggression = 1.0
            queue_pref = 1.0
            conn_density = 1.5
            win_base = 1.4
            win_max = 6

        F = clamp(1.5 * math.sqrt(local_bw / vps_bw), 1, 2)
        T = math.floor(1024 * min(local_bw * F, vps_bw) * 1024 / 8)
        ratio = local_bw / vps_bw
        B = 1.0
        if ratio > 1:
            B = max(0.3, 1 / math.sqrt(min(ratio, 100)))
            if latency > 200:
                B = min(1.0, 1.2 * B)
        N = math.ceil(T * latency / 1000)
        P = max(N, 24576)
        A = 0.1 if mem <= 256 else 0.125
        I = 4194304 if mem <= 256 else 8388608
        U = max(memory_cap(math.ceil(1.5 * ramp * B * N), mem, A), I)
        curve1 = clamp(sigmoid(ramp, 4, 0.3) * (responsiveness / 2), 0.3, 2)
        latency_factor = clamp((2 ** (latency / 120 - 1)) * curve1 * responsiveness, 0.8, 5)
        buffer_factor = clamp(latency_factor * tcpcong(curve1, 'slow_start', 1) * memory_efficiency * buffer_aggression * burst_handling, 0.5, 3)
        queue_factor = clamp((math.log(qtheory(T / 65536 * conn_density, latency / 1000 * 2, 0.8 * curve1) + 1) / math.log(1000)) * queue_pref * (1 + jitter_tolerance), 0.3, 2)
        adv_factor = max(0, math.ceil(math.log2(max(1, 2 * math.ceil(T * latency / 1000) / 65535))))
        adv_win_scale = clamp_tcp_window_scale(max(2, math.ceil(clamp(latency_factor / latency_sensitivity * adv_factor * win_base * curve1, 1, win_max))))
        Vmul = 2.5 if mem <= 256 else 3 if mem <= 512 else 4
        Hmul = 1.2 if mem <= 256 else 1.5 if mem <= 1024 else 2
        U = clamp_kernel_buffer(U)
        tcp_rmem_max = clamp_kernel_buffer(min(math.floor(P * Vmul * buffer_factor), U))
        tcp_wmem_max = clamp_kernel_buffer(min(math.floor(P * Hmul * buffer_factor), U))
        Q = math.ceil(min(2 * max(100, T / 65536), 10000) * queue_factor)
        X = 0.6 if mem <= 256 else 0.8 if mem <= 512 else 1 if mem <= 1024 else 1.2
        somaxconn = int(clamp(math.floor(0.2 * Q * X), 256, 2048))
        backlog = int(clamp(math.floor(0.4 * Q * X), 2000, 4000))
        max_syn = int(clamp(math.floor(0.8 * Q * X), 2048, 16384))
        min_free = tuned_min_free_kbytes(mem, math.floor(1024 * mem * (0.015 if mem <= 256 else 0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03) + math.floor(0.5 * math.ceil(T / 1024))), high_latency=False)
        data = {
            **base,
            'mode': mode,
            'net.core.default_qdisc': qdisc,
            'vm.swappiness': 10,
            'vm.dirty_ratio': 10,
            'vm.dirty_background_ratio': 5,
            'vm.min_free_kbytes': min_free,
            'net.core.netdev_max_backlog': backlog,
            'net.core.rmem_max': U,
            'net.core.wmem_max': U,
            'net.core.rmem_default': 87380,
            'net.core.wmem_default': 65536,
            'net.core.somaxconn': somaxconn,
            'net.core.optmem_max': math.floor(min(65536, P / 4)),
            'net.ipv4.tcp_fack': 0,
            'net.ipv4.tcp_rmem': clamp_tcp_triplet(8192, 87380, tcp_rmem_max),
            'net.ipv4.tcp_wmem': clamp_tcp_triplet(8192, 65536, tcp_wmem_max),
            'net.ipv4.tcp_notsent_lowat': 4096,
            'net.ipv4.tcp_adv_win_scale': adv_win_scale,
            'net.ipv4.tcp_no_metrics_save': 0,
            'net.ipv4.tcp_max_syn_backlog': max_syn,
            'net.ipv4.tcp_max_orphans': 65536,
            'net.ipv4.tcp_synack_retries': 2,
            'net.ipv4.tcp_syn_retries': 3,
            'net.ipv4.neigh.default.gc_thresh1': 1024,
            'net.ipv4.neigh.default.gc_thresh2': 4096,
            'net.ipv4.neigh.default.gc_thresh3': 8192,
        }
    else:
        mode = '高延迟画像'
        qdisc = 'fq'
        throughput_priority = 2.0
        stability = 1.5
        buffer_aggression = 2.0
        queue_depth = 2.5
        conn_scaling = 2.0
        memory_util = 1.5
        win_base = 2.0
        latency_tolerance = 2.0
        win_max = 8
        latency_curve_tolerance = 1.5
        if mem <= 512:
            throughput_priority = 1.8
            stability = 1.8
            buffer_aggression = 1.5
            queue_depth = 2.0
            conn_scaling = 1.5
            memory_util = 1.2
            win_base = 1.5
            win_max = 6
        elif mem <= 2048 and mem > 1024:
            throughput_priority = 2.2
            buffer_aggression = 2.3
            queue_depth = 3.0
            conn_scaling = 2.5
            memory_util = 1.8
            win_base = 2.5
            win_max = 12
        elif mem > 2048:
            throughput_priority = 2.5
            buffer_aggression = 2.5
            queue_depth = 3.5
            conn_scaling = 3.0
            memory_util = 2.0
            win_base = 3.0
            win_max = 16
        F = clamp(latency / 40, 1, 5)
        T = clamp(2 * math.sqrt(local_bw / vps_bw) * F, 1.5, 5)
        S = math.floor(1024 * min(local_bw * T, 2 * vps_bw) * 1024 / 8)
        ratio = local_bw / vps_bw
        Ndamp = 1.0
        if ratio > 100:
            Ndamp = 0.06
        elif ratio > 50:
            Ndamp = 0.12
        elif ratio > 20:
            Ndamp = 0.2
        elif ratio > 10:
            Ndamp = 0.3
        elif ratio > 5:
            Ndamp = 0.5
        elif ratio > 2:
            Ndamp = 0.7
        G = math.ceil(S * latency / 1000)
        if mem <= 512:
            L = max(max(G, 131072), S * latency / 1200)
        elif mem <= 1024:
            L = max(max(G, 262144), S * latency / 1000)
        else:
            L = max(max(G, 524288), S * latency / 800)
        V = math.ceil(S * latency / 1000)
        H = memory_cap(math.ceil(2 * ramp * Ndamp * V), mem, 0.125)
        W = max(H, math.ceil(0.5 * V)) if latency > 500 else H
        if mem <= 512:
            W = min(W, small_mem_buffer_cap(mem))
        else:
            medium_cap = medium_mem_buffer_cap(latency, mem)
            if medium_cap is not None:
                W = min(W, medium_cap)
        curve1 = clamp((math.log(ramp * (math.e - 1) + 1) / math.log(math.e)) * stability * (buffer_aggression / 2), 0.5, 3)
        latency_input = min(1, (latency - 120) / 1880)
        latency_ramp = clamp((latency - 120) / 680, 0, 1)
        latency_factor = clamp((math.log(latency_input * (latency_curve_tolerance - 1) + 1) / math.log(latency_curve_tolerance)) * latency_tolerance * curve1 if latency_input > 0 else 0, 1, 8)
        buffer_factor = clamp(latency_factor * tcpcong(curve1, 'congestion_avoidance', 10) * throughput_priority * buffer_aggression * memory_util * piecewise(curve1, [(0,1),(0.3,1.5),(0.6,2.5),(1,4)]), 1, 8)
        queue_factor = clamp(latency_factor / 3 * (math.log(qtheory(S / 131072 * conn_scaling, latency / 1000 * 3, min(0.9, 0.85 * curve1)) + 1) / math.log(10000) * queue_depth), 0.8, 4)
        adv_factor = max(0, math.ceil(math.log2(max(1, 4 * math.ceil(S * latency / 1000) / 65535))))
        adv_component = clamp(latency_factor / (latency_tolerance * (3.0 - 0.9 * latency_ramp)) * adv_factor * (win_base * (0.26 + 0.14 * latency_ramp)) * ((0.62 + 0.26 * latency_ramp) * curve1 + (0.34 + 0.12 * latency_ramp)), 1.5, max(3, math.ceil(win_max - (5.5 - 2.5 * latency_ramp))))
        if mem <= 512:
            K = clamp(1.5 * F, 3, 6) * buffer_factor
            Q = clamp(1.5 * F, 3, 6)
        elif mem <= 1024:
            K = clamp(1.8 * F, 4, 8) * buffer_factor
            Q = clamp(1.8 * F, 4, 8)
        else:
            K = clamp(2 * F, 5, 10) * buffer_factor
            Q = clamp(2 * F, 5, 10)
        W = clamp_kernel_buffer(W)
        tcp_rmem_max = clamp_kernel_buffer(min(math.floor(L * Q), W))
        tcp_wmem_max = clamp_kernel_buffer(min(math.floor(L * K), W))
        J = math.ceil(min(3 * max(50, S / 131072), 20000) * queue_factor)
        Z = 0.8 if mem <= 512 else 1 if mem <= 1024 else 1.3 if mem <= 2048 else 1.5
        somaxconn = int(clamp(math.floor(0.15 * J * Z), 2560, 8192 if mem <= 512 else 16384))
        backlog = int(clamp(math.floor(0.3 * J * Z), 8192, 16384 if mem <= 512 else 32768))
        max_syn = int(clamp(math.floor(0.6 * J * Z), 8192, 32768 if mem <= 512 else 65536))
        min_free = tuned_min_free_kbytes(mem, math.floor(1024 * mem * (0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03 if mem <= 2048 else 0.035) + math.floor(0.6 * math.ceil(S / 1024))), high_latency=True)
        data = {
            **base,
            'mode': mode,
            'net.core.default_qdisc': qdisc,
            'vm.swappiness': 5,
            'vm.dirty_ratio': 5,
            'vm.dirty_background_ratio': 2,
            'vm.min_free_kbytes': min_free,
            'net.core.netdev_max_backlog': backlog,
            'net.core.rmem_max': W,
            'net.core.wmem_max': W,
            'net.core.rmem_default': 262144,
            'net.core.wmem_default': 262144,
            'net.core.somaxconn': somaxconn,
            'net.core.optmem_max': math.floor(min(262144, L / 2)),
            'net.ipv4.tcp_fack': 1,
            'net.ipv4.tcp_rmem': clamp_tcp_triplet(32768, 262144, tcp_rmem_max),
            'net.ipv4.tcp_wmem': clamp_tcp_triplet(32768, 262144, tcp_wmem_max),
            'net.ipv4.tcp_notsent_lowat': math.floor(min(L / 2, 524288)),
            'net.ipv4.tcp_adv_win_scale': clamp_tcp_window_scale(max(2, math.ceil(F * adv_component))),
            'net.ipv4.tcp_no_metrics_save': 1,
            'net.ipv4.tcp_max_syn_backlog': max_syn,
            'net.ipv4.tcp_max_orphans': 16384 if mem <= 256 else 32768,
            'net.ipv4.tcp_synack_retries': 2,
            'net.ipv4.tcp_syn_retries': 2,
            'net.ipv4.neigh.default.gc_thresh1': 256 if mem <= 512 else 512,
            'net.ipv4.neigh.default.gc_thresh2': 1024 if mem <= 512 else 2048,
            'net.ipv4.neigh.default.gc_thresh3': 2048 if mem <= 512 else 4096,
        }
    return data


def normalize_value(v):
    return ' '.join(str(v).split())


def sysctl_apply_and_readback(profile):
    sysctl_items = [(k, v) for k, v in profile.items() if k != 'mode']
    applied = 0
    matched = 0
    results = []
    for key, value in sysctl_items:
        write = subprocess.run(['sysctl', '-w', f'{key}={value}'], capture_output=True, text=True)
        ok = write.returncode == 0
        readback = None
        match = False
        if ok:
            applied += 1
            read = subprocess.run(['sysctl', '-n', key], capture_output=True, text=True)
            if read.returncode == 0:
                readback = normalize_value(read.stdout.strip())
                match = readback == normalize_value(value)
                if match:
                    matched += 1
        results.append({
            'key': key,
            'expected': normalize_value(value),
            'write_ok': ok,
            'write_stderr': write.stderr.strip(),
            'write_stdout': write.stdout.strip(),
            'readback': readback,
            'match': match,
        })
    total = len(sysctl_items)
    return {
        'total': total,
        'applied': applied,
        'matched': matched,
        'apply_success_ratio': applied / total if total else 0,
        'readback_match_ratio_of_all': matched / total if total else 0,
        'readback_match_ratio_of_applied': matched / applied if applied else 0,
        'results': results,
    }


def fetch_omnitt_evidence():
    req = Request('https://www.omnitt.com/tcp-optimizer', headers={'User-Agent': 'Mozilla/5.0'})
    status_note = 'public endpoint reachable'
    try:
        with urlopen(req, timeout=20) as resp:
            html = resp.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        status_note = f'public endpoint returns HTTP {e.code}; body still carries metadata shell, not generator UI'
        html = e.read().decode('utf-8', 'replace')
    return {
        'status_note': status_note,
        'title_found': 'TCP 迷之调参 - 智能网络优化工具' in html,
        'desc_found': '只需输入本地带宽、服务器带宽和网络延迟' in html,
        'html_excerpt': (m.group(1) if (m := re.search(r'<title>(.*?)</title>', html)) else None),
    }


def main():
    omnitt = fetch_omnitt_evidence()
    scenario_reports = []
    aggregate_total = aggregate_applied = aggregate_matched = 0
    for sc in SCENARIOS:
        profile = current_vpsbox_profile(sc['local_bw'], sc['vps_bw'], sc['latency'], sc['mem'], sc['ramp'], sc['cc'], sc['ecn'])
        apply_report = sysctl_apply_and_readback(profile)
        aggregate_total += apply_report['total']
        aggregate_applied += apply_report['applied']
        aggregate_matched += apply_report['matched']
        mismatches = [r for r in apply_report['results'] if not r['match']]
        failed = [r for r in apply_report['results'] if not r['write_ok']]
        scenario_reports.append({
            'scenario': sc,
            'mode': profile['mode'],
            'key_count': apply_report['total'],
            'apply_success_ratio': apply_report['apply_success_ratio'],
            'readback_match_ratio_of_all': apply_report['readback_match_ratio_of_all'],
            'readback_match_ratio_of_applied': apply_report['readback_match_ratio_of_applied'],
            'failed_writes': failed,
            'mismatches': mismatches,
            'sample_values': {k: profile[k] for k in ['net.core.default_qdisc','net.core.rmem_max','net.core.wmem_max','net.ipv4.tcp_rmem','net.ipv4.tcp_wmem','net.ipv4.tcp_adv_win_scale','net.core.somaxconn','net.core.netdev_max_backlog']},
        })
    overall = {
        'total': aggregate_total,
        'applied': aggregate_applied,
        'matched': aggregate_matched,
        'apply_success_ratio': aggregate_applied / aggregate_total if aggregate_total else 0,
        'readback_match_ratio_of_all': aggregate_matched / aggregate_total if aggregate_total else 0,
        'readback_match_ratio_of_applied': aggregate_matched / aggregate_applied if aggregate_applied else 0,
    }
    report = {
        'omnitt_source': OMNITT_META,
        'omnitt_evidence': omnitt,
        'comparison_possible': False,
        'comparison_blocker': 'Omnitt public endpoint is not exposing runtime generator outputs or readable calculation code, so direct scenario-by-scenario diff against live Omnitt cannot be truthfully completed from public access.',
        'overall_verification': overall,
        'scenarios': scenario_reports,
    }
    REPORT_JSON.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    lines = []
    lines.append('# TCP tuning verification report')
    lines.append('')
    lines.append(f'- Omnitt source checked: {OMNITT_META}')
    lines.append(f"- Omnitt evidence: title_found={omnitt['title_found']}, desc_found={omnitt['desc_found']}, title={omnitt['html_excerpt']}")
    lines.append(f"- Direct Omnitt diff status: blocked ({report['comparison_blocker']})")
    lines.append('')
    lines.append('## Overall live applicability on this kernel')
    lines.append(f"- apply_success_ratio: {overall['apply_success_ratio']:.6f}")
    lines.append(f"- readback_match_ratio_of_all: {overall['readback_match_ratio_of_all']:.6f}")
    lines.append(f"- readback_match_ratio_of_applied: {overall['readback_match_ratio_of_applied']:.6f}")
    lines.append('')
    lines.append('## Scenario results')
    for item in scenario_reports:
        lines.append(f"- {item['scenario']['name']}: mode={item['mode']}, apply={item['apply_success_ratio']:.6f}, readback_all={item['readback_match_ratio_of_all']:.6f}, mismatches={len(item['mismatches'])}, failed_writes={len(item['failed_writes'])}")
        for key, value in item['sample_values'].items():
            lines.append(f"  - {key}: {value}")
        if item['failed_writes']:
            for r in item['failed_writes'][:5]:
                lines.append(f"  - FAILED {r['key']}: stderr={r['write_stderr']}")
        if item['mismatches']:
            for r in item['mismatches'][:5]:
                lines.append(f"  - MISMATCH {r['key']}: expected={r['expected']} readback={r['readback']}")
    REPORT_MD.write_text('\n'.join(lines) + '\n')
    print(json.dumps({'report_json': str(REPORT_JSON), 'report_md': str(REPORT_MD), 'overall': overall}, ensure_ascii=False))

if __name__ == '__main__':
    main()
