#!/bin/bash
# Entrypoint container runner ephemeral (plan 12 R3). PID 1, root-container (userns sysbox → uid host tak berhak).
#  1. JIT config (kredensial sekali pakai, 1 job) dibaca dari STDIN → tidak ada di argv/env container/`docker inspect`.
#  2. dockerd DALAM (data-root /var/lib/docker = bind /srv/ci/docker) → socket lokal untuk job (services, docker run/build).
#  3. Bersihkan sisa job sebelumnya (container/volume/network dalam) + kuota.
#  4. run.sh sebagai uid 1001 tanpa capability (setpriv). JIT runner = ephemeral: keluar setelah satu job.
#  5. Bersih-bersih, hentikan dockerd dalam, keluar dengan kode HASIL JOB (bukan kode run.sh, yang 0 walau job Failed):
#       0 = Succeeded/SucceededWithIssues · 10 = Failed · 11 = Canceled · 12 = Abandoned/lainnya ·
#      13 = runner keluar 0 tanpa job (mis. dihentikan supervisor) · selain itu = kode run.sh (runner error).
#     Hasil diambil dari baris Terminal runner "<ts>Z: Job <nama> completed with result: <X>" (stdout run.sh di-tee).
#     Penanda untuk watchdog supervisor (host): "runner exited rc=", "job result=", "exiting code=".
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

# Sisa milik root (container dalam, mis. Trivy `-v /cache/trivy:/root/.cache/trivy` atau `$RUNNER_TEMP/trivy-cache`) tidak
# bisa dihapus uid 1001 (runner/hook) → di-chown ke 1001. find -P (tanpa ikut symlink) + chown -h. Cache persisten /cache
# dicek penuh (±4 s); _work/_temp hanya ada selama job.
fix_owner() {
  local d
  for d in "$@"; do
    [[ -d "$d" ]] && { find "$d" -xdev \( -uid 0 -o -gid 0 \) -exec chown -h 1001:1001 {} + 2>/dev/null || true; }
  done
  return 0
}
fix_owner /cache
/opt/ci-runner/hooks/cleanup.sh pre-run || true

# Janitor root untuk hook job (hook jalan sebagai uid 1001): hook membuat $JANITOR/request, janitor merapikan kepemilikan
# /home/runner/_work/_temp + /cache lalu menulis $JANITOR/done. Hanya path tetap di atas yang disentuh.
JANITOR=/run/ci-runner-janitor
install -d -m 0770 -o 0 -g 1001 "$JANITOR"
(
  trap - TERM INT
  while :; do
    if [[ -e "$JANITOR/request" ]]; then
      rm -f "$JANITOR/request" "$JANITOR/done"
      fix_owner /home/runner/_work/_temp /cache
      : > "$JANITOR/done"
    fi
    sleep 1
  done
) &
JANITOR_PID=$!

RUNNER_PID=""
forward() { [[ -n "$RUNNER_PID" ]] && kill -TERM "$RUNNER_PID" 2>/dev/null || true; }
trap forward TERM INT

log "starting runner ${CI_RUNNER_IMAGE_VERSION:-?} as uid 1001"
# stdout run.sh → stdout container (json-file/Loki) DAN salinan lokal untuk membaca hasil job (hanya root container).
RUNNER_OUT=/run/ci-runner/runner.out
install -d -m 0700 /run/ci-runner
: > "$RUNNER_OUT"
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
    /home/runner/run.sh > >(tee -a "$RUNNER_OUT") 2>&1 &
RUNNER_PID=$!
unset JIT
wait "$RUNNER_PID"; RC=$?
# wait bisa kembali lebih awal karena trap; tunggu sampai runner benar-benar keluar.
while kill -0 "$RUNNER_PID" 2>/dev/null; do wait "$RUNNER_PID"; RC=$?; done
log "runner exited rc=$RC"

# Hasil job: baris Terminal runner (bukan output step: itu berawalan "[WORKER"/"[RUNNER"). tee bisa tertinggal sedikit.
RESULT=""
for _ in $(seq 1 10); do
  RESULT="$(grep -aE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z: Job .* completed with result: [A-Za-z]+[[:space:]]*$' "$RUNNER_OUT" \
    | tail -n1 | awk '{print $NF}' | tr -dc 'A-Za-z')"
  [[ -n "$RESULT" ]] && break
  grep -qaE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z: Running job: ' "$RUNNER_OUT" || break
  sleep 0.5
done
case "$RESULT" in
  Succeeded|SucceededWithIssues) CODE=0 ;;
  Failed) CODE=10 ;;
  Canceled|Cancelled) CODE=11 ;;
  "") if (( RC == 0 )); then RESULT=none; CODE=13; else RESULT=runner-error; CODE=$RC; fi ;;
  *) CODE=12 ;;
esac
log "job result=$RESULT runner_rc=$RC exit_code=$CODE"
set -e

kill "$JANITOR_PID" 2>/dev/null || true
fix_owner /cache
/opt/ci-runner/hooks/cleanup.sh post-run || true
kill -TERM "$DOCKERD_PID" 2>/dev/null || true
for _ in $(seq 1 20); do kill -0 "$DOCKERD_PID" 2>/dev/null || break; sleep 1; done
log "exiting code=$CODE"
exit "$CODE"
