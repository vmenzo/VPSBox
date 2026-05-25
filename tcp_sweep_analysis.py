#!/usr/bin/env python3
import json
import math
from pathlib import Path

OUT_JSON = Path('/root/github/VPSBox/tcp_sweep_analysis.json')
OUT_MD = Path('/root/github/VPSBox/tcp_sweep_analysis.md')

LOCAL_BWS = [5, 20, 100, 300, 1000, 5000, 20000, 100000]
VPS_BWS = [10, 100, 1000, 10000]
LATENCIES = [1, 20, 60, 120, 180, 350, 800, 1500, 2000]
MEMS = [64, 128, 256, 512, 1024, 2048, 4096, 8192, 32768]
RAMPS = [0.1, 0.5, 1.0]


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
        return 512 * 1024 * 1024 if latency_ms > 1300 else 384 * 1024 * 1024 if latency_ms > 900 else 256 * 1024 * 1024
    if mem_mb <= 8192:
        return 768 * 1024 * 1024 if latency_ms > 1300 else 640 * 1024 * 1024 if latency_ms > 900 else 512 * 1024 * 1024
    return None

def tuned_min_free_kbytes(mem_mb, target_kbytes, high_latency=False):
    floor = 16384 if mem_mb <= 64 else 24576 if mem_mb <= 128 else 32768 if mem_mb <= 256 else 49152 if mem_mb <= 512 else 65536
    ceiling = int(mem_mb * (384 if mem_mb <= 128 else 320 if mem_mb <= 256 else 256 if mem_mb <= 512 else 192 if mem_mb <= 1024 else 160))
    if high_latency:
        ceiling = int(ceiling * 1.15)
    ceiling = max(floor, min(1048576, ceiling))
    return int(clamp(target_kbytes, floor, ceiling))

def triplet_parts(s):
    return [int(x) for x in str(s).split()]

def profile(local_bw, vps_bw, latency, mem, ramp):
    if latency <= 120:
        mode = 'low'
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
        return {'mode': mode,'qdisc': qdisc,'rmem_max': U,'wmem_max': U,'somaxconn': somaxconn,'backlog': backlog,'max_syn': max_syn,'min_free': min_free,'tcp_rmem': clamp_tcp_triplet(8192, 87380, tcp_rmem_max),'tcp_wmem': clamp_tcp_triplet(8192, 65536, tcp_wmem_max),'adv': adv_win_scale}

    mode = 'high'
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
    latency_factor = clamp((math.log(latency_input * (latency_curve_tolerance - 1) + 1) / math.log(latency_curve_tolerance)) * latency_tolerance * curve1 if latency_input > 0 else 0, 1, 8)
    buffer_factor = clamp(latency_factor * tcpcong(curve1, 'congestion_avoidance', 10) * throughput_priority * buffer_aggression * memory_util * piecewise(curve1, [(0,1),(0.3,1.5),(0.6,2.5),(1,4)]), 1, 8)
    queue_factor = clamp(latency_factor / 3 * (math.log(qtheory(S / 131072 * conn_scaling, latency / 1000 * 3, min(0.9, 0.85 * curve1)) + 1) / math.log(10000) * queue_depth), 0.8, 4)
    adv_factor = max(0, math.ceil(math.log2(max(1, 4 * math.ceil(S * latency / 1000) / 65535))))
    adv_component = clamp(latency_factor / (latency_tolerance * 2.4) * adv_factor * (win_base * 0.44) * (0.95 * curve1 + 0.5), 2, max(4, win_max - 5))
    if mem <= 512:
        K = clamp(1.5 * F, 3, 6) * buffer_factor
        Q = clamp(1.5 * F, 3, 6)
    elif mem <= 1024:
        K = clamp(1.8 * F, 4, 8) * buffer_factor
        Q = clamp(1.8 * F, 4, 8)
    else:
        K = clamp(2 * F, 5, 10) * buffer_factor
        Q = clamp(2 * F, 5, 10)
    W = clamp_kernel_buffer(max(W, 32768))
    tcp_rmem_max = clamp_kernel_buffer(min(math.floor(L * Q), W))
    tcp_wmem_max = clamp_kernel_buffer(min(math.floor(L * K), W))
    J = math.ceil(min(3 * max(50, S / 131072), 20000) * queue_factor)
    Z = 0.8 if mem <= 512 else 1 if mem <= 1024 else 1.3 if mem <= 2048 else 1.5
    somaxconn = int(clamp(math.floor(0.15 * J * Z), 2560, 8192 if mem <= 512 else 16384))
    backlog = int(clamp(math.floor(0.3 * J * Z), 8192, 16384 if mem <= 512 else 32768))
    max_syn = int(clamp(math.floor(0.6 * J * Z), 8192, 32768 if mem <= 512 else 65536))
    min_free = tuned_min_free_kbytes(mem, math.floor(1024 * mem * (0.02 if mem <= 512 else 0.025 if mem <= 1024 else 0.03 if mem <= 2048 else 0.035) + math.floor(0.6 * math.ceil(S / 1024))), high_latency=True)
    return {'mode': mode,'qdisc': qdisc,'rmem_max': W,'wmem_max': W,'somaxconn': somaxconn,'backlog': backlog,'max_syn': max_syn,'min_free': min_free,'tcp_rmem': clamp_tcp_triplet(32768, 262144, tcp_rmem_max),'tcp_wmem': clamp_tcp_triplet(32768, 262144, tcp_wmem_max),'adv': clamp_tcp_window_scale(max(2, math.ceil(F * adv_component)))}

