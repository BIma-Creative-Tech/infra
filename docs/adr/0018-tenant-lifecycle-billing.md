# ADR 0018 — Model tenant & siklus langganan di control-plane (implementasi → go-live → garansi → maintenance)

- **Status:** accepted (owner 2026-10-02: "lanjutkan sesuai rekomendasi") — keputusan owner K9, K10, Q2–Q6 dimasukkan.
- **Tanggal:** 2026-10-02
- **Penulis:** Lead (SaaS Fase 1 W1)
- **Terkait:** brief owner 2026-10-02 §2 #1, #7, #8, §2a, §5.2; `docs/plans/saas-inventory.md` §2; `docs/plans/saas-phase-1.md`
  W3/W5–W7, D3/D7–D9; ADR 0009 (job), ADR 0017 (identitas); repo `control-plane` `src/db/schema.ts` (migrasi `0000`–`0003`).

## Context

Fakta (inventaris 2026-10-02):

1. Skema control-plane (Drizzle, 12 tabel, prod = staging): `clients` (slug), `environments` (prod/demo/staging, db, host,
   status db/route/sso), `users` (keycloak_sub, client_id, role cache), `tenant_user_access` (akses SSO per environment),
   `provision_jobs`, `audit_logs` — **dipakai**. `plans`, `subscriptions`, `invoices`, `domains`, `mail_domains`,
   `mailboxes` — **ada, 0 baris, tanpa kode**.
2. Enum `subscription_status` = `pending|active|grace|suspended|terminated` (tanpa `implementation`/`warranty`);
   `invoice_status` = `unpaid|awaiting_confirmation|paid|void`; `provision_jobs` tanpa `idempotency_key` (pengganti: unique
   index satu job aktif per (environment, type)).
