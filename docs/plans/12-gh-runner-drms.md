# Plan 12 — Self-hosted GitHub Actions runner untuk `bctech-adm/drms`

- **Status:** APPROVED (owner GATE 1 2026-09-28: Q1–Q6 all recommendations) (menunggu GATE 1)
- **Tanggal:** 2026-09-28 · **Penulis:** Analyst (untuk Lead) · **Permintaan:** sesi app ProyekKas, keputusan owner
  2026-09-28: "self-hosted runner", karena akun GitHub Free kehabisan menit Actions dan job CI drms gagal dalam 2 s.
- **ADR:** `docs/adr/0014-self-hosted-ci-runner.md` (**proposed**)
- **Terkait:** ADR 0004 (kapasitas, overcommit terkendali 2026-09-27), ADR 0010 (network per konsumen), ADR 0001 (lisensi),
  `docs/runbooks/proyekkas-drms-prod.md` §11 (GHCR + deploy), repo drms `docs/proyekkas/runbooks/ci-ghcr.md`, branch drms
  `ci/self-hosted-runner` (`fca2ef9`, PR menunggu merge owner), CLAUDE.md §0.9, §0.10, §3.5, §3.6, §3.7, §4.

Penanda: **[NYATA]** = diukur/dibaca di sesi ini (2026-09-28) · **[ESTIMASI]** · **[UNVERIFIED]** = wajib dibuktikan di R0/PoC.

## 1. Scope

**IN**
- Satu runner **tingkat repo** untuk `bctech-adm/drms` saja (akun User, bukan org). Label: `self-hosted, linux, x64, drms`.
- **Ephemeral:** satu job per container runner. Container runner selalu baru, workspace bersih. Registrasi JIT per job.
- Isolasi dari prod: tanpa socket Docker host dan tanpa `privileged`. Job tetap bisa memakai Docker: `services:` (postgres
  16.15, mailpit), `docker run` (semgrep/trivy/gitleaks/hadolint/actionlint), `docker build` (web + migrate), plus Flutter +
  Android SDK untuk APK.
- Batas resource (CPU/RAM/PID/IO, satu job sekaligus), kuota disk tetap, cleanup hanya atas data milik runner, revisi ADR 0004.
- Monitoring (Prometheus/Kuma/Loki), rollback, dan daftar perubahan workflow drms (dikerjakan sesi app, bukan branch infra).

**OUT**
- Runner untuk repo lain (`control-plane`, `bct-website`, …). Bisa ditambah kelak dengan instance/label terpisah dan plan kecil.
- Registry image lokal. Opsional, diputuskan di GATE Q5, plan terpisah (12b).
- infra-deploy v2 dan deploy prod otomatis (runbook DRMS §11, tetap tindak lanjut terpisah).
- Autoscaling atau lebih dari satu runner paralel (RAM tidak cukup, §6).

## 2. Fakta yang memengaruhi desain

### 2.1 Host [NYATA 2026-09-28]
| Fakta | Sumber | Implikasi |
|---|---|---|
| 4 vCPU, RAM 15 992 MiB, available ±11 100 MiB, **swap 1 958 / 4 095 MiB terpakai** (bukan 2 GB dari 2 GB: swapfile 4 GiB) | `free -m`, `swapon` | alert ADR 0004 "swap > 1 GiB" sudah aktif. CI tidak boleh memakai swap (`memswap_limit = mem_limit`) |
| Σ `mem_limit` 29 container = **14 768 MiB**, pemakaian nyata 2 661 MiB. Σ `cpus` 16,0 | `docker inspect`, `docker stats` | aturan perencanaan ADR 0004 sudah minus; lihat §6 |
| vmstat 15:32: `wa` **23%**, load 2,4 (saat sesi app menghapus worktree) | `vmstat 1 3` | IO disk adalah titik rebutan nyata. CI wajib dibatasi IO (§6) |
| Disk `/` ext4 193 G: 66% → **56% (107 G, sisa 86 G)** setelah sesi app membersihkan 13 worktree + cache | `df -h /` dua kali | ruang cukup untuk loop 40 GiB (→ ±77%). Tanpa LVM (`vgs` kosong), satu partisi `sda1` |
| `docker system df`: image 70,3 GB (**49 GB reclaimable**), build cache 19,3 GB (12,6 reclaimable) | `docker system df` | pembersihan image/build lama (destruktif, konfirmasi owner) memberi ±50 GB lagi |
| Docker 29.8.1, containerd 2.3.5, runc 1.5.1, snapshotter overlayfs, cgroup v2 + driver systemd, `live-restore: true`, daemon `no-new-privileges: true`, `icc: false`, apparmor + seccomp aktif | `docker info`, `/etc/docker/daemon.json` | NNP daemon-wide juga berlaku untuk container runner (sudo di dalamnya mati, sesuai harapan) |
| Kernel 6.8.0-142, Ubuntu 24.04.5. Tidak ada `/dev/kvm`, flag `vmx/svm` = 0 | `uname`, `/proc/cpuinfo` | **microVM (Firecracker/Kata) tidak mungkin**. Isolasi harus berbasis namespace |
| `unprivileged_userns_clone=1`, `max_user_namespaces=63818`, **`apparmor_restrict_unprivileged_userns=1`** | `/proc/sys` | rootless Docker di host butuh profil AppArmor untuk rootlesskit (opsi c) |
| `/etc/subuid`: `admin:100000:65536`, `deploy:165536:65536` | file | user CI baru butuh rentang sendiri (opsi c), mulai 231072 |
| cgroup2fs, controller root `cpuset cpu io memory hugetlb pids rdma misc` semua di `subtree_control`. Tidak ada drop-in `user@.service.d` | `/sys/fs/cgroup` | limit container via Docker jalan. Opsi c butuh `Delegate=` tambahan |
| Scheduler IO `sda` = **mq-deadline** | `/sys/block/sda/queue/scheduler` | `io.weight`/`blkio_weight` **tidak berefek** (butuh BFQ/io.cost). Pakai batas absolut `io.max` (bps/iops) |
| Loopback host: `127.0.0.1:8080`, `127.0.0.1:8443` (dockerd → entrypoint admin Traefik) | `ss -ltnp` | job yang jalan di netns host (opsi c) bisa menjangkau UI admin. Di container (opsi b) tidak |
| `/opt/infra` 750 root:admin, `.env` 600. **`/opt/src` 755** (checkout app; `proyekkas-private` 700) | `ls -ld` | user host baru (opsi c) bisa membaca `/opt/src`. Container (opsi b) tidak melihatnya sama sekali |
| `/proc` tanpa `hidepid` | `/proc/mounts` | user host (opsi c) bisa melihat cmdline semua proses |
| Subnet `10.100.18.0/24` & `.19` bebas (17 = `analytics-edge`) | `docker network inspect` | network `ci-runner` = 10.100.18.0/24 (cek ulang `git grep` semua branch di R0) |
| node-exporter `--path.rootfs=/host`, bind `/:/host:ro,rslave` | `observability/docker-compose.yml` | mount `/srv/ci` baru otomatis terlihat → metrik disk kuota gratis (cek filter mountpoint di R8) |

