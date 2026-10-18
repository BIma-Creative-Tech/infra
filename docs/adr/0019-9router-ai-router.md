# ADR 0019 — AI router self-hosted: 9Router di `9router.bimacreative.tech`

- **Status:** accepted (permintaan user 2026-10-19, terpasang live di hari yang sama)
- **Tanggal:** 2026-10-19
- **Penulis:** Lead
- **Terkait:** ADR 0001 (stack/lisensi), ADR 0002 (TLS HTTP-01, DNS manual), ADR 0006 (backup), ADR 0010 (network per
  konsumen), ADR 0013 (pola paparan H5 Umami); CLAUDE.md §0.10, §3.

## Context

1. User meminta 9Router (router/proxy API LLM dengan dashboard) dipasang di VPS dengan Docker, resource dibatasi agar tidak
   mengganggu DRMS/Odoo/web client, lalu diakses lewat subdomain `9router.bimacreative.tech`.
2. Fakta 9Router (dibaca 2026-10-19 dari github.com/decolua/9router + Docker Hub `decolua/9router`): lisensi **MIT**; rilis
   rutin (0.5.95 → 0.5.104 dalam 2 minggu); image multi-arch, tag versi tersedia (README hanya menyebut `latest`); Next.js
   16, port `20128`, data SQLite di `DATA_DIR` (`/app/data/db/data.sqlite`, mode WAL); entrypoint `chown` lalu `su-exec node`.
3. Butuh **egress** ke provider AI (OpenAI, Anthropic, Gemini, dsb.), berbeda dari Umami/webmail yang tanpa egress.
4. Body request = prompt LLM bebas (kode, SQL, HTML, path) → OWASP CRS di CrowdSec AppSec memblok 403 (diuji: prompt berisi
   `SELECT … OR 1=1`, `<script>`, `cat /etc/passwd` = 403; prompt biasa = 401 dari app).

## Decision

1. **9Router 0.5.104 (MIT)**, image resmi pin tag + digest
   `decolua/9router:0.5.104@sha256:5fc7020f3cf1ca6831bffe80314ecab9dde915d27ee3c479a4bb66f45dabbc27`, tanpa build sendiri.
   Stack `ai/9router/` di repo; **live di `/opt/9router`** (di luar checkout `/opt/infra`, ikut restic lewat
   `restic_extra_paths`).
2. **Resource:** `cpus: 0.5`, `mem_limit`/`memswap_limit: 512m`, `pids_limit: 128`, `blkio weight 100`, `cap_drop: ALL`
   + `CHOWN/SETUID/SETGID/FOWNER` (kebutuhan entrypoint), `no-new-privileges`. Idle ±60 MiB.
3. **Edge:** network `9router-edge` `10.100.40.0/24` `--internal` (Traefik + 9router) — blok baru di luar edge 0–19 (penuh)
   dan cadangan `db-*` 20–39. Egress lewat network default compose (`9router_default`). Tanpa port host.
4. **Paparan (pola H5):** :443 hanya `/v1`, `/v1/*`, `/v1beta`, `/v1beta/*` (rute API LLM; rewrite Next.js → `/api/v1*`),
   `REQUIRE_API_KEY=true` (tanpa key = 401). Dashboard + seluruh `/api` admin hanya entrypoint `admin` (:8443, SSH tunnel)
   + `ipallowlist-admin`; login `POST /api/auth/*` + `ratelimit-login`. `AUTH_COOKIE_SECURE=true`.
5. **AppSec:** `local/9router-crs-exclusions` — HANYA tag CRS isi (`attack-sqli/-xss/-lfi/-rfi/-rce/-injection-php`) untuk
   in-band `POST` host persis `9router.bimacreative.tech` path `/v1/*`/`/v1beta/*`. CRS lain (protokol, method, scanner,
   934 generic/ssrf), vpatch dan generic rules tetap aktif. Disetujui user (opsi 1) 2026-10-19.
6. **Backup:** `/opt/9router` utuh (termasuk `.env`: `API_KEY_SECRET`/`JWT_SECRET` wajib agar API key valid setelah
   restore); SQLite live (`data/db`) di-exclude, diganti snapshot konsisten `data/snapshot/data.sqlite` (online backup API
   `better-sqlite3` + `integrity_check`) yang dibuat `ExecStartPre=-` drop-in `restic-backup.service`.

## Alternatives

| Opsi | Alasan tidak dipilih |
|---|---|
| Dashboard publik di :443 | Panel admin memegang kredensial provider AI; konvensi platform H5 = admin hanya :8443 |
| Tanpa CrowdSec di router API | Kehilangan vpatch/rule protokol; pengecualian per tag lebih sempit |
| Edge non-internal (egress lewat edge) | Traefik ↔ app tidak butuh egress; egress cukup di network default app |
| Salin SQLite hidup apa adanya | Hanya konsisten crash-level (WAL); snapshot API murah (±170 KB) |

## Consequences

- Satu container lagi (±60–512 MiB). Upgrade = ganti tag + digest di `ai/9router/docker-compose.yml`, salin ke
  `/opt/9router`, `docker compose up -d`; cek ulang rute `/v1*` (rewrite) dan nama tabel tetap.
- Prompt yang memicu CRS 934 (mis. kode Node.js `child_process`) masih bisa 403 — perluas tag hanya dari bukti access log.
- Drop-in systemd belum dikelola role Ansible `backup` (file sumber `ai/9router/systemd/9router-sqlite.conf`).
