# Risk acceptance — CVE fixable-upstream di Keycloak & CrowdSec (QA-T17A-01, QA-T17A-03)

- **Status:** accepted (user, 2026-09-23) · **Kedaluwarsa:** saat rilis patch tersedia ATAU 2026-10-31 (mana lebih dulu)
- **Keycloak** `26.7.4` (rilis 26.x terbaru per 2026-09-23, dicek quay.io): 3 CRITICAL / 3 HIGH fixable —
  netty-handler CVE-2026-75595 (bypass SslContext per-SNI), bcprov CVE-2026-8763 (bypass X.509 Name Constraints).
  Upstream: backport keycloak#52763, keycloak#52971.
- **CrowdSec** `v1.8.1` (rilis terbaru per 2026-09-23, dicek Docker Hub): 24 HIGH fixable (grpc, x/net, x/text, libssl3/libcrypto3).

## Alasan diterima sementara
- Keycloak hanya listen HTTP di network internal; TLS di-terminate Traefik → jalur SNI netty tidak dipakai.
  Autentikator X.509/mTLS tidak dikonfigurasi → jalur Name Constraints bcprov tidak dipakai.
- CrowdSec LAPI hanya 127.0.0.1 + network `crowdsec` internal (traefik saja); tidak terekspos publik.
- Tidak ada rilis resmi yang memperbaiki; nightly/patch jar/build dari source ditolak (stabilitas & supply chain).

## Kontrol & tindak lanjut
1. Pantau rilis Keycloak 26.7.5+ dan CrowdSec v1.8.2+ (minimal mingguan); upgrade + Trivy ulang saat tersedia.
2. Jangan mengaktifkan TLS langsung di Keycloak atau autentikator X.509 selama acceptance berlaku.
3. Gugur bila ada eksploit publik yang relevan dengan konfigurasi kita.

## Review 2026-10-17 (Lead, keputusan owner)
- **Keycloak: DITUTUP.** Live `infra/keycloak:26.7.5-optimized` (upgrade K11, commit 3028cf0). Trivy `aquasec/trivy:0.74.0`, `--scanners vuln --severity CRITICAL,HIGH`, DB 2026-10-17: 0 CRITICAL,
  7 HIGH fixable — `mssql-jdbc` CVE-2025-59250 (driver SQL Server, tidak dipakai; DB = Postgres) dan `pcre2` OS
  (CVE-2026-103111/86145/89161). CVE-2026-75595 (netty) dan CVE-2026-8763 (bcprov) **tidak lagi ada**. Upstream 26.8.1
  (2026-10-13): 0 CRITICAL/HIGH — upgrade minor 26.8 = rencana terpisah (staging dulu), tidak mendesak.
- **CrowdSec: tetap sampai 2026-10-31.** `v1.8.1`: 0 CRITICAL, 66 HIGH fixable / 2 unfixed (naik dari 24 karena DB
  Trivy). Upstream hanya `v1.8.2-rc1` (2026-10-13, pra-rilis — ditolak). LAPI tetap internal. Cek mingguan; upgrade
  begitu v1.8.2 stabil.
