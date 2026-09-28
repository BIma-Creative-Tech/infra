#!/bin/bash
E=/opt/infra-wt/r10/evidence; declare -A seen; cl=0
while true; do
  n=$(wc -l < $E/containers.log); if [ $n -gt $cl ]; then sed -n "$((cl+1)),${n}p" $E/containers.log; cl=$n; fi
  for f in $E/jobs/*.log; do k=$(basename $f); c=$(wc -l < $f); p=${seen[$k]:-0}
    if [ $c -gt $p ]; then sed -n "$((p+1)),${c}p" $f | grep -v JobServerQueue | grep -E "Running job:|completed with result|No space left|ENOSPC|OutOfMemory|oom-kill|Killed process|exit code 137" | sed "s/^/$k: /" | cut -c1-220; seen[$k]=$c; fi
  done
  o=$(tail -1 $E/samples.csv | cut -d, -f2,6); if [ "$o" != "$lo" ]; then case "$o" in *,0|*,|*,oom_kill) ;; *) echo "OOM_KILL $o";; esac; lo=$o; fi
  sleep 15
done
