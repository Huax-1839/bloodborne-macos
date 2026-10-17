#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""powerstats.py [--tsv] [--keys] [--threads <csv>] <name>|<plist>   (run as: python3 -I powerstats.py ...)
powerstats.py --selftest

Joins a powermetrics recording (power.sh, `-f plist` stream) with the run's per-flip log and
reports per minute (docs/metal/power_budget_design.md, "Measurement"): CPU/GPU/package W, E and P
cluster MHz and active residency, GPU MHz and active residency, thermal pressure, FPS, mean and
p95 gpu_ms and rec_busy_ms, missed 30-FPS slots, charge, power source and, with a thread CSV, CPU %
per thread group (100 = one core). Then a summary over the in-game span, minutes 0-5 against 15-20
of it, and the busiest threads.

A bare <name> resolves, in ~/Games/Bloodborne/bench/runs (BB_BENCH_DIR changes the base):
  bench-<name>-powermetrics.plist (required), -powermetrics.start (wall epoch of the start, used
  when samples carry no timestamp), bench-<name>-frames.csv (t_s, frame_ms, gpu_ms, rec_busy_ms,
  draws), bench-<name>.log (line `Frame log: t_s=0 at epoch <s>`; else the CSV's mtime minus its
  last t_s), bench-<name>-power.txt (source and charge once a minute), bench-<name>-threads.csv
  (BB_THREAD_CPU_CSV: epoch_s,interval_s,tid,name,group,user_ms,sys_ms,priority). All but the
  plist are optional. A path to a bench-<name>-powermetrics.plist works as well.

In-game span (as m3stats.py): first to last flip with 300+ draws; minute 0 starts there, earlier
minutes (boot, idle cool-down) are negative. A flip misses its slot when frame_ms > 1000/30+1000/120.
Samples are binned by the middle of their interval. --keys prints the first sample's key tree and
exits (the plist keys differ between macOS versions and chips: it shows what to adjust); the
report names every quantity the plist did not provide. --tsv: tab-separated for the plan's tables."""
import argparse
import calendar
import datetime
import os
import plistlib
import re
import statistics
import sys
import tempfile
from pathlib import Path

IN_GAME_DRAWS = 300
SLOT_MS = 1000 / 30 + 1000 / 120
PRESSURE_ORDER = ["nominal", "light", "fair", "moderate", "heavy", "serious", "trapping", "critical", "sleeping"]
GROUPS = ["guest", "port", "metal", "other"]
LOG_EPOCH = re.compile(r"Frame log: t_s=0 at epoch ([\d.]+)")
POWER_LINE = re.compile(r"power (\d+) source=(\S+) charge=(\d*)")


# ---- plist stream -----------------------------------------------------------------------------
def split_stream(data):
    """Plist documents of a powermetrics stream: NUL-separated; also split at `<?xml` when needed."""
    docs = []
    for chunk in data.split(b"\0"):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = re.split(rb"(?=<\?xml)", chunk)
        docs.extend(p for p in parts if p.strip())
    return docs


def load_doc(doc):
    try:
        try:
            return plistlib.loads(doc, aware_datetime=True)
        except TypeError:  # Python before 3.13: naive datetimes are UTC
            return plistlib.loads(doc)
    except Exception:
        return None  # truncated last sample


def read_samples(path):
    samples = []
    for doc in split_stream(Path(path).read_bytes()):
        d = load_doc(doc)
        if isinstance(d, dict):
            samples.append(d)
    return samples


def to_epoch(dt):
    if dt.tzinfo is not None:
        return dt.timestamp()
    return calendar.timegm(dt.timetuple()) + dt.microsecond / 1e6  # naive: UTC, as plistlib stores it


def key_tree(value, indent=0, name=""):
    pad = "  " * indent
    if isinstance(value, dict):
        print(f"{pad}{name}{{}} ({len(value)} keys)")
        for k, v in value.items():
            key_tree(v, indent + 1, f"{k}: ")
    elif isinstance(value, list):
        print(f"{pad}{name}[] (len {len(value)})")
        if value:
            key_tree(value[0], indent + 1, "[0] ")
    else:
        text = repr(value)
        print(f"{pad}{name}{type(value).__name__} = {text[:60]}")


