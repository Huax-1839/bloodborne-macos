#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""temporal_metrics.py <dir> [--jobs N] [--json FILE] [--no-sheets] [--only a,b] [--preset-motion]

Temporal-stability metrics of the burst dumps macos/bench/temporal_check.sh makes (stdlib only).
<dir> holds one sub-directory per sequence (vpan-e<setting>-r<rep>, dpan, strafe, cut,
cut-steady, preset-*), each with consecutive display frames fNNN_<W>x<H>_<rgba|bgra>.raw
(4 bytes a pixel, BB_PRESENT_DUMP_TRIGGER dumps). Per frame pair:

  motion    global shift of the content from the previous frame to this one, full-resolution
            pixels (dx right, dy down; a camera looking down gives dy < 0): a SAD search at 1/8
            size (+-64 px) on the central 62% of the frame (the HUD sits outside), then
            Gauss-Newton sub-pixel refinement at 1/4 size
  res4/res2 PSNR (dB, luma) of the residual after compensating that shift, at 1/4 and 1/2 size,
            central crop only: the temporal stability (shimmer, ghosting and fresh noise show up
            as a low value; a steady camera and a perfect upscaler would give a high one)
  sharp     mean (|dx| + |dy|) / 2 of the luma gradient on a 640x360 central crop at full size
            (sharp_x, sharp_y: the two parts; vr = sharp_y / sharp_x is less view dependent)
  luma      mean luma of the frame
  raw       PSNR of the uncompensated frames (a 1/13 pixel sample of the green channel)

