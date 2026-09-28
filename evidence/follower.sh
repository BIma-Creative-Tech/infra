#!/bin/bash
# Follows logs of each successive ci-runner-job container (captures to exit even if --rm).
E=/opt/infra-wt/r10/evidence; last=
while true; do
  cid=$(docker inspect -f '{{.Id}}' ci-runner-job 2>/dev/null)
  if [ -n "$cid" ] && [ "$cid" != "$last" ]; then
    last=$cid; s=${cid:0:12}; echo "$(date +%FT%T%z) new container $s" >> $E/containers.log
    ( docker logs -f -t $cid 2>&1 | sed -u -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{10,}/\1***REDACTED***/g; s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/***JWT-REDACTED***/g; s/((Bearer|Basic|token|Token|TOKEN|password|PASSWORD|secret|SECRET)[" :=]+)[A-Za-z0-9+\/_.=-]{12,}/\1***REDACTED***/g' > $E/jobs/$s.log; echo "$(date +%FT%T%z) logs ended $s" >> $E/containers.log ) &
  fi
  sleep 3
done
