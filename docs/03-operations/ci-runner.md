# Operasi — runner GitHub Actions self-hosted (`bctech-adm/drms`)

Plan 12 (`docs/plans/12-gh-runner-drms.md`), ADR 0014. Role Ansible `ci_runner` (`ansible/roles/ci_runner`), tag per bagian:
`ci_runner_disk | ci_runner_sysbox | ci_runner_network | ci_runner_image | ci_runner_toolchain | ci_runner_gc | ci_runner_supervisor`.
Selalu `--check --diff` dulu:

```bash
cd /opt/infra/ansible
/opt/ansible-venv/bin/ansible-playbook site.yml --tags ci_runner_supervisor --check --diff
```

## 1. Komponen

| Komponen | Lokasi | Catatan |
|---|---|---|
| Supervisor | `/usr/local/sbin/ci-runner-supervisor` (unit `ci-runner-supervisor.service`) | registrasi JIT → `docker run --runtime=sysbox-runc` (1 job) → hapus → ulangi; watchdog; metrik |
| Unit path | `ci-runner-supervisor.path` | `PathChanged=/etc/ci-runner/pat` — memulai service setelah PAT **selesai ditulis** |
| Env (tanpa secret) | `/etc/ci-runner/supervisor.env` | dari template role |
| PAT | `/etc/ci-runner/pat` (root 600) | dipasang OWNER; tidak pernah dibaca operator/agent; masuk ke service lewat `LoadCredential` |
| Container job | `ci-runner-job` (label `ci-runner.role=job`), image `ci-runner:<runner>-<build>` | sysbox, 2 vCPU, 5 GiB tanpa swap, pids 4096, `oom_score_adj 800`, io.max |
| Disk | `/var/lib/ci-runner/disk.img` → loop ext4 `/srv/ci` (40 GiB, `srv-ci.mount`) | `docker/` = data-root dockerd dalam, `cache/` = cache Flutter/Gradle/pub/npm/Android SDK/Trivy |
| GC | `ci-runner-gc.timer` (harian) | prune dockerd dalam / reset cache di atas ambang |
| Metrik | `/var/lib/node-exporter-textfile/ci_runner*.prom` | dibaca healthcheck §6 (`scripts/infra-healthcheck.sh`) |

Status cepat:

```bash
systemctl status ci-runner-supervisor ci-runner-supervisor.path --no-pager
journalctl -u ci-runner-supervisor -n 50 --no-pager
docker ps -a --filter label=ci-runner.role=job
grep -v '^#' /var/lib/node-exporter-textfile/ci_runner.prom /var/lib/node-exporter-textfile/ci_runner_heartbeat.prom
docker logs --tail 50 ci-runner-job 2>&1 | grep -E 'ci-runner-entrypoint|Running job|completed with result|Listening'
```

## 2. Metrik & alert

| Metrik | Arti |
|---|---|
| `ci_runner_jobs_total{result=success\|failure\|cancelled\|none\|error}` | hasil job (dari kode keluar entrypoint, sejak R12 / image build 2). `none` = runner berhenti tanpa job (mis. dihentikan supervisor), `error` = runner/dockerd dalam gagal atau container dibuang watchdog tanpa hasil |
| `ci_runner_last_job_exit_code` | 0 ok · 10 Failed · 11 Canceled · 12 hasil lain · 13 tanpa job · 64/70 entrypoint gagal · 125 dibuang watchdog |
| `ci_runner_stuck_total`, `ci_runner_last_stuck_timestamp_seconds`, `ci_runner_stuck_unresolved` | watchdog container macet (§5) |
| `ci_runner_job_timeouts_total`, `ci_runner_job_running_seconds` | guard timeout job (default 3 j, `ci_runner_job_timeout`) |
| `ci_runner_registration_consecutive_failures` | registrasi JIT gagal berturut-turut (PAT kedaluwarsa/dicabut?) |
| `ci_runner_supervisor_heartbeat_timestamp_seconds` | detak tiap 60 s |

Alert healthcheck (email, `infra-healthcheck.timer`): `ci-runner-disk` (/srv/ci > 85% / tidak ter-mount), `ci-runner-supervisor`
(detak basi > 10 mnt), `ci-runner-registration` (≥ 3 gagal), `ci-runner-outdated`, `ci-runner-memory` (anon > 90% limit),
`ci-runner-stuck` (macet belum teratasi, atau watchdog bertindak dalam 24 j terakhir), `ci-runner-job-timeout` (job > 3,5 j).

## 3. Deploy perubahan supervisor / image / env

- Handler role **tidak** me-restart service (restart membatalkan job yang sedang berjalan). Supervisor ≥ R12 memantau metadata
  skripnya, `supervisor.env`, unit service dan file PAT; bila berubah ia keluar di **titik aman** — saat runner masih idle
  (belum ada `Running job:`; container idle dihentikan + registrasi dihapus) atau setelah job selesai — dan systemd
  (`Restart=always`, 30 s) memulainya lagi dengan konfigurasi baru. Cek: `journalctl -u ci-runner-supervisor | grep 'config changed'`.