### 2.2 GitHub, runner, sysbox (sumber resmi, dibaca 2026-09-28)
| Fakta | Sumber |
|---|---|
| Runner self-hosted **gratis** (tidak memakai menit). Kuota menit/penyimpanan paket hanya untuk runner GitHub-hosted | docs.github.com billing "GitHub Actions" |
| **Artifact + GitHub Packages (GHCR) berbagi kuota** (Free 500 MB). **Cache Actions = kuota terpisah 10 GB per repo**, evict bila > 7 hari tidak diakses | billing "How storage billing works"; "dependency-caching" §Usage limits |
| Registration token repo: `POST /repos/{owner}/{repo}/actions/runners/registration-token`, **berlaku 1 jam**. JIT: `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` (body `name`, `runner_group_id`, `labels`, `work_folder`); delete: `DELETE …/actions/runners/{runner_id}` | REST "self-hosted-runners" |
| Fine-grained PAT: ketiga endpoint di atas = **Repository permission "Administration": write**. List runner = Administration: read. Permission yang sama juga membuka `PATCH`/`DELETE /repos/{owner}/{repo}` | "permissions-required-for-fine-grained-personal-access-tokens" |
| `--ephemeral`: runner di-deregister otomatis setelah satu job. GitHub menyarankan ephemeral dan meminta log runner diteruskan ke penyimpanan eksternal. Job dengan label yang tak tersedia menunggu antre sampai 24 jam | "self-hosted-runners" reference |
| `--disableupdate`: update wajib dalam **30 hari** sejak rilis. Lewat dari itu job tidak di-queue. Update keamanan kritis → langsung tidak di-queue sampai diupdate | idem |
| actions/runner **v2.337.0** (2026-08-26), MIT, aktif. SHA-256 `actions-runner-linux-x64-2.337.0.tar.gz` = `70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613` | GitHub API releases |
| Image resmi `ghcr.io/actions/actions-runner:2.337.0` index `sha256:e5496277be5d09bc968b3d64911b74e219ac4a3f2edce956a3ecf9271bea1ef4` (amd64 `sha256:50364809…6ec97`). Basis `dotnet/runtime-deps:8.0-noble`, user `runner` uid 1001, **bundel static Docker 29.7.2 (termasuk `dockerd`)** + buildx 0.36.1, `sudo` NOPASSWD. Dockerfile resmi **tidak** memverifikasi checksum tarball (pin digest menggantikannya) | `docker buildx imagetools inspect`, `images/Dockerfile` tag v2.337.0 |
| **Sysbox** (nestybox/Docker Inc.), Apache-2.0, **v0.7.1 2026-07-31**, v0.7.0 2026-06-02, push terakhir 2026-09-15. Ubuntu 24.04 didukung (kernel ≥ 6.8, tanpa shiftfs). Menjalankan Docker di dalam container **tanpa `--privileged`** (root container dipetakan ke uid host tak berhak) | GitHub API, `docs/distro-compat.md` |
| Sysbox: **harus jalan sebagai root di host** (sysbox-mgr, sysbox-fs). Installer menambah `runtimes.sysbox-runc` ke `daemon.json` dan me-restart dockerd, **kecuali** `bip` + `default-address-pools` sudah ada di `daemon.json` (runtime sendiri bisa di-reload tanpa restart). Tidak bisa: `--privileged`, `--net=host`, `--pid=host`, `--userns=host`, binfmt_misc (buildx+QEMU multi-arch), mknod | `docs/user-guide/install-package.md`, `limitations.md` |
| Tidak ada `/dev/kvm` → GitHub Actions Runner Controller/Kubernetes juga berlebihan untuk 1 host (tidak dipertimbangkan) | — |

### 2.3 Workflow drms (branch `ci/self-hosted-runner`, `fca2ef9`) [NYATA]
- Semua job: `runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-24.04"') }}`. `deploy-prod.yml` memakai `DEPLOY_RUNS_ON` terpisah
  (job-nya memegang `DEPLOY_SSH_KEY`). Push `feat/**`/`fix/**` tidak lagi menjalankan pipeline dobel (hanya lewat PR). Retensi
  artifact: APK staging 7 hari, coverage 3 hari.
