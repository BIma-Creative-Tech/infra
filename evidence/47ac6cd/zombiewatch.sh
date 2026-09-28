#!/bin/bash
# Logs (every 20 s) zombie children of sysbox-fs and any task in wchan zap_pid_ns_processes (nested pid-ns hang signature).
E=/opt/infra-wt/r12b/evidence/47ac6cd
while true; do
  fs=$(pgrep -x sysbox-fs | head -1)
  z=$(ps -o pid,stat,etimes,args --ppid "$fs" 2>/dev/null | awk 'NR>1 && $2 ~ /Z/')
  zap=$(for t in /proc/[0-9]*/task/[0-9]*; do [ "$(cat $t/wchan 2>/dev/null)" = zap_pid_ns_processes ] && echo "$t $(awk '/^Name/{print $2}' $t/status)"; done)
  if [ -n "$z$zap" ]; then echo "=== $(date +%FT%T%z) sysbox-fs=$fs"; echo "$z"; echo "$zap"; fi >> $E/zombiewatch.log
  sleep 20
done
