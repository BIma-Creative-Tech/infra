# ADR 0016 — Data mart: ingest per tenant → dbt → mart ber-RLS → dashboard control-plane

- **Status:** accepted (keputusan user 2026-09-29: dashboard Expomedia di Next.js berbasis data mart dari Postgres Odoo;
  "jalankan hingga deployment, review di akhir")
- **Tanggal:** 2026-09-29
- **Terkait:** CLAUDE.md §3 (tabel stack: data mart), §3.1, §3.3, §3.5; ADR 0001 (pin dbt), ADR 0004 (kapasitas: dbt
  384 MiB transien), ADR 0006 (backup `datamart`), ADR 0010 (network per konsumen, `db-datamart` 10.100.27.0/24);
  plan 14.

## Context

1. CLAUDE.md §3.3 sudah menetapkan arsitekturnya, tetapi pipeline belum pernah dibangun (plan 02: "ditunda sampai ada
   client nyata"):
   - Next.js tidak pernah membaca DB Odoo;
   - alurnya `raw_<slug>` → dbt `stg_*` → `mart_*`, RLS per `client_slug`, `SET LOCAL app.client`.
   - Keadaan saat ini: DB `datamart` kosong, role `datamart` (owner, CONNECTION LIMIT 10) ada, `postgres_fdw`/`dblink`
     tersedia tetapi belum terpasang.
2. Client pertama: Expomedia (`expomedia_staging`; prod menyusul). Owner/Finance melihat nilai SPK; PM hanya status
   (fit-gap `docs/clients/expomedia-fitgap.md`).
3. Batasan terukur:
   - jumlah `CONNECTION LIMIT` role = 196 dari `max_connections` 200 (plan 11 R4); menaikkannya berarti recreate
     postgres;
   - `postgres_fdw` butuh superuser untuk extension, role baca di setiap DB Odoo, `ALTER DEFAULT PRIVILEGES` dari
     role pool, dan baris pg_hba loopback (sekarang `local all all reject`);
   - build image di host dilarang (ADR 0004 §9, build lewat CI);
   - image resmi `ghcr.io/dbt-labs/dbt-postgres` hanya sampai 1.9.0 (2024-12, root, 883 MB) — diverifikasi di registry
     2026-09-29.

## Decision

1. **Ingest = `COPY` terjadwal oleh root di host, bukan FDW.**
   - `datamart/ingest.sh <slug> <env>` menjalankan `docker exec postgres psql -U postgres` (peer, sama seperti
     `backup.sh`) di DB `<slug>_<env>`, lalu `\copy (SELECT <kolom eksplisit>) TO STDOUT`, lalu memuatnya ke schema
     `raw_<slug>_<env>` di `datamart`. Semua dalam **satu transaksi per tenant** (`TRUNCATE` + `COPY`), sehingga
     pembaca tidak pernah melihat raw setengah jadi.
   - Kolom dipilih eksplisit di `datamart/ingest/<slug>.sql`. Tidak ada `SELECT *`, dan tidak ada data pribadi di luar
     nama tampilan (tanpa NIK/NPWP/alamat/telepon/email). Ini **minimisasi data untuk UU PDP**.
   - Akibatnya tidak perlu extension, role baru di DB Odoo, perubahan pg_hba loopback, maupun slot koneksi permanen.
2. **Transform = dbt-core 1.12.5 + dbt-postgres 1.11.0** (pin ADR 0001, kompatibilitasnya kini **terverifikasi**
   dengan `pip download` → 59 paket, lisensi Apache-2.0).
   - Dijalankan di image resmi `python:3.12-slim-bookworm@sha256:392307d2…564e` dengan paket yang dipasang
     `--require-hashes --target` ke `datamart/pylib/` (di luar git, mount ro; pola yang sama dengan ADR 0015).
   - Tanpa build image. User non-root (65534), read-only rootfs, network `db-datamart` saja, `mem_limit 384m`.
3. **Mart = tabel dbt (`materialized='table'`, swap atomik) di schema `mart`.** Setiap tabel punya kolom
   `client_slug` + `env`.
   - Post-hook dbt menjalankan `ENABLE`/`FORCE ROW LEVEL SECURITY` + policy
     `client_slug = current_setting('app.client', true)`, plus `GRANT SELECT` ke `datamart_reader`.
   - Karena tabel dibuat ulang setiap run, policy juga dibuat ulang setiap run. Tes dbt memeriksa policy tersebut.
4. **Jadwal:** systemd timer `datamart-refresh.timer` setiap **30 menit** (ingest semua tenant, lalu `dbt build`).
   Hasilnya ditulis ke journald dengan baris `RESULT`.
5. **Pembaca:** role `datamart_reader` (LOGIN, `CONNECTION LIMIT 5`, `NOBYPASSRLS`), hanya `SELECT` di schema `mart`.
   - Slot koneksi tidak bertambah: limit role `datamart` diturunkan 10 → 5 (dbt memakai ≤ 4 thread), jadi totalnya
     tetap 196. **Tidak ada restart postgres.**
   - pg_hba: `datamart_reader` hanya dari `db-cp` 10.100.23.0/24 dan `db-cp-stg` 10.100.24.0/24.
6. **Dashboard di control-plane**, bukan app baru (§3.1 `web/control-plane # … portal + dashboard`; hemat RAM).
   - Otorisasi bisnis mengikuti **grup Odoo**. `mart.user_access` memetakan Keycloak `sub` (= `res_users.oauth_uid`) ke
     `can_see_value` (anggota efektif `sales_team.group_sale_salesman`), dengan Odoo sebagai sumber tunggal.
   - Control-plane menjalankan query nilai hanya bila `can_see_value`. Isolasi antar-client dijamin RLS.
7. **Staging & prod berbagi satu DB `datamart`**, dibedakan kolom `env`. Control-plane staging hanya membaca
   `env='staging'` dan prod hanya `env='prod'` (env var `DATAMART_ENV`).

## Consequences

- Data dashboard terlambat ≤ 30 menit (ditampilkan "diperbarui <waktu>").
- Setiap kolom baru harus ditambahkan ke `ingest/<slug>.sql` + model stg. Upgrade Odoo yang mengubah skema tabel sumber
  bisa membuat ingest gagal. Kegagalan ditangani dengan `RESULT status=fail` + alert, dan mart lama tetap tersedia.
- Raw memuat data staging dan prod (untuk Expomedia hanya nama & nilai SPK). Backup `datamart` sudah ikut
  (`backup.sh` mencakup semua DB).
- Beban: `COPY` beberapa ribu baris per tenant per 30 menit (dapat diabaikan); dbt ±30–60 detik, ≤ 384 MiB transien
  (sudah dianggarkan di ADR 0004).
- Rollback: `systemctl disable --now datamart-refresh.timer`; `DROP SCHEMA mart, raw_* CASCADE` (DB `datamart`
  tidak dipakai layanan lain); hapus env `DATAMART_URL` dari control-plane (dashboard kembali "Belum ada data").
