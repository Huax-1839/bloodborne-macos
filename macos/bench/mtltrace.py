#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Summarise a Metal System Trace (xctrace .trace) of a bbport run, Metal or MoltenVK backend.

Usage: python3 macos/bench/mtltrace.py <X.trace> [--out DIR] [--top N]

Exports the tables it needs with `xcrun xctrace export` into DIR (default: a fresh temp dir;
existing exports there are reused) and prints a plain-text report of the frames between the
first and the last present of the traced process:
  1 frame delimiting, frames/s, mean/p90 frame time     5 shares of MetalFX, camera motion, ...
  2 command buffers and encoders per frame, by kind      6 CPU time per thread from time-profile
  3 GPU time per encoder label (pass number stripped)     7 commit-to-GPU latency, encode time
  4 GPU busy vs idle, idle gap histogram, largest gaps
Tables used: metal-command-buffer-frame-assignment, metal-gpu-intervals,
metal-application-encoders-list, metal-application-intervals, metal-object-label, time-profile.
Only the stdlib is needed. Notes on accuracy are printed at the end of the report.
"""
import argparse
import bisect
import collections
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

TABLES = ["metal-command-buffer-frame-assignment", "metal-gpu-intervals",
          "metal-application-encoders-list", "metal-application-intervals",
          "metal-object-label", "time-profile"]
NOCB = 0xFFFFFFFFFFFFFFFF
# runtime wrapper frames that sit under every thread and say nothing (skipped in the inclusive lists)
WRAPPER = re.compile(r"^(thread_start|_pthread_start|start_wqthread|_pthread_wqthread|_dispatch_|void\*? ?std::|"
                     r"std::__1::__invoke|decltype|start$|host_start)")


def export(trace, outdir):
    os.makedirs(outdir, exist_ok=True)
    for t in TABLES:
        path = os.path.join(outdir, t + ".xml")
        if os.path.exists(path) and os.path.getsize(path) > 0:
            continue
        xp = '/trace-toc/run[@number="1"]/data/table[@schema="%s"]' % t
        print("exporting %s ..." % t, file=sys.stderr)
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xp,
                        "--output", path], check=True, stdout=subprocess.DEVNULL)
    return outdir


def rows(path):
    """Yield (row, resolve): row is the list of column elements (None for <sentinel/>) with
    ref="N" duplicates replaced by the element that defined id="N"; resolve() does the same for
    nested children (frames of a backtrace, ids inside a formatted-label)."""
    ids = {}

    def res(el):
        r = el.get("ref")
        return ids[r] if r is not None else el

    for ev, el in ET.iterparse(path, events=("end",)):
        if el.tag == "row":
            yield [None if c.tag == "sentinel" else res(c) for c in el], res
            el.clear()
        elif el.get("id") is not None:
            ids[el.get("id")] = el


def fmt(el):
    return None if el is None else el.get("fmt")


def num(el):
    return int(el.text) if el is not None and el.text else None


def ms(ns):
    return ns / 1e6


def pct(vals, p):
    if not vals:
        return 0
    v = sorted(vals)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def short(s, n=100):
    return s if len(s) <= n else s[:n - 3] + "..."


# ---------------------------------------------------------------- labels

GENERIC = re.compile(r"^(Blit|Render|Compute) Command \d+$")


def norm_label(label, cblabel):
    """Group key for an encoder label: pass number stripped, generic names resolved."""
    if label is None or label == "":
        label = "(unlabelled)"
    m = GENERIC.match(label)
    if m:
        cbn = re.sub(r"\d+", "N", cblabel or "")
        if cblabel and not re.match(r"^(bbport draw #N|Command Buffer N|vkQueueSubmit.*)$", cbn):
            return "[cb %s] %s" % (cblabel, m.group(1).lower())
        return "(unlabelled %s)" % m.group(1).lower()
    parts = [re.sub(r"^P\d+ ", "", p) for p in label.split(" & ")]
    return " & ".join(parts)


def kind_of(norm, channels):
    first = norm.split(" & ")[0]
    if first.startswith("MetalFX"):
        return "MetalFX"
    if re.search(r"BlitEncoder$|^\(unlabelled blit\)|\] blit$|^Blit|copy", first):
        return "blit"
    if re.search(r"ComputeEncoder$|^CS |^Camera motion|^Tessellation|\(unlabelled compute\)|\] compute$", first):
        return "compute"
    if re.search(r"RenderEncoder$|^\d+x\d+ |^UI |^Post process|^Present|^Overlay|\(unlabelled render\)|\] render$", first):
        return "render"
    if channels:
        return "render" if channels & {"Vertex", "Fragment"} else "compute"
    return "other"


def category(norm, cblabel, mfx):
    if mfx or norm.startswith("MetalFX"):
        return "MetalFX encoders"
    if "Camera motion" in norm:
        return "Camera motion"
    if "Tessellation kernels" in norm:
        return "Tessellation kernels (incl. merged CS &)"
    if re.match(r"^(UI |Post process|Present|Overlay)", norm) or cblabel == "Present":
        return "UI / post / present"
    if re.match(r"^\d+x\d+ ", norm):
        return "scene render passes (P<n>)"
    if norm.startswith("CS "):
        return "CS dispatches"
    if norm.startswith("vkCmd"):
        return "MoltenVK internal (vkCmd...)"
    return "other (blits, unlabelled, ...)"


# ---------------------------------------------------------------- loading

def load(d):
    # encoders list: the traced process is the one with most encoders
    enc = {}
    procs = collections.Counter()
    for r, _ in rows(os.path.join(d, "metal-application-encoders-list.xml")):
        p = fmt(r[3])
        procs[p] += 1
        enc[num(r[12])] = dict(start=num(r[0]), dur=num(r[1]), thread=fmt(r[2]), proc=p,
                               frame=int(fmt(r[5]).split()[1]), cblabel=fmt(r[6]),
                               label=fmt(r[8]), cb=num(r[11]))
    proc = procs.most_common(1)[0][0]
    enc = {k: v for k, v in enc.items() if v["proc"] == proc}

    cbs = {}
    for r, _ in rows(os.path.join(d, "metal-command-buffer-frame-assignment.xml")):
        if fmt(r[14]) != proc:
            continue
        cbs[num(r[1])] = dict(start=num(r[0]), commit=num(r[2]), frame=num(r[4]),
                              present=fmt(r[7]) == "1", type=fmt(r[9]))

    objlabel = {}
    for r, _ in rows(os.path.join(d, "metal-object-label.xml")):
        objlabel[num(r[1])] = fmt(r[3])

    gpu = []  # (start, end, channel, enc, cb)
    for r, res in rows(os.path.join(d, "metal-gpu-intervals.xml")):
        if fmt(r[10]) != proc:
            continue
        s = num(r[0])
        gpu.append((s, s + num(r[1]), fmt(r[2]), num(r[16]), num(r[15])))
    gpu.sort()

    app = []  # (start, dur, type, cb, enc, depth)
    for r, _ in rows(os.path.join(d, "metal-application-intervals.xml")):
        if fmt(r[2]) != proc:
            continue
        app.append((num(r[0]), num(r[1]), fmt(r[10]), num(r[11]), num(r[12])))

    cpu = []  # (time, thread fmt, stack)
    for r, res in rows(os.path.join(d, "time-profile.xml")):
        if r[2] is None or fmt(r[2]) != proc:
            continue
        w = num(r[5]) or 1000000
        stack = None
        if r[6] is not None:
            stack = [(f.get("name") or "?") for f in (res(c) for c in r[6])]
        cpu.append((num(r[0]), fmt(r[1]), w, stack))
    return proc, enc, cbs, objlabel, gpu, app, cpu


def union(ivs):
    """ivs sorted by start -> merged list of [s, e]."""
    out = []
    for s, e in ivs:
        if out and s <= out[-1][1]:
            if e > out[-1][1]:
                out[-1][1] = e
        else:
            out.append([s, e])
    return out


def clipped_len(segs, starts, t0, t1):
    i = max(0, bisect.bisect_right(starts, t0) - 1)
    tot = 0
    while i < len(segs) and segs[i][0] < t1:
        tot += max(0, min(segs[i][1], t1) - max(segs[i][0], t0))
        i += 1
    return tot


# ---------------------------------------------------------------- report

def report(trace, d, top):
    proc, enc, cbs, objlabel, gpu, app, cpu = load(d)
    out = []
    P = out.append
    P("== %s  process %s" % (os.path.basename(trace.rstrip("/")), proc))

    # --- frames: present command buffers of the process
    cb_gpu_end = {}
    cb_gpu_start = {}
    for s, e, ch, en, cb in gpu:
        cb_gpu_end[cb] = max(cb_gpu_end.get(cb, 0), e)
        if cb not in cb_gpu_start or s < cb_gpu_start[cb]:
            cb_gpu_start[cb] = s
    pres = []  # (frame, time)
    for cb, c in cbs.items():
        if c["present"]:
            pres.append((c["frame"], cb_gpu_end.get(cb, c["commit"]), cb in cb_gpu_end))
    pres.sort(key=lambda x: x[1])
    if len(pres) < 3:
        P("not enough presents (%d) in the trace" % len(pres))
        return out
    pt = [p[1] for p in pres]
    ft = [b - a for a, b in zip(pt, pt[1:])]
    t0, t1 = pt[0], pt[-1]
    nfr = len(ft)
    frames = set(p[0] for p in pres[1:])
    wall = t1 - t0
    p90 = pct(ft, .9)
    P("")
    P("1. FRAMES  method: present command buffers (frame-assignment has-present) of the process;"
      " a frame ends when its present")
    P("   command buffer finishes on the GPU (%d/%d with GPU rows, else commit time)."
      % (sum(1 for p in pres if p[2]), len(pres)))
    P("   window %.3f s .. %.3f s = %.3f s, %d frames (first present only starts the window; frames"
      " before/after not counted)" % (t0 / 1e9, t1 / 1e9, wall / 1e9, nfr))
    P("   frames/s %.2f (1/median frame: %.2f)   frame time ms: mean %.2f  median %.2f  p90 %.2f  p99 %.2f  max %.2f"
      "  min %.2f" % (nfr / (wall / 1e9), 1e9 / pct(ft, .5), ms(sum(ft) / nfr), ms(pct(ft, .5)), ms(p90),
                      ms(pct(ft, .99)), ms(max(ft)), ms(min(ft))))
    longf = sorted(ft, reverse=True)[:6]
    P("   slowest frames ms: " + ", ".join("%.1f" % ms(x) for x in longf) +
      "   frames >33.4 ms: %d, >50 ms: %d" % (sum(1 for x in ft if x > 33.4e6), sum(1 for x in ft if x > 50e6)))

    # --- per-frame counts
    P("")
    per_cb = collections.Counter(c["frame"] for c in cbs.values() if c["frame"] in frames)
    kinds = collections.defaultdict(collections.Counter)  # frame -> kind -> n
    # channels per encoder (for kind fallback) and label per encoder
    chans = collections.defaultdict(set)
    for s, e, ch, en, cb in gpu:
        chans[en].add(ch)
    elabel = {}
    for k, v in enc.items():
        elabel[k] = norm_label(v["label"], v["cblabel"])
    for k, v in enc.items():
        if v["frame"] in frames:
            kinds[v["frame"]][kind_of(elabel[k], chans.get(k))] += 1
    order = ["render", "compute", "blit", "MetalFX", "other"]
    P("2. PER FRAME  (frames by the trace's frame number, %d frames; mean [min..max])" % len(frames))

    def mm(vals):
        vals = list(vals)
        return "%7.1f [%d..%d]" % (sum(vals) / max(1, len(vals)), min(vals) if vals else 0, max(vals) if vals else 0)
    P("   command buffers  %s" % mm(per_cb.get(f, 0) for f in frames))
    P("   encoders total   %s" % mm(sum(kinds[f].values()) for f in frames))
    for k in order:
        P("     %-8s       %s" % (k, mm(kinds[f][k] for f in frames)))
    P("   (kind from the label: P<n>/Render Command/RenderEncoder = render, CS/Camera motion/Tessellation/ComputeEncoder"
      " = compute, Blit Command/BlitEncoder = blit, MetalFX_*; else from the GPU channels)")

    # --- per label GPU time
    inw = [g for g in gpu if t0 <= g[0] < t1]
    per_enc = {}
    for s, e, ch, en, cb in inw:
        a = per_enc.setdefault(en, [s, e, 0, cb])
        a[0] = min(a[0], s)
        a[1] = max(a[1], e)
        a[2] += e - s
    cblabel = lambda cb: (next((v["cblabel"] for v in enc.values() if v["cb"] == cb), None))  # noqa
    cb_names = {}
    for v in enc.values():
        cb_names.setdefault(v["cb"], v["cblabel"])
    for k in per_enc:
        if k not in elabel:
            ol = objlabel.get(k)
            elabel[k] = norm_label(ol, cb_names.get(per_enc[k][3]) or objlabel.get(per_enc[k][3])) if ol \
                else "(encoder unknown to the app list)"
    grp = collections.defaultdict(lambda: [0, 0, 0])  # label -> gpu ns, span ns, count
    for en, (s, e, tot, cb) in per_enc.items():
        g = grp[elabel[en]]
        g[0] += tot
        g[1] += e - s
        g[2] += 1
    P("")
    P("3. GPU TIME PER ENCODER LABEL  (per frame; gpu = sum over Vertex/Fragment/Compute channels, span = wall-clock"
      " first start..last end)")
    P("   %d distinct labels, %d encoders with GPU work per frame, encoders without an app-side label: %d"
      % (len(grp), sum(g[2] for g in grp.values()) // nfr,
         sum(g[2] for k, g in grp.items() if k.startswith("(encoder unknown"))))
    P("   %8s %8s %7s  %s" % ("gpu ms", "span ms", "cnt", "label"))
    tg = sum(g[0] for g in grp.values())
    ts = sum(g[1] for g in grp.values())
    for lab, g in sorted(grp.items(), key=lambda x: -x[1][0])[:top]:
        P("   %8.3f %8.3f %7.2f  %s" % (ms(g[0]) / nfr, ms(g[1]) / nfr, g[2] / nfr, short(lab, 90)))
    P("   %8.3f %8.3f %7.2f  TOTAL (%d labels; shown %d)" % (ms(tg) / nfr, ms(ts) / nfr,
                                                              sum(g[2] for g in grp.values()) / nfr, len(grp),
                                                              min(top, len(grp))))

    # --- busy / idle
    segs = union([(s, e) for s, e, _, _, _ in gpu])
    starts = [s for s, _ in segs]
    busy = [clipped_len(segs, starts, a, b) for a, b in zip(pt, pt[1:])]
    P("")
    P("4. GPU BUSY vs IDLE  (union of all channels of the process; frame windows = present to present)")
    P("   busy ms/frame: mean %.2f  min %.2f  max %.2f  | frame time mean %.2f | busy %.1f%% of frame time (%.1f%% worst frame)"
      % (ms(sum(busy) / nfr), ms(min(busy)), ms(max(busy)), ms(sum(ft) / nfr), 100 * sum(busy) / sum(ft),
         100 * max(b / f for b, f in zip(busy, ft))))
    typ = [i for i, f in enumerate(ft) if f <= p90]
    P("   typical frames (frame time <= p90, %d frames): frame %.2f ms, busy %.2f ms (%.1f%%), idle %.2f ms"
      % (len(typ), ms(sum(ft[i] for i in typ) / len(typ)), ms(sum(busy[i] for i in typ) / len(typ)),
         100 * sum(busy[i] for i in typ) / sum(ft[i] for i in typ),
         ms(sum(ft[i] - busy[i] for i in typ) / len(typ))))
    gaps = []  # (start, end, before_seg_idx)
    for i in range(len(segs) - 1):
        gs, ge = segs[i][1], segs[i + 1][0]
        if gs >= t0 and ge <= t1 and ge > gs:
            gaps.append((gs, ge, i))
    ng = len(gaps)
    P("   idle gaps (no channel busy): %.1f per frame, %.2f ms per frame (%.1f%% of the window)"
      % (ng / nfr, ms(sum(g[1] - g[0] for g in gaps)) / nfr, 100 * sum(g[1] - g[0] for g in gaps) / wall))
    buckets = [("<0.1", 0, 1e5), ("0.1-0.5", 1e5, 5e5), ("0.5-2", 5e5, 2e6), ("2-5", 2e6, 5e6), (">5", 5e6, 1e18)]
    P("   histogram (ms):  " + "   ".join("%s: %.1f/fr %.2f ms/fr" % (
        n, sum(1 for g in gaps if lo <= g[1] - g[0] < hi) / nfr,
        ms(sum(g[1] - g[0] for g in gaps if lo <= g[1] - g[0] < hi)) / nfr) for n, lo, hi in buckets))
    # label of the interval ending last in a segment / starting first in the next
    segend = {}
    segbeg = {}
    si = 0
    for s, e, ch, en, cb in gpu:
        while si < len(segs) - 1 and s > segs[si][1]:
            si += 1
        if e == segs[si][1]:
            segend[si] = (en, cb)
        if s == segs[si][0] and si not in segbeg:
            segbeg[si] = (en, cb)

    def desc(x):
        if x is None:
            return "?"
        en, cb = x
        cbn = (cb_names.get(cb) or objlabel.get(cb) or hex(cb)).replace("vkQueueSubmit MTLCommandBuffer on Queue", "vkSubmit q")
        return "%s {cb %s}" % (short(elabel.get(en) or norm_label(objlabel.get(en), None), 45), short(cbn, 22))
    P("   10 largest gaps:  time s   ms   before -> after")
    for gs, ge, i in sorted(gaps, key=lambda g: g[0] - g[1])[:10]:
        P("     %8.3f %7.2f  %s -> %s" % (gs / 1e9, ms(ge - gs), desc(segend.get(i)), desc(segbeg.get(i + 1))))

    # --- shares
    cat = collections.defaultdict(list)
    cbtype = {k: v["type"] for k, v in cbs.items()}
    for s, e, ch, en, cb in inw:
        cat[category(elabel.get(en, ""), cb_names.get(cb), cbtype.get(cb) == "MetalFx")].append((s, e))
    P("")
    P("5. SHARES  (per frame, wall-clock union of that category's intervals; % of GPU busy; categories overlap)")
    for name, ivs in sorted(cat.items(), key=lambda x: -sum(b - a for a, b in union(sorted(x[1])))):
        u = sum(b - a for a, b in union(sorted(ivs)))
        P("   %-44s %7.3f ms  %5.1f%%   (sum over channels %.3f ms)" % (
            name, ms(u) / nfr, 100 * u / max(1, sum(busy)), ms(sum(b - a for a, b in ivs)) / nfr))

    # --- CPU
    cin = [c for c in cpu if t0 <= c[0] < t1]
    P("")
    P("6. CPU  (time-profile samples of the process in the window, %d samples, %d without a backtrace;"
      " weight %.2f ms; ms of CPU per second)" % (len(cin), sum(1 for c in cin if c[3] is None),
                                                   (cin[0][2] / 1e6) if cin else 0))
    thr = collections.defaultdict(list)
    for c in cin:
        m = re.match(r"^(.*?) \((0x[0-9a-f]+)\)", c[1])
        thr[(m.group(1).strip(), m.group(2)) if m else (c[1], "?")].append(c)
    secs = wall / 1e9
    tl = sorted(thr.items(), key=lambda x: -sum(c[2] for c in x[1]))
    P("   %-30s %-10s %8s %7s" % ("thread", "tid", "ms/s", "samples"))
    for (n, tid), cs in tl[:15]:
        P("   %-30s %-10s %8.1f %7d" % (n[:30], tid, ms(sum(c[2] for c in cs)) / secs, len(cs)))

    def symd(name):
        return not name.startswith("0x")
    for (n, tid), cs in tl[:5]:
        selfc = collections.Counter()
        incl = collections.Counter()
        nostack = 0
        unsym = 0
        root = collections.Counter()
        for _, _, w, st in cs:
            if not st:
                nostack += 1
                continue
            sy = [x for x in st if symd(x)]
            if not sy:
                unsym += 1
                continue
            if sy[0] != st[0]:
                selfc["~" + sy[0]] += 1
            else:
                selfc[sy[0]] += 1
            for x in set(sy):
                incl[x] += 1
            root[sy[-1]] += 1
        tot = max(1, len(cs) - nostack - unsym)
        P("   -- %s %s: %d samples (%.1f ms/s); no backtrace %d, only unsymbolicated frames (guest code) %d;"
          " outermost symbol: %s" % (n, tid, len(cs), ms(len(cs) * 1e6) / secs, nostack, unsym,
                                     ", ".join("%s" % short(k, 30) for k, _ in root.most_common(2)) or "-"))
        P("      self, %% of the %d samples with a symbolicated stack ('~' = leaf unsymbolicated, nearest symbol shown):" % tot)
        for k, v in selfc.most_common(12):
            P("        %5.1f%% %s" % (100 * v / tot, short(k)))
        P("      inclusive:")
        for k, v in [x for x in incl.most_common(60) if not WRAPPER.match(x[0])][:12]:
            P("        %5.1f%% %s" % (100 * v / tot, short(k)))

    # --- CPU -> GPU
    lat = []
    for cb, c in cbs.items():
        if c["frame"] in frames and cb in cb_gpu_start:
            lat.append(cb_gpu_start[cb] - c["commit"])
    cbenc = [a for a in app if a[2] == "Encoding" and a[4] == NOCB and a[3] in cbs and cbs[a[3]]["frame"] in frames]
    encd = [v["dur"] for v in enc.values() if v["frame"] in frames]
    mps = [a for a in app if a[2] == "Encode MPSGraph" and t0 <= a[0] < t1]
    P("")
    P("7. CPU -> GPU")
    if lat:
        P("   commit -> first GPU start per command buffer (%d cbs): mean %.2f ms  p90 %.2f  max %.2f  (negative = %d)"
          % (len(lat), ms(sum(lat) / len(lat)), ms(pct(lat, .9)), ms(max(lat)), sum(1 for x in lat if x < 0)))
    else:
        P("   no commit->GPU data")
    P("   encoding per frame: command buffers (create..commit wall) %.2f ms over %.1f cbs; encoders (sum of encoder encode"
      " time) %.2f ms over %.1f" % (ms(sum(a[1] for a in cbenc)) / len(frames), len(cbenc) / len(frames),
                                    ms(sum(encd)) / len(frames), len(encd) / len(frames)))
    if mps:
        P("   'Encode MPSGraph' (MetalFX, CPU): %.2f ms per frame, %.2f per call" % (
            ms(sum(a[1] for a in mps)) / nfr, ms(sum(a[1] for a in mps) / len(mps))))
    th = collections.defaultdict(lambda: [0, 0])
    for v in enc.values():
        if v["frame"] in frames:
            m = re.match(r"^(.*?) \((0x[0-9a-f]+)\)", v["thread"] or "")
            k = (m.group(1) if m else v["thread"])
            th[k][0] += v["dur"]
            th[k][1] += 1
    P("   encoder encode time by thread per frame: " + ", ".join(
        "%s %.2f ms (%.0f enc)" % (k, ms(a[0]) / len(frames), a[1] / len(frames))
        for k, a in sorted(th.items(), key=lambda x: -x[1][0])[:4]))

    P("")
    P("Notes: frame delimiting by GPU end of the present command buffer; GPU rows of other processes (WindowServer) are")
    P("ignored; per-label numbers use all rows (any nesting depth) that start inside the window, so GPU work of a frame")
    P("is counted when it executes, not by trace frame number; CPU samples are 1 ms interval, running threads only.")
    return out


def main():
    ap = argparse.ArgumentParser(description="Summarise a Metal System Trace of bbport")
    ap.add_argument("trace")
    ap.add_argument("--out", help="directory for the xctrace exports (default: temp dir)")
    ap.add_argument("--top", type=int, default=40, help="labels in the GPU time table")
    a = ap.parse_args()
    d = export(a.trace, a.out or tempfile.mkdtemp(prefix="mtltrace-"))
    print("\n".join(report(a.trace, d, a.top)))


if __name__ == "__main__":
    main()