- Asumsi di workflow yang **menentukan desain isolasi**: `services.postgres` publish `5432:5432` lalu diakses via
  `127.0.0.1:5432`; mailpit `-p 127.0.0.1:1025`. `docker run -v "$PWD:/src"` (bind path workspace). Trivy image memakai
  `-v /var/run/docker.sock:/var/run/docker.sock:ro`. Buildx memakai `cache-from/to: type=gha`. `actions/cache` untuk pub/Gradle,
  `setup-node cache: npm`. `$ANDROID_HOME/build-tools/*/apksigner` (SDK bawaan image GitHub). Flutter tarball + sha256.
  Job `release-prod` APK memakai environment `android-release-prod` (keystore prod).
- Maka daemon Docker yang dipakai job **harus berbagi filesystem dan network namespace dengan langkah job**. Sidecar DinD via
  `DOCKER_HOST=tcp://…` akan mematahkan `127.0.0.1:5432`, bind `$PWD`, dan mount `docker.sock`. Dockerd di dalam container
  runner yang sama tidak mematahkan apa pun.

## 3. Opsi isolasi & rekomendasi

| | (a) runner + sidecar DinD rootless | (b) **runner + dockerd di dalam container sysbox** | (c) user host khusus + rootless Docker | (d) DinD privileged |
|---|---|---|---|---|
| Butuh `privileged`? | **Ya.** Image `docker:*-dind-rootless` tetap butuh `--privileged` (docs image Docker). Tanpa privileged = seccomp/apparmor/systempaths unconfined, tidak standar **[UNVERIFIED]** | **Tidak** | Tidak | Ya |
| Kompatibel workflow (§2.3) | ✗ netns/fs terpisah (bisa diakali `network_mode: service:dind` + volume path sama, rapuh) | ✓ netns + fs sama, `docker.sock` lokal | ✓ port di-publish rootlesskit ke **loopback host** | ✓ |
| Job melihat FS host | tidak | tidak | **ya**, semua yang world-readable (`/opt/src`, `/etc`, cmdline proses). Butuh sandbox systemd | tidak (tapi bisa mount apa saja) |
| Job menjangkau loopback host (`:8443` admin Traefik) | tidak | tidak | **ya**, kecuali aturan nftables `meta skuid` | ya |
| Workspace segar per job | ✓ | ✓ container dibuat ulang tiap job | ✗ bersih-bersih manual (`rm -rf _work`, prune) | ✓ |
| Komponen root baru di host | – | sysbox-mgr + sysbox-fs (root, FUSE) | `newuidmap/newgidmap` setuid (paket `uidmap`), profil AppArmor | – |
| Sentuh dockerd prod | tidak | runtime baru (SIGHUP). Tanpa restart bila `bip`/`default-address-pools` ditulis dulu **[UNVERIFIED: isi postinst 0.7.1]**, fallback 1× restart ±2 s | tidak | tidak |
| Limit resource & metrik | compose biasa | compose/`docker run` biasa → `container-metrics.sh` (ADR 0004 §8.2) langsung mencatat | slice systemd (`user@UID`), di luar metrik container | compose |
| Setara root host bila job jahat | hampir (container privileged) | tidak. Butuh escape kernel/sysbox | tidak. Butuh escape kernel, tapi permukaan host lebar | **ya** |

**(d) ditolak mutlak:** container privileged = semua capability, semua device (`/dev/sda`), tanpa seccomp/apparmor. Root
di dalam container (siapa pun yang bisa push workflow atau dependency npm yang disusupi) = root host = seluruh DB prod,
secret `/opt/infra`, dan kunci TLS. Juga melanggar CLAUDE.md §0.9. **(a)** jatuh ke masalah yang sama (privileged) dan
tetap tidak cocok dengan workflow.

**Rekomendasi: (b) sysbox.** Alasan:
1. Satu-satunya opsi yang **tanpa privileged sekaligus** job tidak melihat FS/loopback host. Root di container dipetakan ke uid
   host tak berhak (userns). Inilah fungsi sysbox. Batas isolasinya sama dengan container prod lain ditambah userns.
2. Kompatibel 1:1 dengan workflow sekarang (dockerd di netns/fs yang sama). Tidak perlu mengubah langkah postgres/mailpit/trivy.
3. Ephemeral sungguhan: container dibuang setelah tiap job. Yang bertahan hanya volume cache di kuota `/srv/ci`.
4. Cocok dengan konvensi platform: limit compose, `container-metrics.sh`, log json-file → Alloy/Loki, dan `oom_score_adj`.

**Fallback (c)** bila PoC R0 gagal (mis. sysbox + NNP daemon-wide/apparmor bentrok) atau owner menolak komponen root baru.
Syaratnya: unit systemd ber-sandbox (`ProtectSystem=strict`, `ProtectHome=tmpfs`, `ProtectProc=invisible`,
`InaccessiblePaths=/opt /root /var/lib/docker /var/lib/containerd /etc/docker /var/lib/infra-jobs`), nftables `meta skuid ci`
yang memblok loopback dan 10.100.0.0/16, profil AppArmor rootlesskit, kuota cgroup di `user@UID.service`. Kompatibilitas
sandbox dengan rootlesskit **[UNVERIFIED]**.

**Risiko sisa (jujur):** CI menjalankan kode repo **dan dependensinya** (npm/pub/Gradle/image). Repo private, yang push hanya
owner dan sesi agent, PR fork tidak ada. Tetapi dependency yang disusupi tetap realistis. Job jahat bisa: membaca secret yang
diberikan ke job itu, memakai egress internet, meracuni cache persisten (§4 T3), dan menyerang kernel/sysbox untuk escape
(→ root host). Probabilitasnya rendah dibanding GitHub-hosted, tetapi **dampaknya di sini adalah host prod**. Mitigasi ada di §4.
Pemicu pindah CI ke VPS terpisah (sesuai ADR 0004 §6 "build/CI keluar host") tetap berlaku.

