# Operasional — Website client Next.js (`web-<slug>`, basis `web-starter`)

- **Onboarding / langkah lengkap:** `docs/runbooks/web-client-onboarding.md` (DNS, provision, form kontak, upgrade, rollback).
  Halaman ini = ringkasan operasional harian.
- **Terkait:** ADR 0007 (`docs/adr/0007-web-client-ui-stack.md`), plan 03 (`docs/plans/03-web-client-template.md`),
  `traefik.md` §Network web-edge, `crowdsec.md` (CRS 920420), `observability.md` (Uptime Kuma).
- **Repo aplikasi:** `web-starter` (`/opt/src/web-starter`, GitHub `bctech-adm/web-starter`, private) → disalin menjadi
  `web-<slug>` per client. Image GHCR `ghcr.io/bctech-adm/web-<slug>`: push `main` → `:sha-<12>`, tag `vX.Y.Z` → `:X.Y.Z`
  (tag harus = `version` di `package.json`).

## Di mana file berada

| Item | Path |
|---|---|
| Template (git) | `templates/web-client/` (`docker-compose.yml`, `docker-compose.contact.yml`, `.env.example`, `.gitignore`), `templates/traefik-web-client.yml` |
| Skrip | `scripts/provision-web-client.sh`, `scripts/lib/traefik-route.sh` |
| Stack prod | `web/clients/<slug>/` |
| Stack staging | `staging/web-clients/<slug>/` |
| `.env` (tanpa secret, 600 root, **tidak** di git) | `<stack>/.env` — `WEB_IMAGE`, `SITE_URL`, `CONTACT_ENABLED`, … |
| Password SMTP (opsional, tidak di git) | `<stack>/secrets/smtp_password.secret` (1001:1001, 0400) |
| Router Traefik | `traefik/dynamic/clients/web-<slug>-<env>.yml` |

Nama container = project compose = router = `web-<slug>-<env>`; hanya network `web-edge`, tanpa port publik; limit 256m / 0.5 CPU.

## Website yang berjalan

| Host | Stack | Image | Catatan |
|---|---|---|---|
| `starter.staging.bimacreative.tech` | `staging/web-clients/starter/` (container `web-starter-staging`) | `web-starter:dev-d5f6148` (lokal) | Demo plan 03. **TEMPORARY(2026-09-25):** image dibangun lokal di VPS karena VPS belum punya token baca GHCR (menunggu user). Setelah token ada dan tag `v0.1.0` di-push + CI hijau: `docker login ghcr.io` lalu upgrade ke `ghcr.io/bctech-adm/web-starter:0.1.0` (§Upgrade) |

Cek image yang sedang berjalan: `docker inspect -f '{{.Config.Image}}' web-<slug>-<env>`.

## Upgrade tag image

```
sudo /opt/infra/scripts/provision-web-client.sh <slug> <env> --host <fqdn> \
  --image ghcr.io/bctech-adm/web-<slug>:<tag-baru> [--www] [--contact …]
```

- Opsi lain **harus sama** dengan provision sebelumnya (`--www`/`--contact` yang terlewat akan dilepas).
- `latest` / tanpa tag ditolak skrip. Hanya `.env` berubah → container di-recreate (jeda singkat, satu replika); route
  identik → tanpa HUP Traefik.
- Catat tag baru di pesan commit infra / `provision_job` (`.env` tidak di git).
- Verifikasi: baris `RESULT … changed=yes`, lalu `curl -sI https://<fqdn>/ | grep -iE '^(HTTP|content-security|strict-transport)'`
  dan `docker stats --no-stream web-<slug>-<env>`.

## Rollback

- **Image:** jalankan ulang perintah upgrade dengan tag lama (tag lama tetap di GHCR; untuk image lokal: `docker image ls web-starter`).
- **Lepas website:** `sudo /opt/infra/scripts/provision-web-client.sh <slug> <env> --remove` (hapus route + HUP, `compose down`
  tanpa `-v`, direktori dipertahankan dengan penanda `.removed`).
- Detail: runbook §5.

## Monitoring

- Healthcheck container: `GET /api/health` (`docker inspect -f '{{.State.Health.Status}}' web-<slug>-<env>`).
- Uptime Kuma: tambahkan monitor HTTP `https://<fqdn>/api/health` — skrip provision **tidak** membuat monitor
  (lihat runbook §3 dan `observability.md`).
- Log: `docker logs --tail 100 web-<slug>-<env>`; Alloy mengumpulkan log json-file semua container ke Loki (`observability.md` §Log) — belum diverifikasi khusus untuk container website.
- 403 tak terduga pada POST → cek CrowdSec AppSec (`crowdsec.md`): gunakan Route Handler, bukan Server Action `text/plain`.

## Catatan keamanan

- CSP dikirim aplikasi (nonce + `strict-dynamic`; `style-src 'unsafe-inline'` disetujui user) — ADR 0007 §5.
- HSTS mengikuti `security-headers` platform (saat ini `max-age=300`).
- Sisa risiko: website di `web-edge` saling bisa menjangkau `:3000` (`traefik.md` §Network web-edge).
