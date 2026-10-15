#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# imgdiff.py: screenshot comparison for Vulkan-vs-Metal image parity (plan P0.2, §6).
#
#   imgdiff.py A.png B.png [--psnr-min 35] [--tile 32] [--tile-max 64] [--map out.png]
#                          [--crop x,y,w,h] [--no-ignore-alpha] [--resize]
#
# Compares RGB (alpha is ignored by default) of two screenshots of the same size and prints
#   PASS|FAIL psnr=XX.XX dB mae=X.XX worst_tile=(tx,ty) max=NN tiles_over=K/N
# followed by up to 10 worst tiles. PASS needs PSNR >= --psnr-min and no tile whose maximum
# absolute channel error exceeds --tile-max. Exit code: 0 pass, 1 fail, 2 usage/IO error.
#
# --map writes a PNG with one 8x8 block per tile; its colour is the tile's maximum error on a
# black -> red -> yellow ramp (square-root scaled so errors of 1..3 still show).
# --resize scales B to A's size with `sips -z` instead of failing on a size mismatch.
# --crop uses pixel coordinates (Retina screenshots are 2x of window points).
#
# Python 3 standard library only. PNGs (8-bit RGB/RGBA, non-interlaced) are decoded here; any
# other input (JPEG, TIFF, 16-bit, palette, interlaced) is first converted with
# `sips -s format png`. Colour profiles are not interpreted (raw values are compared).

import argparse
import math
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from array import array
from itertools import accumulate

PNG_SIG = b"\x89PNG\r\n\x1a\n"


class ImgError(Exception):
    pass


class Unsupported(ImgError):
    pass


# ---------------------------------------------------------------------------------------------
# PNG reading


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


_LITTLE = sys.byteorder == "little"


def _unfilter_sub(raw, bpp):
    # Per channel a prefix sum modulo 256; accumulate runs in C, the low byte of each 32-bit
    # partial sum is the answer (max partial sum 255 * width fits easily).
    out = bytearray(len(raw))
    for c in range(bpp):
        sums = array("I", accumulate(raw[c::bpp]))
        b = sums.tobytes()
        out[c::bpp] = b[0::4] if _LITTLE else b[3::4]
    return out


