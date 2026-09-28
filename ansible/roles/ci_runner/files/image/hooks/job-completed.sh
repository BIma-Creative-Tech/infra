#!/bin/bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED — buang container/volume/network dalam milik job.
/opt/ci-runner/hooks/cleanup.sh job-completed
exit 0