- Bump image (`ci_runner_version`/digest/`ci_runner_image_build`) → `--tags ci_runner_image,ci_runner_supervisor`: image baru
  dibangun, `CI_IMAGE` di env berubah → reload otomatis di titik aman. Image lama tidak dihapus otomatis (rollback); hapus
  manual setelah beberapa hari: `docker image rm ci-runner:<tag-lama>`.
- Restart paksa hanya saat **idle** (tidak ada `Running job:` di `docker logs ci-runner-job` tanpa `completed with result`):
  `systemctl restart ci-runner-supervisor`.

## 4. Rotasi PAT

PAT fine-grained: hanya repo `bctech-adm/drms`, izin **Administration: Read and write**. Kedaluwarsa ≤ 90 hari.

1. Owner membuat PAT baru di GitHub, lalu di host:
   `sudo install -m 600 -o root -g root /dev/stdin /etc/ci-runner/pat` (tempel PAT, Enter, Ctrl-D).
2. Supervisor mendeteksi perubahan file dan me-restart dirinya di titik aman (tidak membatalkan job). Bila service sedang
   tidak berjalan, `ci-runner-supervisor.path` (PathChanged) memulainya begitu file selesai ditulis.
3. **Verifikasi / restart setelah rotasi:** `journalctl -u ci-runner-supervisor -n 20` harus memuat `preflight OK` dan
   `registered runner … id=N` dengan waktu setelah rotasi. Bila tidak ada (mis. supervisor < R12) dan runner idle:
   `systemctl restart ci-runner-supervisor`.
4. Cabut PAT lama di GitHub.

Catatan race (R12): `PathExists` lama memicu service saat file baru **dibuat** (sebelum isinya ditulis) → salinan
`LoadCredential` kosong → HTTP 401. Kini (a) path unit memakai `PathChanged`, (b) `preflight` menolak credential kosong/format
tidak dikenal (isi tidak dicetak) → systemd mencoba lagi 30 s kemudian dengan salinan baru.

## 5. Runbook: container job macet

Gejala: job antre di GitHub, `docker ps` menunjukkan `ci-runner-job` "Up" lama padahal log berisi
`[ci-runner-entrypoint] … runner exited rc=` / `exiting code=`; `docker rm -f` gagal "did not receive an exit event".
Insiden 2026-09-28 23:48 WIB: zombie `runc:[2:INIT]` (pid ns container) dengan parent `sysbox-fs` tidak di-reap, init container
macet di `zap_pid_ns_processes` ±3 j, sampai `systemctl restart sysbox-fs`.

**Akar masalah (terbukti live 2026-09-29 02:0x WIB, `evidence/47ac6cd/buildkit-runc-zombie-*.txt`):** buildx driver
`docker-container` menjalankan buildkitd di dockerd dalam; `buildkit-runc run` untuk step RUN membuat pid namespace bersarang.
`sysbox-fs` (host) menyuntikkan helper (`nsenter`, tampil sebagai `runc:[2:INIT]`) ke pid ns itu dan **tidak me-reap-nya**
(zombie, parent = sysbox-fs). Init pid ns lalu macet di `zap_pid_ns_processes` → build menggantung sampai `timeout-minutes`,
dan saat job dibatalkan container job macet di exit dengan tanda yang sama. Bug sysbox 0.7.1; mitigasi di workflow drms
(`--oci-worker-no-process-sandbox` atau driver `docker`) + watchdog di bawah. Pantau: zombie anak sysbox-fs
`ps -o pid,stat,etimes,args --ppid $(pgrep -x sysbox-fs) | awk '$2 ~ /Z/'`.

**Otomatis (watchdog supervisor, R12):**
- `exiting code=` tercatat tetapi container belum keluar > `ci_runner_stuck_grace` (180 s), atau `runner exited` tanpa keluar
  > `ci_runner_cleanup_grace` (600 s), atau guard timeout job (> `ci_runner_job_timeout` = 3 j sejak `Running job:` →
  `docker stop`, runner membatalkan job) tanpa keluar > 180 s → **macet**:
  `docker stop` → `docker kill` → bila tidak ada container `sysbox-runc` lain yang berjalan: `systemctl restart sysbox-fs`
  (ikut me-restart `sysbox` + `sysbox-mgr`; supervisor hanya `Wants=sysbox.service` sehingga tidak ikut berhenti) →
  `docker rm -f`. Log `WARN: job container STUCK`, `ci_runner_stuck_total`++, alert `ci-runner-stuck` 24 j.
- Container sisa yang tidak bisa dihapus saat supervisor start → reaper yang sama.
- Terbukti live 2026-09-29 (job image 47ac6cd dibatalkan 02:11:10 WIB → `exiting code=11` 02:11:40 → STUCK 02:14:51 → stop/kill
  gagal → restart sysbox-fs 02:17:02 → dihapus 02:17:03 → registrasi ulang 02:17:20; prod tidak berubah). Bila container macet
  belum bisa dibuang, supervisor tidak meregistrasi runner baru dan mencoba lagi tiap 5 menit.

