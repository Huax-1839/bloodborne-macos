# SPDX-License-Identifier: GPL-2.0-or-later
"""Summarise the TSV of BB_IMAGE_USAGE_LOG (P10.1 step 2, docs/metal/texture_compression_design.md).

    python3 -I macos/bench/image_usage.py <tsv> [--top N]

The Metal backend writes, per texture of the texture cache, the usages it was created with, the
views made of it (pixel format, swizzle, what differs from the base) and how often it was bound
(sampled, as a storage image the shader writes, as a render target, written by the upscaler's merge).
This script answers: how many images (and MiB) need MTLTextureUsageShaderWrite and which views
need MTLTextureUsagePixelFormatView, i.e. what a lossless-compression policy could drop.

The file holds `dead` lines (destroyed images) and `live` snapshots; the latest snapshot plus the
dead lines are used, deduplicated by image id (a dead line wins).
"""

import argparse
import sys
from collections import Counter, defaultdict

COLUMNS = [
    "state", "snap", "id", "created_s", "created_frame", "destroyed_s", "destroyed_frame",
    "mtl_format", "vk_format", "width", "height", "depth", "mips", "layers", "samples", "type",
    "ds", "block", "usage", "alloc_bytes", "views_total", "views_whole", "views", "storage_binds",
    "sampled_binds", "rt_binds", "upscaler_writes", "name",
]
MIB = 1 << 20


class Image:
    def __init__(self, fields):
        row = dict(zip(COLUMNS, fields))
        self.state = row["state"]
        self.snap = int(row["snap"])
        self.id = int(row["id"])
        self.fmt = row["mtl_format"]
        self.vk = row["vk_format"]
        self.w, self.h, self.d = int(row["width"]), int(row["height"]), int(row["depth"])
        self.mips, self.layers, self.samples = int(row["mips"]), int(row["layers"]), int(row["samples"])
        self.type = row["type"]
        self.ds = row["ds"]
        self.block = row["block"] == "1"
        self.usage = row["usage"]
        self.bytes = int(row["alloc_bytes"])
        self.views_total = int(row["views_total"])
        self.views_whole = int(row["views_whole"])
        self.storage_binds = int(row["storage_binds"])
        self.sampled_binds = int(row["sampled_binds"])
        self.rt_binds = int(row["rt_binds"])
        self.upscaler_writes = int(row["upscaler_writes"])
        self.name = row["name"]
        # (view format, swizzle, flags, count)
        self.views = []
        if row["views"] != "-":
            for entry in row["views"].split(";"):
                fmt, swizzle, flags, count = entry.split("|")
                self.views.append((fmt, swizzle, "" if flags == "-" else flags, int(count)))

    @property
    def mib(self):
        return self.bytes / MIB

    @property
    def needs_write(self):
        return self.storage_binds > 0 or self.upscaler_writes > 0

    def view_kinds(self):
        """The kinds of views the image has, from {format, srgb, swizzle, stencil, range}."""
        kinds = set()
        for _, _, flags, _ in self.views:
            if "F" in flags:
                kinds.add("format")
            if "S" in flags and "F" not in flags:
                kinds.add("srgb")
            if "X" in flags:
                kinds.add("stencil")
            if "W" in flags and not set(flags) & {"F", "S", "X"}:
                kinds.add("swizzle")
            elif flags and not set(flags) - {"R", "T"}:
                kinds.add("range")
        return kinds

    def size_text(self):
        text = f"{self.w}x{self.h}"
        if self.d > 1:
            text += f"x{self.d}"
        if self.layers > 1:
            text += f"[{self.layers}]"
        if self.mips > 1:
            text += f" m{self.mips}"
        if self.samples > 1:
            text += f" s{self.samples}"
        return text


def load(path):
    live, dead, bad = {}, {}, 0
    latest = -1
    rows = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle):
            line = line.rstrip("\n")
            if number == 0 and line.startswith("state\t"):
                continue
            if not line:
                continue
            fields = line.split("\t", len(COLUMNS) - 1)
            if len(fields) < len(COLUMNS) - 1:  # a cut last line of a killed run
                bad += 1
                continue
            if len(fields) == len(COLUMNS) - 1:
                fields.append("")
            try:
                image = Image(fields)
            except ValueError:
                bad += 1
                continue
            rows.append(image)
            if image.state == "live":
                latest = max(latest, image.snap)
    for image in rows:
        if image.state == "dead":
            dead[image.id] = image
        elif image.snap == latest:
            live[image.id] = image
    images = dict(live)
    images.update(dead)  # a dead line wins over the snapshot that still had the image
    return list(images.values()), len(live), len(dead), latest, bad


def mib(images):
    return sum(i.bytes for i in images) / MIB


