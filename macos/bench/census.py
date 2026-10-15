# SPDX-License-Identifier: GPL-2.0-or-later
# census.py <census.txt> [frame]: symbolizes the end backtraces and prints one frame's passes.
import sys, re, subprocess, collections
lines = open(sys.argv[1]).read().splitlines()
import os
lib = os.environ.get('BB_GPU_LIB', os.path.join(os.path.dirname(os.path.abspath(__file__)), '../out/gpu/libbbgpu.dylib'))
offs = sorted({o for l in lines for o in re.findall(r'libbbgpu\.dylib\+(0x[0-9a-f]+)', l)})
out = subprocess.run(['atos', '-o', lib, '-arch', 'x86_64', '-l', '0x0'] + offs, capture_output=True, text=True).stdout.splitlines()
def short(s):
    s = re.sub(r'\(in libbbgpu.dylib\) ', '', s)
    s = re.sub(r'Vulkan::|AmdGpu::|VideoCore::|std::__1::', '', s)
    s = re.sub(r'\(.*\) \(', ' (', s)
    return s
sym = {o: short(s) for o, s in zip(offs, out)}
frame = sys.argv[2] if len(sys.argv) > 2 else lines[0].split()[0]
for l in lines:
    if not l.startswith(frame + ' '): continue
    head, _, end = l.partition(' end=')
    head = re.sub(r'^F\d+ S0x[0-9a-f]+ ', '', head)
    fr = [sym.get(o, o) for o in re.findall(r'libbbgpu\.dylib\+(0x[0-9a-f]+)', end)]
    # skip EndRendering itself and the census; show the next 3 callers
    fr = [f for f in fr if 'CensusPass' not in f and 'EndRendering' not in f]
    print(head, '|', ' < '.join(f.split(' (')[0] for f in fr[:3]))