def analyze(case, p):
    issues = []
    tcp_rmem = triplet_parts(p['tcp_rmem'])
    latency = case['latency']
    mem = case['mem']
    ratio = case['local_bw'] / case['vps_bw']
    if p['mode'] == 'high':
        if p['adv'] >= 31 and latency < 250:
            issues.append('adv_win_scale_saturated_early')
        if p['adv'] >= 31 and latency < 500 and ratio <= 1:
            issues.append('adv_win_scale_saturated_sub500ms')
        if p['rmem_max'] < 32768:
            issues.append('core_buffer_below_triplet_min')
        if p['rmem_max'] <= 262144 and latency >= 800 and ratio <= 1:
            issues.append('very_high_latency_buffer_too_small')
        if tcp_rmem[2] <= 262144 and latency >= 800 and mem >= 1024 and ratio <= 1:
            issues.append('high_latency_tcp_rmem_ceiling_too_low')
    if p['min_free'] > mem * 1024 * 0.5:
        issues.append('min_free_kbytes_excessive_vs_mem')
    if p['rmem_max'] > 268435456 and mem <= 512:
        issues.append('buffer_too_aggressive_for_small_mem')
    if p['rmem_max'] == 1073741824:
        issues.append('kernel_buffer_cap_hit')
    return issues

def main():
    cases = []
    for lb in LOCAL_BWS:
        for vb in VPS_BWS:
            for lat in LATENCIES:
                for mem in MEMS:
                    for ramp in RAMPS:
                        case = {'local_bw': lb, 'vps_bw': vb, 'latency': lat, 'mem': mem, 'ramp': ramp}
                        p = profile(**case)
                        issues = analyze(case, p)
                        cases.append({'case': case, 'profile': p, 'issues': issues})
    counts = {}
    for c in cases:
        for i in c['issues']:
            counts[i] = counts.get(i, 0) + 1
    report = {
        'issue_counts': counts,
        'examples': {k: next(c for c in cases if k in c['issues']) for k in counts},
        'extremes': {
            'rmem_min': min(cases, key=lambda c: c['profile']['rmem_max']),
            'rmem_max': max(cases, key=lambda c: c['profile']['rmem_max']),
            'adv_max': max(cases, key=lambda c: c['profile']['adv']),
            'min_free_max': max(cases, key=lambda c: c['profile']['min_free']),
        }
    }
    OUT_JSON.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    lines = ['# TCP sweep analysis', '']
    for k, v in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append(f'- {k}: {v}')
    OUT_MD.write_text('\n'.join(lines) + '\n')
    print(json.dumps(report, ensure_ascii=False))

if __name__ == '__main__':
    main()