# ---- sample extraction ------------------------------------------------------------------------
def num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def lookup(containers, key):
    for c in containers:
        if isinstance(c, dict) and num(c.get(key)) is not None:
            return num(c[key])
    return None


def watts(containers, power_keys, energy_keys, elapsed_s):
    """W from a power key (mW) or an energy key (mJ over the sample)."""
    for k in power_keys:
        v = lookup(containers, k)
        if v is not None:
            return v / 1000.0
    for k in energy_keys:
        v = lookup(containers, k)
        if v is not None and elapsed_s > 0:
            return v / 1000.0 / elapsed_s
    return None


def to_mhz(v):
    """freq_hz is Hz for the CPU clusters but MHz for the GPU on macOS 26 (338.0): decide by size."""
    if v is None or v <= 0:
        return None  # 0: the cluster was never active in the interval
    return v / 1e6 if v >= 1e5 else v


def cluster_stats(c):
    """(freq MHz, active ratio) of one cluster dict, from its own keys or its cpus."""
    cpus = [x for x in c.get("cpus", []) if isinstance(x, dict)]
    idle = num(c.get("idle_ratio"))
    if idle is None:
        idles = [num(x.get("idle_ratio")) for x in cpus if num(x.get("idle_ratio")) is not None]
        idle = statistics.mean(idles) if idles else None
    act = None if idle is None else 1.0 - idle
    freq = num(c.get("freq_hz"))
    if freq is None:
        pairs = [(num(x.get("freq_hz")), 1.0 - (num(x.get("idle_ratio")) or 0.0)) for x in cpus
                 if num(x.get("freq_hz")) is not None]
        if pairs:
            w = sum(a for _, a in pairs)
            freq = sum(f * a for f, a in pairs) / w if w > 0 else statistics.mean(f for f, _ in pairs)
    return to_mhz(freq), act


def group_clusters(clusters, prefix):
    stats = [cluster_stats(c) for c in clusters if str(c.get("name", "")).upper().startswith(prefix)]
    freqs = [(f, a) for f, a in stats if f is not None]
    acts = [a for _, a in stats if a is not None]
    mhz = None
    if freqs:
        w = sum((a or 0.0) for _, a in freqs)
        mhz = sum(f * (a or 0.0) for f, a in freqs) / w if w > 0 else None
    return mhz, (statistics.mean(acts) if acts else None)


def extract(d, prev_end, start_epoch):
    """One sample dict of the quantities (None where missing), with its interval's end and middle epoch."""
    proc = d.get("processor") if isinstance(d.get("processor"), dict) else {}
    gpu = d.get("gpu") if isinstance(d.get("gpu"), dict) else {}
    elapsed = (num(d.get("elapsed_ns")) or 1e9) / 1e9
    ts = d.get("timestamp")
    if isinstance(ts, datetime.datetime):
        end = to_epoch(ts)
    elif start_epoch is not None:
        end = (prev_end if prev_end is not None else start_epoch) + elapsed
    else:
        end = None
    clusters = [c for c in proc.get("clusters", []) if isinstance(c, dict)]
    e_mhz, e_act = group_clusters(clusters, "E")
    p_mhz, p_act = group_clusters(clusters, "P")
    s = {"end": end, "elapsed": elapsed, "mid": None if end is None else end - elapsed / 2}
    top = [proc, d]
    s["cpu_w"] = watts(top, ["cpu_power"], ["cpu_energy"], elapsed)
    s["pkg_w"] = watts(top, ["combined_power", "package_power"], ["combined_energy", "package_energy"], elapsed)
    # The gpu dict's energy first: processor.gpu_power is 0.0 in the first sample of a recording.
    s["gpu_w"] = watts([gpu], [], ["gpu_energy"], elapsed)
    if s["gpu_w"] is None:
        s["gpu_w"] = watts([gpu, proc, d], ["gpu_power"], ["gpu_energy"], elapsed)
    s["e_mhz"], s["e_act"], s["p_mhz"], s["p_act"] = e_mhz, e_act, p_mhz, p_act
    gmhz = lookup([gpu], "freq_hz")
    gmhz = to_mhz(gmhz)
    gidle = lookup([gpu], "idle_ratio")
    states = [x for x in gpu.get("dvfm_states", []) if isinstance(x, dict)]
    if states and (gmhz is None or gidle is None):
        used = [(num(x.get("freq")) or 0.0, num(x.get("used_ratio")) or 0.0) for x in states]
        busy = [(f, u) for f, u in used if f > 0]
        if gidle is None and busy:
            gidle = 1.0 - sum(u for _, u in busy)
        if gmhz is None and busy and sum(u for _, u in busy) > 0:
            gmhz = sum(f * u for f, u in busy) / sum(u for _, u in busy)
    s["gpu_mhz"] = gmhz
    s["gpu_act"] = None if gidle is None else 1.0 - gidle
    pr = d.get("thermal_pressure")
    s["press"] = pr if isinstance(pr, str) else None
    return s