## 4. Arsitektur

```
GitHub (drms) ⇄ HTTPS long-poll ⇄ container ci-runner-<n> (sysbox-runc, uid runner 1001, NNP, egress saja)
                                   ├─ dockerd bagian dalam (root palsu di userns) → services/docker run/build
                                   ├─ /var/lib/docker  ← bind /srv/ci/docker   (cache image/build, kuota)
                                   └─ /cache           ← bind /srv/ci/cache    (npm, pub, gradle, flutter, android-sdk)
host: ci-runner-supervisor.service (root) ── PAT (systemd LoadCredential, 600) ──▶ API generate-jitconfig
      /srv/ci = ext4 di loop file /var/lib/ci-runner/disk.img (40 GiB, fallocate) · network ci-runner 10.100.18.0/24
```

**Supervisor (host, root, `/usr/local/sbin/ci-runner-supervisor` + unit systemd)**, loop:
1. Baca PAT dari `$CREDENTIALS_DIRECTORY` (`LoadCredential=pat:/etc/ci-runner/pat`, file 600 root). PAT **tidak pernah** masuk
   ke container.
2. `POST generate-jitconfig` (`name=drms-<host>-<epoch>`, `labels=[self-hosted,linux,x64,drms]`, `runner_group_id` default,
   **[UNVERIFIED]** id grup untuk repo akun User → cek respons 201). `encoded_jit_config` = kredensial sekali pakai untuk satu job.
3. `docker run --rm --runtime=sysbox-runc` image runner. JIT config diteruskan lewat file tmpfs mode 0400 (bukan argumen, supaya
   tidak terlihat di `ps`). Entrypoint (root container) menjalankan dockerd bagian dalam, lalu `setpriv` ke uid 1001 dan
   `./run.sh --jitconfig`. JIT runner otomatis ephemeral: keluar setelah satu job.
4. Container keluar → hapus sisa registrasi offline via API bila ada → tulis metrik textfile → ulangi. Gagal → backoff 30 s–10 mnt,
   metrik `ci_runner_registration_failures_total`.

**Pseudo-config container (bukan final):**
```yaml
runtime: sysbox-runc
image: ci-runner:2.337.0-1        # FROM ghcr.io/actions/actions-runner:2.337.0@sha256:e5496277…ef4 (+ xz-utils, zip, openssl)
networks: [ci-runner]             # 10.100.18.0/24, BUKAN --internal (butuh egress), tanpa publish port
cpus: 2.0
cpu_shares: 256                   # cgroup v2 cpu.weight ≈ 10 vs 39 default → prod menang saat rebutan
mem_limit: 4g
memswap_limit: 4g                 # tanpa swap
pids_limit: 4096                  # dockerd + Gradle/Kotlin daemon (thread dihitung)
oom_score_adj: 800                # korban OOM pertama bila host kehabisan RAM
blkio_config: {device_write_bps: [{path: /dev/loopN, rate: 60mb}], device_read_bps: [{path: /dev/loopN, rate: 120mb}]}  # [UNVERIFIED] atribusi loop → sda, dituning di R10
security_opt: ["no-new-privileges:true"]   # sudo image resmi jadi mati → job tidak bisa apt-get
volumes: ["/srv/ci/docker:/var/lib/docker", "/srv/ci/cache:/cache"]
logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}
# TIDAK ada: /var/run/docker.sock host, privileged, cap_add, publish port, mount /opt/*
```
`read_only`/`cap_drop: ALL` **tidak** dipakai: dockerd bagian dalam butuh capability root-palsu di userns sysbox. Ini
pengecualian §3.5 yang dicatat di ADR 0014, dengan kompensasi userns sysbox dan NNP.

**Egress:** network `ci-runner` biasa + aturan `DOCKER-USER` (Ansible, subnet tetap) yang **drop** dari 10.100.18.0/24 ke
10.0.0.0/8 (selain gateway DNS), 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16. Ke host, ufw INPUT default deny sudah hanya
membuka port publik. Allowlist domain (github.com, *.actions.githubusercontent.com, ghcr.io, pkg-containers.githubusercontent.com,
registry.npmjs.org, nodejs.org, pub.dev, storage.googleapis.com, dl.google.com, maven.google.com, repo.maven.apache.org,
plugins.gradle.org, services.gradle.org, registry-1.docker.io/auth.docker.io/production.cloudflare.docker.com, mirror.gcr.io
(DB trivy), semgrep.dev (ruleset `p/…`), api.adoptium.net) **tidak** ditegakkan di L3. Semuanya CDN dengan IP berubah, dan ADR
0010 menolak aturan IP dinamis. Proxy egress ber-allowlist (tool baru) = hardening fase berikut (R-risk 4).

**Cache & data (semua di `/srv/ci`, milik runner):**
| Path | Isi | Batas |
|---|---|---|
| `/srv/ci/docker` | image job (postgres, mailpit, semgrep, trivy, …), build cache BuildKit, image `proyekkas-*:ci` | GC dalam daemon: `builder.gc` max 8 GB. Prune image `until=168h` bila `/srv/ci` > 75% |
| `/srv/ci/cache/{npm,pub,gradle,flutter,android-sdk,trivy}` | pengganti `actions/cache`/`setup-node cache`. Tarball Flutter per versi (sha256 dicek ulang tiap job) | gradle > 6 GB atau total > 85% → hapus subdir itu |
| workspace `_work` | di rootfs container → hilang saat container dibuang | — |

