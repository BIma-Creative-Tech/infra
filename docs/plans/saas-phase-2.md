# SaaS Fase 2 — Provisioning Odoo + Traefik (job, template dedicated, domain kustom)

Status 2026-10-03: **DRAFT (Lead) — menunggu persetujuan owner + Q1–Q10**. Belum ada kode. Prasyarat: gate Fase 1 lulus di
staging dan "FREEZE DICABUT" (urutan wajib brief §6: 0 → 1 → 2). Dasar: brief §2a, §5.3, §5.4, §6 (Fase 2), §6a M7; owner K10
(baris §2a "domain sendiri" masuk gate Fase 2); `saas-inventory.md`; kontrak `saas-phase-1-contract.md` v1.2 (dispatcher 1.2.0);
ADR 0002/0003/0004/0006/0009/0010/0015; `saas-migration-prod.md` (M7 brief dipindah ke sini). Prinsip sama dengan Fase 1:
perluas yang ada; eksekusi lewat dispatcher root (ADR 0009); tipe baru hanya di `staging.conf job_types` sampai disetujui.

## 1. Tujuan & batas

**IN**: job `odoo_instance_ensure`, `odoo_module_install`, `odoo_db_backup`, `traefik_router_write`, `dns_verify`,
`monitor_ensure`; perluasan `odoo_db_provision`/`odoo_route`/`odoo_sso_*` untuk host domain kustom terverifikasi + instance
di-resolve host-side; template dedicated `odoo/<slug>` (prod) dan `staging/odoo-<slug>` + **ADR 0019**; generator route
deterministik `scripts/route-gen.py` (header `# GENERATED`) + migrasi M7 (dry-run diff 18 file); domain kustom (K10): UI →
checklist → `dns_verify` → router (+ redirect URI SSO + monitor), `dns_verify` harian; backup per tenant (`odoo_db_backup`,
volume filestore dinamis) + uji restore SATU DB tenant; amandemen ADR 0002/0003/0004/0006/0009/0010.

**OUT**: DKIM otomatis & job mail (Fase 4); web/Payload (Fase 4; generator hanya merender `web` untuk migrasi header); pindah
tenant pool → dedicated (plan sendiri); upgrade/uninstall modul; VPS-2 (Fase 5); semua langkah prod (plan migrasi prod).

## 2. Keputusan desain (ringkas)

| # | Keputusan | Alasan |
|---|---|---|
| D1 | Nama snake_case: `odoo.db.create`=`odoo_db_provision` (ada), `odoo.db.install`=`odoo_module_install`, `odoo.db.backup`=`odoo_db_backup`, suspend/resume = Fase 1, `odoo.instance.create`=`odoo_instance_ensure`, `traefik.router.write`=`traefik_router_write`, `dns.verify`=`dns_verify`, `monitor.add`=`monitor_ensure` | konvensi kontrak |
| D2 | `dns_verify` = job dispatcher (worker CP hanya di network `--internal`, tanpa egress DNS); jadwal harian dari pg-boss CP, eksekusi di host | ADR 0009; host sudah memakai `dig` |
| D3 | Host kustom masuk dispatcher **hanya lewat registry host-side** `/var/lib/infra-jobs/<inst>/domains/<fqdn>.json` (root 0600), ditulis `dns-verify.sh` setelah TXT `_platform-verify.<fqdn>` = token; ikatan pertama per slug; lepas hanya `release` (ditolak bila host masih di route) | CP tertembus tidak bisa membajak host tenant lain tanpa kontrol DNS |
| D4 | Domain kustom lama (`erp.expomedia.id`, `demo-erp.expomedia.id`, …) didaftarkan operator (`--seed-from-routes`, `method=operator`) | tidak ada token TXT historis |
| D5 | Cek per purpose (odoo/web/insight: A = IP platform, tanpa AAAA; mail: MX/SPF/DKIM/DMARC; sso: tanpa DNS); cek harian tidak pernah menghapus router — gagal → `domains.status=failed` + email ops | ACME rate limit + downtime lebih buruk |
| D6 | IP hard-coded (`lib/traefik-route.sh`) → `/opt/infra/config/platform.env` (`PLATFORM_PUBLIC_IPV4`) | persiapan VPS-2 |
| D7 | `route-gen.py` (kind `odoo` host + ≤ 4 alias dalam satu file → suspend menutup alias; `redirect`; `web` render saja); tulis hanya bila beda → HUP; `render-client-route.sh` jadi pembungkus | brief §5.3; alias manual tidak ikut suspend sekarang |
| D8 | State suspend dipertahankan host-side; `traefik_router_write` tidak pernah mengubah state — **perbaikan awal sudah di Fase 1** (`9078ee2`: render ulang mempertahankan suspended kecuali `--resume`) | render ulang = resume diam-diam (temuan) |
| D9 | Semua `dynamic/clients/*.yml` berbaris-1 `# GENERATED` atau `# MANUAL`; `route-gen.py --check` melaporkan drift | brief §6a M7 |
| D10 | Template dedicated (ADR 0019) dari `odoo/pool-a`: image+digest sama, workers dari plan (default 2; staging 1), `mem_limit = workers×896+512` MiB, `dbfilter ^<s>_(prod\|demo)$` dengan `<s>` = slug `-`→`_`, role `odoo_<s>` CONNECTION LIMIT `(workers+2)×8`, volume `odoo_<s>_data` (label `infra.backup=odoo-filestore`), addons ro `shared`+`platform`+`clients/<slug>` (pin sama ADR 0015) | brief §5.4 |
| D11 | Network: `db-odoo-<slug>` (`--internal`, blok 10.100.29–39) + **`odoo-edge-<slug>` per instance** (blok baru 10.100.40–59), `SH_DBFILTER_TRUSTED_PROXIES` = subnet itu. Brief menulis `odoo-edge` bersama → pool-a jadi peer tepercaya instance dedicated (melanggar ADR 0010 D4/H1) → **Q1** | isolasi = alasan dedicated |
| D12 | Kelas staging berprefiks (`stg-odoo-<slug>`, …); **slug reserved**: `platform`, `staging`, `stg`, `pool-*`, `edge*` | nama network/role bentrok |
| D13 | Instance di-resolve host-side (`instance_for_tenant` membaca `instance.env`); job tidak membawa nama instance (`args.isolation` hanya asersi) | kontrak: nama DB/path tidak dari job |
| D14 | Integrasi Postgres/Traefik tanpa recreate: `docker network connect` live + override compose generated; pg_hba blok `# BEGIN GENERATED dedicated` (validasi `pg_hba_file_rules` sebelum reload) | recreate Traefik berisiko akun ACME; recreate Postgres memutus semua app |
| D15 | `monitor_ensure` lewat socket.io Uptime Kuma 2.5.5 (tanpa REST tulis — UNVERIFIED), idempoten by name; kredensial file root 0600 → **Q2** | brief §5.3 |
| D16 | `odoo_module_install`: install saja, allowlist `odoo/module-allowlist.txt`, di akhir rantai onboarding | durasi tidak terduga |
| D17 | `odoo_db_backup`: restic dump satu DB (tag `db:<db>`, `on-demand`) + filestore; `backup.sh` menemukan volume via label ∪ daftar statis | dedicated otomatis ter-backup |