def build_samples(docs, start_epoch):
    samples, prev_end = [], None
    for d in docs:
        s = extract(d, prev_end, start_epoch)
        if s["end"] is None:
            continue
        prev_end = s["end"]
        samples.append(s)
    return samples


# ---- other inputs -----------------------------------------------------------------------------
def read_frames(path, epoch0):
    """Flips as dicts with epoch, frame_ms, gpu_ms, rec_ms (None when the column is missing), draws."""
    with open(path, errors="replace") as f:
        header = f.readline().strip().split(",")
        idx = {k: header.index(k) for k in ("t_s", "frame_ms", "draws")}
        gpu_i = header.index("gpu_ms") if "gpu_ms" in header else None
        rec_i = header.index("rec_busy_ms") if "rec_busy_ms" in header else None
        rows = []
        for line in f:
            c = line.strip().split(",")
            if len(c) < len(header):
                continue  # the last line of a killed run
            try:
                rows.append((float(c[idx["t_s"]]), float(c[idx["frame_ms"]]), int(c[idx["draws"]]),
                             float(c[gpu_i]) if gpu_i is not None else None,
                             float(c[rec_i]) if rec_i is not None else None))
            except ValueError:
                continue
    return rows


def read_power_log(path):
    out = []
    for line in Path(path).read_text(errors="replace").splitlines():
        if m := POWER_LINE.match(line):
            out.append((float(m[1]), m[2], int(m[3]) if m[3] else None))
    return sorted(out)


def read_threads(path):
    rows = []
    with open(path, errors="replace") as f:
        header = f.readline().strip().split(",")
        ix = {k: header.index(k) for k in ("epoch_s", "interval_s", "tid", "name", "group", "user_ms", "sys_ms")}
        for line in f:
            c = line.rstrip("\n").split(",")
            if len(c) < len(header):
                continue
            try:
                rows.append((float(c[ix["epoch_s"]]), float(c[ix["interval_s"]]), c[ix["tid"]], c[ix["name"]],
                             c[ix["group"]], float(c[ix["user_ms"]]) + float(c[ix["sys_ms"]])))
            except ValueError:
                continue
    return rows


