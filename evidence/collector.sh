#!/bin/bash
# R10 host-side collector (read-only). Samples every 30s.
E=/opt/infra-wt/r10/evidence
scrub() { sed -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{10,}/\1***REDACTED***/g; s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/***JWT-REDACTED***/g; s/((Bearer|Basic|token|Token|TOKEN|password|PASSWORD|secret|SECRET)[" :=]+)[A-Za-z0-9+\/_.=-]{12,}/\1***REDACTED***/g'; }
URLS="kas=https://drms-kas.bimacreative.tech/api/v1/health erp=https://demo.erp.bimacreative.tech/web/login cp=https://cp.bimacreative.tech/"
echo "ts,cid,mem_cur,mem_peak,oom,oom_kill,pids,cpu_pct,srvci_used_kb,root_used_kb,load1,swap_used_kb,iowait,drops" >> $E/samples.csv
echo "ts,target,code,time_total" >> $E/latency.csv
while true; do
  ts=$(date +%FT%T%z)
  cid=$(docker inspect -f '{{.Id}}' ci-runner-job 2>/dev/null)
  mc=; mp=; oom=; ok=; pids=; cpu=
  if [ -n "$cid" ]; then
    cg=/sys/fs/cgroup/system.slice/docker-$cid.scope
    mc=$(cat $cg/memory.current 2>/dev/null); mp=$(cat $cg/memory.peak 2>/dev/null)
    oom=$(awk '$1=="oom"{print $2}' $cg/memory.events 2>/dev/null); ok=$(awk '$1=="oom_kill"{print $2}' $cg/memory.events 2>/dev/null)
    pids=$(cat $cg/pids.current 2>/dev/null)
    cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' ci-runner-job 2>/dev/null)
    s=${cid:0:12}
    [ -f $E/jobs/$s.meta ] || docker inspect -f 'id={{.Id}} started={{.State.StartedAt}} runtime={{.HostConfig.Runtime}} mem={{.HostConfig.Memory}} cpus={{.HostConfig.NanoCpus}} pids={{.HostConfig.PidsLimit}}' ci-runner-job > $E/jobs/$s.meta
    echo "$ts peak=$mp oom=$oom oom_kill=$ok" > $E/jobs/$s.cgroup-last
    cp $cg/memory.events $E/jobs/$s.memory.events 2>/dev/null
  fi
  su=$(df -k --output=used /srv/ci | tail -1 | tr -d ' '); ru=$(df -k --output=used / | tail -1 | tr -d ' ')
  l1=$(cut -d' ' -f1 /proc/loadavg); sw=$(free -k | awk '/Swap/{print $3}')
  wa=$(vmstat 1 2 | tail -1 | awk '{print $16}')
  dr=$(iptables -L CI-RUNNER-EGRESS -nv -x | awk '$3=="DROP"{s+=$1} END{print s}')
  echo "$ts,${cid:0:12},$mc,$mp,$oom,$ok,$pids,$cpu,$su,$ru,$l1,$sw,$wa,$dr" >> $E/samples.csv
  for u in $URLS; do n=${u%%=*}; url=${u#*=}
    r=$(curl -s -o /dev/null -m 20 -w '%{http_code},%{time_total}' "$url"); echo "$ts,$n,$r" >> $E/latency.csv; done
  sleep 28
done
