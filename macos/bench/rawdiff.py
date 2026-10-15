# SPDX-License-Identifier: GPL-2.0-or-later
# rawdiff.py A.raw B.raw WIDTH HEIGHT: PSNR and per-tile (32 px) max error of two raw 4-byte-per-pixel
# display buffer dumps (BB_PRESENT_DUMP_TRIGGER); swap R/B of a BGRA dump first when the other is RGBA.
import sys, math
def load(p):
    d=open(p,'rb').read(); return d
a=load(sys.argv[1]); b=load(sys.argv[2]); w=int(sys.argv[3]); h=int(sys.argv[4])
assert len(a)==len(b)==w*h*4, (len(a),len(b))
# RGB only
import array
se=0; mx=0; n=0
tile=32; tmax={}
for y in range(h):
    row=y*w*4
    for x in range(w):
        i=row+x*4
        for c in range(3):
            d=abs(a[i+c]-b[i+c]); se+=d*d
            if d>mx: mx=d
            k=(x//tile,y//tile)
            if d>tmax.get(k,0): tmax[k]=d
n=w*h*3
psnr=10*math.log10(255*255/(se/n)) if se else 99
over=sum(1 for v in tmax.values() if v>64)
print(f"psnr={psnr:.2f} dB max={mx} tiles_over64={over}/{len(tmax)}")
print(sorted(tmax.items(), key=lambda kv:-kv[1])[:6])