def percentile(values, p):
    values = sorted(values)
    if not values:
        return None
    k = (len(values) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def mean(values):
    values = [v for v in values if v is not None]
    return statistics.mean(values) if values else None


# ---- the join ---------------------------------------------------------------------------------
class Run:
    def __init__(self, samples, frames=None, epoch0=None, power_log=None, threads=None):
        self.samples = sorted(samples, key=lambda s: s["mid"])
        self.flips = []
        if frames:
            self.flips = [dict(t=epoch0 + t, ms=ms, draws=dr, gpu=g, rec=r) for t, ms, dr, g, r in frames]
        self.power_log = power_log or []
        self.threads = threads or []
        game = [f["t"] for f in self.flips if f["draws"] >= IN_GAME_DRAWS]
        self.t0 = game[0] if game else None
        self.t1 = game[-1] if game else None
        self.has_span = self.t0 is not None
        if self.t0 is None:
            self.t0 = self.samples[0]["mid"] if self.samples else 0.0
        self.frame_range = (self.flips[0]["t"] - 0.05, self.flips[-1]["t"] + 0.05) if self.flips else None
        self.has_rec = any(f["rec"] is not None for f in self.flips)
        self.has_gpu = any(f["gpu"] is not None for f in self.flips)

    def aggregate(self, lo, hi):
        """The columns over wall epochs [lo, hi)."""
        r = {}
        ss = [s for s in self.samples if lo <= s["mid"] < hi]
        r["n_samples"] = len(ss)
        for k in ("cpu_w", "gpu_w", "pkg_w"):
            r[k] = mean(s[k] for s in ss)
        for k, a in (("e_mhz", "e_act"), ("p_mhz", "p_act"), ("gpu_mhz", "gpu_act")):
            # Active frequency: weighted by the active residency (an idle second reports 0 or noise).
            pairs = [(s[k], s[a]) for s in ss if s[k] is not None and s[a] is not None and s[a] > 0]
            w = sum(x for _, x in pairs)
            r[k] = sum(f * x for f, x in pairs) / w if w > 0 else mean(s[k] for s in ss)
        for k in ("e_act", "p_act", "gpu_act"):
            v = mean(s[k] for s in ss)
            r[k] = None if v is None else v * 100
        levels = [s["press"] for s in ss if s["press"]]
        r["press"] = None
        if levels:
            mode = max(set(levels), key=levels.count)
            worst = max(levels, key=lambda x: PRESSURE_ORDER.index(x.lower()) if x.lower() in PRESSURE_ORDER else -1)
            r["press"] = mode if mode == worst else f"{mode}/{worst}"
        fl = [f for f in self.flips if lo <= f["t"] < hi]
        r["fps"] = r["gpu_mean"] = r["gpu_p95"] = r["rec_mean"] = r["rec_p95"] = r["miss_pct"] = r["miss_n"] = None
        if fl and self.frame_range:
            span = min(hi, self.frame_range[1]) - max(lo, self.frame_range[0])
            r["fps"] = len(fl) / span if span > 0 else None
            gm = [f["gpu"] for f in fl if f["gpu"] is not None and f["gpu"] > 0]
            rc = [f["rec"] for f in fl if f["rec"] is not None and f["rec"] > 0]
            r["gpu_mean"], r["gpu_p95"] = mean(gm), percentile(gm, 0.95)
            r["rec_mean"], r["rec_p95"] = mean(rc), percentile(rc, 0.95)
            miss = sum(f["ms"] > SLOT_MS for f in fl)
            r["miss_n"], r["miss_pct"] = miss, 100.0 * miss / len(fl)
        r["charge"] = r["source"] = None
        prior = [p for p in self.power_log if p[0] <= hi]
        if prior:
            r["charge"], r["source"] = prior[-1][2], prior[-1][1]
        for g in GROUPS:
            r["cpu_" + g] = None
        if self.threads:
            rows = [t for t in self.threads if lo <= t[0] < hi]
            intervals = {}
            for t in rows:
                intervals[round(t[0], 3)] = t[1]
            total = sum(intervals.values())
            if total > 0:
                for g in GROUPS:
                    r["cpu_" + g] = sum(t[5] for t in rows if t[4] == g) / (total * 1000.0) * 100
        return r

    def minutes(self):
        lo_t = [s["mid"] for s in self.samples] + [f["t"] for f in self.flips[:1]]
        hi_t = [s["mid"] for s in self.samples] + [f["t"] for f in self.flips[-1:]]
        first, last = int((min(lo_t) - self.t0) // 60), int((max(hi_t) - self.t0) // 60)
        rows = []
        for m in range(first, last + 1):
            r = self.aggregate(self.t0 + m * 60, self.t0 + (m + 1) * 60)
            r["minute"] = m
            r["phase"] = ("pre" if m < 0 else "post" if self.has_span and self.t0 + m * 60 >= self.t1 else
                          "game" if self.has_span else "?")
            rows.append(r)
        return rows

    def windows(self):
        """(label, aggregate) for the whole in-game span, minutes 0-5 and 15-20."""
        if not self.has_span:
            return []
        out = [("span", self.aggregate(self.t0, self.t1 + 1e-6))]
        for a, b in ((0, 5), (15, 20)):
            lo, hi = self.t0 + a * 60, min(self.t0 + b * 60, self.t1 + 1e-6)
            out.append((f"min {a}-{b}", self.aggregate(lo, hi) if hi - lo >= 60 else None))
        return out

    def top_threads(self, n=10):
        if not self.has_span or not self.threads:
            return []
        rows = [t for t in self.threads if self.t0 <= t[0] <= self.t1]
        total = sum({round(t[0], 3): t[1] for t in rows}.values())
        if total <= 0:
            return []
        acc = {}
        for t in rows:
            k = (t[2], t[3], t[4])
            acc[k] = acc.get(k, 0.0) + t[5]
        top = sorted(acc.items(), key=lambda kv: -kv[1])[:n]
        return [(name, group, tid, ms / (total * 1000.0) * 100) for (tid, name, group), ms in top]


# ---- output -----------------------------------------------------------------------------------
COLUMNS = [  # key, header, format, number of decimals (None: text)
    ("cpu_w", "CPU W", 2), ("gpu_w", "GPU W", 2), ("pkg_w", "pkg W", 2),
    ("e_mhz", "E MHz", 0), ("p_mhz", "P MHz", 0), ("e_act", "E act%", 1), ("p_act", "P act%", 1),
    ("gpu_mhz", "GPU MHz", 0), ("gpu_act", "GPU act%", 1), ("press", "pressure", None),
    ("fps", "FPS", 2), ("gpu_mean", "gpu ms", 2), ("gpu_p95", "gpu p95", 2),
    ("rec_mean", "rec ms", 2), ("rec_p95", "rec p95", 2), ("miss_pct", "miss %", 2), ("miss_n", "miss n", 0),
    ("charge", "chg %", 0), ("source", "source", None),
    ("cpu_guest", "guest %", 0), ("cpu_port", "port %", 0), ("cpu_metal", "metal %", 0), ("cpu_other", "other %", 0),
]


def fmt(v, dec):
    if v is None:
        return "-"
    return str(v) if dec is None else f"{v:.{dec}f}"


def columns_in_use(rows):
    return [c for c in COLUMNS if any(r.get(c[0]) is not None for r in rows)]


def table(rows, cols, label_head, tsv):
    head = [label_head] + [c[1] for c in cols]
    body = [[r["label"]] + [fmt(r.get(c[0]), c[2]) for c in cols] for r in rows]
    if tsv:
        return "\n".join("\t".join(x) for x in [head] + body)
    widths = [max(len(x[i]) for x in [head] + body) for i in range(len(head))]
    return "\n".join("  ".join(c.rjust(w) if i else c.ljust(w) for i, (c, w) in enumerate(zip(x, widths)))
                     for x in [head] + body)


def report(run, tsv, notes, thread_top_n=10):
    out = []
    mins = run.minutes()
    for r in mins:
        r["label"] = f"{r['minute']}{'' if r['phase'] == 'game' else ' ' + r['phase']}"
    windows = run.windows()
    cols = columns_in_use(mins + [w for _, w in windows if w])
    if not tsv:
        out.extend(notes)
        out.append("")
    out.append(table(mins, cols, "minute", tsv))
    if windows:
        rows = []
        for c in cols:
            vals = [w.get(c[0]) if w else None for _, w in windows]
            row = {"label": c[1], "span": vals[0], "a": vals[1], "b": vals[2]}
            rows.append((c, row))
        head = ["", "span", "min 0-5", "min 15-20", "delta %"]
        body = []
        for c, row in rows:
            a, b = row["a"], row["b"]
            delta = "-"
            if c[2] is not None and a is not None and b is not None and a != 0:
                delta = f"{(b - a) / abs(a) * 100:+.1f}"
            body.append([c[1], fmt(row["span"], c[2]), fmt(a, c[2]), fmt(b, c[2]), delta])
        out.append("")
        if not tsv:
            out.append("summary (in-game span; minutes 0-5 vs 15-20 of it):")
        if tsv:
            out.append("\t".join(head))
            out.extend("\t".join(x) for x in body)
        else:
            widths = [max(len(x[i]) for x in [head] + body) for i in range(len(head))]
            for x in [head] + body:
                out.append("  ".join(v.rjust(w) if i else v.ljust(w) for i, (v, w) in enumerate(zip(x, widths))))
    top = run.top_threads(thread_top_n)
    if top:
        out.append("")
        out.append("busiest threads over the in-game span (CPU %, 100 = one core):")
        for name, group, tid, pct in top:
            out.append(f"  {pct:6.1f}  {group:<6} {name or '(unnamed)'} [{tid}]" if not tsv
                       else f"{pct:.1f}\t{group}\t{name}\t{tid}")
    return "\n".join(out)


# ---- locating the files -----------------------------------------------------------------------
def resolve(arg):
    p = Path(arg)
    if p.suffix == ".plist" and p.exists():
        m = re.match(r"bench-(.*)-powermetrics$", p.stem)
        return (m.group(1) if m else p.stem), p.parent, p
    base = Path(os.environ.get("BB_BENCH_DIR", Path.home() / "Games/Bloodborne/bench")) / "runs"
    return arg, base, base / f"bench-{arg}-powermetrics.plist"


def load_run(name, runs, plist, threads_arg):
    notes, missing = [], []
    raw = split_stream(plist.read_bytes())
    docs = [d for d in (load_doc(x) for x in raw) if isinstance(d, dict)]
    skipped = len(raw) - len(docs)
    start_f = runs / f"bench-{name}-powermetrics.start"
    start = float(start_f.read_text().strip()) if start_f.exists() else None
    if start is None and not any(isinstance(d.get("timestamp"), datetime.datetime) for d in docs):
        sys.exit(f"{plist.name}: samples have no timestamp and {start_f.name} is missing")
    samples = build_samples(docs, start)
    if not samples:
        sys.exit(f"{plist}: no samples")
    notes.append(f"{plist.name}: {len(samples)} samples" + (f" ({skipped} unreadable skipped)" if skipped else "") +
                 (", times from timestamp" if any(isinstance(d.get("timestamp"), datetime.datetime) for d in docs)
                  else f", times from {start_f.name} + elapsed_ns"))
    for k, label in (("cpu_w", "CPU W"), ("gpu_w", "GPU W"), ("pkg_w", "package/combined W"), ("e_mhz", "E cluster"),
                     ("p_mhz", "P cluster"), ("gpu_mhz", "GPU MHz"), ("gpu_act", "GPU active %"), ("press", "pressure")):
        if all(s[k] is None for s in samples):
            missing.append(label)
    if missing:
        notes.append("not in the plist (see --keys): " + ", ".join(missing))
    frames = epoch0 = None
    frames_f = runs / f"bench-{name}-frames.csv"
    if frames_f.exists():
        log_f = runs / f"bench-{name}.log"
        base_epoch = None
        if log_f.exists():
            found = LOG_EPOCH.findall(log_f.read_text(errors="replace"))
            if found:
                base_epoch = float(found[-1])
        raw_frames = read_frames(frames_f, 0.0)
        if base_epoch is not None:
            how = f"t_s=0 epoch from {log_f.name}"
        elif raw_frames:
            base_epoch = frames_f.stat().st_mtime - raw_frames[-1][0]
            how = "t_s=0 epoch = CSV mtime - last t_s (no 'Frame log' line in the game log; approximate)"
        if raw_frames:
            frames, epoch0 = raw_frames, base_epoch
            notes.append(f"{frames_f.name}: {len(raw_frames)} flips, {how}")
            if not any(r[3] is not None for r in raw_frames):
                notes.append("no gpu_ms column in the frames log")
            if not any(r[4] is not None for r in raw_frames):
                notes.append("no rec_busy_ms column in the frames log")
    else:
        notes.append(f"{frames_f.name} missing: no FPS, GPU time or missed slots")
    power_f = runs / f"bench-{name}-power.txt"
    power_log = read_power_log(power_f) if power_f.exists() else None
    if power_log is None:
        notes.append(f"{power_f.name} missing: no charge or source")
    thr_f = Path(threads_arg) if threads_arg else runs / f"bench-{name}-threads.csv"
    threads = read_threads(thr_f) if thr_f.exists() else None
    if threads is not None:
        notes.append(f"{thr_f.name}: {len(threads)} thread rows")
    elif threads_arg:
        sys.exit(f"{thr_f}: not found")
    return Run(samples, frames, epoch0, power_log, threads), notes


# ---- selftest ---------------------------------------------------------------------------------
def selftest():
    S = 1_800_000_000
    E0 = S + 30

    def sample(i, with_ts):
        idle = i < 30
        d = {"elapsed_ns": 1_000_000_000, "thermal_pressure": "Nominal" if i < 100 else "Moderate",
             "processor": {
                 "clusters": [
                     {"name": "E-Cluster", "freq_hz": 1.0e9, "idle_ratio": 0.5, "cpus": [{"freq_hz": 1e9, "idle_ratio": 0.5}]},
                     {"name": "P0-Cluster", "freq_hz": 3.0e9, "idle_ratio": 0.5},
                     {"name": "P1-Cluster", "freq_hz": 2.0e9, "cpus": [{"freq_hz": 2.0e9, "idle_ratio": 0.0}]}],
                 "cpu_power": 2000.0 if idle else 4000.0},
             "gpu": {"freq_hz": 1.0e9, "idle_ratio": 0.75, "gpu_energy": 3000.0}}
        if with_ts:
            d["timestamp"] = datetime.datetime.fromtimestamp(S + i + 1, datetime.timezone.utc)
        return d

    with tempfile.TemporaryDirectory() as tmp:
        runs = Path(tmp)
        for name, with_ts in (("ts", True), ("nots", False)):
            blob = b"".join(plistlib.dumps(sample(i, with_ts)) + b"\0" for i in range(200))
            blob += plistlib.dumps(sample(200, with_ts))[:300]  # truncated last sample
            (runs / f"bench-{name}-powermetrics.plist").write_bytes(blob)
            (runs / f"bench-{name}-powermetrics.start").write_text(f"{S}\n")
            (runs / f"bench-{name}.log").write_text(f"x\nFrame log: t_s=0 at epoch {E0}.000\n")
            lines = ["t_s,frame_ms,gpu_ms,rec_busy_ms,draws"]
            for k in range(4500):
                t = (k + 0.5) / 30
                game = t >= 30
                slow = t >= 90 and k % 10 == 0
                lines.append(f"{t:.4f},{50.0 if slow else 33.33},{20 if slow else 10},5,{400 if game else 10}")
            (runs / f"bench-{name}-frames.csv").write_text("\n".join(lines) + "\n")
            (runs / f"bench-{name}-power.txt").write_text(
                f"power {S + 10} source=AC_Power charge=90 lowpower=0 therm=\n"
                f"power {S + 70} source=AC_Power charge=89 lowpower=0 therm=\n"
                f"power {S + 130} source=AC_Power charge=88 lowpower=0 therm=\n")
            th = ["epoch_s,interval_s,tid,name,group,user_ms,sys_ms,priority"]
            for j in range(20):
                e = S + 5 + 10 * j
                th += [f"{e},10,1,main,guest,400,200,33", f"{e},10,2,bb:A,port,100,50,33", f"{e},10,3,bb:B,port,100,50,33",
                       f"{e},10,4,x,other,10,0,0"]
            (runs / f"bench-{name}-threads.csv").write_text("\n".join(th) + "\n")
            n, rdir, plist = resolve(str(runs / f"bench-{name}-powermetrics.plist"))
            assert n == name
            run, notes = load_run(n, rdir, plist, None)
            assert len(run.samples) == 200, len(run.samples)
            assert abs(run.t0 - (S + 60)) < 0.1 and abs(run.t1 - (S + 179.98)) < 0.1, (run.t0, run.t1)
            rows = {r["minute"]: r for r in run.minutes()}
            assert set(range(-1, 3)) <= set(rows), sorted(rows)

            def near(a, b, tol=0.05):
                assert a is not None and abs(a - b) <= tol, (name, a, b)
            near(rows[-1]["cpu_w"], 3.0)
            assert rows[-1]["phase"] == "pre" and rows[0]["phase"] == "game"
            near(rows[0]["cpu_w"], 4.0); near(rows[1]["cpu_w"], 4.0)
            near(rows[0]["gpu_w"], 3.0)
            near(rows[0]["e_mhz"], 1000); near(rows[0]["e_act"], 50)
            near(rows[0]["p_mhz"], 2333.33, 0.5); near(rows[0]["p_act"], 75)
            near(rows[0]["gpu_mhz"], 1000); near(rows[0]["gpu_act"], 25)
            assert rows[-1]["press"] == "Nominal" and rows[0]["press"] == "Nominal/Moderate" and rows[1]["press"] == "Moderate", \
                (rows[-1]["press"], rows[0]["press"], rows[1]["press"])
            near(rows[-1]["fps"], 30, 0.1); near(rows[0]["fps"], 30, 0.1); near(rows[1]["fps"], 30, 0.1)
            near(rows[0]["gpu_mean"], 10); near(rows[1]["gpu_mean"], 11); near(rows[1]["gpu_p95"], 20)
            near(rows[0]["rec_mean"], 5); near(rows[0]["rec_p95"], 5)
            assert rows[0]["miss_n"] == 0 and rows[1]["miss_n"] == 180, (rows[0]["miss_n"], rows[1]["miss_n"])
            near(rows[1]["miss_pct"], 10.0)
            assert rows[-1]["charge"] == 90 and rows[0]["charge"] == 89 and rows[1]["charge"] == 88
            near(rows[0]["cpu_guest"], 6.0); near(rows[0]["cpu_port"], 3.0); near(rows[0]["cpu_other"], 0.1)
            assert rows[0]["cpu_metal"] is None or rows[0]["cpu_metal"] == 0
            w = dict(run.windows())
            assert w["min 15-20"] is None and w["span"]["miss_n"] == 180
            near(w["span"]["cpu_w"], 4.0, 0.01)
            top = run.top_threads()
            assert top[0][0] == "main" and abs(top[0][3] - 6.0) < 0.1, top
            text = report(run, False, notes)
            assert "pre" in text and "summary" in text and "main" in text
            assert report(run, True, notes).count("\t") > 20
        # no thread CSV, no frames: still reports the power minutes
        only = tmp + "/only.plist"
        Path(only).write_bytes(b"".join(plistlib.dumps(sample(i, True)) + b"\0" for i in range(5)))
        run = Run(build_samples(read_samples(only), None))
        assert run.minutes() and report(run, False, [])
        # macOS 26 sample shapes: GPU freq_hz in MHz, an idle P cluster at 0 Hz, processor.gpu_power 0.0
        real = {"elapsed_ns": 1_000_000_000, "timestamp": datetime.datetime(2026, 1, 1),
                "processor": {"clusters": [{"name": "E-Cluster", "freq_hz": 1.4e9, "idle_ratio": 0.5},
                                           {"name": "P-Cluster", "freq_hz": 0.0, "idle_ratio": 1.0}],
                              "cpu_power": 135.0, "gpu_power": 0.0, "combined_power": 135.0},
                "gpu": {"freq_hz": 338.0, "idle_ratio": 0.8, "gpu_energy": 38}}
        x = extract(real, None, None)
        assert x["gpu_mhz"] == 338.0 and abs(x["gpu_w"] - 0.038) < 1e-9 and x["p_mhz"] is None and x["p_act"] == 0.0, x
        assert abs(x["e_mhz"] - 1400) < 1e-6 and abs(x["end"] - 1767225600) < 1, x["end"]
        # --keys style tree and split without NUL
        data = plistlib.dumps(sample(0, True)) + plistlib.dumps(sample(1, True))
        assert len(split_stream(data)) == 2
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tsv", action="store_true", help="tab-separated output")
    ap.add_argument("--keys", action="store_true", help="print the first sample's key tree and exit")
    ap.add_argument("--threads", help="thread CSV (default bench-<name>-threads.csv)")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("run", nargs="?", help="<name> or path of a powermetrics plist")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if not args.run:
        ap.error("run name or plist required")
    name, runs, plist = resolve(args.run)
    if not plist.exists():
        sys.exit(f"{plist}: not found")
    if args.keys:
        docs = [d for d in (load_doc(x) for x in split_stream(plist.read_bytes())) if isinstance(d, dict)]
        if not docs:
            sys.exit(f"{plist}: no readable sample")
        key_tree(docs[0])
        return
    run, notes = load_run(name, runs, plist, args.threads)
    print(report(run, args.tsv, notes))


if __name__ == "__main__":
    main()