**Job hook** (`ACTIONS_RUNNER_HOOK_JOB_STARTED/COMPLETED` di image): pre-job `docker rm -f` semua container dalam +
`volume/network prune`, dan cek kuota. Post-job hal yang sama. Supervisor dan timer harian host **hanya** menyentuh `/srv/ci`
dan container berlabel `ci-runner`. **Tidak pernah** menjalankan `docker system prune` di daemon host.

**Keracunan cache (T3):** cache dibagi antar job. Job tag rilis (`v*.*.*`, `mobile-v*`) dan `release-prod` wajib build tanpa
cache (`no-cache: true`, `PUB_CACHE`/`GRADLE_USER_HOME` di `$RUNNER_TEMP`), memverifikasi lockfile (`npm ci`,
`--enforce-lockfile` sudah ada), dan tetap Trivy. Image dasar di-pin digest, sehingga penggantian tag lokal tidak bisa menukar isi.

## 5. Kredensial & registrasi (GATE Q3)

| Opsi | Token owner dipakai | Rahasia jangka panjang | Ephemeral | Catatan |
|---|---|---|---|---|
| **A. Fine-grained PAT → JIT per job (rekomendasi)** | tidak perlu | PAT: repo `drms` saja, permission **Administration: read & write** (+ Metadata read otomatis), kedaluwarsa 180 hari | ✓ | PAT juga bisa ubah/hapus repo (permission yang sama) → hanya di host root 600 via `LoadCredential`, tidak pernah di container/job/log. Rotasi terjadwal + alert gagal registrasi |
| B. GitHub App (dipasang di akun User, Administration: write) | tidak | private key App (tanpa kedaluwarsa), token instalasi 1 jam | ✓ | kekuatan sama dengan A, setup lebih panjang (JWT). Cocok bila kelak banyak repo |
| C. Registrasi persisten sekali dengan token 1 jam dari owner, container baru per job | **ya, sekali** (tidak disimpan) | `.runner` + `.credentials` (RSA) runner, root 600, di-mount ke tiap container | ✗ (runner sama menerima banyak job) | kredensial harus terbaca uid job → job jahat bisa mencurinya dan membajak job berikut (termasuk secret). GitHub tidak menyarankan autoscale persisten |

Token registrasi 1 jam dari UI (Settings → Actions → Runners) **hanya** dibutuhkan untuk opsi C atau uji manual R0. Aturannya:
token dipakai sekali lewat stdin (`read -rs`), tidak ditulis ke file/riwayat shell, dan kedaluwarsa sendiri.

## 6. Kapasitas & prioritas (revisi ADR 0004)

| Item | Nilai usulan | Dasar |
|---|---|---|
| Runner | **1 job sekaligus** (1 container), `cpus 2.0`, `cpu_shares 256`, `mem_limit 4g` tanpa swap, `pids 4096`, `oom_score_adj 800` | APK: Gradle + Kotlin daemon ±2,5–3,5 GB, `next build` ±1,5–2 GB **[ESTIMASI]**. `GRADLE_OPTS -Xmx2g`, `org.gradle.workers.max=2` di env job self-hosted |
| sysbox-mgr + sysbox-fs | ±50–100 MiB **[ESTIMASI]**, unit host (di luar Σ container) | diukur R2 |
| Disk | loop ext4 **40 GiB** (`fallocate`, `mkfs.ext4 -m 0`), mount `/srv/ci` `nosuid` (`nodev` diuji di R1) | image+build cache ±12 GB, cache Flutter/Android/Gradle/npm/pub ±12 GB, workspace ±3 GB, sisa GC **[ESTIMASI]**. `/` 107 → 147 G ≈ **76%** tanpa pembersihan image lama. Dengan R0b (±50 GB reclaimable) ≈ 50% |
| IO | `io.max` bps pada device loop | mq-deadline → `io.weight` tidak berlaku (§2.1) |
| Timeout | `timeout-minutes` workflow sudah ada (20–45) | antre maksimal 24 jam (perilaku GitHub) |

**Aturan perencanaan ADR 0004:** Σ limit 14 768 + 4 096 (CI) + 384 (dbt) + 2 048 (cadangan) = 21 296 vs 15 992 → **−5,3 GiB**.
Jadi CI tidak bisa "muat" menurut aturan batas atas. Usulan revisi ADR 0004 (keputusan GATE Q4):
1. Kategori baru **"anggaran build/CI" 4 GiB**, dicatat terpisah dari layanan: batas keras, korban OOM pertama (`oom_score_adj`),
   CPU weight rendah, tanpa swap. Ia **menggantikan** build ad-hoc di dockerd host yang sekarang tak terbatas (puncak T19:
   used 10,7 GiB + swap 1,2 GiB berasal dari build lokal).
2. Setelah runner lulus QA: build image ProyekKas di dockerd host oleh sesi agent **dihentikan** (build lewat CI). Pengecualian
   darurat dicatat. Tanpa aturan ini beban justru bertambah (CI + build lokal).
3. Pemicu evaluasi: 7 hari data `container-metrics` → bila RAM available p05 < 3 GiB atau swap > 1 GiB berulang saat job CI →
   turunkan CI ke 3 GiB (APK dipisah ke malam hari) atau pindahkan CI ke VPS terpisah (ADR 0004 §6).
4. Disk: `/srv/ci` dihitung sebagai alokasi tetap 40 GiB. Alert `/` > 70% tetap. Laju tumbuh `/` harus turun (build pindah ke
   kuota tetap), diukur 7 hari setelah R10.

## 7. Image & penyimpanan GitHub 500 MB (GATE Q5)