## 3. Kontrak job baru (draft v2.0; dokumen kontrak + fixture di W1)

| Tipe | Skrip & argv | `args` | Aturan utama | Timeout | RESULT | Kuota |
|---|---|---|---|---|---|---|
| `odoo_instance_ensure` | `odoo-instance.sh <slug> <env> --workers <n> [--approve] [--dry-run]` | `{workers}` / `approve` | 1..4 (staging 1..2); prod apply wajib `approve`; blokir bila Σ`mem_limit` + baru > `capacity_max_mib` atau slot subnet/koneksi habis | 600 | `instance pool workers mem created changed` | 2/hari |
| `odoo_module_install` | `odoo-module.sh <slug> <env> --module <m>… [--dry-run]` | `{modules}` | 1..20, `[a-z][a-z0-9_]{1,63}`, allowlist | 1800 | `db modules changed` | 10/jam |
| `odoo_db_backup` | `odoo-db-backup.sh <slug> <env> [--dry-run]` | `{}` | DB dari slug/env | 1800 | `db snapshot changed` | 6/hari |
| `traefik_router_write` | `route-gen.py odoo <slug> <env> [--host h] [--alias h]… [--remove] [--dry-run]` | `{remove}` / `host`, `aliases` | host/alias = D3; ≤ 4 alias; state suspend tidak diatur (D8) | 60 | `route host hosts state changed` | 30/jam |
| `dns_verify` | `dns-verify.sh <slug> <env> --fqdn f --purpose p [--token t] [--dkim-txt v] [--release] [--dry-run]` | `{fqdn, purpose}` / `token`, `dkim_txt`, `release` | bukan zona platform; purpose ∈ odoo,web,mail,insight; token 43 char | 120 | `fqdn owner a mx spf dkim dmarc verified changed` | 120/jam |
| `monitor_ensure` | `monitor.sh <slug> <env> --host h [--remove] [--dry-run]` | `{host, remove}` | host harus ada di route `<slug>-<env>` | 120 | `monitor host changed` | 30/jam |

`_host`/`_hosts` tipe lama memakai validator D3. CP: migrasi `0006` (enum `job_type` += 6), `idempotency_key`
`<type>:<slug>:<env>:<target>` (harian `dns_verify` + `:<YYYY-MM-DD>`). Dispatcher `VERSION 2.0.0`.

## 4. Paket kerja (ESTIMASI, hari kerja)

