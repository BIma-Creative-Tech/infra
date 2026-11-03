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

## Status prod (2026-11-02, GATE 2 "deploy prod")

Kode CP `9b7b979` (migrasi `0008`-`0010`) dan modul `sh_bct_tenant_agent` (gitlink `64f8a8a`) sudah terpasang di prod,
tetapi **pendaftaran self-serve masih mati**: `BCTONE_REGISTER_ENABLED` tidak diisi di `web/control-plane/.env`
→ `/daftar` 404. Endpoint `POST /api/bctone/usage` juga 404 (`USAGE_INGEST_SECRET` kosong) dan gateway AI 404
(`AI_*` kosong), sama seperti perilaku lama.

Sebelum membuka self-serve di prod, selesaikan berurutan:
1. ✅ (2026-11-02) `USAGE_INGEST_SECRET` + `/etc/infra-jobs/bctone-usage-prod.secret` (lihat bagian Rahasia), lalu
   `compose up -d` → `POST https://cp.<domain>/api/bctone/usage` = 401.
2. ✅ (2026-11-02) `bctone_tenant_config` ke `job_types` `/etc/infra-jobs/prod.conf` **dan** `INFRA_JOBS_TYPES` compose
   prod, lalu role `infra_jobs` (`/opt/ansible-venv/bin/ansible-playbook site.yml --tags infra_jobs`).
3. ✅ (2026-11-03) SMTP worker prod → `mail.bimacreative.tech:587` (no-reply@), uji AUTH 235 + kirim `status=sent`
   (§Email prod). Catatan: MX iCloud/Amazon SES inbound tidak terjangkau :25 dari VPS (mail.md §Antrean macet).
4. ✅ (2026-11-03, CP `952fa48`; tautan langkah akun `890efa9`) `/syarat` + `/privasi` (DRAF operasional, tinjauan hukum owner menyusul) dan rekening
   Mandiri default (`src/lib/company.ts`; `PAYMENT_INSTRUCTIONS` hanya override).
5. Host tenant prod = `<slug>.erp.bimacreative.tech` (wildcard `*.erp` sudah ada) → **tidak** butuh DNS `*.one` untuk
   pendaftaran. `one`/`*.one` (marketing + web profil, v2.1 D-3) menyusul bersama web marketing.
6. ✅ (2026-11-03) Pendaftaran prod DIBUKA: `BCTONE_REGISTER_ENABLED: "1"` + `BCTONE_CAPACITY: "15"` di `environment`
   web `web/control-plane/docker-compose.yml` → `docker compose up -d web` → `/daftar` 200. Menutup lagi: ubah ke `"0"`
   lalu `up -d web` (pendaftar yang sedang provisioning tetap diproses worker).

## Email prod (2026-11-03)

Worker CP prod mengirim lewat `mail.bimacreative.tech:587` (login/From `no-reply@bimacreative.tech`), network
`cp-mail-egress` 10.100.43.0/24 (worker saja). Secret (sekali):
```bash
cd /opt/infra/web/control-plane && sudo install -d -m 0700 secrets
sudo install -o 950 -g 950 -m 0400 /opt/infra/mail/secrets/no-reply@bimacreative.tech.password secrets/smtp_password.secret
sudo docker compose up -d worker
sudo docker logs --since 1m control-plane-worker | grep -ci "nonaktif"   # 0
```
Rollback: hapus blok SMTP_*/secrets/cp-mail-egress di compose → `docker compose up -d worker` (email nonaktif lagi).
