# Risk acceptance — CVE tanpa perbaikan di image Postgres (QA-T17A-02)

- **Status:** accepted (user, 2026-09-23) · **Review:** bulanan — terakhir 2026-10-17, berikutnya paling lambat **2026-11-17**
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

## Review 2026-10-17 (Lead, keputusan owner "Ya, sekarang")
- Tag `postgres:16.15-bookworm` di-rebuild upstream 2026-10-06 (PostgreSQL tetap `16.15-1.pgdg12+2`, hanya paket Debian).
  Trivy `aquasec/trivy:0.74.0`, `--scanners vuln --severity CRITICAL,HIGH`, DB 2026-10-17: digest lama `efedf359…` CRITICAL 13 fixable / 3 unfixed, HIGH 41 / 71 → digest baru `0ea6700a…` CRITICAL
  **1** fixable (Go stdlib di `gosu`, tidak dipakai saat runtime) / 3 unfixed (zlib CVE-2023-45853, sqlite CVE-2025-7458,
  libxml2 CVE-2026-6653), HIGH 24 / 71.
- Diterapkan 2026-10-17 12:53 WIB: backup penuh `backup.sh run` (snapshot `699fbc25`, 13 DB ok, remote ok) →
  compose digest baru → `docker compose up -d postgres` (healthy 22 s termasuk stop) → `docker update --cpu-shares 10240`
  (tier prod; compose tidak memuat nilai ini). Klien tersambung ulang: DRMS prod/stg, Keycloak, Odoo (worker yang
  terputus saat shutdown di-respawn), CP; `control-plane-staging-worker` keluar lalu di-restart otomatis (healthy).
- Acceptance diperpanjang untuk 3 CRITICAL unfixed + HIGH unfixed (alasan & kontrol di atas tetap berlaku).