- `actions/cache` + `cache: npm` + buildx `type=gha` **tidak** memakai kuota 500 MB (cache = 10 GB terpisah). Di self-hosted
  tetap diganti cache lokal: lebih cepat, tanpa evict 7 hari, tanpa lalu lintas keluar. Workflow memakai kondisi
  `runner.environment == 'github-hosted'` agar tetap jalan di GitHub-hosted.
- Artifact: retensi 3–7 hari (sudah di `fca2ef9`). Usulan tambahan: coverage tidak di-upload di self-hosted (cukup ringkasan job),
  APK release staging 3 hari.
- **GHCR private menghabiskan kuota 500 MB yang sama.** Ukuran lokal: `proyekkas-migrate` ±2,0 GB, `proyekkas-web` ±360 MB
  (tidak terkompresi) [NYATA `docker images`]. Terkompresi ±0,5–0,7 GB per rilis **[ESTIMASI]**, sehingga satu rilis saja
  kemungkinan sudah > 500 MB. Tiap push `develop` menambah tag `-stg-`.
  - (a) Tetap GHCR: hanya push tag rilis `v*` + staging terakhir, workflow retensi hapus versi lama (butuh `packages: delete`),
    dan perampingan image migrate oleh tim app. Deploy flow infra **tidak berubah** (runbook DRMS §11: `ghcr.io/…@sha256`).
  - (b) Registry lokal (CNCF Distribution, Apache-2, tool baru → ADR tersendiri, plan 12b): runner push ke `registry:5000`
    (network `ci-registry`), host pull dari `127.0.0.1:5000` (dockerd host sudah memercayai `127.0.0.0/8` sebagai insecure
    registry [NYATA `docker info`]). Implikasi: `.env` prod `PK_*_IMAGE=127.0.0.1:5000/proyekkas-*:X.Y.Z@sha256:…`, regex allowlist
    infra-deploy v2 berubah, job `resolve` di `deploy-prod.yml` harus jalan di self-hosted, registry butuh kuota disk + GC +
    pencadangan tag prod (atau rebuild reproducible dari tag).
  - **Rekomendasi:** mulai (a) sekarang. Owner cek pemakaian nyata di Settings → Billing → Usage. Lanjut ke (b) hanya bila
    push GHCR terblokir atau tagihan penyimpanan muncul. Keputusan eksplisit di GATE Q5.

## 8. Task

| # | Task | Owner | Dep | Estimasi | Downtime prod |
|---|---|---|---|---|---|
| R0 | PoC & pra-cek read-only: (1) ekstrak `sysbox-ce_0.7.1` deb (`dpkg-deb -e`), baca postinst: kondisi restart dockerd, isi yang ditulis ke `daemon.json`; (2) `git grep` subnet 10.100.18 di semua branch; (3) nilai `bip`/`default-address-pools` yang identik dengan perilaku sekarang (docker0 172.17.0.1/16; semua network platform bersubnet eksplisit) | infra-engineer | GATE 1 | 1 j | 0 |
| R0b | Pembersihan image/build cache lama di dockerd host (±50 GB reclaimable). **Destruktif → daftar + konfirmasi owner** (CLAUDE.md §0.5) | Lead + owner | GATE 1 | 30 mnt | 0 |
| R1 | `/srv/ci`: `fallocate -l 40G /var/lib/ci-runner/disk.img`, `mkfs.ext4 -m 0 -L ci`, unit `srv-ci.mount` (loop, `nosuid`), subdir `docker/` & `cache/` (owner uid hasil mapping sysbox, dicek di R3) — Ansible role `ci_runner` | infra-engineer | R0 | 45 mnt | 0 |
| R2 | Sysbox 0.7.1 (deb pin sha256, Ansible): tulis `bip` + `default-address-pools` ke `daemon.json` via role docker **tanpa restart** → install → verifikasi `docker info` Runtimes berisi `sysbox-runc` + `StartedAt` semua container tidak berubah. Bila postinst tetap me-restart: hentikan, jadwalkan jendela sepi (±2 s, prosedur ADR 0004 §8.1) | infra-engineer + Lead | R0 | 1 j | **0** (fallback ±2 s edge blip, jam sepi) |
| R3 | Image `ci-runner:2.337.0-1`: `FROM ghcr.io/actions/actions-runner:2.337.0@sha256:e5496277…`, + `xz-utils zip openssl`, entrypoint (dockerd dalam → `setpriv` uid 1001 → `run.sh --jitconfig`), hook job, `daemon.json` dalam (`builder.gc` 8 GB, log json-file). Hadolint + Trivy (CRITICAL = stop). Build satu kali di dockerd host (image kecil, infra-owned) | infra-engineer | R2 | 2 j | 0 |
| R4 | Network `ci-runner` 10.100.18.0/24 (bootstrap infra) + aturan `DOCKER-USER` persisten (Ansible) + uji jangkauan | infra-engineer | R0 | 45 mnt | 0 |
| R5 | Supervisor + unit `ci-runner-supervisor.service` (`LoadCredential`, `Restart=always`, backoff, cleanup registrasi offline, metrik textfile `ci_runner_*`, push Kuma) + `/etc/ci-runner/` (700 root) | infra-engineer | R1–R4, **owner: PAT** | 3 j | 0 |
| R6 | Cache & toolchain: `android-sdk` (cmdline-tools pin sha256, `sdkmanager` platform/build-tools/NDK sesuai Flutter 3.47.5 **[UNVERIFIED versi]**), env `ANDROID_HOME`, `PUB_CACHE`, `GRADLE_USER_HOME`, `npm_config_cache` di image. Timer harian host: kuota `/srv/ci` (hanya data runner) | infra-engineer | R3 | 1,5 j | 0 |
| R7 | Monitoring: alert Prometheus (`/srv/ci` > 85%, supervisor mati > 10 mnt, registrasi gagal ≥ 3, runner image > 21 hari di belakang rilis terbaru, memori CI > 90% limit), monitor push Kuma, label Loki `ci-runner` | infra-engineer | R5 | 1 j | 0 |
| R8 | Workflow drms (repo app, **sesi app**): cache lokal dengan kondisi `runner.environment`; buildx `driver: docker` + tanpa `type=gha` di self-hosted; tag rilis/`release-prod` `no-cache`; `GRADLE_OPTS`; unggah coverage hanya di GitHub-hosted | Next.js/app session | GATE 1 (paralel R1–R7) | 2 j | 0 |
| R9 | Aktivasi: owner set variabel repo `CI_RUNS_ON` = `["self-hosted","linux","x64","drms"]`. `DEPLOY_RUNS_ON` **tidak diset** (GATE Q6). Jalankan `workflow_dispatch` ci + mobile | **owner** + Lead | R5–R8 | 15 mnt | 0 |
| R10 | QA (§9) + uji rebutan: job APK/`docker build` berjalan sambil mengukur latensi `/api/v1/health` DRMS prod & Odoo `/web/health` | QA & Security | R9 | 2 j | 0 |
| R11 | Docs: `docs/03-operations/ci-runner.md` (operasi, rotasi PAT, update runner, reset cache), ADR 0014 → accepted, revisi ADR 0004 (§6), baris CLAUDE.md §3 CI/CD (butuh persetujuan user), runbook DRMS §11 catatan GHCR, CHANGELOG | Docs & Versioning | R10 | 1 j | — |

