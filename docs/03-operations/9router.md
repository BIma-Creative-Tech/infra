# 9Router — operasional (ADR 0019)

AI router/proxy (OpenAI/Anthropic/Gemini-compatible) di `https://9router.bimacreative.tech`. Sumber stack: `ai/9router/`;
**live: `/opt/9router`** (compose, `.env`, `data/`).

| Item | Nilai |
|---|---|
| Image | `decolua/9router:0.5.104@sha256:5fc7020f…bbc27` (MIT) |
| Resource | 0.5 CPU, 512 MiB (tanpa swap), 128 pids |
| Network | `9router-edge` 10.100.40.0/24 `--internal` (Traefik ↔ app) + `9router_default` (egress provider) |
| Publik :443 | `/v1*`, `/v1beta*` saja — router `ninerouter-api` (`traefik/dynamic/platform/9router.yml`) |
| Admin :8443 | dashboard + `/api/*` — `ninerouter-admin`, `ninerouter-admin-login` + `ipallowlist-admin` |
| Secrets | `/opt/9router/.env` (600 root): `INITIAL_PASSWORD`, `JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT` |

## Pasang dari nol

1. DNS A `9router` → `31.97.50.221` (tanpa AAAA); cek `dig +short 9router.bimacreative.tech A @1.1.1.1` dan `@8.8.8.8`.
2. `traefik/scripts/bootstrap.sh` (membuat `9router-edge`) → `docker network connect 9router-edge traefik` (atau recreate
   Traefik dengan compose repo).
3. `install -d /opt/9router/data && cp ai/9router/{docker-compose.yml,gen-env.sh,sqlite-snapshot.sh} /opt/9router/`;
   `/opt/9router/gen-env.sh` (tidak menimpa `.env` yang ada, tidak mencetak isi); `cd /opt/9router && docker compose up -d`.
4. CrowdSec AppSec (§ di bawah) **sebelum** router, lalu router: file sudah di `traefik/dynamic/platform/` →
   `docker exec traefik kill -HUP 1`.
5. Backup: `install -D -m 644 ai/9router/systemd/9router-sqlite.conf /etc/systemd/system/restic-backup.service.d/9router-sqlite.conf`
   → `systemctl daemon-reload`; role `backup` (group_vars sudah memuat path + exclude).

## Akses dashboard

**Sejak 2026-10-19 (amandemen ADR 0019):** `https://9router.bimacreative.tech` → "Masuk dengan SSO Bima Creative" →
Keycloak realm `platform`. Hanya pemegang client role `9router.access` (saat ini `am.ademaryadi@gmail.com`) yang lolos;
user lain "Access denied". Tambah/cabut akses: client `9router` → Roles → `access` → assign/unassign user (atau ubah
`ALLOWED_EMAIL` di `ai/9router/keycloak/provision-9router-sso.sh`, yang menolak bila pemegang ≠ email itu).
Login password 9router dimatikan (`authMode=oidc`). Pulihkan mode password bila Keycloak bermasalah: jalur :8443 di
bawah tetap hidup, tetapi login tetap SSO — hapus kunci `authMode` di tabel `settings` (`data/db/data.sqlite`) lalu
`docker compose restart` (password = `INITIAL_PASSWORD`).

Jalur cadangan (SSH tunnel, router admin):

```bash
ssh -p 2221 -L 8443:127.0.0.1:8443 admin@31.97.50.221
# /etc/hosts laptop: 127.0.0.1 9router.bimacreative.tech  → https://9router.bimacreative.tech:8443
```
Login pertama: `INITIAL_PASSWORD` dari `.env` → ganti di dashboard. Klien AI memakai base URL
`https://9router.bimacreative.tech/v1` + API key buatan dashboard.

## CrowdSec AppSec

`security/crowdsec/appsec-configs/9router-crs-exclusions.yaml` + baris `local/9router-crs-exclusions` di
`acquis.d/appsec.yaml`. Terapkan (±10 s 403 fail-closed di semua router ber-`crowdsec`):
```bash
L=/opt/infra/security/crowdsec
install -m 0644 -o root -g root $L/appsec-configs/9router-crs-exclusions.yaml $L/data/config/appsec-configs/
docker exec crowdsec kill -HUP 1
docker exec crowdsec cscli appsec-configs list | grep 9router   # enabled,local
```
Diverifikasi 2026-10-19 (key uji tidak valid → 401 = sampai app): prompt SQL/`<script>`/`/etc/passwd`/PHP 403 → 401;
kontrol negatif tetap 403: SQLi di query `GET /v1/models`, POST SQLi ke `cp.bimacreative.tech`.
Rollback: hapus file di `data/config/appsec-configs/` + baris acquis → HUP.

## Backup & restore

- restic `files`: `/opt/9router` (via `restic_extra_paths`), exclude `/opt/9router/data/db` (SQLite live).
- `ExecStartPre=-/opt/9router/sqlite-snapshot.sh` (drop-in) → `data/snapshot/data.sqlite`, satu file mandiri
  (`journal_mode=DELETE`, `integrity_check` = ok). Gagal tidak membatalkan backup platform: `journalctl -t 9router-snapshot`.
- Restore: `docker compose stop` → pulihkan `/opt/9router` dari restic → `cp data/snapshot/data.sqlite data/db/data.sqlite`,
  hapus `data/db/data.sqlite-{wal,shm}` → `docker compose up -d`.

## Upgrade

Tag + digest baru (`curl -s "https://hub.docker.com/v2/repositories/decolua/9router/tags?page_size=5&ordering=last_updated"`)
di `ai/9router/docker-compose.yml` → salin ke `/opt/9router` → `docker compose pull && docker compose up -d`. Cek ulang:
rewrite `/v1*` di `/app/.next/routes-manifest.json`, `curl -s -o /dev/null -w '%{http_code}' https://9router.bimacreative.tech/v1/models`
= 401, `/` = 404, snapshot SQLite jalan.

## Rollback total

`rm traefik/dynamic/platform/9router.yml && docker exec traefik kill -HUP 1`; `cd /opt/9router && docker compose down`;
`docker network disconnect 9router-edge traefik && docker network rm 9router-edge`; hapus exclusion AppSec (di atas) dan
drop-in systemd (`daemon-reload`).
