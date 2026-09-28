#!/usr/bin/env python3
"""R10 analysis: per-job stats from samples/mem/latency + container logs."""
import csv, re, glob, os, statistics as st
from datetime import datetime, timezone
E='/opt/infra-wt/r10/evidence'
def p(ts): return datetime.fromisoformat(ts[:-2]+':'+ts[-2:]) if re.search(r'[+-]\d{4}$',ts) else datetime.fromisoformat(ts)
jobs=[]
for f in sorted(glob.glob(E+'/jobs/*.log'), key=os.path.getmtime):
    cid=os.path.basename(f)[:12]; name=start=end=res=None; errs=set()
    for line in open(f, errors='replace'):
        m=re.search(r'Z: Running job: (.*)$',line)
        if m and 'WRITE LINE' not in line: name=m.group(1).strip(); start=line[:19]
        m=re.search(r'Z: Job (.*) completed with result: (\w+)',line)
        if m and 'WRITE LINE' not in line: res=m.group(2); end=line[:19]
        for k,rx in [('ENOSPC',r'No space left|ENOSPC'),('OOM',r'OutOfMemoryError|oom-kill|Killed process|exit code 137'),('DNS',r'Temporary failure in name resolution|Could not resolve host|EAI_AGAIN|getaddrinfo'),('NET',r'Connection timed out|ETIMEDOUT|Connection refused|ECONNRESET')]:
            if re.search(rx,line): errs.add(k)
    jobs.append(dict(cid=cid,name=name,start=start,end=end,res=res,errs=errs))
S=list(csv.DictReader(open(E+'/samples.csv'))); M=list(csv.DictReader(open(E+'/mem.csv')))
def num(x):
    try: return float(x)
    except: return None
for j in jobs:
    ss=[r for r in S if r['cid']==j['cid']]; ms=[r for r in M if r['cid']==j['cid']]
    j['peak']=max([num(r['mem_peak']) or 0 for r in ss] or [0])
    j['anon']=max([num(r['anon']) or 0 for r in ms] or [0])
    j['oom']=max([num(r['oom_kill']) or 0 for r in ss] or [0])
    j['pids']=max([num(r['pids']) or 0 for r in ss] or [0])
    su=[num(r['srvci_used_kb']) for r in ss if num(r['srvci_used_kb'])]
    j['disk']=(min(su)/1048576, max(su)/1048576) if su else (0,0)
    j['load']=max([num(r['load1']) or 0 for r in ss] or [0])
    j['iow']=max([num(r['iowait']) or 0 for r in ss] or [0])
print('| cid | job | start-end UTC | result | peak mem (cgroup, incl cache) | peak anon | oom_kill | max pids | /srv/ci used GiB min→max | max load1 | max iowait | log errors |')
for j in jobs:
    print(f"| {j['cid']} | {j['name']} | {(j['start'] or '')[11:]}–{(j['end'] or '')[11:]} | {j['res']} | {j['peak']/2**30:.2f} GiB | {j['anon']/2**30:.2f} GiB | {int(j['oom'])} | {int(j['pids'])} | {j['disk'][0]:.1f}→{j['disk'][1]:.1f} | {j['load']:.1f} | {j['iow']:.0f} | {','.join(sorted(j['errs'])) or '-'} |")
# latency: busy = sample ts inside any job window (UTC), idle otherwise
win=[(datetime.fromisoformat(j['start']+'+00:00'),datetime.fromisoformat(j['end']+'+00:00')) for j in jobs if j['start'] and j['end']]
L=list(csv.DictReader(open(E+'/latency.csv')))
def pct(a,q):
    a=sorted(a); return a[min(len(a)-1,int(round(q*(len(a)-1))))] if a else float('nan')
print('\n| target | idle n | idle p50 | idle p95 | busy n | busy p50 | busy p95 | p95 ratio | non-2xx/3xx busy |')
for t in ['kas','erp','cp']:
    idle=[];busy=[];bad=0
    for r in L:
        if r['target']!=t: continue
        ts=p(r['ts']).astimezone(timezone.utc); v=num(r['time_total'])
        if v is None: continue
        b=any(a<=ts<=z for a,z in win)
        (busy if b else idle).append(v)
        if b and not r['code'].startswith(('2','3')): bad+=1
    print(f"| {t} | {len(idle)} | {pct(idle,.5):.3f} | {pct(idle,.95):.3f} | {len(busy)} | {pct(busy,.5):.3f} | {pct(busy,.95):.3f} | {pct(busy,.95)/pct(idle,.95):.2f}x | {bad} |")
# host
sw=[num(r['swap_used_kb']) for r in S if num(r['swap_used_kb'])]
av=[num(r['avail_host_kb']) for r in M if num(r['avail_host_kb'])]
print(f"\nswap used KiB min/max: {min(sw):.0f}/{max(sw):.0f}; host MemAvailable min: {min(av)/1024:.0f} MiB; drops first/last: {S[0]['drops']}/{S[-1]['drops']}")
