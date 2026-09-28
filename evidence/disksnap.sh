#!/bin/bash
# At each container transition: /srv/ci/docker size, inner container dirs, df.
E=/opt/infra-wt/r10/evidence; cl=0
echo "ts,event,docker_du_kb,cache_du_kb,inner_container_dirs,srvci_used_kb,root_used_kb" >> $E/disk-trend.csv
while true; do n=$(wc -l < $E/containers.log)
  if [ $n -ne $cl ]; then cl=$n; ev=$(tail -1 $E/containers.log | cut -d' ' -f2-)
    echo "$(date +%FT%T%z),$ev,$(du -sk /srv/ci/docker|cut -f1),$(du -sk /srv/ci/cache|cut -f1),$(ls /srv/ci/docker/containers|wc -l),$(df -k --output=used /srv/ci|tail -1|tr -d ' '),$(df -k --output=used /|tail -1|tr -d ' ')" >> $E/disk-trend.csv; fi
  sleep 5; done
