#!/usr/bin/env python3
"""Read-only macOS NetBar CPU/RSS sampling; never starts or kills an application."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time


def cpu_seconds(value):
    days, _, rest = value.rpartition('-')
    total = float(days or 0) * 86400
    fields = (rest or value).split(':')
    return total + sum(float(v) * 60 ** i for i, v in enumerate(reversed(fields)))


def snapshot():
    output = subprocess.run(
        ['/bin/ps', '-axo', 'pid=,ppid=,time=,rss=,%cpu=,comm='],
        check=True, capture_output=True, text=True, timeout=5,
    ).stdout
    result = {}
    for line in output.splitlines():
        fields = line.split(None, 5)
        if len(fields) != 6:
            continue
        pid, parent, cpu, rss, percent, command = fields
        result[int(pid)] = dict(parent=int(parent), cpu=cpu_seconds(cpu), rss_kib=int(rss),
                                reported_cpu_percent=float(percent), name=Path(command).name)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int)
    parser.add_argument('--duration', type=float, default=60)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--max-cpu', type=float, help='Fail if NetBar mean CPU exceeds this percent of one core')
    args = parser.parse_args()
    if not 1 <= args.duration <= 3600:
        parser.error('duration must be 1–3600 seconds')
    first = snapshot()
    candidates = [pid for pid, p in first.items() if p['name'] == 'NetBar']
    if args.pid is None and len(candidates) != 1:
        parser.error('expected exactly one NetBar; specify --pid explicitly')
    pid = args.pid if args.pid is not None else candidates[0]
    if pid not in first or first[pid]['name'] != 'NetBar':
        parser.error('pid must identify a running NetBar process')
    started = time.monotonic()
    initial_cpu = first[pid]['cpu']
    samples = []
    seen = {pid}
    child_cpu = {}
    peak_rss = first[pid]['rss_kib']
    while True:
        current = snapshot()
        if pid not in current:
            raise SystemExit('NetBar exited during measurement; no passing result recorded')
        owned = {pid}
        while True:
            more = {p for p, info in current.items() if info['parent'] in owned}
            if more <= owned:
                break
            owned |= more
        seen |= owned
        for child in (seen & current.keys()) - {pid}:
            child_cpu[child] = current[child]['cpu']
        elapsed = time.monotonic() - started
        peak_rss = max(peak_rss, current[pid]['rss_kib'])
        samples.append(dict(elapsed=round(elapsed, 3), main=current[pid],
                            children={p: current[p] for p in sorted(owned - {pid})}))
        if elapsed >= args.duration:
            break
        time.sleep(min(1, args.duration - elapsed))
    cpu = current[pid]['cpu'] - initial_cpu
    mean = cpu / elapsed * 100
    result = dict(
        measured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        pid=pid, duration_seconds=round(elapsed, 3), main_cpu_seconds=round(cpu, 3),
        main_mean_cpu_percent=round(mean, 3), main_peak_rss_mib=round(peak_rss / 1024, 2),
        observed_child_cpu_seconds=round(sum(child_cpu.values()), 3),
        observed_child_count=len(child_cpu), samples=samples,
        limitation='Child CPU is a sampled lower bound; short-lived processes and WebKit XPC workers are not fully attributed. CPU is not temperature or whole-machine power.',
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'samples'}, indent=2))
    if args.max_cpu is not None and mean > args.max_cpu:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