def line(label, images, total=None):
    share = f"  ({100.0 * mib(images) / total:5.1f}%)" if total else ""
    print(f"  {label:<46} {len(images):7d} images {mib(images):10.1f} MiB{share}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("tsv")
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()

    images, n_live, n_dead, snap, bad = load(args.tsv)
    if not images:
        print("no images in", args.tsv)
        return 1
    total = mib(images)
    print(f"{args.tsv}: {len(images)} images, {total:.1f} MiB "
          f"({n_live} live in snapshot {snap}, {n_dead} destroyed"
          + (f", {bad} unreadable lines skipped" if bad else "") + ")")

    print("\nBy use (exclusive: block, depth/stencil, rendered colour, the rest):")
    block = [i for i in images if i.block]
    depth = [i for i in images if not i.block and i.ds != "-"]
    colour = [i for i in images if not i.block and i.ds == "-" and i.rt_binds > 0]
    sampled = [i for i in images if not i.block and i.ds == "-" and i.rt_binds == 0]
    line("render target, colour (attached at least once)", colour, total)
    line("depth / stencil", depth, total)
    line("block compressed", block, total)
    line("sampled / storage only (never attached)", sampled, total)
    line("  of those never bound at all", [i for i in sampled if not i.sampled_binds
                                          and not i.storage_binds and not i.upscaler_writes])
    created_rt = [i for i in images if "T" in i.usage]
    line("created as render target, never attached", [i for i in created_rt if i.rt_binds == 0])

    print("\nShaderWrite (a storage binding the shader writes, or the upscaler's merge):")
    storage = [i for i in images if i.storage_binds > 0]
    upscaler = [i for i in images if i.upscaler_writes > 0]
    needs = [i for i in images if i.needs_write]
    line("bound as a written storage image", storage, total)
    line("written by the upscaler's merge", upscaler, total)
    line("needs ShaderWrite (either)", needs, total)
    line("created with ShaderWrite", [i for i in images if "W" in i.usage], total)
    line("created with ShaderWrite, never needed", [i for i in images
                                                    if "W" in i.usage and not i.needs_write], total)
    wrong = [i for i in needs if "W" not in i.usage]
    if wrong:
        line("NEEDS ShaderWrite but was created without (!)", wrong, total)
    for kind, group in (("colour", colour), ("depth", depth), ("block", block), ("sampled", sampled)):
        line(f"  needs ShaderWrite, {kind}", [i for i in group if i.needs_write])

    print("\nViews:")
    with_views = [i for i in images if i.views_total > 0]
    line("images with any view made", with_views, total)
    line("images with only whole-texture views or none", [i for i in images if not i.views], total)
    kinds = defaultdict(list)
    for image in images:
        for kind in image.view_kinds():
            kinds[kind].append(image)
    line("any view in another pixel format", kinds["format"], total)
    line("any view that is only the sRGB/linear twin", kinds["srgb"], total)
    line("any view with a swizzle (no format change)", kinds["swizzle"], total)
    line("any stencil view of a depth/stencil image", kinds["stencil"], total)
    line("any view with only a sub range / type change", kinds["range"], total)
    needs_view = [i for i in images if i.view_kinds() & {"format", "srgb", "stencil"}]
    needs_view_ids = {i.id for i in needs_view}
    line("needs PixelFormatView (format, sRGB or stencil view)", needs_view, total)
    line("created with PixelFormatView", [i for i in images if "V" in i.usage], total)
    line("created with PixelFormatView, never needed", [i for i in images
                                                        if "V" in i.usage and i.id not in needs_view_ids], total)
    needs_either = [i for i in images if i.needs_write or i.id in needs_view_ids]
    line("needs ShaderWrite or PixelFormatView", needs_either, total)
    either_ids = {i.id for i in needs_either}
    line("needs neither (could be created without both)", [i for i in images if i.id not in either_ids],
         total)

    def pairs(select):
        counts, sizes = Counter(), Counter()
        for image in images:
            seen = set()
            for fmt, _, flags, _ in image.views:
                if select(flags):
                    seen.add((image.fmt, fmt))
            for pair in seen:
                counts[pair] += 1
                sizes[pair] += image.bytes
        return counts, sizes

    for title, select in (("base -> view format pairs (other format)",
                           lambda f: "F" in f),
                          ("base -> view format pairs (sRGB twin only)",
                           lambda f: "S" in f and "F" not in f)):
        counts, sizes = pairs(select)
        if counts:
            print(f"\n{title}:")
            for pair, count in sorted(counts.items(), key=lambda kv: -sizes[kv[0]]):
                print(f"  {pair[0]:<24} -> {pair[1]:<24} {count:7d} images {sizes[pair] / MIB:10.1f} MiB")

    swizzles = Counter()
    swizzle_sizes = Counter()
    for image in images:
        seen = {sw for _, sw, flags, _ in image.views
                if "W" in flags and not set(flags) & {"F", "S", "X"}}
        for sw in seen:
            swizzles[sw] += 1
            swizzle_sizes[sw] += image.bytes
    if swizzles:
        print("\nswizzle views (no format change):")
        for sw, count in sorted(swizzles.items(), key=lambda kv: -swizzle_sizes[kv[0]]):
            print(f"  {sw:<8} {count:7d} images {swizzle_sizes[sw] / MIB:10.1f} MiB")

    print(f"\nThe {args.top} largest images that need ShaderWrite or a non-trivial view:")
    interesting = [i for i in images if i.needs_write or i.view_kinds()]
    interesting.sort(key=lambda i: -i.bytes)
    for image in interesting[:args.top]:
        why = []
        if image.storage_binds:
            why.append(f"storage x{image.storage_binds}")
        if image.upscaler_writes:
            why.append(f"upscaler x{image.upscaler_writes}")
        for fmt, swizzle, flags, count in image.views:
            if flags:
                why.append(f"view {fmt}{'' if swizzle == '-' else ' ' + swizzle} [{flags}] x{count}")
        print(f"  #{image.id:<7} {image.mib:8.1f} MiB {image.fmt:<22} {image.size_text():<24} "
              f"{image.usage:<5} {image.state:<4} {'; '.join(why)}")
        if image.name:
            print(f"           {image.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
