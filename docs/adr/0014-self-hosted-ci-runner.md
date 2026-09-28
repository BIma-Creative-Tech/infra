# ADR 0014 — Self-hosted GitHub Actions runner (ephemeral, sysbox) untuk `bctech-adm/drms`

- **Status:** accepted (2026-09-28, owner GATE 1)
- **Tanggal:** 2026-09-28
- **Penulis:** Analyst
- **Terkait:** plan 12 (`docs/plans/12-gh-runner-drms.md`, fakta + sumber §2), ADR 0001 (lisensi), ADR 0004 (kapasitas),
  ADR 0010 (network), runbook DRMS prod §11; CLAUDE.md §0.9, §0.10, §3 (CI/CD), §3.5, §3.6, §3.7.

## Context

1. Akun owner `bctech-adm` (akun User, GitHub Free) kehabisan menit Actions. Job CI repo private `drms` gagal dalam 2 s.
   Runner self-hosted tidak memakai menit (docs billing, 2026-09-28).
2. Job drms butuh Docker di netns/fs yang sama dengan langkah job: `services` postgres dipakai via `127.0.0.1:5432`, mailpit
   `-p 127.0.0.1`, `docker run -v $PWD`, Trivy mount `docker.sock`, `docker build`. Build APK butuh Flutter + Android SDK.
3. Host = VPS prod tunggal: 4 vCPU, 16 GB, tanpa KVM (microVM tidak mungkin). Docker 29.8.1 cgroup v2, NNP daemon-wide,
   `live-restore`. Anggaran RAM ADR 0004 sudah minus (Σ limit 14 768 MiB), IO disk sudah jadi titik rebutan.
4. Socket Docker host = root host. `privileged: true` dilarang (CLAUDE.md §0.9).
5. Sysbox (Apache-2.0, v0.7.1 2026-07-31, aktif, Docker Inc.) menjalankan dockerd di dalam container tanpa privileged
   (userns). Ubuntu 24.04/kernel 6.8 didukung. Harus jalan sebagai root di host.

## Decision (usulan)

1. **Satu runner tingkat repo** untuk `drms`, label `self-hosted, linux, x64, drms`, **ephemeral via JIT config** per job. Dipilih
   lewat variabel repo `CI_RUNS_ON`. `DEPLOY_RUNS_ON` tidak diset (deploy prod tidak di runner ini).
2. **Isolasi: container runner dengan runtime `sysbox-runc`**, dockerd bagian dalam, tanpa socket host, tanpa privileged, NNP,
   uid job 1001. Container dibuat baru per job. Image `FROM ghcr.io/actions/actions-runner:<versi>@sha256:<digest>` (resmi, MIT),
   dibangun lokal dan di-pin.
3. **Kredensial:** supervisor root di host membuat JIT config memakai fine-grained PAT (hanya repo `drms`, Administration RW,
   180 hari) dari `LoadCredential` (file 600 root). PAT tidak pernah masuk container. Token registrasi UI 1 jam tidak disimpan.
4. **Resource:** 1 job sekaligus. `cpus 2`, `cpu_shares 256`, `mem_limit 4g` tanpa swap, `pids 4096`, `oom_score_adj 800`, `io.max`
   di device loop. Data runner hanya di `/srv/ci` (ext4 di loop file 40 GiB tetap). Cleanup hanya atas data runner.
5. **Network** `ci-runner` 10.100.18.0/24 (bukan internal, tanpa publish) + `DOCKER-USER` drop ke rentang privat/link-local.
   Allowlist domain tidak ditegakkan (CDN), dicatat sebagai risiko.
6. **Update:** runner di-pin, upgrade ≤ 21 hari setelah rilis (batas GitHub 30 hari), dengan alert.
7. **Pengecualian §3.5 yang dicatat:** container runner tanpa `read_only`/`cap_drop: ALL` (dockerd dalam butuh root-palsu di
   userns). Kompensasinya userns sysbox, NNP, tanpa mount host selain `/srv/ci`, dan limit keras.
8. Tambahan baris CLAUDE.md §3 CI/CD (butuh persetujuan user): "Runner self-hosted ephemeral (sysbox) untuk repo terpilih, 1 job,
   anggaran build/CI 2 vCPU/4 GiB/40 GiB".

## Alternatives

| Opsi | Alasan tidak dipilih |
|---|---|
| DinD `--privileged` | container privileged = root host (semua device & capability, tanpa seccomp/apparmor); melanggar §0.9 |
| Runner + sidecar `docker:dind-rootless` | image tetap butuh `--privileged`. Netns/fs terpisah mematahkan `127.0.0.1:5432`, bind `$PWD`, `docker.sock` |
| Mount socket Docker host ke runner | setara root host dan bisa menyentuh semua container prod |
| User host khusus + rootless Docker | tanpa komponen root baru dan tanpa sentuh dockerd, tetapi job jalan di FS/netns host: bisa membaca `/opt/src` (755) dan cmdline proses, menjangkau `127.0.0.1:8443`. Butuh sandbox systemd + nftables per uid + profil AppArmor (`apparmor_restrict_unprivileged_userns=1`), dan workspace tidak segar. **Fallback** bila PoC sysbox gagal |
| microVM (Firecracker/Kata) | tidak ada `/dev/kvm` |
| Registrasi persisten (tanpa PAT) | kredensial runner terbaca job → job jahat bisa membajak job berikut. GitHub menyarankan ephemeral |
| Tetap GitHub-hosted (bayar menit) | keputusan owner 2026-09-28: tidak |
| CI di VPS terpisah | isolasi terbaik, tetapi biaya/host baru; tetap jalur lanjutan (ADR 0004 §6) |

## Consequences

- (+) CI drms jalan tanpa menit GitHub dan tanpa mengubah langkah workflow (hanya `runs-on` + cache lokal).
- (+) Build image yang tadinya tak terbatas di dockerd host pindah ke anggaran tetap (CPU/RAM/IO/disk). Syaratnya build lokal oleh
  sesi agent dihentikan (revisi ADR 0004).
- (−) Komponen root baru (sysbox-mgr/fs) + runtime baru di dockerd prod. 40 GiB disk dialokasikan tetap.
- (−) Aturan perencanaan RAM ADR 0004 makin minus (−5,3 GiB berdasarkan batas atas). Diterima sebagai kategori "build/CI" yang
  jadi korban OOM pertama.
- (−) Job antre (1 runner), CI lebih lama. Operasi baru: rotasi PAT, upgrade runner ≤ 21 hari, reset cache.
- (−) Penyimpanan GitHub Free 500 MB (artifact + GHCR) tetap terbatas. Registry lokal = keputusan terpisah (plan 12 §7).

## Security implications

Job menjalankan kode repo dan dependensinya **di host prod**. Batasnya kernel + userns sysbox (bukan VM). Escape = root host.
Job bisa membaca secret yang diberikan ke job itu, memakai egress internet, dan meracuni cache bersama. Karena itu: build rilis
tanpa cache, digest pin, Trivy, tidak ada deploy prod dari runner, dan PAT tetap di luar container. Lisensi: sysbox Apache-2.0,
actions/runner MIT (§0.10: aktif, dipakai luas). STRIDE + AC di plan 12 §4, §9.

## Rollback

Hapus variabel `CI_RUNS_ON` (instan). Hentikan supervisor, hapus runner + revoke PAT, `umount /srv/ci` + hapus loop file (data
runner saja), `apt remove sysbox-ce` + hapus runtime dari `daemon.json` (SIGHUP). Detail di plan 12 §11.
