# web/clients/ditled — Website Dit. LED "Jelajah" (deploy sementara)

Portal Direktorat Layanan Ekosistem Digital (Next.js 15 + Payload CMS 3), dihosting **sementara** di
`https://ditled.bimacreative.tech` sampai klien punya VPS sendiri. Dipasang 2026-10-09.

**Beda dari website client lain:** stack ini ditulis manual (pola `web/control-plane`), bukan dari
`scripts/provision-web-client.sh`, karena aplikasi stateful: CMS dengan basis data SQLite dan unggahan
di disk, dan butuh memori lebih besar (mem_limit 1g, template website statis 256m). Hardening tetap
sama: non-root 1001, rootfs read-only, cap_drop ALL, no-new-privileges, hanya network `web-edge`,
tanpa port publik, router Traefik `traefik/dynamic/clients/web-ditled-prod.yml`.

## Letak

| Apa | Di mana |
|---|---|
| Sumber aplikasi (untuk build image) | `/home/admin/src/led-website` (salinan, bukan git) |
| Data persisten: `dittel.db`, `media/`, `attachments/` | `/srv/ditled/data` (1001:1001, 0700) |
| Secret | `.env` di direktori ini (600 root): `PAYLOAD_SECRET`, `DITLED_TAG` |
| Admin CMS | `https://ditled.bimacreative.tech/admin` |

## Operasi

```bash
# status / log
docker compose -f /opt/infra/web/clients/ditled/docker-compose.yml ps
docker logs --tail 100 web-ditled-prod

# update aplikasi: salin sumber baru ke /home/admin/src/led-website, lalu
cd /home/admin/src/led-website
docker build --build-arg NEXT_PUBLIC_SERVER_URL=https://ditled.bimacreative.tech -t web-ditled:<tag-baru> .
sed -i 's/^DITLED_TAG=.*/DITLED_TAG=<tag-baru>/' /opt/infra/web/clients/ditled/.env
cd /opt/infra/web/clients/ditled && docker compose up -d      # rollback: kembalikan DITLED_TAG lama, up -d lagi

# backup data (DB + unggahan)
tar czf /root/ditled-data-$(date +%F).tgz -C /srv/ditled data

# pindah ke VPS klien: bawa /srv/ditled/data + sumber aplikasi; DATABASE_URI dan UPLOAD_DIR sama.
```

Subdomain ini di-set `NOINDEX=1` (robots Disallow + meta noindex). Saat pindah ke domain resmi, hapus env itu.

## Database: Postgres shared (sejak 2026-10-18)

- DB `ditled`, role pemilik `ditled` (postgres/scripts/init-roles.sh, password `PG_DITLED_PASSWORD` di postgres/.env),
  network `db-ditled` 10.100.30.0/24, baris pg_hba sendiri. `DATABASE_URI` ada di `.env` stack ini.
- Skema = migrasi Payload di repo aplikasi (`src/migrations`), dijalankan otomatis saat app start (prodMigrations).
  Perubahan field/koleksi WAJIB disertai migrasi baru (lihat `docs/deploy-postgres.md` di repo aplikasi).
- Isi awal disalin dari SQLite dengan `scripts/sqlite-to-postgres.mjs`: konten dari DB lokal pengembang,
  users/sessions/feedback/preferences dari `/srv/ditled/data/dittel.db`. File SQLite itu dibiarkan sebagai arsip.
- Backup: `docker exec postgres pg_dump -U postgres -Fc ditled > ditled.dump` + direktori `/srv/ditled/data`.
- Rollback ke image SQLite lama (`0.1.0-202610090059`) butuh `DATABASE_URI: file:/data/dittel.db` lagi di compose
  (data yang ditulis setelah 2026-10-18 tidak ikut).
- Pindah ke VPS Komdigi: `pg_dump`/`pg_restore` + salin media/attachments, runbook di `docs/deploy-postgres.md` repo aplikasi.
