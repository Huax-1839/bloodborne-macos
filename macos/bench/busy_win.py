# SPDX-License-Identifier: GPL-2.0-or-later
# busy_win.py gpu.xml: GPU busy union per 500 ms window, and per channel sums.
import sys, xml.etree.ElementTree as ET, collections
root = ET.parse(sys.argv[1]).getroot(); ids = {}
def val(e):
    if 'ref' in e.attrib: return ids[e.attrib['ref']]
    if 'id' in e.attrib: ids[e.attrib['id']] = e
    for c in e: val(c)
    return e
cols = [c.find('mnemonic').text for c in root.iter('col')]
spans=[]
for row in root.iter('row'):
    d = dict(zip(cols, [val(c) for c in row]))
    if 'bb-probe' not in d['process'].attrib.get('fmt', ''): continue
    if d['event-depth'].attrib.get('fmt') != '0': continue
    st=int(d['start'].text); du=int(d['duration'].text)
    spans.append((st,st+du,d['channel-name'].attrib.get('fmt')))
spans.sort(); t0=spans[0][0]; W=500_000_000
win=collections.defaultdict(lambda:[0,0,collections.Counter()]); end=0
for s,e,ch in spans:
    w=(s-t0)//W
    win[w][2][ch]+=e-s
    if e>end:
        win[w][0]+=e-max(s,end); end=e
for w in sorted(win):
    b,_,c=win[w]
    print(f"{w*0.5:5.1f}s busy {b/W*100:5.1f}%  "+"  ".join(f"{k} {v/1e6:6.1f}ms" for k,v in c.most_common()))