- **W0 prasyarat (1, jendela owner)**: restic hijau; `/` < 70 % (K4); Postgres `max_connections` 200 → 260 (**Σ CONNECTION LIMIT
  role sekarang 196 dari 197 slot non-superuser — terverifikasi 2026-10-03; pemakaian nyata 31**; recreate ±6 s, Q4);
  `config/platform.env`; cadangan blok subnet.
- **W1 ADR + kontrak (1,5)**: ADR 0019; amandemen 0002/0003/0004/0006/0009/0010; `saas-phase-2-contract.md` + fixture.
- **W2 generator + M7 dry-run (3)**: `route-gen.py`, `--check`, `--migrate-report`; output = 10 file render sekarang.
- **W3 `dns_verify` + registry + validator host (3)**.
- **W4 template dedicated + `odoo_instance_ensure` (5)** — uji nested mount ro & `docker compose` di sandbox systemd (UNVERIFIED).
- **W5 modul + backup per DB + runbook restore satu tenant (2,5)**.
- **W6 `monitor_ensure` (1,5)**.
- **W7 control-plane (5, paralel W3–W6)**: kontrak TS, migrasi 0006, rantai onboarding (+ dedicated, monitor, modul), Domains
  "Verifikasi sekarang" / "Aktifkan di router", jadwal harian 03:10 WIB, portal status.
- **W8 deploy staging + gate (3 + 7 hari observasi)**.

Total ±25 hari kerja (±4 minggu kalender dengan infra ∥ CP).

## 5. Gate (staging)
1. Onboarding satu klik tenant shared **dan** dedicated → DB + router + SSO + monitor UP **< 10 menit**, tanpa terminal.
2. Rantai diulang 2× → `changed=0`; kegagalan disuntik (DNS salah, Postgres/Kuma down) → `failed` + `error_code`, re-run berhasil.
3. Dedicated staging ≥ 7 hari healthy; SSO ke DB benar; header DB dari container lain diabaikan; `net-matrix.sh --check` OK.
4. Domain kustom (K10): UI → checklist → verify (TXT + A) → router alias + redirect SSO → login; negatif: tanpa TXT, terikat slug
   lain, zona platform ditolak; suspend menutup alias.
5. Restore SATU DB tenant dari restic (ke DB baru + drill penuh tenant uji dedicated) → login berhasil; RTO tercatat.
6. M7: laporan diff 18 file; identik → header `# GENERATED`; sisanya `# MANUAL` + alasan; `--check` bersih.

## 6. Risiko utama
Job menulis pg_hba/override (blast radius) → blok bertanda + validasi + staging dulu · recreate Traefik & akun ACME → hanya
terjadwal, cek `acme.json` · OOM/overcommit → ambang `capacity_max_mib`, staging workers 1, dedicated prod = keputusan owner ·
slot koneksi Postgres (196/197) → W0 · ACME rate limit domain kustom (UNVERIFIED) → router hanya setelah verify, tanpa retry
otomatis · API socket.io Kuma berubah saat upgrade → pin + checklist upgrade · file route di git → tree kotor (Q3).

## 7. Kapasitas (nyata 2026-10-03)
RAM 15 992 MiB; Σ`mem_limit` berjalan 14 512 MiB (19,2 GiB dengan `ci-runner-job`); swap terpakai ±2 GiB; `/` 64 %.
Dedicated: workers 1 = 1 408 MiB, workers 2 = 2 304 MiB (ESTIMASI rumus brief). Setiap dedicated prod = keputusan owner +
perampingan ADR 0004 §5 atau VPS-2. Subnet: `db-*` sisa 11; edge blok baru 20 instance.

## 8. Pertanyaan untuk owner
- **Q1** Edge dedicated per instance `odoo-edge-<slug>` (rekomendasi) atau `odoo-edge` bersama (brief)?
- **Q2** Kredensial Uptime Kuma untuk job (password admin di host, root 0600)? Status 2FA Kuma?
- **Q3** File route generated tetap di git atau dikeluarkan (rekomendasi: keluarkan kecuali `# MANUAL`)?
- **Q4** Jendela recreate Postgres (±6 s) untuk `max_connections` 260.
- **Q5** Domain kustom: tenant-admin boleh menambah + "Cek sekarang" (rekomendasi), aktivasi router tetap platform-admin?
- **Q6** Dedicated prod diizinkan di host ini? Plan apa, workers default berapa?
- **Q7** Suspend tenant dedicated: router saja atau juga `compose stop` (membebaskan RAM)?
- **Q8** `plan.limits.workers` + modul per plan di `plans.features` (jsonb) atau kolom baru? Pemelihara `module-allowlist.txt`?
- **Q9** Gagal `dns_verify` harian: status + email ops (rekomendasi) atau suspend router otomatis?
- **Q10** Daftar slug reserved (D12) disetujui?
