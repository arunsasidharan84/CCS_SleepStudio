import sys, numpy as np
def read(f):
    b=open(f,'rb').read(); ns=int(b[252:256]); nrec=int(b[236:244]); hb=int(b[184:192])
    H=b[256:256+ns*256]
    spr=[int(H[ns*216+i*8:ns*216+(i+1)*8]) for i in range(ns)]
    lab=[H[i*16:(i+1)*16].decode().strip() for i in range(ns)]
    d=np.frombuffer(b[hb:hb+nrec*sum(spr)*2],dtype='<i2').reshape(nrec,sum(spr))
    out=[];o=0
    for s in spr: out.append(d[:,o:o+s].reshape(-1)); o+=s
    return lab,out
la,a=read(sys.argv[1]); lb,b=read(sys.argv[2])
tot=0; bad=0
for i,(x,y) in enumerate(zip(a,b)):
    n=min(len(x),len(y)); diff=np.nonzero(x[:n]!=y[:n])[0]; tot+=n; bad+=len(diff)
    if len(x)!=len(y) or len(diff): print(f'  {la[i]:16s} len {len(x)} vs {len(y)}; {len(diff)} differ; first {diff[:5]} maxabs {np.abs(x[:n].astype(int)-y[:n]).max()}')
print(f'{sys.argv[2]}: {len(a)} traces, {tot} samples, {bad} differing')