**Manual** (alert `ci-runner-stuck` dengan `ci_runner_stuck_unresolved 1`, atau watchdog tidak bertindak):
1. `journalctl -u ci-runner-supervisor -n 100 | grep -E 'STUCK|ERROR'` dan `docker logs --tail 30 ci-runner-job`.
2. Pastikan tidak ada container sysbox lain:
   `docker ps -q | xargs -r docker inspect -f '{{.HostConfig.Runtime}} {{.Name}}' | grep sysbox-runc`
   (hanya `/ci-runner-job` yang boleh muncul). Ada yang lain → koordinasi dulu (restart sysbox-mgr merusaknya).
3. `systemctl restart sysbox-fs` → tunggu `docker ps -a --filter label=ci-runner.role=job` kosong/Exited → `docker rm -f ci-runner-job`.
4. Supervisor registrasi ulang sendiri; cek `registered runner` di journal. Prod tidak terpengaruh (runtime prod = runc) — tetap
   verifikasi `StartedAt` container prod tidak berubah.
5. **Jangan** `docker exec` ke `ci-runner-job` untuk diagnosis (setns gagal pada container sysbox yang macet); pakai log
   host, `/proc/<pid>/status`, `ps -o pid,ppid,stat,wchan:32,cmd --ppid <pid-sysbox-fs>`.

## 6. Reset cache

Cache bisa dibuang kapan saja **saat idle** (job berikut lebih lambat; Android SDK di-bootstrap ulang oleh role):

```bash
systemctl stop ci-runner-supervisor.path ci-runner-supervisor       # hanya saat idle
rm -rf /srv/ci/cache/{gradle,pub,npm,flutter,trivy,toolcache}/*      # pilih yang perlu
rm -rf /srv/ci/cache/android-sdk/*                                    # opsional → wajib bootstrap ulang
cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook site.yml --tags ci_runner_disk,ci_runner_toolchain
systemctl start ci-runner-supervisor
```

`ci_runner_disk` membuat ulang subdir cache (uid 1001), `ci_runner_toolchain` menjalankan `android-bootstrap.sh` (idempoten,
marker `/srv/ci/cache/android-sdk/.ci-runner-bootstrap`). Data-root dockerd dalam (`/srv/ci/docker`) dikelola hook
cleanup + `ci-runner-gc`; reset penuh: hentikan supervisor, `rm -rf /srv/ci/docker/*`, start.

## 7. Disk `/srv/ci`

- File loop **harus teralokasi penuh** (bukan sparse) agar `/` tidak ikut tumbuh saat cache terisi. Cek:
  `stat -c 'size=%s blocks512=%b' /var/lib/ci-runner/disk.img` (blocks512 × 512 harus ≥ size) atau `du -h /var/lib/ci-runner/disk.img` ≈ 40G.
- Role: `mkfs.ext4 -m 0 -E nodiscard` (mke2fs default men-discard = punch hole di file loop), mount tanpa `discard`, dan
  memeriksa `/srv/ci` tidak ikut `fstrim.timer` (Ubuntu: `fstrim --listed-in /etc/fstab:/proc/self/mountinfo` memakai
  `/etc/fstab` karena tidak kosong → hanya `/` dan `/boot`; `/srv/ci` adalah unit mount systemd). Temuan R10 "fstrim akan
  mengosongkan tiap minggu" dikoreksi: sparse berasal dari discard mkfs.
- File sparse diisi tanpa kehilangan data (fallocate tanpa `-p`, hanya mengalokasikan hole) — saat idle:
  ```bash
  systemctl stop ci-runner-supervisor.path ci-runner-supervisor
  /opt/ansible-venv/bin/ansible-playbook site.yml --tags ci_runner_disk -e ci_runner_fill_disk_holes=true
  systemctl start ci-runner-supervisor
  ```
  Dilakukan 2026-09-29 01:49–01:50 WIB: 31,3 → 40,0 GiB teralokasi, `/` 52 % → 55 %.
- Anggaran `/`: `/srv/ci` dihitung penuh 40 GiB; alert `/` > 70 % tetap berlaku.

## 8. Upgrade runner

GitHub berhenti meng-queue job ke runner > 30 hari di belakang rilis; alert `ci-runner-outdated` di 21 hari. Ubah
`ci_runner_version` + `ci_runner_base_image` (digest index multi-arch) di `defaults/main.yml`, reset `ci_runner_image_build: 1`,
lalu `--tags ci_runner_image,ci_runner_supervisor` (reload otomatis di titik aman, §3).

## 9. Hentikan / rollback

- Hentikan sementara: `systemctl stop ci-runner-supervisor.path ci-runner-supervisor` (job yang berjalan dibatalkan — tunggu idle).
  Workflow drms kembali ke GitHub-hosted bila owner menghapus variabel repo `CI_RUNS_ON`.
- Rollback penuh: `ci_runner_state: absent` (plan 12 §11; paket sysbox, disk, image tidak dihapus otomatis).
