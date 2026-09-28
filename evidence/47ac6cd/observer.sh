#!/bin/bash
# Plan 12 R12 observer (host-only): per job container -> scrubbed docker logs, anon/file samples (5 s),
# memory.peak + memory.events at end, inspect meta. No GitHub credentials used.
E=/opt/infra-wt/r12b/evidence/47ac6cd; last=
scrub='s/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{10,}/\1***REDACTED***/g; s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/***JWT-REDACTED***/g; s/((Bearer|Basic|token|Token|TOKEN|password|PASSWORD|secret|SECRET)[" :=]+)[A-Za-z0-9+\/_.=-]{12,}/\1***REDACTED***/g'
sample() { # $1 cid
  local cid=$1 s=${1:0:12} cg=/sys/fs/cgroup/system.slice/docker-$1.scope maxa=0
  docker inspect $cid > $E/jobs/$s.inspect.json 2>/dev/null
  echo "ts,anon,file,current,avail_host_kb" > $E/jobs/$s.mem.csv
  while [ -d $cg ]; do
    read an fi < <(awk '$1=="anon"{a=$2}$1=="file"{f=$2}END{print a,f}' $cg/memory.stat 2>/dev/null)
    cu=$(cat $cg/memory.current 2>/dev/null)
    [ -n "$an" ] && [ "$an" -gt "$maxa" ] && maxa=$an
    echo "$(date +%FT%T%z),$an,$fi,$cu,$(awk '/MemAvailable/{print $2}' /proc/meminfo)" >> $E/jobs/$s.mem.csv
    cat $cg/memory.peak > $E/jobs/$s.peak 2>/dev/null; cat $cg/memory.events > $E/jobs/$s.memory.events 2>/dev/null
    echo $maxa > $E/jobs/$s.peak_anon
    sleep 5
  done
  echo "$(date +%FT%T%z) cgroup gone $s peak_anon=$maxa peak_total=$(cat $E/jobs/$s.peak 2>/dev/null) events=$(tr '\n' ' ' < $E/jobs/$s.memory.events 2>/dev/null)" >> $E/containers.log
  docker inspect -f '{{.State.ExitCode}} {{.State.StartedAt}} {{.State.FinishedAt}}' $cid >> $E/jobs/$s.exit 2>&1
}
while true; do
  cid=$(docker inspect -f '{{.Id}}' ci-runner-job 2>/dev/null)
  if [ -n "$cid" ] && [ "$cid" != "$last" ]; then
    last=$cid; s=${cid:0:12}; echo "$(date +%FT%T%z) new container $s" >> $E/containers.log
    ( docker logs -f -t $cid 2>&1 | sed -u -E "$scrub" > $E/jobs/$s.log; echo "$(date +%FT%T%z) logs ended $s" >> $E/containers.log ) &
    sample $cid &
  fi
  sleep 3
done
