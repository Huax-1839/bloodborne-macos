#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""temporal_synth.py <outdir> [--size WxH] [--verify] [--jobs N]

Synthetic burst dumps for testing temporal_metrics.py without the game (stdlib only): the same
layout temporal_check.sh writes (<outdir>/<sequence>/fNNN_<W>x<H>_rgba.raw) from an analytic
band-limited texture, so every sub-pixel shift is exact:

  vpan-e0/e8/e2-r1/r2  6 vertical pans with known shifts; the settings differ in contrast (e0
                       sharpest, e8 softest; noise adds gradient energy, so it stays equal)
  dpan                 diagonal pan, known shifts
  strafe               a still camera with a 'character' block moving through the centre
  cut, cut-steady      still view; the post-close frames carry a decaying ghost (tile 192,128), a
                       persistent offset (tile 512,256) and a randomly animated tile (704,320)
                       that is animated in the steady frames too
  preset-q2p/p2q       40 frames; q2p has a black frame (17) and a contrast (sharpness) step at 25

truth.json records the shifts and anomalies. --verify runs temporal_metrics.py on the result and
checks the recovered shifts (within 0.25 px), the ghost/persistent/animation classification, the
black frame and the sharpness step, the vpan verdict; exit code 1 when a check fails.
"""
import argparse
import json
import math
import os
import random
import subprocess
import sys
import time
from itertools import repeat
from operator import add, mul

HERE = os.path.dirname(os.path.abspath(__file__))


class Texture:
    """f(x, y) = sum_k G_k(x) H_k(y), a few tens of levels of contrast: band-limited (periods 8..250 px, 1/f-like)."""

    def __init__(self, seed=7):
        rnd = random.Random(seed)
        self.comp = []
        def terms():
            fs = [math.exp(rnd.uniform(math.log(0.004), math.log(0.12))) for _ in range(6)]
            amps = [f ** -0.7 for f in fs]
            total = sum(amps)
            return [(f, rnd.uniform(0, 6.28), 0.5 * a / total) for f, a in zip(fs, amps)]
        for _ in range(4):
            self.comp.append((terms(), terms()))

    @staticmethod
    def table(terms, n, shift, scale):
        return [scale * sum(a * math.cos(2 * math.pi * f * (i - shift) + ph) for f, ph, a in terms)
                for i in range(n)]

    def frame_rows(self, W, H, sx, sy, amp=1.0):
        """Rows of floats (128 + 80 * amp * f(x - sx, y - sy))."""
        gt = [self.table(g, W, sx, 80.0 * amp * 2) for g, _ in self.comp]
        ht = [self.table(h, H, sy, 1.0 * 2) for _, h in self.comp]
        for y in range(H):
            acc = None
            for k in range(4):
                term = map(mul, gt[k], repeat(ht[k][y]))
                acc = term if acc is None else map(add, acc, term)
            yield list(map(add, acc, repeat(128.0)))


def to_rgba(row_lists, W, noise_amp, rnd, extra=None):
    """Raw RGBA bytes of the rows; `extra(y, row)` may modify a row (list of floats) first."""
    bank = [[rnd.randint(-noise_amp, noise_amp) if noise_amp else 0 for _ in range(W)]
            for _ in range(16)]
    out = bytearray()
    alpha = bytes([255]) * W
    for y, row in enumerate(row_lists):
        if extra:
            extra(y, row)
        if noise_amp:
            row = list(map(add, row, bank[y % 16]))
        try:
            v = bytes(map(int, row))
        except ValueError:  # a rare peak beyond 8 bits
            v = bytes(min(255, max(0, int(x))) for x in row)
        line = bytearray(W * 4)
        line[0::4] = v
        line[1::4] = v
        line[2::4] = v
        line[3::4] = alpha
        out += line
    return bytes(out)


def write_frame(d, i, W, H, data):
    with open(os.path.join(d, f'f{i:03d}_{W}x{H}_rgba.raw'), 'wb') as f:
        f.write(data)


def rect_adder(x0, x1, y0, y1, delta):
    def extra(y, row):
        if y0 <= y < y1:
            row[x0:x1] = [v + delta for v in row[x0:x1]]
    return extra


def chain(*fns):
    def run(y, row):
        for fn in fns:
            if fn:
                fn(y, row)
    return run


def make(outdir, W, H):
    tex = Texture()
    rnd = random.Random(1)
    truth = {}
    os.makedirs(outdir, exist_ok=True)

    def pan(name, shifts, amp, noise, start=(0.0, 0.0)):
        d = os.path.join(outdir, name)
        os.makedirs(d, exist_ok=True)
        x, y = start
        pos = [(x, y)]
        for sx, sy in shifts:
            x, y = x + sx, y + sy
            pos.append((x, y))
        for i, (px, py) in enumerate(pos):
            write_frame(d, i, W, H, to_rgba(tex.frame_rows(W, H, px, py, amp), W, noise, rnd))
        truth[name] = dict(shifts=shifts)

    t0 = time.time()
    # vertical pans: shifts of the content (dy < 0: the camera looks down), with a little speed
    # variation; settings differ in contrast (sharpness) and noise (stability)
    settings = {0: (1.0, 1), 8: (0.8, 1), 2: (0.9, 1)}
    for rep in (1, 2):
        for exp, (amp, noise) in settings.items():
            base = -7.0 - 0.6 * rep
            shifts = [(0.0, base + 0.35 * math.sin(i)) for i in range(8)]
            pan(f'vpan-e{exp}-r{rep}', shifts, amp, noise)
    pan('dpan', [(4.37 + 0.2 * i, -2.61 + 0.15 * ((-1) ** i)) for i in range(8)], 1.0, 1)
    print(f'panning sequences written ({time.time() - t0:.0f} s)')

    # strafe: still camera, a block (the character) moving through the centre
    d = os.path.join(outdir, 'strafe')
    os.makedirs(d, exist_ok=True)
    for i in range(8):
        bx = W // 2 - 80 + 6 * i
        by0, by1 = H // 2 - 100, H // 2 + 100
        rows = list(tex.frame_rows(W, H, 0, 0, 1.0))
        def block(y, row, bx=bx, by0=by0, by1=by1):
            if by0 <= y < by1:
                row[bx:bx + 100] = [152.0 if (x // 8 + y // 8) % 2 else 104.0 for x in range(100)]
        write_frame(d, i, W, H, to_rgba(rows, W, 1, rnd, block))
    truth['strafe'] = dict(shifts=[(0.0, 0.0)] * 7)

    # cut: steady frames (noise only), the animated tile is random in every frame
    still = lambda: list(tex.frame_rows(W, H, 0, 0, 1.0))

    rnd_anim = random.Random(5)
    # one offset a frame (same for all rows of the tile)
    def anim_frame():
        off = rnd_anim.uniform(-30, 30)
        return rect_adder(704, 768, 320, 384, off)
    ds = os.path.join(outdir, 'cut-steady')
    dc = os.path.join(outdir, 'cut')
    os.makedirs(ds, exist_ok=True)
    os.makedirs(dc, exist_ok=True)
    for i in range(8):
        write_frame(ds, i, W, H, to_rgba(still(), W, 1, rnd, anim_frame()))
    for i in range(12):
        ghost = rect_adder(192, 320, 128, 192, 55.0 * 0.55 ** i)
        persistent = rect_adder(512, 576, 256, 320, 40.0)
        write_frame(dc, i, W, H, to_rgba(still(), W, 1, rnd, chain(ghost, persistent, anim_frame())))
    truth['cut'] = dict(ghost=(192, 128), persistent=(512, 256), animated=(704, 320))
    print(f'cut sequences written ({time.time() - t0:.0f} s)')

    # preset: a slow pan; q2p has a black frame and a contrast step
    for name, bad_frame, step in (('preset-q2p', 17, 25), ('preset-p2q', None, None)):
        d = os.path.join(outdir, name)
        os.makedirs(d, exist_ok=True)
        for i in range(40):
            if i == bad_frame:
                data = bytearray(W * H * 4)
                data[3::4] = bytes([255]) * (W * H)
                write_frame(d, i, W, H, bytes(data))
                continue
            amp = 0.5 if step is not None and i >= step else 1.0
            write_frame(d, i, W, H, to_rgba(tex.frame_rows(W, H, 0.9 * i, 0.4 * i, amp), W, 1, rnd))
        truth[name] = dict(black=bad_frame, step=step)
    with open(os.path.join(outdir, 'truth.json'), 'w') as f:
        json.dump(truth, f)
    print(f'all written ({time.time() - t0:.0f} s)')
    return truth


def verify(outdir, truth, jobs):
    metrics = os.path.join(outdir, 'metrics.json')
    t0 = time.time()
    subprocess.run([sys.executable, os.path.join(HERE, 'temporal_metrics.py'), outdir,
                    '--json', metrics, '--jobs', str(jobs)], check=True)
    print(f'\nmetrics took {time.time() - t0:.0f} s')
    res = {r['name']: r for r in json.load(open(metrics))}
    failures = []
    worst = 0.0

    def check(ok, text):
        print(('PASS ' if ok else 'FAIL ') + text)
        if not ok:
            failures.append(text)

    for name, t in sorted(truth.items()):
        shifts = t.get('shifts')
        if shifts is None or name not in res:
            continue
        rows = res[name]['rows']
        err = 0.0
        for row, (sx, sy) in zip(rows[1:], shifts):
            err = max(err, abs(row['dx'] - sx), abs(row['dy'] - sy))
        worst = max(worst, err)
        check(err <= 0.25, f'{name}: shifts recovered, max error {err:.3f} px over {len(shifts)} pairs')
    print(f'worst shift error overall: {worst:.3f} px')
    cut = res.get('cut', {})
    tg = truth['cut']
    check(tuple(tg['ghost']) in [tuple(t) for t in cut.get('decaying', [])],
          f"cut: the ghost tile {tg['ghost']} is flagged as decaying "
          f"(decaying: {cut.get('decaying')})")
    check(tuple(tg['persistent']) in [tuple(t) for t in cut.get('persistent', [])],
          f"cut: the persistent tile {tg['persistent']} is flagged as staying "
          f"(persistent: {cut.get('persistent')})")
    check(tuple(tg['animated']) not in [tuple(t) for t in cut.get('decaying', []) +
                                        cut.get('persistent', [])],
          'cut: the randomly animated tile is flagged neither way')
    check(len(cut.get('decaying', [])) <= 4 and len(cut.get('persistent', [])) <= 4,
          'cut: no flood of false tiles')
    q = res.get('preset-q2p', {})
    check(q.get('bad') == [truth['preset-q2p']['black']],
          f"preset-q2p: the black frame {truth['preset-q2p']['black']} is the only garbage frame "
          f"(found {q.get('bad')})")
    check(q.get('step') is not None and abs(q['step'] - truth['preset-q2p']['step']) <= 1,
          f"preset-q2p: the sharpness step at {truth['preset-q2p']['step']} (found {q.get('step')})")
    p = res.get('preset-p2q', {})
    check(p.get('bad') == [], f"preset-p2q: no garbage frames (found {p.get('bad')})")
    sharp = {}
    for exp in (0, 8, 2):
        vals = [row['sharp'] for rep in (1, 2) for row in res[f'vpan-e{exp}-r{rep}']['rows']]
        sharp[exp] = sum(vals) / len(vals)
    check(max(sharp, key=sharp.get) == 0 and min(sharp, key=sharp.get) == 8,
          f'vpan: sharpness e0 {sharp[0]:.2f} > e2 {sharp[2]:.2f} > e8 {sharp[8]:.2f}')
    print('\nALL PASS' if not failures else f'\n{len(failures)} FAILED')
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('outdir')
    ap.add_argument('--size', default='960x540')
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--jobs', type=int, default=4)
    a = ap.parse_args()
    W, H = (int(v) for v in a.size.split('x'))
    truth = make(a.outdir, W, H)
    return verify(a.outdir, truth, a.jobs) if a.verify else 0


if __name__ == '__main__':
    sys.exit(main())
