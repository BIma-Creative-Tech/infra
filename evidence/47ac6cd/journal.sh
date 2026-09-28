#!/bin/bash
E=/opt/infra-wt/r12b/evidence/47ac6cd
journalctl -u ci-runner-supervisor -u ci-runner-supervisor.path -u sysbox-fs -u sysbox-mgr -f -o short-iso --since "2026-09-29 01:30" | sed -u -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{10,}/\1***REDACTED***/g' > $E/supervisor-journal.txt
