# Draft upstream issue — nestybox/sysbox (NOT posted; owner decides)

**Title:** sysbox-fs leaves unreaped zombie in nested PID namespace (BuildKit runc inside sysbox container) → init stuck in `zap_pid_ns_processes`, container cannot be killed

**Environment**
- sysbox-ce 0.7.1 (deb, Ubuntu 24.04), kernel 6.8.0-142-generic, Docker Engine 29.8.1 (containerd snapshotter)
- Outer container: `--runtime=sysbox-runc`, not privileged, runs its own dockerd (GitHub Actions runner image `actions-runner:2.337.0`)
- Inside: `docker buildx` with the `docker-container` driver (moby/buildkit), default OCI worker (process sandbox enabled)

**What happens**
1. BuildKit runs a `RUN` step via `buildkit-runc run`, creating a nested PID namespace.
2. A `runc:[2:INIT]` process appears in that nested PID ns whose **parent is the host `sysbox-fs` process**; it becomes a zombie and is never reaped.
3. The nested ns init (another `runc:[2:INIT]`) exits, but its remaining thread blocks in the kernel:
   `do_exit → exit_notify → forget_original_parent → zap_pid_ns_processes` (waiting for the zombie to be reaped).
4. The build hangs forever. When the outer container is stopped, it also hangs: `docker rm -f` → "could not kill container: tried to kill container, but did not receive an exit event".
5. `systemctl restart sysbox-fs` reaps the zombie; the outer container then exits immediately.

**Reproducibility:** 3/3 publish builds hung (2026-09-28/29). The same builds with the dockerd builder (`docker` driver) or with buildkitd `--oci-worker-no-process-sandbox` never hang.

**Evidence available:** process trees, `/proc/<tid>/stack`, PPid of the zombie = sysbox-fs PID (host-side captures).

**Workaround:** buildkitd `--oci-worker-no-process-sandbox`, plus a host watchdog that restarts sysbox-fs when a sysbox container is stuck.

**Question:** Is sysbox-fs expected to spawn helper processes into nested PID namespaces (e.g. for procfs/sysfs emulation via nsenter), and if so, should it reap them / use a subreaper?
