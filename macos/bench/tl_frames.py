#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# tl_frames.py <BB_TIMELINE file>: per flip, where the GPU command thread's time went since the previous
# end-of-pipe flip; missed slots (vblank gap 3) against on-time ones (gap 2).
import sys, collections, statistics as st
(GSUB, GSUBDONE, GWAITB, GWAITE, DECB, DECE, PIPE, VSUB, GPUDONE, RETIRED, IDLEB, IDLEE,
 VOB, VOE, RMB, RME, GFLIP, EOP, FLIP) = range(19)
ev = []
for line in open(sys.argv[1]):
    ns, e, a, a2 = line.split()
    ns = int(ns)
    if ns:
        ev.append((ns, int(e), int(a), int(a2)))
ev.sort()
flips = [(ns, a) for ns, e, a, _ in ev if e == FLIP]
eops = [ns for ns, e, _, _ in ev if e == EOP]
gflips = [ns for ns, e, _, _ in ev if e == GFLIP]

def spans(b, e):
    out, start = [], None
    for ns, ev_, _, _ in ev:
        if ev_ == b:
            start = ns
        elif ev_ == e and start is not None:
            out.append((start, ns)); start = None
    return out
kinds = {'vo_wait': spans(VOB, VOE), 'regmem_wait': spans(RMB, RME), 'idle': spans(IDLEB, IDLEE),
         'guest_wait': spans(GWAITB, GWAITE)}

def overlap(sp, a, b):
    return sum(max(0, min(e, b) - max(s, a)) for s, e in sp) / 1e6

import bisect
rows = []
for i in range(2, len(flips)):
    fns, vb = flips[i]
    gap = vb - flips[i - 1][1]
    k = bisect.bisect_left(eops, fns) - 1          # the EOP flip taken by this flip
    if k < 1:
        continue
    a, b = eops[k - 1], eops[k]
    g = bisect.bisect_left(gflips, b) - 1
    r = {'gap': gap, 'frame_ms': (fns - flips[i - 1][0]) / 1e6, 'eop_to_flip': (fns - b) / 1e6,
         'span': (b - a) / 1e6, 'guest_to_eop': (b - gflips[g]) / 1e6 if g >= 0 else float('nan')}
    for name, sp in kinds.items():
        r[name] = overlap(sp, a, b)
    r['decode'] = r['span'] - r['vo_wait'] - r['regmem_wait'] - r['idle']
    # the last VO wait end in the span, relative to the previous flip (the tick that released it)
    ends = [e for s, e in kinds['vo_wait'] if a < e <= b]
    r['vo_end_after_prev_flip'] = (ends[-1] - flips[i - 1][0]) / 1e6 if ends else float('nan')
    r['eop_after_vo_end'] = (b - ends[-1]) / 1e6 if ends else float('nan')
    rows.append(r)

print('flips', len(rows), 'gaps', collections.Counter(r['gap'] for r in rows).most_common(5))
keys = ['span', 'vo_wait', 'regmem_wait', 'idle', 'guest_wait', 'decode', 'guest_to_eop',
        'vo_end_after_prev_flip', 'eop_after_vo_end', 'eop_to_flip']
def q(v, p):
    v = sorted(x for x in v if x == x)
    return v[int(p * (len(v) - 1))] if v else float('nan')
for label, sel in [('missed (gap 3)', [r for r in rows if r['gap'] >= 3]),
                   ('on time (gap 2)', [r for r in rows if r['gap'] == 2])]:
    print(f'\n{label}: {len(sel)}')
    print(f"  {'ms':24}{'p10':>8}{'med':>8}{'p90':>8}")
    for key in keys:
        v = [r[key] for r in sel]
        print(f'  {key:24}{q(v, .1):8.1f}{q(v, .5):8.1f}{q(v, .9):8.1f}')

# The window from the guest's flip call to the EOP flip, and the frame's first guest submission.
gsubs = [ns for ns, e, _, _ in ev if e == GSUB]
decs = spans(DECB, DECE)
print('\nwindow guest flip call -> EOP')
for label, want in [('missed', lambda g, i: g >= 3), ('on time', lambda g, i: g == 2 and i % 10 == 0)]:
    acc = collections.defaultdict(list)
    for i in range(2, len(flips)):
        fns, vb = flips[i]
        gap = vb - flips[i - 1][1]
        if not want(gap, i):
            continue
        k = bisect.bisect_left(eops, fns) - 1
        g = bisect.bisect_left(gflips, eops[k]) - 1
        if k < 1 or g < 1:
            continue
        a, b = gflips[g], eops[k]
        acc['total'].append((b - a) / 1e6)
        acc['guest_wait'].append(overlap(kinds['guest_wait'], a, b))
        acc['idle'].append(overlap(kinds['idle'], a, b))
        acc['decoding'].append(overlap(decs, a, b))
        # guest submissions of this frame: after the previous flip call
        n = [s for s in gsubs if gflips[g - 1] < s <= a]
        acc['submissions'].append(len(n))
        acc['first_sub_after_prev_call'].append((n[0] - gflips[g - 1]) / 1e6 if n else float('nan'))
        acc['call_interval'].append((a - gflips[g - 1]) / 1e6)
        acc['call_after_prev_flip'].append((a - flips[i - 1][0]) / 1e6)
    print(f'  {label}: {len(acc["total"])}')
    for key, v in acc.items():
        print(f'    {key:28}{q(v, .1):8.1f}{q(v, .5):8.1f}{q(v, .9):8.1f}')
