# SPDX-License-Identifier: GPL-2.0-or-later
# kids.py sample.txt thread-substr frame-substr [depth]: children of a frame within one thread.
import sys,re,collections
txt=open(sys.argv[1]).read()
sec=txt.split('Call graph:')[1].split('Total number in stack')[0]
blocks=re.split(r'\n(?=    \d+ Thread_)',sec)
for b in blocks:
    lines=b.split('\n')
    if sys.argv[2] not in lines[0]: continue
    ents=[]
    for l in lines[1:]:
        m=re.match(r'^([ +!:|]*?)(\d+) (.*)$',l)
        if m: ents.append((len(m.group(1)),int(m.group(2)),re.sub(r'\s+\(in .*?\)','',m.group(3))))
    agg=collections.Counter()
    for i,(d,c,n) in enumerate(ents):
        if sys.argv[3] in n:
            for d2,c2,n2 in ents[i+1:]:
                if d2<=d: break
                if d2==d+2: agg[n2[:150]]+=c2
            print('==',lines[0].strip()[:60],'|',n[:100],c)
    for k,v in agg.most_common(int(sys.argv[4]) if len(sys.argv)>4 else 12): print('  ',v,k)
