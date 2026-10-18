#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""chansplit.py <export dir> [--frames]: GPU ms a frame by channel (Vertex / Fragment / Compute)
per pass group, from a Metal System Trace export made by mtltrace.py (--out). Pass groups are the
pass labels without their shader hashes ("960x540 C6 D" = all G-buffer passes, needs
BB_PASS_LABELS=1); other labels with their digits folded. Tells vertex-bound from pixel-bound
passes, which the per-label table of mtltrace.py (sum over channels) does not.

--frames: instead, one line per trace frame (the command buffers' frame number) with the work by
channel, and for the six frames with the most work, the pass groups that grew against the
median frame (for slow frames at the cap: more work, or a longer span without more work).

    python3 macos/bench/chansplit.py ~/Games/Bloodborne/bench/traces/export-yh-tr-960x540
"""
import collections
import os
import re
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mtltrace as M  # noqa: E402


def group(label):
    m = re.match(r'(\d+x\d+) (C\d+)( D)?', label or '?')
    return f'{m.group(1)} {m.group(2)}{m.group(3) or ""}' if m else re.sub(r'\d+', 'N', label or '?')[:40]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    proc, enc, cbs, objlabel, gpu, app, cpu = M.load(sys.argv[1])
    elabel = {k: M.norm_label(v['label'], v['cblabel']) for k, v in enc.items()}
    if '--frames' not in sys.argv:
        pres = sorted(c['start'] for c in cbs.values() if c['present'])
        nfr = max(1, len(pres) - 1)
        t0, t1 = pres[0], pres[-1]
        grp = collections.defaultdict(collections.Counter)
        for s, e, ch, en, cb in gpu:
            if t0 <= s < t1:
                key = group(elabel.get(en) or objlabel.get(en))
                grp[key][ch] += e - s
                grp['TOTAL'][ch] += e - s
        print(f'{nfr} frames; GPU ms a frame by channel')
        for k, c in sorted(grp.items(), key=lambda x: -sum(x[1].values()))[:25]:
            chans = '  '.join(f'{ch} {v / 1e6 / nfr:6.2f}' for ch, v in sorted(c.items()))
            print(f'{sum(c.values()) / 1e6 / nfr:7.2f}  {chans}   {k}')
        return 0
    work = collections.Counter()
    lab = collections.defaultdict(collections.Counter)
    chs = collections.defaultdict(collections.Counter)
    first, last = {}, {}
    for s, e, ch, en, cb in gpu:
        f = cbs.get(cb, {}).get('frame')
        if f is None:
            continue
        work[f] += e - s
        lab[f][group(elabel.get(en) or objlabel.get(en))] += e - s
        chs[f][ch] += e - s
        first[f] = min(first.get(f, s), s)
        last[f] = max(last.get(f, e), e)
    frames = sorted(work)[2:-2]  # the trace's partial first and last frames
    w = [work[f] / 1e6 for f in frames]
    print(f'{len(frames)} frames, GPU work a frame: median {st.median(w):.2f} ms, '
          f'p90 {sorted(w)[int(.9 * len(w))]:.2f}, max {max(w):.2f}')
    med_lab = {k: st.median([lab[f][k] / 1e6 for f in frames]) for k in set().union(*(lab[f] for f in frames))}
    med_ch = {c: st.median([chs[f][c] / 1e6 for f in frames]) for c in ('Vertex', 'Fragment', 'Compute')}
    for f in sorted(frames, key=lambda f: -work[f])[:6]:
        grew = sorted(((lab[f][k] / 1e6 - med_lab.get(k, 0), k) for k in lab[f]), reverse=True)[:4]
        ch = ' '.join(f'{c} {chs[f][c] / 1e6:.1f} (med {med_ch[c]:.1f})' for c in med_ch)
        print(f'frame {f}: work {work[f] / 1e6:.2f} span {(last[f] - first[f]) / 1e6:.2f} | {ch}')
        print('    grew: ' + '; '.join(f'{k} +{v:.2f}' for v, k in grew))
    return 0


if __name__ == '__main__':
    sys.exit(main())
