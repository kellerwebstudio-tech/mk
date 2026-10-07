import sys, os, collections
import numpy as np
from PIL import Image, ImageDraw

def load_obj(path):
    V=[]; VT=[]; VN=[]; F=[]  # faces as list of (vi, vti, vni) tuples
    for line in open(path, encoding='utf-8', errors='ignore'):
        if line.startswith('v '):
            V.append([float(x) for x in line.split()[1:4]])
        elif line.startswith('vt '):
            VT.append([float(x) for x in line.split()[1:3]])
        elif line.startswith('vn '):
            VN.append([float(x) for x in line.split()[1:4]])
        elif line.startswith('f '):
            face=[]
            for tok in line.split()[1:]:
                parts=tok.split('/')
                vi=int(parts[0]); vti=int(parts[1]) if len(parts)>1 and parts[1] else 0; vni=int(parts[2]) if len(parts)>2 and parts[2] else 0
                face.append((vi-1, vti-1, vni-1))
            F.append(face)
    return np.array(V), np.array(VT), np.array(VN), F

def components(nv, F):
    parent=list(range(nv))
    def find(a):
        while parent[a]!=a:
            parent[a]=parent[parent[a]]; a=parent[a]
        return a
    def union(a,b):
        ra,rb=find(a),find(b)
        if ra!=rb: parent[ra]=rb
    for face in F:
        for k in range(1,len(face)): union(face[0][0], face[k][0])
    comp=collections.defaultdict(list)
    for i in range(nv): comp[find(i)].append(i)
    return list(comp.values())

def render(V, F, path, axis_pairs, size=700):
    # axis_pairs: list of (name, xi, yi, flipx) for orthographic views; painter's algorithm by remaining axis
    n=len(axis_pairs)
    img=Image.new('RGB',(size*n, size),(240,240,240)); d=ImageDraw.Draw(img)
    mn=V.min(0); mx=V.max(0); ext=(mx-mn).max()
    for k,(name,xi,yi,zi,flipx) in enumerate(axis_pairs):
        ox=k*size
        pts=[]
        for face in F:
            idx=[f[0] for f in face]
            P=V[idx]
            depth=P[:,zi].mean()
            poly=[]
            for p in P:
                x=(p[xi]-mn[xi])/ext; y=(p[yi]-mn[yi])/ext
                if flipx: x=1-x
                poly.append((ox+40+x*(size-80), size-40-y*(size-80)))
            pts.append((depth, poly, P))
        pts.sort(key=lambda t: t[0])
        for depth,poly,P in pts:
            # shade by face normal z-ish
            n0=np.cross(P[1]-P[0], P[2]-P[0]); nl=np.linalg.norm(n0)
            shade=0.5 if nl==0 else 0.35+0.65*abs(n0[zi]/nl)
            c=int(60+150*shade)
            d.polygon(poly, fill=(c, int(c*0.9), int(c*0.8)), outline=None)
        d.text((ox+10,10), name, fill=(0,0,0))
        d.line([(ox+40, size-40),(ox+size-40, size-40)], fill=(200,0,0)); d.text((ox+size-60, size-36), f"+{'xyz'[xi]}" if not flipx else f"-{'xyz'[xi]}", fill=(200,0,0))
        d.line([(ox+40, size-40),(ox+40, 40)], fill=(0,0,200)); d.text((ox+44, 44), f"+{'xyz'[yi]}", fill=(0,0,200))
    img.save(path)

if __name__ == '__main__':
  for path in sys.argv[1:]:
      V,VT,VN,F=load_obj(path)
      name=path.split('/')[1] if path.startswith('meshes/') else os.path.basename(os.path.dirname(os.path.dirname(path)))
      tri=sum(1 for f in F if len(f)==3); quad=sum(1 for f in F if len(f)==4); other=len(F)-tri-quad
      mn=V.min(0); mx=V.max(0); size=mx-mn
      print(f"== {name}: verts {len(V)} faces {len(F)} (tri {tri}, quad {quad}, ngon {other}) -> ~{tri+2*quad+3*other} triangles")
      print(f"   bbox min {np.round(mn,3)} max {np.round(mx,3)} size {np.round(size,3)} centre {np.round((mn+mx)/2,3)}")
      comps=components(len(V), F)
      comps.sort(key=len, reverse=True)
      print(f"   connected components: {len(comps)}")
      for c in comps[:12]:
          P=V[c]; cmn=P.min(0); cmx=P.max(0)
          print(f"     n={len(c):5d} size {np.round(cmx-cmn,3)} centre {np.round((cmn+cmx)/2,3)}")
      out=os.path.join('/tmp/claude-0/-home-user-mk/3419e611-d3a8-57fd-a159-26d72f1bea4b/scratchpad/meshes', f'{name}_views.png')
      render(V,F,out,[('side (x right, y up)',0,1,2,False),('top (x right, z up)',0,2,1,False),('front (z right, y up)',2,1,0,False)])
      print("   rendered", out)
