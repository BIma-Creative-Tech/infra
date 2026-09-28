#!/bin/bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED — workspace bersih + kuota sebelum job.
/opt/ci-runner/hooks/cleanup.sh job-started
exit 0
