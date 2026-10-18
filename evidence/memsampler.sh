#!/bin/bash
# anon/file breakdown for job container + docker stats mem (excl. inactive file) every 15s
E=/opt/infra-wt/r10/evidence
echo "ts,cid,anon,file,shmem,docker_mem,avail_host_kb" >> $E/mem.csv
while true; do
  cid=$(docker inspect -f '{{.Id}}' ci-runner-job 2>/dev/null)
  if [ -n "$cid" ]; then cg=/sys/fs/cgroup/system.slice/docker-$cid.scope
    read an fl sh < <(awk '$1=="anon"{a=$2}$1=="file"{f=$2}$1=="shmem"{s=$2}END{print a,f,s}' $cg/memory.stat 2>/dev/null)
    dm=$(docker stats --no-stream --format '{{.MemUsage}}' ci-runner-job 2>/dev/null | cut -d/ -f1 | tr -d ' ')
  else an=;fl=;sh=;dm=; fi
  av=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  echo "$(date +%FT%T%z),${cid:0:12},$an,$fl,$sh,$dm,$av" >> $E/mem.csv
  sleep 13
done
