# Risk acceptance — CVE tanpa perbaikan di image Postgres (QA-T17A-02)

- **Status:** accepted (user, 2026-09-23) · **Review:** bulanan, paling lambat 2026-10-23
- **Komponen:** `postgres:16.15-bookworm` (container `postgres`)
- **Temuan:** 16 CRITICAL (15 unfixed dari Debian: perl, zlib, sqlite, libxml2; 1 fixable pada
  Go stdlib di `gosu` yang tidak dipakai saat runtime), 99 HIGH — lihat `docs/qa/2026-09-23-t17a-platform-core.md`.

## Alasan diterima sementara
- Postgres tidak mem-publish port ke host; hanya terjangkau dari network docker `db` (`--internal`).
- `pg_hba` + `CONNECT` membatasi setiap role ke DB miliknya; superuser tidak bisa login via TCP.
- Paket rentan adalah pustaka OS di image, bukan jalur input jaringan Postgres yang terekspos.

## Kontrol & tindak lanjut
1. Setiap bulan: `trivy image --severity CRITICAL postgres:<tag>` dan cek tag patch/Debian terbaru;
   upgrade bila ada perbaikan (backup dulu — `docs/03-operations/backup.md`).
2. Pertimbangkan varian image lain (mis. alpine) hanya lewat ADR baru.
3. Acceptance gugur otomatis bila ada CVE yang dapat dieksploitasi lewat jaringan Postgres.
