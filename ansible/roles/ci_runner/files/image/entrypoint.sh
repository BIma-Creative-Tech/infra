#!/bin/bash
# Entrypoint container runner ephemeral (plan 12 R3). PID 1, root-container (userns sysbox → uid host tak berhak).
#  1. JIT config (kredensial sekali pakai, 1 job) dibaca dari STDIN → tidak ada di argv/env container/`docker inspect`.
#  2. dockerd DALAM (data-root /var/lib/docker = bind /srv/ci/docker) → socket lokal untuk job (services, docker run/build).
#  3. Bersihkan sisa job sebelumnya (container/volume/network dalam) + kuota.
#  4. run.sh sebagai uid 1001 tanpa capability (setpriv). JIT runner = ephemeral: keluar setelah satu job.
#  5. Bersih-bersih, hentikan dockerd dalam, keluar dengan kode run.sh.
set -euo pipefail
log() { echo "[ci-runner-entrypoint] $(date -Is) $*" >&2; }

JIT=""
if ! IFS= read -r -t 30 JIT || [[ -z "$JIT" ]]; then
  log "no JIT config on stdin"; exit 64
fi
exec 0</dev/null

log "starting inner dockerd"
dockerd --host=unix:///var/run/docker.sock --group=docker >/var/log/dockerd.log 2>&1 &
DOCKERD_PID=$!
for _ in $(seq 1 60); do
  docker info >/dev/null 2>&1 && break
  kill -0 "$DOCKERD_PID" 2>/dev/null || break
  sleep 1
done
if ! docker info >/dev/null 2>&1; then
  log "inner dockerd failed to start"; tail -n 50 /var/log/dockerd.log >&2 || true; exit 70
fi
log "inner dockerd up: $(docker version --format '{{.Server.Version}}') storage=$(docker info --format '{{.Driver}}')"

/opt/ci-runner/hooks/cleanup.sh pre-run || true

RUNNER_PID=""
forward() { [[ -n "$RUNNER_PID" ]] && kill -TERM "$RUNNER_PID" 2>/dev/null || true; }
trap forward TERM INT

log "starting runner ${CI_RUNNER_IMAGE_VERSION:-?} as uid 1001"
set +e
# shellcheck disable=SC2154  # npm_config_cache dkk. = ENV image
setpriv --reuid=1001 --regid=1001 --init-groups \
  --inh-caps=-all --bounding-set=-all --no-new-privs \
  env -i HOME=/home/runner USER=runner LANG=C.UTF-8 PATH="$PATH" \
    ACTIONS_RUNNER_INPUT_JITCONFIG="$JIT" \
    RUNNER_MANUALLY_TRAP_SIG=1 ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    RUNNER_TOOL_CACHE="$RUNNER_TOOL_CACHE" AGENT_TOOLSDIRECTORY="$AGENT_TOOLSDIRECTORY" \
    npm_config_cache="$npm_config_cache" PUB_CACHE="$PUB_CACHE" GRADLE_USER_HOME="$GRADLE_USER_HOME" \
    ANDROID_HOME="$ANDROID_HOME" ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" FLUTTER_TARBALL_CACHE="$FLUTTER_TARBALL_CACHE" \
    TRIVY_CACHE_DIR="$TRIVY_CACHE_DIR" \
    ACTIONS_RUNNER_HOOK_JOB_STARTED="$ACTIONS_RUNNER_HOOK_JOB_STARTED" \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED="$ACTIONS_RUNNER_HOOK_JOB_COMPLETED" \
    /home/runner/run.sh &
RUNNER_PID=$!
unset JIT
wait "$RUNNER_PID"; RC=$?
# wait bisa kembali lebih awal karena trap; tunggu sampai runner benar-benar keluar.
while kill -0 "$RUNNER_PID" 2>/dev/null; do wait "$RUNNER_PID"; RC=$?; done
set -e
log "runner exited rc=$RC"

/opt/ci-runner/hooks/cleanup.sh post-run || true
kill -TERM "$DOCKERD_PID" 2>/dev/null || true
for _ in $(seq 1 20); do kill -0 "$DOCKERD_PID" 2>/dev/null || break; sleep 1; done
exit "$RC"
