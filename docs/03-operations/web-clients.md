# Operasional — Website client Next.js (`web-<slug>`, basis `web-starter`)

- **Onboarding / langkah lengkap:** `docs/runbooks/web-client-onboarding.md` (DNS, provision, form kontak, upgrade, rollback).
  Halaman ini = ringkasan operasional harian.
- **Terkait:** ADR 0007 (`docs/adr/0007-web-client-ui-stack.md`), plan 03 (`docs/plans/03-web-client-template.md`),
  `traefik.md` §Network web-edge, `crowdsec.md` (CRS 920420), `observability.md` (Uptime Kuma).
- **Repo aplikasi:** `web-starter` (`/opt/src/web-starter`, GitHub `BIma-Creative-Tech/web-starter`, private) → disalin menjadi
  `web-<slug>` per client. Image GHCR `ghcr.io/bima-creative-tech/web-<slug>` (sebelum 2026-10-18: `ghcr.io/bctech-adm/…` — org lama, tidak bisa di-push lagi): push `main` → `:sha-<12>`, tag `vX.Y.Z` → `:X.Y.Z`
  (tag harus = `version` di `package.json`).

## Di mana file berada

| Item | Path |
|---|---|
| Template (git) | `templates/web-client/` (`docker-compose.yml`, `docker-compose.contact.yml`, `docker-compose.turnstile.yml`, `docker-compose.umami.yml`, `.env.example`, `.gitignore`), `templates/traefik-web-client.yml` |
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
| `starter.staging.bimacreative.tech` | `staging/web-clients/starter/` (container `web-starter-staging`) | `ghcr.io/bima-creative-tech/web-starter:sha-9f36bd86f28e` (`@sha256:7d7ec2bb…`, main `9f36bd8`, next 16.3.8) | Demo plan 03. Sejak 2026-10-18 dari GHCR (TEMPORARY image lokal 2026-09-25 selesai; rollback lokal `web-starter:dev-d5f6148`). Tanpa contact/Umami/www; `mem_limit` 192m dipulihkan setelah render (§Upgrade, jebakan render ulang). |
| `expomedia.id` (+ `www` → 301) | `web/clients/expomedia/` (container `web-expomedia-prod`) | `web-expomedia:dev-8408d19` (lokal, repo `/opt/src/web-expomedia` branch `fix/deps-cve-2026-10` = v0.6.0 `033f5b1` + patch CVE next 16.3.8) | Client Expomedia Indo Karya (plan 07). **Mode coming soon** (`src/config/launch.ts`, host prod) sampai konten asli dikonfirmasi client; form kontak ON (SMTP `info@expomedia.id`). **TEMPORARY(2026-09-25):** image lokal (tanpa GHCR). **2026-10-18:** patch CVE; rollback `dev-033f5b1`. Commit `8408d19` hanya lokal — deploy key VPS ditolak GitHub (repo pindah org?), push setelah akses pulih. |
| `expomedia.staging.bimacreative.tech` | `staging/web-clients/expomedia/` (container `web-expomedia-staging`) | `web-expomedia:dev-8408d19` (lokal, sama dengan prod) | Website lengkap (konten PLACEHOLDER) untuk review client; form kontak ON + lead CRM ke `expomedia_staging` (plan 13). TEMPORARY sama dengan prod. **2026-10-18:** `.env` sebelumnya masih `dev-cc9ce18` (v0.5.0) sementara container jalan `dev-033f5b1` lewat override shell → `up -d` sempat turun ke v0.5.0 ±1 menit; `.env` kedua stack kini `dev-8408d19` (owner via `!`, backup `.env.bak-20261018`). Cek `docker compose up -d --dry-run` = Running sebelum deploy. |
| `erajaya-loyalty.staging.bimacreative.tech` | `staging/erajaya-loyalty/` (container `erajaya-staging-web`) — **bukan** template web-client | `erajaya-loyalty:<tag>` (lokal, repo `/opt/src/erajaya-loyalty`) | Next.js 16 + **Payload CMS 3 + Postgres** (portal member, `/admin`, API POS HMAC, cron expiry). Stack manual pola DRMS: edge sendiri `erajaya-edge-stg` (internal, tanpa egress), DB `erajaya_loyalty_stg` (`db-erajaya-stg`), 512m. **Disiapkan 2026-10-07, container belum dijalankan** — runbook `docs/runbooks/erajaya-loyalty-staging.md`. `OTP_DEV_MODE=true` (demo, TEMPORARY). |