Sequences: vpan: the A/B/C table over the settings (experiment 0, 8, 2) with the repetitions as
the noise floor; cut (with cut-steady): per 64 px tile the maximum difference of every post-close
frame from the steady state, tiles that decay (a ghost of the menu or a trail) against tiles that
stay; preset-*: garbage frames (luma outliers, PSNR to both neighbours below 15 dB) and the frame
where the sharpness steps. A contact sheet (PNG, 4 frames a row at 1/3 size) is written next to
each sequence's frames as <sequence>/sheet.png, per-frame values as metrics.tsv.
Exit code 0 unless <dir> is missing or holds no frames; the caller judges the numbers.
"""
import argparse
import json
import math
import os
import re
import statistics
import struct
import sys
import time
import zlib
from concurrent.futures import ProcessPoolExecutor
from itertools import repeat
from operator import add, mul, sub

NAME = re.compile(r'^f?(\d+)_.*?_?(\d+)x(\d+)_(rgba|bgra)\.raw$')
TILE = 64            # full-resolution pixels of a tile of the cut analysis
GHOST_MIN_DIFF = 6.0 # luma levels at 1/8 size a tile must differ by to count
MAX_SHEET_FRAMES = 16
STEP_MIN = 0.04      # relative change of the sharpness a preset switch must make to be reported
CLIP3 = 24 * 256     # the SAD of the coarse search clips a pixel's difference at 24 luma levels


# ---------------------------------------------------------------- frame access

def list_frames(path):
    found = []
    for name in os.listdir(path):
        m = NAME.match(name)
        if m:
            found.append((int(m.group(1)), os.path.join(path, name), int(m.group(2)),
                          int(m.group(3)), m.group(4) == 'bgra'))
    found.sort()
    return [(p, w, h, bgra) for _, p, w, h, bgra in found]


def region_luma4(data, W, x0, y0, w, h):
    """4 * luma ((R + 2G + B) / 4 each) of the rectangle, a flat list (row-major, width w)."""
    rows = [data[((y0 + y) * W + x0) * 4:((y0 + y) * W + x0 + w) * 4] for y in range(h)]
    b = b''.join(rows)
    c0, c1, c2 = b[0::4], b[1::4], b[2::4]
    return list(map(add, map(add, c0, c2), map(add, c1, c1)))


def down2(p, w, h):
    """Sum of 2x2 blocks (w and h even); the scale grows by 4 a level."""
    hs = list(map(add, p[0::2], p[1::2]))
    w2 = w // 2
    out = []
    for y in range(0, h, 2):
        out.extend(map(add, hs[y * w2:(y + 1) * w2], hs[(y + 1) * w2:(y + 2) * w2]))
    return out


def sharpness(data, W, H):
    sw, sh = min(640, W), min(360, H)
    x0, y0 = (W - sw) // 2, (H - sh) // 2
    gx = gy = 0
    prev = None
    for y in range(sh):
        o = ((y0 + y) * W + x0) * 4
        row = data[o:o + sw * 4]
        c0, c1, c2 = row[0::4], row[1::4], row[2::4]
        lum = list(map(add, map(add, c0, c2), map(add, c1, c1)))
        gx += sum(map(abs, map(sub, lum[1:], lum[:-1])))
        if prev is not None:
            gy += sum(map(abs, map(sub, lum, prev)))
        prev = lum
    mx, my = gx / (sh * (sw - 1)) / 4, gy / ((sh - 1) * sw) / 4
    return (mx + my) / 2, mx, my


def mean_luma(data):
    r, g, b = data[0::52], data[1::52], data[2::52]
    n = len(g)
    return (sum(r) + 2 * sum(g) + sum(b)) / (4 * n)


def psnr_samples(a, b):
    d = list(map(sub, a, b))
    sse = sum(map(mul, d, d))
    return 99.0 if sse == 0 else 10 * math.log10(255 * 255 / (sse / len(d)))


# ---------------------------------------------------------------- motion

def geometry(W, H):
    cw, ch = int(W * 0.625) // 16 * 16, int(H * 0.625) // 16 * 16
    cx0, cy0 = (W - cw) // 2 // 8 * 8, (H - ch) // 2 // 8 * 8
    mx = min(80, cx0 // 8 * 8)
    my = min(80, cy0 // 8 * 8)
    return dict(cw=cw, ch=ch, mx=mx, my=my, rx0=cx0 - mx, ry0=cy0 - my, rw=cw + 2 * mx,
                rh=ch + 2 * my, ok=mx >= 24 and my >= 24 and cw >= 64 and ch >= 64)


def pyramid(data, W, g):
    p = region_luma4(data, W, g['rx0'], g['ry0'], g['rw'], g['rh'])
    w, h = g['rw'], g['rh']
    levels = {}
    for k in (1, 2, 3):
        p = down2(p, w, h)
        w, h = w // 2, h // 2
        levels[k] = p
    return levels


def level_geom(g, k):
    return g['rw'] >> k, (g['mx'] >> k), (g['my'] >> k), g['cw'] >> k, g['ch'] >> k


def gradients(A, g, k):
    """Central differences (twice the gradient) over the crop and their products."""
    w, ox, oy, cw, ch = level_geom(g, k)
    gx, gy = [], []
    for y in range(ch):
        r = (oy + y) * w + ox
        gx.extend(map(sub, A[r + 1:r + cw + 1], A[r - 1:r + cw - 1]))
        gy.extend(map(sub, A[r + w:r + w + cw], A[r - w:r - w + cw]))
    return gx, gy, list(map(mul, gx, gx)), list(map(mul, gx, gy)), list(map(mul, gy, gy))


def sad_search(A3, B3, g):
    w, ox, oy, cw, ch = level_geom(g, 3)
    rx, ry = max(0, min(8, ox - 2)), max(0, min(8, oy - 2))
    ys = range(0, ch, 2)
    tmpl = [A3[(oy + y) * w + ox:(oy + y) * w + ox + cw] for y in ys]
    cands = sorted(((sx, sy) for sy in range(-ry, ry + 1) for sx in range(-rx, rx + 1)),
                   key=lambda c: c[0] * c[0] + c[1] * c[1])
    best, best_s = None, (0, 0)
    for sx, sy in cands:
        tot = 0
        for n, (t, y) in enumerate(zip(tmpl, ys)):
            o = (oy + y + sy) * w + ox + sx
            tot += sum(map(min, map(abs, map(sub, t, B3[o:o + cw])), repeat(CLIP3)))
            if best is not None and tot >= best:
                break
        else:
            if best is None or tot < best:
                best, best_s = tot, (sx, sy)
    saturated = abs(best_s[0]) >= rx > 0 or abs(best_s[1]) >= ry > 0
    return best_s, saturated


def residual(A, B, g, k, sx, sy):
    """B(p + s) - A(p) over the crop at level k (bilinear), a flat list."""
    w, ox, oy, cw, ch = level_geom(g, k)
    ix, iy = math.floor(sx), math.floor(sy)
    fx, fy = sx - ix, sy - iy
    w00, w10, w01, w11 = (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy
    e = []
    for y in range(ch):
        r0 = (oy + y + iy) * w + ox + ix
        r1 = r0 + w
        interp = map(add,
                     map(add, map(mul, B[r0:r0 + cw], repeat(w00)),
                         map(mul, B[r0 + 1:r0 + cw + 1], repeat(w10))),
                     map(add, map(mul, B[r1:r1 + cw], repeat(w01)),
                         map(mul, B[r1 + 1:r1 + cw + 1], repeat(w11))))
        e.extend(map(sub, interp, A[(oy + y) * w + ox:(oy + y) * w + ox + cw]))
    return e


def refine(A, B, g, k, s, grad, maxit, thresh=None):
    """Gauss-Newton on the shift s = (sx, sy) at level k with outlier rejection (pixels whose
    residual exceeds `thresh`, by default 3 sigma of the median absolute residual of the pass:
    a moving object does not drag the global motion). Returns (sse over all pixels, n, s, thresh
    of the last pass)."""
    gx, gy, gxx, gxy, gyy = grad
    limit_x, limit_y = (g['mx'] >> k) - 3, (g['my'] >> k) - 3
    scale = 4 * 4 ** k
    best = None
    sx, sy = s
    for it in range(maxit + 1):
        e = residual(A, B, g, k, sx, sy)
        sse = sum(map(mul, e, e))
        n = len(e)
        if thresh is None:
            t = max(1.0 * scale, 3 * 1.4826 * sorted(map(abs, e))[n // 2])
        else:
            t = thresh
        m = [1.0 if -t < v < t else 0.0 for v in e]
        em = list(map(mul, e, m))
        robust = sum(map(mul, em, e)) / max(1.0, sum(m))
        if best is None or robust < best[0]:
            best = (robust, sse, n, (sx, sy), t)
        if it == maxit:
            break
        hxx, hxy, hyy = (sum(map(mul, m, q)) / 4 for q in (gxx, gxy, gyy))
        det = hxx * hyy - hxy * hxy
        if det <= 1e-9 * (hxx * hyy + 1):
            break
        bx, by = sum(map(mul, em, gx)) / 2, sum(map(mul, em, gy)) / 2
        dx = -(hyy * bx - hxy * by) / det
        dy = -(-hxy * bx + hxx * by) / det
        dx, dy = max(-2.0, min(2.0, dx)), max(-2.0, min(2.0, dy))
        if abs(dx) < 0.01 and abs(dy) < 0.01:
            break
        sx = max(-limit_x, min(limit_x, sx + dx))
        sy = max(-limit_y, min(limit_y, sy + dy))
    return best[1], best[2], best[3], best[4]


def level_psnr(sse, n, k):
    scale = 4 * 4 ** k
    mse = sse / n / (scale * scale)
    return 99.0 if mse <= 0 else 10 * math.log10(255 * 255 / mse)


def motion_pair(prev, cur, g):
    (s3x, s3y), saturated = sad_search(prev['lv'][3], cur['lv'][3], g)
    if 'grad2' not in prev:
        prev['grad2'] = gradients(prev['lv'][2], g, 2)
    if 'grad1' not in prev:
        prev['grad1'] = gradients(prev['lv'][1], g, 1)
    sse, n, (sx, sy), t = refine(prev['lv'][2], cur['lv'][2], g, 2, (2.0 * s3x, 2.0 * s3y),
                                 prev['grad2'], 3)
    res4 = level_psnr(sse, n, 2)
    # the last refinement at 1/2 size (the 1/4 size image of fine texture is aliased: a bias of
    # a fraction of a pixel); its residual (all pixels) is the res2 figure
    sse1, n1, (s1x, s1y), _ = refine(prev['lv'][1], cur['lv'][1], g, 1, (2 * sx, 2 * sy),
                                     prev['grad1'], 2, t / 4)
    return dict(dx=s1x * 2, dy=s1y * 2, res4=res4, res2=level_psnr(sse1, n1, 1), sat=saturated)


# ---------------------------------------------------------------- frames, thumbs, PNG

DIV9 = bytes(min(255, v // 9) for v in range(2296))


def thumb(data, W, H, bgra):
    """The frame at 1/3 size (3x3 box): a list of RGB rows (bytes)."""
    tw, th = W // 3, H // 3
    chans = []
    for c in (0, 1, 2):
        plane = data[c::4]
        rows = []
        for y in range(th):
            acc = None
            for k in range(3):
                o = (3 * y + k) * W
                row = plane[o:o + tw * 3]
                hs = map(add, map(add, row[0::3], row[1::3]), row[2::3])
                acc = hs if acc is None else map(add, acc, hs)
            rows.append(bytes(map(DIV9.__getitem__, acc)))
        chans.append(rows)
    r, gch, b = (chans[2], chans[1], chans[0]) if bgra else chans
    out = []
    for y in range(th):
        ba = bytearray(tw * 3)
        ba[0::3], ba[1::3], ba[2::3] = r[y], gch[y], b[y]
        out.append(bytes(ba))
    return out


def write_png(path, rows, width):
    raw = b''.join(b'\x00' + r for r in rows)
    def chunk(tag, body):
        return (struct.pack('>I', len(body)) + tag + body +
                struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff))
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', width, len(rows), 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 1)) + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


def write_sheet(path, thumbs):
    if not path or not thumbs:
        return
    tw, th = len(thumbs[0][0]) // 3, len(thumbs[0])
    gut = 4
    cols = 4
    gutter = bytes([64, 64, 64]) * gut
    blank = bytes([32, 32, 32]) * tw
    rows = []
    for r in range(0, len(thumbs), cols):
        group = thumbs[r:r + cols]
        for y in range(th):
            parts = [t[y] for t in group] + [blank] * (cols - len(group))
            rows.append(gutter.join(parts))
        rows.extend([bytes([64, 64, 64]) * (cols * tw + (cols - 1) * gut)] * gut)
    write_png(path, rows, cols * tw + (cols - 1) * gut)


def sheet_indices(n):
    if n <= MAX_SHEET_FRAMES:
        return list(range(n))
    return sorted({round(i * (n - 1) / (MAX_SHEET_FRAMES - 1)) for i in range(MAX_SHEET_FRAMES)})


def frame_l3(data, W, H):
    """Luma (0..255 scale) at 1/8 size of the whole frame: (plane, width, height)."""
    w8, h8 = W // 8 * 8, H // 8 * 8
    p = region_luma4(data, W, 0, 0, w8, h8)
    w, h = w8, h8
    for _ in range(3):
        p = down2(p, w, h)
        w, h = w // 2, h // 2
    return [v / 256.0 for v in p], w, h


def analyze_frames(frames, motion=True, want_l3=False, sheet=None):
    """Per-frame metrics of an ordered burst. Returns (list of dict, thumbs, extra)."""
    out, thumbs, l3 = [], [], []
    prev = None
    g = None
    want = set(sheet_indices(len(frames))) if sheet else set()
    for i, (path, W, H, bgra) in enumerate(frames):
        data = open(path, 'rb').read()
        if len(data) != W * H * 4:
            raise ValueError(f'{path}: {len(data)} bytes, expected {W * H * 4}')
        if g is None:
            g = geometry(W, H)
        sharp, sharp_x, sharp_y = sharpness(data, W, H)
        cur = dict(i=i, name=os.path.basename(path), sharp=sharp, luma=mean_luma(data),
                   sample=data[1::52])
        use_motion = motion and g['ok']
        if use_motion:
            cur['lv'] = pyramid(data, W, g)
        if want_l3:
            l3.append(frame_l3(data, W, H))
        if i in want:
            thumbs.append(thumb(data, W, H, bgra))
        row = dict(i=i, name=cur['name'], sharp=sharp, sx=sharp_x, sy=sharp_y,
                   vr=sharp_y / sharp_x if sharp_x > 0 else None, luma=cur['luma'], raw=None,
                   dx=None, dy=None, res4=None, res2=None, sat=False)
        if prev is not None:
            row['raw'] = psnr_samples(prev['sample'], cur['sample'])
            if use_motion and 'lv' in prev:
                row.update(motion_pair(prev, cur, g))
            prev.pop('lv', None)
            prev.pop('grad2', None)
            prev.pop('grad1', None)
        out.append(row)
        prev = cur
    return out, thumbs, l3


# ---------------------------------------------------------------- per-sequence analyses

def med(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def summarize(rows):
    mags = [math.hypot(r['dx'], r['dy']) for r in rows if r['dx'] is not None]
    return dict(n=len(rows), dx=med([r['dx'] for r in rows]), dy=med([r['dy'] for r in rows]),
                mag=med(mags), res4=med([r['res4'] for r in rows]),
                res2=med([r['res2'] for r in rows]), sharp=med([r['sharp'] for r in rows]),
                vr=med([r['vr'] for r in rows]),
                luma=med([r['luma'] for r in rows]), raw=med([r['raw'] for r in rows]),
                saturated=sum(1 for r in rows if r['sat']))


def fmt(v, spec='.2f'):
    return '-' if v is None else format(v, spec)


def table(rows):
    lines = ['  fr    dx     dy   res4   res2  sharp  luma    raw']
    for r in rows:
        lines.append(f"  {r['i']:2d} {fmt(r['dx'], '6.2f'):>6} {fmt(r['dy'], '6.2f'):>6} "
                     f"{fmt(r['res4'], '6.2f'):>6} {fmt(r['res2'], '6.2f'):>6} "
                     f"{r['sharp']:6.2f} {r['luma']:5.1f} {fmt(r['raw'], '6.2f'):>6}")
    return lines


def write_tsv(path, rows):
    with open(path, 'w') as f:
        f.write('frame\tname\tdx\tdy\tres4\tres2\tsharp\tsharp_x\tsharp_y\tluma\traw\n')
        for r in rows:
            f.write('\t'.join([str(r['i']), r['name']] + [fmt(r[k], '.4f') for k in
                              ('dx', 'dy', 'res4', 'res2', 'sharp', 'sx', 'sy', 'luma', 'raw')]) + '\n')


def tiles_max(diff, w, h):
    """Per 8x8 block (a 64 px tile at 1/8 size) maximum of a flat list: dict-free grid."""
    tx, ty = (w + 7) // 8, (h + 7) // 8
    grid = [[0.0] * tx for _ in range(ty)]
    for y in range(h):
        row = diff[y * w:(y + 1) * w]
        grow = grid[y // 8]
        for t in range(tx):
            m = max(row[t * 8:t * 8 + 8])
            if m > grow[t]:
                grow[t] = m
    return grid, tx, ty


def analyze_cut(cut_frames, steady_frames, sheet_path, name):
    result = dict(kind='cut', name=name)
    rows, thumbs, l3 = analyze_frames(cut_frames, motion=True, want_l3=True, sheet=bool(sheet_path))
    srows, _, sl3 = analyze_frames(steady_frames, motion=True, want_l3=True) \
        if steady_frames else ([], [], [])
    result['rows'], result['steady_rows'] = rows, srows
    write_sheet(sheet_path, thumbs)
    out = [f'== {name}: {len(rows)} frames after the menu closed, {len(srows)} steady frames']
    out += table(rows)
    if srows:
        out += ['  steady:'] + table(srows)
    if not sl3:
        out.append('  no steady frames: ghost analysis skipped')
        result['text'] = out
        return result
    plane, w, h = sl3[0]
    n = len(sl3)
    ref = [sum(s[0][k] for s in sl3) / n for k in range(w * h)]
    floor_grid = None
    for s in sl3:
        grid, tx, ty = tiles_max([abs(a - b) for a, b in zip(s[0], ref)], w, h)
        if floor_grid is None:
            floor_grid = grid
        else:
            floor_grid = [[max(a, b) for a, b in zip(r1, r2)] for r1, r2 in zip(floor_grid, grid)]
    diffs = []
    for p, pw, ph in l3:
        grid, _, _ = tiles_max([abs(a - b) for a, b in zip(p, ref)], w, h)
        diffs.append(grid)
    k = min(3, len(diffs))
    decaying, persistent, ghost = [], [], []
    active_per_frame = [0] * len(diffs)
    for ty_ in range(ty):
        for tx_ in range(tx):
            fl = floor_grid[ty_][tx_]
            thr = max(GHOST_MIN_DIFF, 2.5 * fl)
            prof = [d[ty_][tx_] for d in diffs]
            for i, v in enumerate(prof):
                if v > thr:
                    active_per_frame[i] += 1
            first = sum(prof[:k]) / k
            last = sum(prof[-k:]) / k
            if first > thr and last < 0.5 * first:
                decaying.append((tx_, ty_, thr, prof, last <= thr))
            elif last > thr and last >= 0.6 * first:
                persistent.append((tx_, ty_, thr, prof))
    decaying.sort(key=lambda t: -t[3][0])
    persistent.sort(key=lambda t: -max(t[3]))
    cleared = next((i for i in range(len(diffs)) if all(
        not (d_[3][i] > d_[2]) for d_ in decaying)), None)
    out.append(f'  tiles: {tx}x{ty} of {TILE} px, threshold max({GHOST_MIN_DIFF:g}, 2.5 x the '
               f'steady spread) luma levels')
    out.append('  tiles above threshold per post-close frame: ' +
               ' '.join(str(c) for c in active_per_frame))
    out.append(f'  decaying tiles (ghost/trail/fade): {len(decaying)}, '
               f'of which gone by the last frame: {sum(1 for d_ in decaying if d_[4])}; '
               f'all below threshold from frame {cleared if cleared is not None else "never"}')
    for tx_, ty_, thr, prof, gone in decaying[:5]:
        out.append(f'    tile x={tx_ * TILE} y={ty_ * TILE}: ' + ' '.join(f'{v:.0f}' for v in prof) +
                   f' (thr {thr:.0f}){"" if gone else "  still above threshold"}')
    out.append(f'  persistent tiles (differ from the steady state throughout: animation/other '
               f'content): {len(persistent)}')
    for tx_, ty_, thr, prof in persistent[:5]:
        out.append(f'    tile x={tx_ * TILE} y={ty_ * TILE}: ' + ' '.join(f'{v:.0f}' for v in prof) +
                   f' (thr {thr:.0f})')
    result.update(decaying=[(a * TILE, b * TILE) for a, b, *_ in decaying],
                  persistent=[(a * TILE, b * TILE) for a, b, *_ in persistent],
                  active_per_frame=active_per_frame, cleared=cleared)
    ramp = [r['sharp'] for r in rows]
    if ramp:
        steady_sharp = med([r['sharp'] for r in srows])
        out.append(f'  sharpness {ramp[0]:.2f} -> {ramp[-1]:.2f} over the burst'
                   + (f' (steady {steady_sharp:.2f})' if steady_sharp else ''))
    result['text'] = out
    return result


def analyze_preset(frames, sheet_path, name, motion):
    rows, thumbs, _ = analyze_frames(frames, motion=motion, sheet=bool(sheet_path))
    write_sheet(sheet_path, thumbs)
    out = [f'== {name}: {len(rows)} frames']
    n = len(rows)
    bad = []
    for i, r in enumerate(rows):
        lo, hi = max(0, i - 3), min(n, i + 4)
        neighbours = [rows[j]['luma'] for j in range(lo, hi) if j != i]
        local = statistics.median(neighbours) if neighbours else r['luma']
        luma_out = abs(r['luma'] - local) > max(6.0, 0.2 * local)
        before = rows[i]['raw'] if i > 0 else None
        after = rows[i + 1]['raw'] if i + 1 < n else None
        psnr_out = all(v is not None and v < 15.0 for v in (before, after) if v is not None) and \
            (before is not None or after is not None)
        if luma_out or psnr_out:
            why = ('luma %.1f vs neighbours %.1f' % (r['luma'], local) if luma_out else '') + \
                  (' ' if luma_out and psnr_out else '') + \
                  ('PSNR to neighbours %s / %s dB' % (fmt(before, '.1f'), fmt(after, '.1f'))
                   if psnr_out else '')
            bad.append((i, why))
    sharp = [r['sharp'] for r in rows]
    badset = {i for i, _ in bad}
    series = [(i, r['sharp']) for i, r in enumerate(rows) if i not in badset]
    w = min(5, len(series) // 3) if len(series) >= 6 else 0
    step = None
    best = 0
    for j in range(w, len(series) - w + 1):
        b4 = statistics.fmean(v for _, v in series[j - w:j])
        af = statistics.fmean(v for _, v in series[j:j + w])
        if b4 > 0 and abs(af - b4) / b4 > best:
            best, step = abs(af - b4) / b4, (series[j][0], b4, af)
    out.append(f'  sharpness {sharp[0]:.2f} .. {sharp[-1]:.2f}, median {med(sharp):.2f}; '
               f'luma median {med([r["luma"] for r in rows]):.1f}')
    if step and best >= STEP_MIN:
        out.append(f'  sharpness step at frame {step[0]}: mean of {w} frames {step[1]:.2f} -> '
                   f'{step[2]:.2f} ({100 * (step[2] - step[1]) / step[1]:+.1f}%)')
    else:
        out.append(f'  no clear sharpness step (largest change of {w}-frame means: {100 * best:.1f}%'
                   + (f' at frame {step[0]}' if step else '') + f', below {100 * STEP_MIN:.0f}%)')
        step = None
    out.append(f'  garbage frames (luma outlier or PSNR below 15 dB to both neighbours): '
               f'{len(bad)}' + ''.join(f'\n    frame {i}: {why}' for i, why in bad))
    dips = sorted((r['raw'], r['i']) for r in rows if r['raw'] is not None)[:3]
    out.append('  lowest PSNR to the previous frame: ' +
               ', '.join(f'frame {i} {v:.1f} dB' for v, i in dips))
    out.append('  sharpness: ' + ' '.join(f'{v:.1f}' for v in sharp))
    return dict(kind='preset', name=name, rows=rows, text=out, bad=[i for i, _ in bad],
                step=step[0] if step else None)


def analyze_generic(frames, sheet_path, name, kind):
    rows, thumbs, _ = analyze_frames(frames, motion=True, sheet=bool(sheet_path))
    write_sheet(sheet_path, thumbs)
    s = summarize(rows)
    out = [f'== {name}: {len(rows)} frames']
    if kind != 'vpan':  # the vpan table has the numbers; frames are in metrics.tsv
        out += table(rows)
    out.append(f"  medians: motion ({fmt(s['dx'])}, {fmt(s['dy'])}) |{fmt(s['mag'])}| px, "
               f"res4 {fmt(s['res4'])} dB, res2 {fmt(s['res2'])} dB, sharp {fmt(s['sharp'])}, "
               f"luma {fmt(s['luma'], '.1f')}")
    return dict(kind=kind, name=name, rows=rows, summary=s, text=out)


def analyze_sequence(task):
    kind, name, root, extra = task
    t0 = time.time()
    path = os.path.join(root, name)
    frames = list_frames(path)
    sheets = extra.get('sheets', True)
    sheet_path = os.path.join(path, 'sheet.png') if sheets else None
    try:
        if kind == 'cut':
            steady = list_frames(os.path.join(root, 'cut-steady')) \
                if os.path.isdir(os.path.join(root, 'cut-steady')) else []
            res = analyze_cut(frames, steady, sheet_path, name)
        elif kind == 'preset':
            res = analyze_preset(frames, sheet_path, name, extra.get('preset_motion', False))
        else:
            res = analyze_generic(frames, sheet_path, name, kind)
        rows = res.get('rows', [])
    except Exception as e:  # keep the other sequences
        return dict(kind=kind, name=name, error=f'{type(e).__name__}: {e}', text=[f'== {name}: ERROR {e}'])
    if rows:
        write_tsv(os.path.join(path, 'metrics.tsv'), rows)
    res['seconds'] = time.time() - t0
    return res


# ---------------------------------------------------------------- report

def kind_of(name):
    if name.startswith('vpan-'):
        return 'vpan'
    if name in ('dpan', 'strafe', 'cut', 'cut-steady'):
        return name
    if name.startswith('preset'):
        return 'preset'
    return 'generic'


def vpan_report(results, summary_lines, warnings):
    groups = {}
    for r in results:
        m = re.match(r'vpan-e(\d+)-r(\d+)$', r['name'])
        if not m or 'rows' not in r:
            continue
        groups.setdefault(int(m.group(1)), {})[int(m.group(2))] = r
    if not groups:
        return []
    labels = {0: 'base', 8: 'motion y flipped', 2: 'jitter y flipped'}
    out = ['== vpan: settings A/B/C (each over its repetitions)',
           '  exp  setting             reps  frames  |dy| px   res4 dB   res2 dB    sharp  sy/sx   luma']
    stats = {}
    for exp, reps in sorted(groups.items()):
        rows = [row for r in reps.values() for row in r['rows']]
        s = summarize(rows)
        per = {rep: summarize(r['rows']) for rep, r in reps.items()}
        stats[exp] = (s, per)
        adx = med([abs(r['dy']) for r in rows if r['dy'] is not None])
        out.append(f"  {exp:3d}  {labels.get(exp, '?'):<18} {len(reps):4d}  {s['n']:6d}  "
                   f"{fmt(adx, '.2f'):>7}  {fmt(s['res4'], '.2f'):>8}  {fmt(s['res2'], '.2f'):>8}  "
                   f"{fmt(s['sharp'], '.3f'):>7}  {fmt(s['vr'], '.3f'):>5}  {fmt(s['luma'], '.1f'):>5}")
        for rep, ps in sorted(per.items()):
            out.append(f"       rep {rep}                          {ps['n']:6d}  "
                       f"{fmt(med([abs(r['dy']) for r in reps[rep]['rows'] if r['dy'] is not None]), '.2f'):>7}"
                       f"  {fmt(ps['res4'], '.2f'):>8}  {fmt(ps['res2'], '.2f'):>8}  "
                       f"{fmt(ps['sharp'], '.3f'):>7}  {fmt(ps['vr'], '.3f'):>5}  {fmt(ps['luma'], '.1f'):>5}")
        if adx is not None and adx < 0.5:
            warnings.append(f'vpan exp {exp}: median |dy| {adx:.2f} px, the camera did not pan')
    verdict = []
    for key, label in (('sharp', 'sharpness'),
                       ('vr', 'vertical/horizontal sharpness (a wrong y sign blurs vertical detail on a vertical pan)'),
                       ('res2', 'residual PSNR (1/2)'), ('res4', 'residual PSNR (1/4)')):
        vals = {e: stats[e][0][key] for e in stats if stats[e][0][key] is not None}
        if len(vals) < 2:
            continue
        noise = 0.0
        for e in stats:
            per = [p[key] for p in stats[e][1].values() if p[key] is not None]
            if len(per) >= 2:
                noise = max(noise, max(per) - min(per))
        best = max(vals, key=vals.get)
        worst = min(vals, key=vals.get)
        spread = vals[best] - vals[worst]
        sig = 'above' if spread > 2 * noise else 'within'
        verdict.append(f'  {label}: best exp {best} ({labels.get(best, "?")}) '
                       f'{vals[best]:.3f}, worst exp {worst} {vals[worst]:.3f}; spread {spread:.3f} '
                       f'is {sig} 2x the repetition disagreement ({noise:.3f})')
    speeds = {e: med([abs(r['dy']) for rr in groups[e].values() for r in rr['rows']
                      if r['dy'] is not None]) for e in groups}
    sp = [v for v in speeds.values() if v]
    if len(sp) >= 2 and max(sp) > 1.25 * min(sp):
        warnings.append('vpan: pan speed differs by more than 25% between settings '
                        '(' + ', '.join(f'exp {e}: {v:.1f} px' for e, v in sorted(speeds.items())) + ')')
    out += verdict
    summary_lines += ['vpan: ' + v.strip() for v in verdict]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('dir')
    ap.add_argument('--jobs', type=int, default=min(4, os.cpu_count() or 1))
    ap.add_argument('--json')
    ap.add_argument('--no-sheets', action='store_true')
    ap.add_argument('--only', default='', help='comma separated sequence names')
    ap.add_argument('--preset-motion', action='store_true',
                    help='motion search in the preset sequences too (slow, off by default)')
    a = ap.parse_args()
    if not os.path.isdir(a.dir):
        print(f'temporal_metrics: no directory {a.dir}', file=sys.stderr)
        return 2
    only = {s for s in a.only.split(',') if s}
    names = sorted(n for n in os.listdir(a.dir)
                   if os.path.isdir(os.path.join(a.dir, n)) and not n.startswith('_')
                   and list_frames(os.path.join(a.dir, n)) and (not only or n in only))
    if not names:
        print(f'temporal_metrics: no frames under {a.dir}', file=sys.stderr)
        return 2
    extra = dict(sheets=not a.no_sheets, preset_motion=a.preset_motion)
    # cut-steady is analysed together with cut (by itself, as a plain sequence, when cut is missing)
    have_cut = 'cut' in names
    tasks = [(kind_of(n), n, a.dir, extra) for n in names if not (have_cut and n == 'cut-steady')]
    tasks = [('generic' if t[0] == 'cut-steady' else t[0], t[1], t[2], t[3]) for t in tasks]
    # the slow ones first
    tasks.sort(key=lambda t: -len(list_frames(os.path.join(a.dir, t[1]))))
    t0 = time.time()
    if a.jobs > 1 and len(tasks) > 1:
        with ProcessPoolExecutor(max_workers=a.jobs) as pool:
            results = list(pool.map(analyze_sequence, tasks))
    else:
        results = [analyze_sequence(t) for t in tasks]
    results.sort(key=lambda r: r['name'])
    warnings, summary = [], []
    for r in results:
        if 'error' in r:
            warnings.append(f"{r['name']}: {r['error']}")
    printed_vpan = False
    for r in results:
        if r['name'].startswith('vpan-') and not printed_vpan:
            printed_vpan = True
            print('\n'.join(vpan_report(results, summary, warnings)))
            print()
        print('\n'.join(r['text']))
        print()
    for r in results:
        if 'summary' in r:
            s = r['summary']
            summary.append(f"{r['name']}: {s['n']} frames, motion ({fmt(s['dx'])}, {fmt(s['dy'])}) px, "
                           f"res4 {fmt(s['res4'])} dB, res2 {fmt(s['res2'])} dB, "
                           f"sharp {fmt(s['sharp'], '.3f')}")
            if kind_of(r['name']) in ('dpan', 'vpan') and (s['mag'] or 0) < 0.5:
                warnings.append(f"{r['name']}: median motion {fmt(s['mag'])} px, the camera did not pan")
            if s['saturated']:
                warnings.append(f"{r['name']}: motion search saturated in {s['saturated']} pairs "
                                f"(motion beyond +-64 px, shifts unreliable)")
        if r['kind'] == 'cut' and 'decaying' in r:
            summary.append(f"cut: {len(r['decaying'])} decaying tiles (ghost/trail), "
                           f"{len(r['persistent'])} persistent, tiles above threshold per frame "
                           f"{r['active_per_frame']}, clear from frame {r['cleared']}")
        if r['kind'] == 'preset':
            summary.append(f"{r['name']}: sharpness step at frame {r['step'] if r['step'] is not None else 'none'}, garbage frames "
                           f"{r['bad'] if r['bad'] else 'none'}")
            if r['bad']:
                warnings.append(f"{r['name']}: garbage frames {r['bad']}")
    print('=' * 72)
    print(f'temporal_metrics summary ({a.dir}, {len(results)} sequences, '
          f'{time.time() - t0:.0f} s, {a.jobs} jobs)')
    print('=' * 72)
    for line in summary:
        print(line)
    for w in warnings:
        print('WARNING', w)
    if not warnings:
        print('no warnings')
    print('contact sheets: <sequence>/sheet.png (4 frames a row, row-major, 1/3 size); per-frame '
          'values: <sequence>/metrics.tsv')
    if a.json:
        with open(a.json, 'w') as f:
            json.dump([{k: v for k, v in r.items() if k != 'text'} for r in results], f)
    return 0


if __name__ == '__main__':
    sys.exit(main())