3. Tabel `users` prod **kosong** (upsert saat login tidak pernah tersimpan) → `audit_logs.actor_user_id` NULL di prod.
4. Permission map default-deny di `src/lib/roles.ts` (`invoices:confirm` sudah didefinisikan untuk superadmin+ops).
5. Brief: control-plane = sumber kebenaran tenant/user/layanan/subscription/domain; tabel/role yang ada tidak di-rename
   (keputusan owner §13 #2, K9).

## Decision

1. **Pemetaan entitas (tanpa rename)**: tenant = `clients` (+ `status` `active|suspended|terminated`, `isolation`
   `shared|dedicated`, `brand`, `kc_org_id`, `is_platform`); user tenant = `users` (+ `status` `invited|active|disabled`,
   `invited_by`, `disabled_at`; `keycloak_sub` diisi saat user dibuat oleh job karena id user Keycloak = `sub`);
   tenant_domain = `domains` (+ `purpose` `odoo|web|mail|insight|sso`, `dkim_txt`, `last_check jsonb`); job =
   `provision_jobs` (+ `idempotency_key text unique` = `<type>:<slug>:<target>`). Migrasi Drizzle **aditif** `0004`.
2. **Tenant khusus `platform`** (`is_platform=true`, tepat satu baris) menampung user internal (role `superadmin`/`ops`).
   Halaman Users satu untuk semua tenant.
3. **Tepat satu tenant-admin** (`client_admin`) aktif/invited per tenant non-platform: partial unique index (≤ 1) + cek
   harian `subscription_tick` (≥ 1, laporan ke platform-admin bila nol).
4. **Siklus langganan** — tambah nilai enum `implementation`, `warranty`, `past_due`; `pending` dan `grace` **usang** (tidak
   dipakai kode baru; Postgres tidak bisa drop nilai enum). Kolom: `current_period_start` = *starts_at*,
   `current_period_end` = *ends_at*, `grace_until` (ada), + `go_live_at`, `warranty_until`, `notes`.

   | Dari | Ke | Pemicu |
   |---|---|---|
   | (baru) | `implementation` | tenant dibuat; tanpa invoice maintenance (invoice implementasi = `invoices.kind='implementation'`) |
   | `implementation` | `warranty` | platform-admin menekan **Go-live** (isi `go_live_at`); `warranty_until = go_live_at + 2 bulan` |
   | `warranty` | `active` | `subscription_tick`: `today > warranty_until` → `starts_at = warranty_until`, `ends_at = starts_at + periode plan`, terbit invoice maintenance pertama |
   | `active` | `past_due` | `today > ends_at`; `grace_until = ends_at + 2 bulan` |
   | `past_due` | `suspended` | `today > grace_until` → enqueue `tenant_suspend` |
   | `past_due`/`suspended` | `active` | invoice ditandai lunas → `ends_at` + satu periode; bila suspended → enqueue `tenant_resume` |
   | apa pun | `terminated` | manual platform-admin (arsip = fase lain) |

   Tenant `implementation`/`warranty` **tidak pernah** disuspend otomatis. Pembayaran manual (transfer); invoice ditandai
   lunas oleh role ber-permission `invoices:confirm` (superadmin/ops) dengan bukti.
5. **`subscription_tick`**: pg-boss schedule harian 00:15 WIB di worker CP; hanya transisi DB + enqueue job (bukan aksi
   infra langsung). Staging boleh `TICK_NOW` (tanggal disuntik) untuk uji; prod tidak.
6. **Kebijakan suspend**:
   - Odoo: route dirender ulang dengan middleware `suspended` → halaman CP `/suspended/<slug>` (DB/filestore utuh).
   - Mail (Q2): **terima-saja** — kirim dimatikan (quota kirim 0, submission nonaktif); diimplementasikan di Fase 4.
   - Web profile (Q3): **tetap tayang**.
   - User Keycloak **tidak** dinonaktifkan saat suspend (tenant-admin tetap bisa masuk portal untuk melihat/membayar
     invoice); override manual tersedia.
7. **Plan awal** (Q4, harga `NULL` diisi kemudian, periode bulanan, maintenance dimulai setelah garansi 2 bulan):
   `odoo-shared-s` (5 user, env prod), `odoo-shared-m` (15 user, prod+demo), `odoo-dedicated` (sesuai kontrak, workers 2),
   `mail-5` (5 mailbox × 2 GB), `mail-20` (20 mailbox × 2 GB), `web-profile` (1 site + CMS), `insight-basic` (dashboard
   standar). Kolom `plans.price_amount` diubah menjadi nullable; `+ service`.
8. **Email pengingat** (Q5): pengirim `noreply@bimacreative.tech` via submission 587; penerima tenant-admin + alamat billing
   internal `billing@bimacreative.tech` (mailbox dibuat 2026-10-02); H-14 sebelum garansi berakhir, H+0/H+14/H+45 setelah `ends_at`. Staging
   **hanya ke Mailpit** (container uji baru di network staging, ±30 MB RAM). Password SMTP dari secret file
   `SMTP_PASSWORD_FILE` di CP (bukan secret infra; ADR 0009 tidak dilanggar).
9. **Portal client** (tenant-admin): Ringkasan, Users, Domain & Mail. Setiap server action memeriksa `client_id` sesi ==
   baris target di server (bukan filter UI); uji unit lintas tenant wajib. Fitur lain menunggu tiga halaman ini dipakai.
10. **Data demo** (Q6): `demo_staging` = tenant uji Fase 1; `ssotest_staging` dihapus setelah Fase 1 lulus (dump ke restic
    dulu); `demo_demo` dipertahankan; tidak ada DB lain yang dihapus. **Amandemen 2026-10-04 (owner):** gate Fase 1 dipercepat;
    tenant uji `ssotest`, `ujiq` (dibuat untuk gate §7.1) dan `qajob` (DB sudah tidak ada) di-terminate di CP staging, DB +
    filestore `ssotest_staging`/`ujiq_staging` di-drop setelah dump (`backups/saas-cleanup/`, restic 15:14).

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Tabel baru `tenant`, `tenant_user`, … sesuai nama brief | Owner §13 #2: tidak rename; tabel yang ada sudah dipakai job/reconcile |
| Status langganan sebagai state machine terpisah (tabel event) | Berlebihan untuk volume kecil; `audit_logs` sudah mencatat transisi |
| Suspend = nonaktifkan semua user | Tenant-admin tidak bisa membayar via portal; brief: tanpa hapus data |
| Payment gateway | Di luar scope brief §8 |

## Consequences

- (+) Satu halaman Tenant memuat layanan, subscription, invoice, user, domain, job terakhir (brief §2a).
- (+) Migrasi aditif; rollback = image CP lama (kolom/nilai enum baru diabaikan kode lama).
- (−) Nilai enum usang (`pending`, `grace`) tetap ada di DB; dokumentasi + lint kode mencegah pemakaian.
- (−) Mailpit = container staging baru (kecil).
- (−) Temuan `users` prod kosong **wajib** terjawab di W3 (syarat owner #2) sebelum migrasi prod M4.

## Security implications

- Portal: otorisasi baris di server; uji akses lintas tenant (URL langsung + server action) masuk gate Fase 1.
- Invoice/bukti pembayaran = data finansial client → hanya superadmin/ops + tenant-admin tenant itu.
- `TICK_NOW` hanya dibaca bila `INFRA_JOBS_INSTANCE=staging`.

## Rollback

`CONTROL_PLANE_TAG=<tag lama>`; migrasi `0004` aditif (tidak perlu down-migration); job `tenant_suspend` yang sudah jalan
dibalik dengan `tenant_resume`.

## Riwayat revisi

- 2026-10-02: dibuat (proposed) — SaaS Fase 1 W1; memuat keputusan owner Q2–Q6.
- 2026-10-02: proposed → accepted; Q5 alamat billing = `billing@bimacreative.tech`.
