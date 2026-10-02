# SaaS — log progres

Append per sesi, bertanggal. Pertanyaan pemblokir selalu di bagian **Butuh keputusan** paling atas.

---

## Butuh keputusan

### Mendesak (sebelum Minggu 2026-10-04 03:00)

- **K1 — Lepas stale lock restic.** Restore-test 2026-10-01 GAGAL di `restic check` karena lock basi (PID 435014,
  2026-09-27 14:30, proses sudah tidak ada — diverifikasi). `restic-prune` Minggu 03:00 kemungkinan ikut gagal.
  Usulan: `restic unlock` (hanya menghapus lock basi; tidak menyentuh snapshot) lalu jalankan ulang
  `restic-restore-test.service`. Tidak menyentuh komponen yang di-freeze. **Boleh dikerjakan sebelum demo selesai?**
- **K2 — Hold job CI drms selama jendela demo?** `ci-runner-job` bisa memakai 5 GiB (jumlah `mem_limit` host sudah
  19,2 GiB vs RAM 15 GiB). Usulan: `systemctl stop ci-runner-supervisor` selama demo, start lagi sesudahnya.
  Ini perubahan → hanya bila disetujui.

### Setelah demo / freeze dicabut

- **K3 — Repo tanpa remote dan tanpa backup**: `web-expomedia` (situs live), `odoo-data-expomedia`, `web-tambang`,
  `proyekkas-private`; `odoo-addons-athera`/`-expomedia` hanya aman sampai commit yang di-pin submodule infra.
  `/opt/src` tidak masuk restic. Pilihan: (a) buat repo di GitHub `bctech-adm` dan push; (b) tambah `/opt/src` ke
  cakupan restic; (c) keduanya (rekomendasi).
- **K4 — Pembersihan disk** (daftar persis: `saas-inventory.md` §11): `docker rmi` 21 image + `builder prune
  --filter until=72h` (≈ 54 %); opsional `docker volume prune` anonim (3,4 GB), scratchpad Claude > 3 hari (7,7 GB),
  cache trivy & versi CLI lama (2,4 GB) → ≈ 46–48 %. **Jangan** `image prune -a` apa adanya (menghapus image datamart).
- **K5 — Image prod drms tanpa tag** (`42682f7f2d09` = seharusnya `proyekkas-web:0.4.1`) dan rollback
  `proyekkas-*:0.3.0` → tag ulang / pin sebelum ada prune rutin.
- **K6 — DMARC `expomedia.id`** → `p=quarantine; pct=25` (record siap di inventaris §11.8; diubah owner di DNS).

### Arsitektur (memblokir Fase 1)

- **K7 — Eksekutor job (D1).** Brief: worker CP mengeksekusi job dengan kredensial `cp-admin`. Kondisi nyata + ADR
  0009: CP sengaja tanpa secret/Docker; eksekusi oleh dispatcher root ter-allowlist. **Rekomendasi: pertahankan ADR
  0009** — job baru ditambahkan ke dispatcher; `cp-admin` hidup di host.
- **K8 — Client OIDC Odoo (D2).** Brief: satu client `odoo` + verifikasi `tenant_id`. Kondisi nyata: satu client per
  tenant-env (ADR 0008), isolasi fail-closed. **Rekomendasi: pertahankan per tenant-env**, `tenant_id` sebagai lapisan
  kedua.
- **K9 — Nama role (D3).** Pakai role CP yang ada (`superadmin/ops/client_admin/client_user`) dengan label UI
  platform-admin/platform-viewer/tenant-admin/tenant-user, atau buat realm role baru sesuai brief? **Rekomendasi:
  pakai yang ada.**
- **K10 — Cakupan gate Fase 1.** Brief §2a mewajibkan "seluruh baris tabel" di gate Fase 1, tetapi job domain/router
  (`traefik.router.write`, `dns.verify`) dijadwalkan Fase 2 dan mail di Fase 4. **Rekomendasi: baris "domain sendiri"
  dan "mailbox" diuji di gate Fase 2/4**; Fase 1 menyediakan data domain + checklist saja.

### Pertanyaan terbuka brief §9 (belum dijawab)

- **Q1** Brand domain subdomain tenant. Fakta: saat ini `<slug>.erp.bimacreative.tech` (prod) dan
  `<slug>.staging.bimacreative.tech`; dispatcher hanya mengizinkan dua pola ini. Tetap, atau domain brand Athera/BCT baru?
- **Q2** Mail saat suspended: terima-saja (rekomendasi) atau nonaktif penuh?
- **Q3** Site web saat suspended: tetap tayang (rekomendasi) atau halaman ditangguhkan?
- **Q4** Paket awal (`plan`): kode, layanan, limit, harga.
- **Q5** Penerima & alamat pengirim email tagihan.
- **Q6** DB demo (`demo_demo`, `demo_staging`, `ssotest_staging`): hapus atau jadikan tenant uji? Rekomendasi:
  `demo` jadi tenant uji Fase 1, `ssotest_staging` dihapus setelah Fase 1.
- **Q11** Kapan freeze demo dicabut (tanggal/jam)?

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
