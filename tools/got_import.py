"""Diagnostic: name the import bound to a GOT slot (guest offsets) in the prepared boot.bin
(macos/out/game/boot.bin, or BOOT_BIN=<path> for another data directory)."""
import os, re, struct, sys
from pathlib import Path
here = Path(__file__).resolve().parent.parent  # repository root
data = Path(os.environ.get('BOOT_BIN', here / 'macos/out/game/boot.bin')).read_bytes()
size, entry, ns, nr, ni, caps = struct.unpack_from('<QQQQQQ', data, 8)
pos = 56 + ns * 24
names = [data[pos + i * 128:pos + (i + 1) * 128].split(b'\0')[0].decode() for i in range(ni)]
pos += ni * 128
symbols = dict(re.findall(r'\{"([^"]+)","([^"]+)"\}', (here / 'src/import_names.inc').read_text()))
slots = {}
for i in range(nr):
    target, kind, value, addend = struct.unpack_from('<QQqq', data, pos + i * 32)
    if kind:
        slots[target] = names[value]
for arg in sys.argv[1:]:
    nid = slots.get(int(arg, 16))
    print(arg, nid, symbols.get(nid) if nid else '')
