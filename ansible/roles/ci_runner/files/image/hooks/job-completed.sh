#!/bin/bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED — buang container/volume/network dalam milik job.
# Sisa milik root di _work/_temp (mis. trivy-cache/fanal) → minta janitor root (entrypoint) chown ke 1001 sebelum runner
# membersihkan temp ("Access to the path … is denied") dan sebelum cleanup menghapus cache.
J=/run/ci-runner-janitor
if [[ -d "$J" && -w "$J" ]]; then
  rm -f "$J/done" 2>/dev/null; : > "$J/request"
  for _ in $(seq 1 120); do [[ -e "$J/done" ]] && break; sleep 1; done
  [[ -e "$J/done" ]] || echo "[ci-runner-cleanup:job-completed] janitor did not answer within 120 s"
fi
/opt/ci-runner/hooks/cleanup.sh job-completed
exit 0
