# BCTOne self-serve — operasi (ADR 0019)

## Komponen

| Komponen | Di mana | Catatan |
|---|---|---|
| Siklus `self_serve`, kuota, pajak, ingest pemakaian | control-plane (`cp.`, `cp.staging.`) | migrasi `0006`, `0007`; endpoint `POST /api/bctone/usage` |
| Agen tenant | modul `sh_bct_tenant_agent` (odoo-addons-shared) | inert sampai `sh_bct_tenant_agent.enabled=1` |
| Konfigurasi tenant | job `bctone_tenant_config` → `scripts/bctone-tenant-config.sh` | install modul, file kunci, ICP kuota |

## Rahasia

- Master ingest per instance: `/etc/infra-jobs/bctone-usage-<prod|staging>.secret` (600 root:root, di luar git,
  32..4096 karakter ASCII cetak). Nilainya **sama** dengan `USAGE_INGEST_SECRET` di `.env` control-plane instance itu
  (`web/control-plane/.env`, `staging/control-plane/.env`).
- Kunci per tenant = HMAC-SHA256(master, `bctone-usage:<slug>`), ditulis skrip ke
  `<pool>/secrets/oidc/bct-usage.<db>` (0440 root:101). Modul membacanya lewat `$SH_OIDC_SECRET_DIR` yang sudah di-mount.
- Rotasi master: tulis file baru + `.env` CP → `docker compose up -d` CP → jalankan ulang `bctone_tenant_config` untuk
  setiap tenant BCTOne (file kunci ditulis ulang). Selama jeda, kiriman pemakaian ditolak 401 (tidak ada data hilang:
  kiriman berikutnya membawa akumulasi bulan berjalan).

## Mengaktifkan (sekali per instance, staging dulu)

```bash
umask 077
head -c 48 /dev/urandom | base64 | tr -d '\n=' > /etc/infra-jobs/bctone-usage-staging.secret
chown root:root /etc/infra-jobs/bctone-usage-staging.secret && chmod 600 /etc/infra-jobs/bctone-usage-staging.secret
# salin nilai yang sama ke staging/control-plane/.env sebagai USAGE_INGEST_SECRET=…, lalu:
cd /opt/infra/staging/control-plane && docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://cp.staging.bimacreative.tech/api/bctone/usage   # 401 (bukan 404)
```

Lalu tambahkan `bctone_tenant_config` ke `infra_jobs_job_types.<inst>` (`ansible/group_vars/all.yml`) dan jalankan role
`infra_jobs` (dispatcher ≥ 1.3.0 terpasang di `/usr/local/sbin/infra-job`).

## Uji manual satu tenant (staging)

```bash
scripts/bctone-tenant-config.sh <slug> staging --plan bctone-free --limit users=1 --limit trx_per_month=300 --dry-run
scripts/bctone-tenant-config.sh <slug> staging --plan bctone-free --limit users=1 --limit trx_per_month=300
docker exec -i odoo-staging odoo shell -c /etc/odoo/odoo.conf -d <db> --no-http --workers=0 --max-cron-threads=0 \
  <<< "print(env['sh.bct.tenant.agent']._push_usage())"   # → stored
```

## Menonaktifkan / rollback

- Satu tenant: job `bctone_tenant_config` dengan `enabled=false` (`--disable`): ICP `enabled=0`, file kunci dihapus.
  Modul tetap ter-install tetapi inert.
- Semua: kosongkan `USAGE_INGEST_SECRET` di CP (endpoint 404). Tenant tetap berjalan; kiriman gagal tercatat WARNING.
