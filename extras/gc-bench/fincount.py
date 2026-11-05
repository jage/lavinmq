import sys,re
r=sys.argv[1]
d=open(f"{r}/driver.log").read()
t0=int(re.search(r"measure_start (\d+)",d).group(1)); t1=int(re.search(r"measure_end (\d+)",d).group(1))
rec=int(re.search(r"reconnects (\d+)",d).group(1))
rows=[]
for l in open(f"{r}/gc.pauses.finalizers"):
    p=l.split(); rows.append((int(p[0]),dict(x.rsplit("=",1) for x in p[1:])))
a=min(rows,key=lambda x:abs(x[0]-t0)); b=min(rows,key=lambda x:abs(x[0]-t1))
secs=(b[0]-a[0])/1e9
print(r.split("/")[-1], "reconnects", rec, f"over {(t1-t0)/1e9:.0f}s; counts over {secs:.0f}s")
a,b=a[1],b[1]
for k in sorted(b,key=lambda k:-(int(b[k])-int(a.get(k,0)))):
    n=int(b[k])-int(a.get(k,0))
    if n: print(f"  {n:7}  {n/secs:7.1f}/s  {k}")