Paralel: {R0, R0b, R4, R8} → R1 → R2 → R3 → {R5, R6} → R7 → R9 → R10 → R11. **Total ±15–17 jam agen, kalender 2 hari**
(tergantung PAT owner + merge PR drms). **Downtime prod: 0** (R2 fallback ±2 s bila postinst memaksa restart).

## 9. Acceptance criteria (QA)

```
docker inspect ci-runner-* → Runtime=sysbox-runc, Privileged=false, NanoCpus=2e9, Memory=4g, MemorySwap=4g, PidsLimit=4096,
  CpuShares=256, OomScoreAdj=800, SecurityOpt ∋ no-new-privileges, Mounts HANYA /srv/ci/docker & /srv/ci/cache, tanpa PortBindings
di dalam job: id → uid=1001(runner); sudo -n true → gagal; ls /opt/infra /opt/src → tidak ada; test -S /var/run/docker.sock → socket dockerd DALAM
  (docker info Name ≠ srv2001692)
host: ps -o user,pid,cmd -C dockerd → dockerd dalam berjalan dengan uid host ≥ 100000 (userns sysbox), bukan 0
jangkauan dari job: curl 10.100.18.1:8443, nc -z 10.100.25.2 5432 (db-drms), curl 169.254.169.254 → gagal;
  curl -sI https://github.com → 200; curl https://drms-kas.bimacreative.tech/api/v1/health → 200 (hairpin publik saja)
ci.yml & mobile.yml (workflow_dispatch) di self-hosted → hijau: services postgres 127.0.0.1:5432, mailpit, semgrep/trivy/gitleaks/hadolint, build web+migrate, APK debug
ephemeral: setelah job → GET /repos/bctech-adm/drms/actions/runners tanpa runner offline sisa; container lama tidak ada; job berikut: docker ps -a (dalam) kosong, _work baru
2 job bersamaan → yang kedua queued sampai yang pertama selesai
PAT: grep -r "github_pat_" di container/log Loki/journal → 0; /etc/ci-runner/pat 600 root; ps tidak menampilkan JIT config
kuota: isi /srv/ci sampai penuh (dd di job) → job gagal ENOSPC, df / tidak berubah, layanan prod tetap sehat
OOM: alokasi > 4 GiB di job → hanya container CI di-kill (memory.events oom_kill container CI), tidak ada restart container prod
rebutan: selama build APK → p95 latensi health DRMS prod & Odoo naik < 2× baseline; tidak ada healthcheck prod unhealthy
monitoring: stop supervisor → alert < 15 mnt; /srv/ci > 85% (file dummy) → alert; log runner terlihat di Loki
dockerd host: StartedAt semua container prod sebelum = sesudah R2 (atau jendela ±2 s tercatat)
```

## 10. Risiko

| # | Risiko | Mitigasi |
|---|---|---|
| 1 | Escape kernel/sysbox dari job (dependency jahat) → root host prod | userns sysbox, NNP, tanpa privileged/socket host; `unattended-upgrades` kernel + sysbox dipantau rilis; pemicu pindah CI ke VPS-2 |
| 2 | Keracunan cache persisten → rilis tercemar | build rilis tanpa cache (§4), lockfile, digest pin, Trivy; reset `/srv/ci` total bila ragu (runbook) |
| 3 | Rebutan CPU/IO membuat prod lambat (4 vCPU, `wa` 23% teramati) | cpu weight rendah, `cpus 2`, `io.max`, 1 job; R10 mengukur. Bila gagal → jadwalkan job berat malam atau turunkan limit |
| 4 | Egress tanpa allowlist domain → eksfiltrasi secret job | secret job minimal (GITHUB_TOKEN `contents: read` default); drop private ranges; proxy allowlist = fase berikut |
| 5 | CI memicu CrowdSec/AppSec (mis. DAST ke host sendiri) → ban IP hairpin VPS → OIDC back-channel/hairpin semua container terganggu | tidak ada DAST ke host platform dari runner tanpa plan terpisah; cek `cscli decisions list` di R10 |
| 6 | Runner > 30 hari di belakang rilis → job tidak di-queue diam-diam | alert "image > 21 hari di belakang"; upgrade = bump digest + rebuild (±30 mnt); auto-update di container ephemeral dimatikan **[UNVERIFIED perilaku update mode JIT]** |
| 7 | PAT (Administration RW) bocor = repo bisa dihapus/diubah | hanya repo drms, root 600 + `LoadCredential`, tidak ke container/log, kedaluwarsa 180 hari, owner bisa revoke kapan saja |
| 8 | Sysbox tidak cocok dengan NNP daemon-wide/apparmor/`live-restore` | R0/R2 PoC; fallback opsi (c); uninstall bersih |
| 9 | Disk `/` naik lagi karena build lokal tetap jalan di dockerd host | aturan ADR 0004 §6 poin 2; alert 70%; R0b |
| 10 | Satu runner = job antre (verify, integration, security serial) → CI lebih lama (±2–3× wall time) **[ESTIMASI]** | diterima (gratis). Evaluasi setelah 1 minggu |
| 11 | Free plan: environment required reviewers tidak tersedia untuk repo private → deploy prod dari CI tanpa gerbang persetujuan | `DEPLOY_RUNS_ON` tidak diset, deploy prod tetap manual Lead (Q6) |

