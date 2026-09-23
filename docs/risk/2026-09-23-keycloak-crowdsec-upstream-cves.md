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