def _unfilter_up(raw, prev):
    # Byte-wise (raw + prev) mod 256 using 16-bit lanes of a big integer.
    n = len(raw)
    m = int.from_bytes(b"\xff\x00" * (n // 2) + (b"\xff" if n & 1 else b""), "little")
    a = int.from_bytes(raw, "little")
    b = int.from_bytes(prev, "little")
    even = ((a & m) + (b & m)) & m
    odd = (((a >> 8) & m) + ((b >> 8) & m)) & m
    return (even | (odd << 8)).to_bytes(n, "little")


def _unfilter_avg(raw, prev, bpp):
    n = len(raw)
    out = bytearray(n)
    for i in range(min(bpp, n)):
        out[i] = (raw[i] + (prev[i] >> 1)) & 255
    for i in range(bpp, n):
        out[i] = (raw[i] + ((out[i - bpp] + prev[i]) >> 1)) & 255
    return out


def _unfilter_paeth(raw, prev, bpp):
    n = len(raw)
    out = bytearray(n)
    for i in range(min(bpp, n)):
        out[i] = (raw[i] + prev[i]) & 255
    for i in range(bpp, n):
        a = out[i - bpp]
        b = prev[i]
        c = prev[i - bpp]
        p = a + b - c
        pa = abs(p - a)
        pb = abs(p - b)
        pc = abs(p - c)
        if pa <= pb and pa <= pc:
            pr = a
        elif pb <= pc:
            pr = b
        else:
            pr = c
        out[i] = (raw[i] + pr) & 255
    return out


def read_png(data):
    """Decode a PNG to (width, height, [RGBA row bytes]); raises Unsupported for other kinds."""
    if data[:8] != PNG_SIG:
        raise Unsupported("not a PNG file")
    pos = 8
    ihdr = None
    idat = []
    while pos + 8 <= len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    if ihdr is None or not idat:
        raise ImgError("truncated or corrupt PNG (no IHDR/IDAT)")
    w, h, depth, ctype, comp, filt, interlace = ihdr
    if depth != 8 or ctype not in (2, 6) or interlace != 0 or comp != 0 or filt != 0:
        raise Unsupported(
            "unsupported PNG (bit depth %d, colour type %d, interlace %d)" % (depth, ctype, interlace))
    bpp = 3 if ctype == 2 else 4
    stride = w * bpp
    try:
        raw = zlib.decompress(b"".join(idat))
    except zlib.error as e:
        raise ImgError("corrupt PNG data: %s" % e)
    if len(raw) < (stride + 1) * h:
        raise ImgError("truncated PNG data")

    rows = []
    prev = bytes(stride)
    mv = memoryview(raw)
    pad = b"\xff" * w
    for y in range(h):
        off = y * (stride + 1)
        ft = raw[off]
        line = mv[off + 1:off + 1 + stride]
        if ft == 0:
            cur = bytes(line)
        elif ft == 1:
            cur = _unfilter_sub(line, bpp)
        elif ft == 2:
            cur = _unfilter_up(line, prev)
        elif ft == 3:
            cur = _unfilter_avg(line, prev, bpp)
        elif ft == 4:
            cur = _unfilter_paeth(line, prev, bpp)
        else:
            raise ImgError("corrupt PNG: filter type %d in row %d" % (ft, y))
        prev = cur
        if bpp == 4:
            rows.append(bytes(cur))
        else:
            rgba = bytearray(4 * w)
            rgba[0::4] = cur[0::3]
            rgba[1::4] = cur[1::3]
            rgba[2::4] = cur[2::3]
            rgba[3::4] = pad
            rows.append(bytes(rgba))
    return w, h, rows


def _sips(args):
    try:
        subprocess.run(["sips"] + args, check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE)
    except FileNotFoundError:
        raise ImgError("sips not found (needed for this input)")
    except subprocess.CalledProcessError as e:
        raise ImgError("sips failed: %s" % e.stderr.decode(errors="replace").strip())


def load_image(path, tmpdir, tag):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise ImgError("cannot read %s: %s" % (path, e.strerror))
    try:
        return read_png(data)
    except Unsupported as first:
        tmp = os.path.join(tmpdir, "conv_%s.png" % tag)
        _sips(["-s", "format", "png", path, "--out", tmp])
        try:
            with open(tmp, "rb") as f:
                return read_png(f.read())
        except Unsupported as second:
            raise ImgError("%s: %s (also after sips conversion: %s)" % (path, first, second))


def png_size(path):
    try:
        with open(path, "rb") as f:
            head = f.read(33)
    except OSError:
        return None
    if head[:8] == PNG_SIG and head[12:16] == b"IHDR":
        return struct.unpack(">II", head[16:24])
    return None


# ---------------------------------------------------------------------------------------------
# PNG writing


def write_png(path, w, h, rows_rgb):
    def chunk(typ, body):
        c = struct.pack(">I", len(body)) + typ + body
        return c + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + r for r in rows_rgb)
    png = (PNG_SIG + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def heat_color(v):
    t = math.sqrt(v / 255.0)
    if t < 0.5:
        return (int(255 * t * 2), 0, 0)
    return (255, int(255 * (t - 0.5) * 2), 0)


def write_map(path, tw, th, tmax, scale=8):
    pal = [bytes(heat_color(v)) * scale for v in range(256)]
    rows = []
    for ty in range(th):
        line = b"".join(pal[tmax[ty][tx]] for tx in range(tw))
        rows.extend([line] * scale)
    write_png(path, tw * scale, th * scale, rows)


# ---------------------------------------------------------------------------------------------
# Comparison


def compare(rows_a, rows_b, w, h, tile, ignore_alpha):
    """Returns (sum_abs, sum_sq, channels, tile_max[ty][tx])."""
    L = 4 * w
    half = L // 2
    M = int.from_bytes(b"\xff\x00" * half, "little")    # even byte of each 16-bit lane
    H = int.from_bytes(b"\x00\x01" * half, "little")    # 256 per lane
    ONE = int.from_bytes(b"\x01\x00" * half, "little")  # 1 per lane
    chan = b"\xff\xff\xff\x00" if ignore_alpha else b"\xff\xff\xff\xff"
    CH = int.from_bytes(chan * w, "little")
    lo = bytes((d * d) & 255 for d in range(256))
    hi = bytes((d * d) >> 8 for d in range(256))

    tiles_x = (w + tile - 1) // tile
    tiles_y = (h + tile - 1) // tile
    tmax = [[0] * tiles_x for _ in range(tiles_y)]
    spans = [(tx * tile * 4, min(w, (tx + 1) * tile) * 4) for tx in range(tiles_x)]
    sum_abs = 0
    sum_sq = 0
    from_bytes = int.from_bytes
    for y in range(h):
        ra = rows_a[y]
        rb = rows_b[y]
        if ra == rb:
            continue
        A = from_bytes(ra, "little")
        B = from_bytes(rb, "little")
        # |a - b| per byte: d1 = 256 + a - b, d2 = 256 + b - a on 16-bit lanes (no borrows).
        ae = A & M
        be = B & M
        d1 = (ae | H) - be
        d2 = (be | H) - ae
        mk = ((d1 >> 8) & ONE) * 255
        even = (d1 & mk) | (d2 & (M ^ mk))
        ao = (A >> 8) & M
        bo = (B >> 8) & M
        d1 = (ao | H) - bo
        d2 = (bo | H) - ao
        mk = ((d1 >> 8) & ONE) * 255
        odd = (d1 & mk) | (d2 & (M ^ mk))
        diff = (((even | (odd << 8)) & CH)).to_bytes(L, "little")
        sum_abs += sum(diff)
        sum_sq += sum(diff.translate(lo)) + 256 * sum(diff.translate(hi))
        row_max = tmax[y // tile]
        for tx, (s, e) in enumerate(spans):
            m = max(diff[s:e])
            if m > row_max[tx]:
                row_max[tx] = m
    return sum_abs, sum_sq, (3 if ignore_alpha else 4), tmax


def parse_crop(text):
    try:
        x, y, cw, ch = (int(v) for v in text.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError("--crop expects x,y,w,h (integers)")
    if x < 0 or y < 0 or cw <= 0 or ch <= 0:
        raise argparse.ArgumentTypeError("--crop needs x,y >= 0 and w,h > 0")
    return x, y, cw, ch


def main():
    ap = argparse.ArgumentParser(description="Compare two screenshots (PSNR and per-tile max error).")
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--psnr-min", type=float, default=35.0, help="minimum PSNR in dB (35)")
    ap.add_argument("--tile", type=int, default=32, help="tile size in pixels (32)")
    ap.add_argument("--tile-max", type=int, default=64,
                    help="largest allowed per-tile max channel error (64)")
    ap.add_argument("--map", metavar="OUT.png", help="write the per-tile error heat map")
    ap.add_argument("--crop", type=parse_crop, metavar="x,y,w,h", help="compare only this region")
    ap.add_argument("--ignore-alpha", action=argparse.BooleanOptionalAction, default=True,
                    help="ignore the alpha channel (default; --no-ignore-alpha to include it)")
    ap.add_argument("--resize", action="store_true",
                    help="scale B to A's size with sips if the sizes differ")
    args = ap.parse_args()
    if args.tile < 1:
        ap.error("--tile must be >= 1")

    try:
        with tempfile.TemporaryDirectory(prefix="imgdiff_") as tmp:
            wa, ha, rows_a = load_image(args.a, tmp, "a")
            b_path = args.b
            sb = png_size(b_path)
            if args.resize and sb is not None and sb != (wa, ha):
                scaled = os.path.join(tmp, "scaled_b.png")
                _sips(["-s", "format", "png", "-z", str(ha), str(wa), b_path, "--out", scaled])
                b_path = scaled
            wb, hb, rows_b = load_image(b_path, tmp, "b")
            if (wb, hb) != (wa, ha):
                if args.resize:
                    scaled = os.path.join(tmp, "scaled_b2.png")
                    _sips(["-s", "format", "png", "-z", str(ha), str(wa), args.b, "--out", scaled])
                    wb, hb, rows_b = load_image(scaled, tmp, "b2")
                if (wb, hb) != (wa, ha):
                    raise ImgError("size mismatch: A is %dx%d, B is %dx%d (use --resize)"
                                   % (wa, ha, wb, hb))
            w, h = wa, ha
            if args.crop:
                cx, cy, cw, ch = args.crop
                if cx + cw > w or cy + ch > h:
                    raise ImgError("--crop %d,%d,%d,%d exceeds the image (%dx%d)"
                                   % (cx, cy, cw, ch, w, h))
                rows_a = [r[cx * 4:(cx + cw) * 4] for r in rows_a[cy:cy + ch]]
                rows_b = [r[cx * 4:(cx + cw) * 4] for r in rows_b[cy:cy + ch]]
                w, h = cw, ch

            sum_abs, sum_sq, nch, tmax = compare(rows_a, rows_b, w, h, args.tile, args.ignore_alpha)
            if args.map:
                write_map(args.map, len(tmax[0]), len(tmax), tmax)
    except ImgError as e:
        print("imgdiff: %s" % e, file=sys.stderr)
        return 2
    except OSError as e:
        print("imgdiff: %s" % e, file=sys.stderr)
        return 2

    count = w * h * nch
    mae = sum_abs / count
    mse = sum_sq / count
    psnr = math.inf if sum_sq == 0 else 10.0 * math.log10(255.0 * 255.0 / mse)
    tiles = [(m, tx, ty) for ty, row in enumerate(tmax) for tx, m in enumerate(row)]
    ntiles = len(tiles)
    over = sum(1 for m, _, _ in tiles if m > args.tile_max)
    # Worst tile first; ties in raster order.
    tiles.sort(key=lambda t: (-t[0], t[2], t[1]))
    wm, wx, wy = tiles[0]
    ok = psnr >= args.psnr_min and over == 0
    psnr_s = "inf" if math.isinf(psnr) else "%.2f" % psnr
    print("%s psnr=%s dB mae=%.2f worst_tile=(%d,%d) max=%d tiles_over=%d/%d"
          % ("PASS" if ok else "FAIL", psnr_s, mae, wx, wy, wm, over, ntiles))
    for m, tx, ty in tiles[:10]:
        if m == 0:
            break
        print("  tile (%d,%d) at px (%d,%d): max=%d" % (tx, ty, tx * args.tile, ty * args.tile, m))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
