# ADR 0013 — Web analytics self-hosted: Umami di `analytics.bimacreative.tech`

- **Status:** accepted (GATE 1 plan 11, 2026-09-27)
- **Tanggal:** 2026-09-27
- **Penulis:** Analyst
- **Terkait:** ADR 0001 (stack/lisensi), ADR 0002 (TLS HTTP-01, DNS manual), ADR 0004 (kapasitas), ADR 0006 (backup),
  ADR 0007 (web client, CSP nonce), ADR 0010 (network per konsumen); plan 11; CLAUDE.md §0.10, §3, §3.5, §3.6.

## Context

1. Owner ingin statistik pengunjung website client (pertama `bimacreative.tech`, repo `bct-website`) tanpa Google Analytics
   dan tanpa cookie. `bct-website` sudah mengantisipasi Umami di CSP (`lib/csp.ts`, `NEXT_PUBLIC_UMAMI_SRC`) tetapi belum
   merender skrip, dan nilainya build-time (tidak cocok satu image untuk staging & prod).
2. CLAUDE.md §0.10: tool baru wajib lisensi terbuka, aktif (< 6 bulan), dipakai luas, alasan di ADR; §3 tabel stack hanya
   berubah dengan ADR + persetujuan user.
3. Fakta Umami (dibaca 2026-09-27, detail + sumber di plan 11 §2.2): MIT; v3.4.0 rilis 2026-09-17, rilis rutin; image resmi
   `ghcr.io/umami-software/umami:3.4.0@sha256:85909afc…2f367`; PostgreSQL saja (≥ 12.14); migrasi Prisma otomatis saat
   start; uid 1001; tanpa cookie, IP tidak disimpan; **tanpa OIDC/SSO**; tanpa retensi otomatis; `POST /api/send` JSON +
   CORS `*`.
4. Anggaran RAM perencanaan ADR 0004 sudah minus sebelum permintaan ini (plan 11 §6).

## Decision (usulan)

1. **Umami 3.4.0 (MIT)** sebagai web analytics platform, satu instance untuk semua website client (satu "website" Umami per
   host/env), image resmi pin tag + digest, tanpa build sendiri.
2. **Data di Postgres shared**, DB `umami`, satu role owner `umami` (`CONNECTION LIMIT 10`), network `db-umami`
   `10.100.28.0/24` `--internal` + baris `pg_hba` per subnet (ADR 0010). Bukan Postgres dedicated.
3. **Edge:** network `analytics-edge` `10.100.17.0/24` `--internal` (Traefik + Umami; Umami tanpa egress,
   `PRIVATE_MODE`/`DISABLE_TELEMETRY`/`DISABLE_UPDATES`). Di :443 hanya router skrip tracker (`GET/HEAD /<nama>.js`) dan
   `POST/OPTIONS /api/send` (crowdsec+AppSec, header, rate limit per IP); UI/API admin **hanya** entrypoint `admin` (:8443,
   loopback, SSH tunnel) + `ipallowlist-admin` — pola H5. Login lokal Umami + 2FA (Umami OSS tidak mendukung OIDC; proxy auth
   = tool baru, tidak dipilih).
4. **Integrasi website:** env runtime tetap `UMAMI_SCRIPT_URL` + `UMAMI_WEBSITE_ID` (berpasangan), dirender app dengan nonce
   CSP (ADR 0007 §5); template infra memakai override `docker-compose.umami.yml` + flag `provision-web-client.sh` (opsional,
   default off, backward compatible).
5. Tambahan baris CLAUDE.md §3: "Web analytics | Umami 3.x (MIT) | self-hosted, DB Postgres shared, UI admin via :8443".

## Alternatives

| Opsi | Alasan tidak dipilih |
|---|---|
| Google Analytics / layanan SaaS | data keluar ke pihak ketiga, cookie + banner consent, bertentangan dengan permintaan owner |
| Plausible CE (AGPL-3) | butuh ClickHouse (RAM jauh lebih besar dari anggaran yang sudah minus) |
| Matomo (GPL-3) | PHP + MySQL/MariaDB (stack DB baru), cookie default, lebih berat |
| Umami + Postgres dedicated | +128–256 MiB dan path backup/patch baru tanpa kebutuhan isolasi nyata |
| Umami UI publik di :443 + login lokal | permukaan serangan login publik tanpa SSO/allowlist; tidak ada kebutuhan akses publik |

## Consequences

- +1 container (256 MiB limit), +1 DB, +2 network, +1 hostname sertifikat. Backup otomatis (daftar DB dinamis ADR 0006).
- `sum(rolconnlimit)` 186 → 196 dari 197 slot efektif; DB berikutnya kemungkinan butuh `max_connections` naik.
- Upgrade Umami = migrasi DB maju otomatis → wajib `pg_dump` sebelum upgrade; rollback = restore, bukan hanya image.
- Client melihat statistik hanya lewat admin (share link = keputusan terpisah).

## Security implications

Endpoint beacon publik tanpa autentikasi (bawaan analytics): data palsu mungkin → rate limit/isbot/CrowdSec. FP AppSec pada
beacon dapat mem-ban pengunjung di semua host HTTP → uji wajib (plan 11 AC-11). Container tanpa egress, rootfs read-only,
non-root, DB terisolasi per subnet. Tidak ada cookie di domain client; IP tidak disimpan (pseudonim) — catatan UU PDP plan 11 §5.

## Rollback

Plan 11 §9: hapus router + HUP, `compose down`, cabut flag di website; `DROP DATABASE umami` hanya dengan konfirmasi user.
