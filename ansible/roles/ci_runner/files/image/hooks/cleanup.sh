#!/bin/bash
# Bersih-bersih HANYA state dockerd dalam + /cache milik runner (plan 12 §4 "Job hook"). Tidak pernah gagal (exit 0):
# kegagalan hook "job started" akan menggagalkan job.
set -uo pipefail
PHASE="${1:-hook}"
log() { echo "[ci-runner-cleanup:$PHASE] $*"; }
pct() { df --output=pcent "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

ids="$(docker ps -aq 2>/dev/null)"
if [[ -n "$ids" ]]; then
  log "removing inner containers: $(echo "$ids" | wc -l)"
  # shellcheck disable=SC2086
  docker rm -f $ids >/dev/null 2>&1
fi
docker volume prune -a -f >/dev/null 2>&1
docker network prune -f >/dev/null 2>&1

used="$(pct /var/lib/docker)"
if [[ -n "$used" && "$used" -ge 75 ]]; then
  log "/srv/ci ${used}% ≥ 75% → prune images/build cache older than 7d"
  docker image prune -a -f --filter until=168h >/dev/null 2>&1
  docker builder prune -f --filter until=168h >/dev/null 2>&1
fi
used="$(pct /var/lib/docker)"
if [[ -n "$used" && "$used" -ge 85 ]]; then
  log "/srv/ci ${used}% ≥ 85% → prune ALL unused images/build cache"
  docker image prune -a -f >/dev/null 2>&1
  docker builder prune -a -f >/dev/null 2>&1
fi
if [[ -d /cache/gradle ]]; then
  gkb="$(du -sk /cache/gradle 2>/dev/null | cut -f1)"
  if [[ -n "$gkb" && "$gkb" -gt $((6 * 1024 * 1024)) ]]; then
    log "gradle cache $((gkb / 1024)) MiB > 6 GiB → reset /cache/gradle/caches"
    rm -rf /cache/gradle/caches 2>/dev/null
  fi
fi
log "done: /srv/ci $(pct /var/lib/docker)% used"
exit 0
