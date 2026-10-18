#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""framestats.py <run name>...: one line per bench run from its per-flip log
($BB_BENCH_DIR/runs/bench-<name>-frames.csv, BB_FRAME_LOG) and, when present, its per-thread CPU
log (-threads.csv, BB_THREAD_CPU_CSV) and game log (thermal pressure at the end).

In-game flips only (>= 300 draws), the first 20 s in game skipped. Columns: flips, FPS, frame time
median/p99/max, gpu_ms median/p90 (Metal: union of the command buffers' GPU intervals),
rec_busy_ms median/p90 (the recording thread), the mean waits, draws/dispatches/submissions a
flip, compiles, the per-thread CPU groups in cores (last two thirds of the samples), missed
30-FPS slots (flips > 40 ms, meaningful at the cap) and the last thermal pressure level logged.

    python3 -I macos/bench/framestats.py yh-mtl540u-1 yh-mtl540u-2 | column -t
"""
import csv
import os
import statistics as st
import sys

RUNS = os.path.join(os.environ.get('BB_BENCH_DIR', os.path.expanduser('~/Games/Bloodborne/bench')), 'runs')


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p / 100 * len(v)))] if v else float('nan')


def fl(r, k):
    try:
        return float(r[k] or 'nan')
    except (ValueError, KeyError, TypeError):
        return float('nan')


HDR = ('name', 'n', 'fps', 'med_ms', 'p99_ms', 'max_ms', 'gpu_med', 'gpu_p90', 'rec_med', 'rec_p90',
       'gnm_wait', 'present_wait', 'tick_wait', 'draws', 'disp', 'subm', 'compiles',
       'thr_guest', 'thr_port', 'thr_metal', 'thr_other', 'miss40_pct', 'thermal')


def summary(name):
    f = f'{RUNS}/bench-{name}-frames.csv'
    if not os.path.exists(f):
        return [name, 'missing']
    game = [r for r in csv.DictReader(open(f)) if fl(r, 'draws') >= 300]
    if not game:
        return [name, 'no in-game flips']
    t0 = fl(game[0], 't_s') + 20  # streaming and compiles right after the load
    g = [r for r in game if fl(r, 't_s') >= t0] or game
    ft = [fl(r, 'frame_ms') for r in g]

    def col(k):
        return [x for x in (fl(r, k) for r in g) if x == x]

    thr = {}
    tf = f'{RUNS}/bench-{name}-threads.csv'
    if os.path.exists(tf):
        rows = list(csv.DictReader(open(tf)))
        epochs = sorted({r['epoch_s'] for r in rows})
        keep = set(epochs[len(epochs) // 3:])
        for r in rows:
            if r['epoch_s'] in keep:
                thr[r['group']] = thr.get(r['group'], 0) + \
                    (float(r['user_ms']) + float(r['sys_ms'])) / float(r['interval_s'])
        for k in thr:
            thr[k] /= max(1, len(keep)) * 1000  # cores
    thermal = 'nominal'
    lf = f'{RUNS}/bench-{name}.log'
    if os.path.exists(lf):
        for line in open(lf, errors='replace'):
            if line.startswith('Thermal pressure:'):
                thermal = line.split('->')[1].split()[0]
    gpu, rec = col('gpu_ms'), col('rec_busy_ms')
    return [name, len(g), 1000 * len(ft) / sum(ft), st.median(ft), pct(ft, 99), max(ft),
            st.median(gpu) if gpu else 0.0, pct(gpu, 90), st.median(rec) if rec else 0.0, pct(rec, 90),
            st.mean(col('gnm_wait_ms') or [0]), st.mean(col('present_wait_ms') or [0]),
            st.mean(col('tick_wait_ms') or [0]), st.mean(col('draws')), st.mean(col('dispatches') or [0]),
            st.mean(col('submissions') or [0]), sum(col('compiles')),
            thr.get('guest', 0.0), thr.get('port', 0.0), thr.get('metal', 0.0), thr.get('other', 0.0),
            100 * sum(1 for x in ft if x > 40) / len(ft), thermal]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    print('\t'.join(HDR))
    for name in sys.argv[1:]:
        print('\t'.join(f'{x:.2f}' if isinstance(x, float) else str(x) for x in summary(name)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
