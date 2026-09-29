# ADR 0015 — Modul platform Athera (`addons/platform`) di pool Odoo bersama

- **Status:** accepted (keputusan user 2026-09-29, sesi plan 13)
- **Tanggal:** 2026-09-29
- **Terkait:** ADR 0001 (image dipin), ADR 0003 (tanpa OCA), ADR 0004 (kapasitas), CLAUDE.md §3.2; plan 13;
  repo `/opt/src/odoo-addons-athera`; `docs/03-operations/odoo.md` §Addons platform.

## Context

1. Tenant `expomedia` (PT Expomedia Indo Karya, kontraktor booth/event) membutuhkan alur penawaran → SPK → produksi →
   absensi → payroll → dashboard → akuntansi. Modulnya sudah dibuat owner sebagai paket Athera (arsip
   `addons-full-20260928T231052Z.tar.gz`, ±200 modul Odoo 19 CE, prefix `custom_*`, LGPL-3), bukan modul per client
   `cl_<slug>_*` maupun modul `sh_*` di `odoo-addons-shared`.
2. Arsip memuat hal yang tidak boleh berada di pool bersama: data klien lain (`_tenants/*`: saldo awal, register aset),
   modul dengan akses SSH/Docker (`control_plane/*`), internal (`operations/*`), vertical lain, fixture demo, `.git`.
3. Pool memakai image resmi, root FS read-only; `httpx` dan `xmlschema` (dependensi `custom_ai_bridge`, `custom_coretax`)
   tidak ada di image `odoo:19.0-20260908`.
4. Semua modul di `addons_path` terlihat oleh setiap DB di pool (`odoo.md` §Keamanan).

## Decision

1. **Kategori ketiga addons:** `addons/platform` = git submodule `odoo-addons-athera` (subset terkurasi arsip, isi modul
   identik byte-per-byte, tanpa patch), dipin SHA/tag yang sama di `staging/odoo` dan `odoo/pool-a`. `addons_path` =
   `shared,platform,clients/*`. Isi repo = closure dependensi dari daftar root yang disetujui user
   (`tools/closure.py --check` wajib lulus).
2. **Dilarang masuk `platform`:** `_tenants/*`, `control_plane/*` (termasuk yang menariknya: `custom_hht_bridge`,
   `custom_athera_sso`), `operations/*`, `custom_demo_seed`, `_vendor/*` (OCA — ADR 0003), dan data seed klien lain.
   SSO tenant tetap `sh_auth_oidc` (ADR 0008).
3. **Dependensi Python tanpa image turunan:** wheel pure-Python dipin ber-hash di `requirements.txt` repo platform,
   dipasang `tools/build-pylib.sh` (`pip --target --no-deps --require-hashes`, dijalankan dengan image pool yang sama) ke
   `<pool>/pylib/` (di luar git), mount ro `/mnt/extra-python`, env `PYTHONPATH`. Paket yang sudah ada di image
   (certifi, idna, typing_extensions, lxml, cryptography) tidak di-vendor agar tidak menimpa versi sistem.
4. **Pool bersama, bukan dedicated** (keputusan user): modul platform terlihat oleh tenant lain di pool (demo, ssotest);
   modul hanya aktif di DB yang meng-install-nya. Pemicu pindah ke dedicated tetap ADR 0004 §6.
5. Per tenant: `custom_ai.enabled = False` (gateway AI `AI_GATEWAY_URL` tidak ada di platform) sampai ada ADR gateway AI.

## Consequences

- Upgrade modul platform = bump submodule di staging → `-u <modul>` per DB → QA → pool-a (runbook `odoo.md`).
- Restart pool saat pertama menambah path (`addons_path` dibaca saat start). Modul baru di path yang sama cukup `-i`.
- Tes upstream belum hijau penuh di DB kosong (plan 13 §5: 9 gagal + 23 error dari 669) — dilacak, bukan pemblokir.
- Build pylib butuh akses PyPI saat build; runtime tidak.
- Repo platform saat ini lokal (`/opt/src/odoo-addons-athera`, URL submodule path lokal seperti preseden
  `odoo-addons-shared`); ganti ke remote GitHub dengan `git submodule set-url` setelah owner membuat repo.