## 11. Rollback

- **Instan (tanpa ubah kode):** owner menghapus/mengosongkan variabel repo `CI_RUNS_ON` → workflow kembali ke `ubuntu-24.04`.
  Selama menit masih habis, CI GitHub-hosted gagal lagi. Itu kondisi awal dan dapat diterima.
- **Runner:** `systemctl disable --now ci-runner-supervisor` → `docker rm -f` container berlabel `ci-runner` → hapus runner via
  API/UI → owner **revoke PAT** → hapus `/etc/ci-runner`.
- **Data:** `umount /srv/ci` + hapus `disk.img` (destruktif atas data runner saja, konfirmasi) → ruang 40 GiB kembali.
- **Sysbox:** `apt remove sysbox-ce` (dan hapus runtime dari `daemon.json` via Ansible + SIGHUP). `bip`/`default-address-pools`
  boleh tetap (nilai identik). Network `ci-runner` + aturan `DOCKER-USER` dihapus via Ansible.
- **Docs/ADR:** ADR 0014 → rejected/superseded, revisi ADR 0004 dicatat.
- Tidak ada data prod yang disentuh. Tidak perlu backup (runner stateless, cache bisa dibangun ulang).

## 12. Pertanyaan GATE 1 (owner)

1. **Isolasi:** setuju **(b) sysbox** (komponen root baru di host, tanpa privileged, job tanpa akses FS/loopback host)?
   Fallback (c) user host + rootless Docker bila PoC gagal. *Rekomendasi: ya (b). (d) privileged ditolak.*
2. **Sentuhan dockerd:** R2 diupayakan tanpa restart. Bila postinst sysbox tetap memaksa restart, setuju **satu restart dockerd
   ±2 s** di jam sepi (container tetap hidup, `live-restore`)? *Rekomendasi: ya, dengan jendela yang diumumkan.*
3. **Kredensial ephemeral:** fine-grained PAT (repo `drms` saja, **Administration: read & write**, kedaluwarsa 180 hari) disimpan
   hanya di host root 600? Atau GitHub App (B), atau registrasi persisten tanpa PAT (C, tidak ephemeral)? *Rekomendasi: PAT (A).*
4. **Kapasitas:** setuju anggaran build/CI **2 vCPU / 4 GiB / 40 GiB disk**, prioritas terendah, 1 job sekaligus, revisi ADR 0004
   (§6), **dan** build image di dockerd host oleh sesi agent dihentikan setelah runner lulus QA? Setuju pembersihan image lama
   (R0b, daftar dikonfirmasi dulu)? *Rekomendasi: ya.*
5. **Image registry:** tetap GHCR (hanya tag rilis + staging terakhir, retensi, perampingan migrate) dan cek pemakaian di
   Billing. Registry lokal (plan 12b) hanya bila GHCR terblokir? *Rekomendasi: ya, GHCR dulu.*
6. **Deploy prod:** `DEPLOY_RUNS_ON` **tetap tidak diset** (deploy prod tetap manual Lead, runbook §11). Job yang memegang
   `DEPLOY_SSH_KEY` tidak jalan di runner yang juga menjalankan kode PR dengan cache bersama, dan Free plan tidak punya required
   reviewers untuk repo private. *Rekomendasi: ya, tetap tidak diset. Ditinjau lagi bersama infra-deploy v2.*

## 13. Aksi owner

1. Jawab GATE Q1–Q6.
2. Merge PR drms `ci/self-hosted-runner` (`fca2ef9`, sudah siap) dan PR lanjutan R8 dari sesi app.
3. Buat fine-grained PAT: *Settings → Developer settings → Fine-grained tokens → Generate*. Resource owner `bctech-adm`, Only
   select repositories = `drms`, Repository permissions → **Administration: Read and write** (Metadata: read otomatis), Expiration
   180 hari. **Owner sendiri** memasukkannya ke host lewat SSH: `sudo install -m 600 -o root -g root /dev/stdin /etc/ci-runner/pat`
   (tempel, Ctrl-D). Jangan lewat chat/issue.
4. Setelah QA hijau (R10): set variabel repo `CI_RUNS_ON` = `["self-hosted","linux","x64","drms"]` (*Settings → Secrets and
   variables → Actions → Variables*). `DEPLOY_RUNS_ON` jangan diset.
5. Cek *Settings → Billing → Usage* (penyimpanan Packages + artifact) untuk Q5. Pastikan *Actions → General → Fork pull request
   workflows* tidak aktif.
6. Pengingat kalender rotasi PAT (hari ke-170). Kuma/alert juga akan menyala bila registrasi gagal.