Cek image yang sedang berjalan: `docker inspect -f '{{.Config.Image}}' web-<slug>-<env>`.

## Upgrade tag image

```
sudo /opt/infra/scripts/provision-web-client.sh <slug> <env> --host <fqdn> \
  --image ghcr.io/bima-creative-tech/web-<slug>:<tag-baru> [--www] [--contact …]
```

- Opsi lain **harus sama** dengan provision sebelumnya (`--www`/`--contact` yang terlewat akan dilepas).
- `latest` / tanpa tag ditolak skrip. Hanya `.env` berubah → container di-recreate (jeda singkat, satu replika); route
  identik → tanpa HUP Traefik.
- Catat tag baru di pesan commit infra / `provision_job` (`.env` tidak di git).
- Verifikasi: baris `RESULT … changed=yes`, lalu `curl -sI https://<fqdn>/ | grep -iE '^(HTTP|content-security|strict-transport)'`
  dan `docker stats --no-stream web-<slug>-<env>`.
- **Jebakan render ulang (2026-10-18):** skrip menyalin ulang `docker-compose*.yml` dari `templates/web-client/`. Override
  per stack yang di-commit (mis. `staging/web-clients/bct/docker-compose.yml` `mem_limit: 192m`, owner 2026-10-04) kembali ke
  template → setelah provision: `git checkout -- <dir>/docker-compose.yml && docker compose up -d`. File override yang belum
  pernah ada (mis. `docker-compose.odoo.yml`) ikut tersalin tanpa aktif; hapus bila tidak dipakai.
- Riwayat: bct staging + prod 2026-10-18 → `ghcr.io/bima-creative-tech/bct-website:sha-0aca342802ad`
  (`@sha256:cf391406…`, next 16.3.8/sharp 0.35.5; rollback `ghcr.io/bctech-adm/bct-website:0.2.0` masih ada lokal).

## Analytics Umami (opsional, plan 11 / ADR 0013)

- Flag berpasangan `--umami-script-url https://analytics.bimacreative.tech/insight.js --umami-website-id <uuid>` → `.env`
  `UMAMI_SCRIPT_URL`, `UMAMI_WEBSITE_ID` (bukan secret) + `docker-compose.umami.yml` di `COMPOSE_FILE` → container di-recreate.
  Hanya satu flag / URL bukan `https://…/<nama>.js` / UUID bukan huruf kecil → skrip menolak sebelum menulis apa pun.
- Tanpa flag → `.env` dan `COMPOSE_FILE` identik dengan sebelumnya (website lain tidak di-recreate; diuji: salinan stack
  `bct` staging + file override baru → `docker compose --dry-run up -d` = Running). Semua opsi lain tetap harus diulang.
- Aplikasi membaca env runtime (bukan `NEXT_PUBLIC_*`), merender `<script defer src=… data-website-id=… data-domains=<host>
  data-do-not-track="true" data-exclude-search="true" nonce=…>` dan menambah origin analytics ke `script-src`/`connect-src`
  (ADR 0007 §5). Image yang belum mendukung env ini mengabaikannya.
- Website ID per host/env di UI Umami (`analytics.md` §Akses admin). Mematikan: provision ulang tanpa kedua flag.

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
- HSTS mengikuti `security-headers` platform (saat ini `max-age=604800`; 31536000 mulai 2026-10-09 — `traefik.md` §HSTS bertahap).
- Sisa risiko: website di `web-edge` saling bisa menjangkau `:3000` (`traefik.md` §Network web-edge).
