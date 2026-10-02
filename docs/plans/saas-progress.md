# SaaS — log progres

Append per sesi, bertanggal. Pertanyaan pemblokir selalu di bagian **Butuh keputusan** paling atas.

---

## Butuh keputusan

- **K3 (owner, HARI INI)** — buat 5 repo **private** kosong di `bctech-adm`: `web-expomedia`, `odoo-data-expomedia`,
  `odoo-addons-athera`, `odoo-addons-expomedia`, `web-tambang`; **nonaktifkan Actions** dulu (web-expomedia/web-tambang punya
  `ci.yml` yang langsung jalan saat push tag/branch); pasang deploy key **write** (public key di laporan sesi; file
  `~/.ssh/deploy_<repo>.pub` root di host). Setelah itu Claude menjalankan push semua branch + tag.
- **K3 pengecualian** — `proyekkas-private` **TIDAK** di-push: bukan repo git dan berisi keystore Android
  `proyekkas-staging.jks` + **password-nya dalam file teks**, `pseudonym-map.md`, bundle history pra-publik. Diamankan lewat
  restic (`/opt/src`, branch `feat/backup-opt-src`). Konfirmasi owner bahwa ini diterima.
- **Q5 (sisa)** — alamat email billing internal untuk pengingat tagihan.
- **Review ADR** — `0017-identity-organizations.md`, `0018-tenant-lifecycle-billing.md`, amandemen `0009` (status proposed).
- **FREEZE** — berlaku sampai owner menulis "FREEZE DICABUT". Setelah itu: K2 start ulang CI runner, K4–K5, apply K3 restic,
  W0–W8.

## Keputusan owner (2026-10-02)

| # | Keputusan | Status pelaksanaan |
|---|---|---|
| K1 | `restic unlock` + ulang restore-test | **selesai** 23:03 — lock basi dihapus; `restic check` **ok**; `db_compare=failed` (lihat log sesi) |
| K2 | stop `ci-runner-supervisor` selama demo, start saat freeze dicabut | **selesai** — supervisor stop, container job idle ikut berhenti |
| K3 | repo privat GitHub + push semua branch/tag hari ini; `/opt/src` ke restic (apply setelah freeze) | sebagian — key/remote siap, menunggu repo dibuat owner; restic di branch belum di-merge |
| K4 | setelah freeze: hapus 21 image per `repo:tag` tanpa `-f` (pre-check daftar ID/tag, keluarkan yang dipakai container/compose/.env + 4 basis), `builder prune --filter until=72h`, `volume prune` anonim (lampirkan `volume ls -f dangling=true` sebelum/sesudah); §11.3 TIDAK; `docker-host-gc.timer` via Ansible dry-run dulu | menunggu freeze |
| K5 | tag ulang `42682f7f2d09` → `proyekkas-web:0.4.1`; pin `proyekkas-*:0.3.0` | menunggu freeze |
| K6 | owner ubah DMARC `expomedia.id` → `p=quarantine; pct=25` setelah demo; **ingatkan seminggu kemudian** untuk hapus `pct` | menunggu owner (pengingat: 7 hari setelah owner mengonfirmasi perubahan DNS) |
| K7–K10 | ADR 0009 tetap; client OIDC per tenant-env; role CP yang ada + label; domain/mailbox di gate Fase 2/4 | dimasukkan ke ADR 0017/0018/0009 |
| §13 | usulan 1–8 disetujui; #6 (mart bersama + RLS) diputuskan di plan Fase 3 | — |
| Q1 | Fase 1 tetap `<slug>.erp.bimacreative.tech` / `<slug>.staging.bimacreative.tech`; pola host = parameter inventory Fase 5 | — |
| Q2/Q3 | mail suspended = terima-saja (kirim mati); web suspended = tetap tayang | ADR 0018 D6 |
| Q4 | plan awal 7 kode, harga nullable | ADR 0018 D7 |
| Q5 | pengirim `noreply@bimacreative.tech`; penerima tenant-admin + billing internal; staging → Mailpit | ADR 0018 D8 (alamat billing belum) |
| Q6 | `ssotest_staging` hapus setelah Fase 1 lulus (dump dulu); `demo_staging` tenant uji; `demo_demo` dipertahankan | ADR 0018 D10 |
| Q11 | freeze berlaku sampai owner menulis "FREEZE DICABUT" | — |
| Fase 1 | draft disetujui dengan syarat S1 → ADR 0017 sebelum W2#2, dan `users` prod kosong terjawab di W3 | W1 selesai (draft ADR) |

