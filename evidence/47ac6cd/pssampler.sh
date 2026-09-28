#!/bin/bash
# Snapshot process tree of the job container cgroup every 60 s (host view; diagnoses hangs e.g. buildkit/Gradle).
E=/opt/infra-wt/r12b/evidence/47ac6cd
while true; do
  cid=$(docker inspect -f '{{.Id}}' ci-runner-job 2>/dev/null)
  if [ -n "$cid" ]; then cg=/sys/fs/cgroup/system.slice/docker-$cid.scope
    pids=$(find $cg -name cgroup.procs -exec cat {} + 2>/dev/null | sort -n | tr '\n' ',' | sed 's/,$//')
    n=$(echo "$pids" | tr ',' '\n' | grep -c .)
    if [ "$n" -gt 12 ]; then { echo "=== $(date +%FT%T%z) ${cid:0:12} procs=$n io=$(grep -h . $cg/io.stat 2>/dev/null | tr '\n' ' ')"; ps -o pid,ppid,stat,etimes,rss,pcpu,wchan:24,args -p "$pids" 2>/dev/null | cut -c1-220 | sed -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{10,}/\1***REDACTED***/g'; } >> $E/jobs/${cid:0:12}.ps.txt; fi
  fi
  sleep 60
done