---

## 2026-10-02 — Fase 0 (inventaris, read-only)

**Berubah**
- Repo infra: `docs/plans/saas-inventory.md`, `docs/plans/saas-phase-1.md`, `docs/plans/saas-progress.md`
  (branch `docs/saas-phase0`, merge ke `main`). Tidak ada perubahan konfigurasi/host/container.
- Sebelumnya di sesi yang sama (bukan bagian brief): kebijakan izin Claude Code `.claude/hooks/bash-policy.sh` +
  `.claude/settings.json` (commit `56e22b2`, `a4cc439`; merge `a479e2c`, `0050678`).

**Diperiksa / hasil**
- Inventaris §3.1 butir 1–9 selesai; asumsi A1–A9 dijawab (`saas-inventory.md` §12): A2/A3/A1 sebagian, A5 & A8
  salah (Organizations sudah tersedia; dump per DB sudah ada), A4/A6/A7/A9 benar.
- OOM 2026-09-28: container ci-runner-job (build APK Flutter, limit 4 GiB), sudah diperbaiki `1673916` (5 GiB).
- `vm.swappiness` sudah 10.
- Ditemukan: restore-test restic gagal (stale lock), repo tanpa remote/backup, image prod drms tanpa tag, tabel
  `users` prod kosong (penyebab belum terverifikasi), ADR 0014 usang (4g).

**Belum (menunggu freeze dicabut / keputusan)**
- Pekerjaan rumah §3.2 yang menghapus/mengubah (K1–K6).
- Gate Fase 0 "disk < 50 %" belum terpenuhi (62 %); proyeksi setelah K4 ≈ 46–48 %.
- Rencana Fase 1 menunggu persetujuan + K7–K10 + Q1/Q4/Q5.

## 2026-10-02 (malam) — keputusan owner Fase 0 → Fase 1

**Berubah**
- Host (disetujui K1/K2): `restic unlock` repo lokal (1 lock basi PID 435014 dihapus; tanpa `--remove-all`);
  `restic-restore-test.service` dijalankan ulang; `ci-runner-supervisor.service` di-stop (container `ci-runner-job` idle ikut
  berhenti; `ci-runner-supervisor.path` tetap aktif — hanya memicu bila `/etc/ci-runner/pat` berubah; unit `enabled` → akan
  hidup lagi bila host reboot).
- Host (K3 persiapan): 5 deploy key ed25519 `~/.ssh/deploy_<repo>` + alias `github-<repo>` di `~/.ssh/config` (backup
  `config.bak-*`), remote `origin` ditambahkan di 5 repo `/opt/src`. Belum ada push (repo GitHub belum ada).
- Repo infra: fix hook `bash-policy.sh` (deteksi push paksa per segmen, 89 kasus; merge `94c2c7e`); branch
  `feat/backup-opt-src` (`9a3ce82`, **belum di-merge**): `restic_extra_paths: [/opt/src]` + exclude build/dependensi
  (±200 MB); ADR 0017, ADR 0018, amandemen ADR 0009; status plan Fase 1.

**Diuji / hasil**
- `restic check --read-data-subset=1/5`: **no errors** (masalah lock selesai). Filestore restore sha256 ok, RTO 60 s.
- `db_compare=failed` untuk `expomedia_prod`: snapshot 01:30 vs DB **live**; sejak 01:30 ada **5 modul baru** + 368 baris
  `ir_module_module` ter-update (deploy plan 19 ke prod hari ini) → perbedaan jumlah tabel/modul **diharapkan**, bukan
  kerusakan backup. Kelemahan desain uji: membandingkan dengan DB live. Usulan (setelah freeze): simpan statistik DB
  (`db_stats`) saat backup sebagai snapshot kecil dan bandingkan restore dengan statistik itu. Uji ulang otomatis berikutnya
  2026-11-01; bisa dijalankan manual setelah backup 01:30 berikutnya bila owner mau bukti hijau sebelum itu.
- gitleaks seluruh history 5 repo yang akan dipush: **no leaks found**.

**Belum**
- Push K3 (menunggu repo + deploy key dari owner).
- Spike S1, W0, W2–W8 (menunggu "FREEZE DICABUT").
