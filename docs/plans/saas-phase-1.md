# SaaS Fase 1 — Identitas + control-plane inti (RENCANA, menunggu persetujuan)

Status 2026-10-02: **DRAFT — BELUM ADA IMPLEMENTASI.** Eksekusi dimulai hanya setelah (1) owner menyetujui dokumen ini
dan keputusan di `saas-progress.md` §Butuh keputusan, dan (2) FREEZE DEMO expomedia dicabut. Dasar: brief owner
2026-10-02 §2, §2a, §5.1–5.3, §6, §6a; fakta dari `docs/plans/saas-inventory.md`.

Prinsip: **adopsi, bukan bangun ulang** — perluas `clients`/`users`/`provision_jobs`/dispatcher yang ada; semua di
staging (`control-plane-staging`, realm `platform-staging`, `odoo-staging`, DB `*_staging`). Prod tidak disentuh di
Fase 1 kecuali ADR dan dokumen.

---

## 1. Tujuan dan batas

**Masuk (IN)**

- ADR identitas (menggantikan sebagian ADR 0008) dan ADR model tenant/siklus langganan; amandemen ADR 0009 (tipe job
  baru).
- Realm sebagai kode: desired-state realm `platform` di repo + job `kc_realm_sync` ke `platform-staging`.
- Keycloak staging: Organizations aktif, atribut `tenant_id`, mapper klaim `tenant_id`/`organization`, service account
  `cp-admin` (harian) dan `kc-realm-sync` (khusus sync).
- Model data CP (migrasi Drizzle `0004`): tenant status/isolation/brand/kc_org_id, tenant `platform`, user tenant
  (perluasan `users`), siklus langganan baru, invoice kind, domain purpose, `idempotency_key`.
- Job dispatcher baru (instance staging dulu): org, user (ensure/enable/disable/roles/reset), Odoo user, realm sync,
  tenant suspend/resume.
- UI platform-admin: **Tenants, Users, Subscriptions & Invoices, Domains (data + checklist), Jobs, Audit**.
- Portal client (tenant-admin): **Ringkasan, Users, Domain & Mail (baca + checklist)**.
- `subscription_tick` harian + email pengingat.
- `sh_auth_oidc` 19.0.1.3.0: klaim `tenant_id` dengan mode `off|compat|strict` — **di `odoo-staging` saja**.

**Keluar (OUT, fase lain)**: router domain kustom otomatis + `dns_verify` job (Fase 2), template dedicated Odoo
(Fase 2), mail job (Fase 4), Payload (Fase 4), insight (Fase 3), Ansible multi-VPS (Fase 5), seluruh langkah prod
M3–M10 (butuh plan migrasi tersendiri setelah Fase 1 lulus).

---

## 2. Keputusan desain (diusulkan — rinci di ADR)

| # | Keputusan | Alasan |
|---|---|---|
| D1 | Semua aksi ke Keycloak/Odoo/Traefik tetap dieksekusi **dispatcher root (ADR 0009)**, bukan worker CP. Kredensial `cp-admin` di `identity/keycloak/secrets/cp-admin-<realm>.secret` (600 root), dipakai skrip job | CP terekspos internet; ADR 0009 menjaga CP tanpa secret infra |
| D2 | Tetap **satu client OIDC per tenant-env** untuk Odoo (`odoo-<slug>-<env>`, ADR 0008); klaim `tenant_id` ditambahkan sebagai **lapisan kedua** (defense in depth), bukan pengganti | Isolasi yang ada sudah fail-closed dan teruji; mengganti ke satu client `odoo` menambah risiko tanpa manfaat |
| D3 | Tabel/role tidak di-rename: `clients`=tenant, `users`=tenant_user, `domains`=tenant_domain, `provision_jobs`=job. Role CP `superadmin/ops/client_admin/client_user` (client role `control-plane`) = `platform-admin/platform-viewer/tenant-admin/tenant-user` di UI | Brief §6a "tidak di-rename"; role sudah dipakai di klaim & permission map |
| D4 | User Odoo dibuat oleh **job** (`odoo_user_ensure`: `res.users` internal + group sesuai role + link `oauth_uid`), **bukan** JIT di `sh_auth_oidc` | Jalur login tidak diubah untuk pembuatan user; group dari role mudah diaudit; `odoo-sso-user.sh` sekarang menolak membuat `res.users` |
| D5 | Realm-as-code: file desired-state `identity/keycloak/realm/platform.json` (tanpa secret) + skrip `kc_realm_sync.py` (stdlib, pola `odoo_sso_kc.py`) yang menerapkan: atribut realm (`organizationsEnabled`), user profile (`tenant_id`), realm/client role, client scope & mapper, client non-tenant. Override per env di `platform-staging.overrides.json` | Partial import KC tidak mencakup atribut realm/user profile/organization; skrip sendiri = tanpa dependensi baru (ADR 0001) |
| D6 | Dua service account: `cp-admin` (`manage-users`, `view-users`, `query-users`, dan hak Organizations minimal hasil spike S1) untuk job harian; `kc-realm-sync` (`manage-realm`, `manage-clients`) **hanya** untuk `kc_realm_sync`, prod perlu `--approve` | Brief §5.1: bukan `realm-admin`; memisahkan hak harian dari hak ubah realm |
| D7 | Siklus langganan: tambah nilai enum `implementation`, `warranty`, `past_due`; `starts_at`=`current_period_start`, `ends_at`=`current_period_end`; nilai lama `pending`/`grace` ditandai usang | Postgres tidak bisa drop nilai enum; kolom yang ada dipakai ulang |
| D8 | Suspend Fase 1 = route Odoo dirender ulang dengan middleware `suspended` (redirect ke halaman CP `/suspended/<slug>`) + opsional disable user KC; DB/filestore tidak disentuh | Reversibel, tanpa restart; sesuai brief (tanpa hapus data) |
| D9 | Email pengingat dikirim worker CP via SMTP submission (`noreply@<brand>`), password dari secret file `SMTP_PASSWORD_FILE` | Bukan secret infra; tidak perlu tipe job |

---

## 3. Paket kerja (urut; tiap paket punya bukti uji di `saas-progress.md`)

### W0 — Persiapan (setelah freeze dicabut)
- Branch: `feat/saas-p1-*` per repo (infra, control-plane, odoo-addons-shared) di worktree.
- Lepas stale lock restic + jalankan ulang restore-test (prasyarat semua perubahan, §6a M1).
- Snapshot M1 versi staging: `pg_dump` `control_plane_staging`, `keycloak`; salinan `realm-export/` terbaru.

### W1 — ADR (tanpa kode)
- `docs/adr/0017-identity-organizations.md`: Organizations per tenant, `tenant_id` sebagai atribut + klaim, `cp-admin`
  + `kc-realm-sync`, realm-as-code, console hanya insiden. **Menggantikan** bagian ADR 0008 tentang Organizations dan SA.
- `docs/adr/0018-tenant-lifecycle-billing.md`: model tenant/subscription/invoice, status & transisi, tenant `platform`,
  aturan tepat satu tenant-admin, portal 3 halaman.
- Amandemen ADR 0009 (bagian "Tipe job"): tipe baru, kuota, `idempotency_key`.

### W2 — Keycloak staging
1. **Spike S1** (read-only + staging): verifikasi di dokumentasi KC 26.7 hak minimum Admin API Organizations
   (`/organizations`, `/members`) dan efek `organizationsEnabled=true` terhadap token/sesi client yang ada. Hasil
   dicatat di ADR 0017 sebelum langkah 2.
2. Bootstrap satu kali (console via tunnel, terdokumentasi di `docs/03-operations/keycloak.md`): buat client
   `kc-realm-sync` di `platform-staging` + secret file host. Ini satu-satunya aksi console Fase 1.
3. Tulis `identity/keycloak/realm/platform.json` dari kondisi realm saat ini (dibaca read-only via SA) +
   tambahan: `organizationsEnabled`, attribute `tenant_id` (admin view/edit, user tidak bisa ubah), client scope
   `tenant` (mapper `oidc-usermodel-attribute-mapper` → klaim `tenant_id`), scope `organization` default di client
   `control-plane` & `odoo-*`, client `cp-admin` (SA).
4. Job `kc_realm_sync` (dry-run → diff → apply) ke `platform-staging`; jalankan dua kali → diff kedua kosong.

### W3 — Model data control-plane (migrasi `0004`, staging)
- `clients` + `status` (`active|suspended|terminated`), `isolation` (`shared|dedicated`), `brand`, `kc_org_id`,
  `is_platform` (tepat satu baris `platform`).
- `users` → user tenant: + `status` (`invited|active|disabled`), `invited_by`, `disabled_at`; `keycloak_sub` diisi
  saat user dibuat (id KC = `sub`); partial unique index satu `client_admin` aktif/invited per client.
- `subscriptions`: enum + `go_live_at`, `warranty_until`, `notes`; `plans` + `service`; `invoices` + `kind`
  (`implementation|maintenance`).
- `domains` + `purpose`, `dkim_txt`, `last_check jsonb`.
- `provision_jobs` + `idempotency_key text unique` (`<type>:<slug>:<target>`), + `client_id` wajib untuk tipe tenant.
- Perbaiki temuan `users` prod kosong: tes login staging → baris `users` terbentuk; bila gagal, perbaiki upsert.
- Seed staging: tenant `platform` (user internal), tenant uji `demo`, plan contoh (menunggu Q4).

### W4 — Dispatcher: tipe job baru (instance **staging** saja; prod tetap 5 tipe sampai disetujui)

| Tipe | Skrip | Aksi | Idempotensi |
|---|---|---|---|
| `kc_realm_sync` | `kc-realm-sync.sh` | terapkan desired-state realm | diff kosong → no-op |
| `kc_org_ensure` | `kc-org.sh` | org alias=`tenant_id`, nama=slug, atribut `slug` | cari by alias |
| `kc_user_ensure` | `kc-user.sh ensure` | user (username=email), atribut `tenant_id`, member org, client role CP, `execute-actions-email UPDATE_PASSWORD` bila baru | cari by email; update atribut/role |
| `kc_user_set_enabled` | `kc-user.sh enable/disable` | `enabled`, logout sesi saat disable | set ke nilai target |
| `kc_user_set_roles` | `kc-user.sh roles` | role CP + `odoo_access`/`odoo_admin` per tenant-env | set ke himpunan target |
| `kc_user_action_email` | `kc-user.sh reset` | kirim UPDATE_PASSWORD | kuota 3/user/jam |
| `odoo_user_ensure` | `odoo-user.sh` | `res.users` internal, group dari role, link `oauth_uid`=sub | cari by login/oauth_uid |
| `tenant_suspend` / `tenant_resume` | `tenant-state.sh` | render route dengan/tanpa middleware `suspended`; opsi disable user | cek isi route |

- Validator baru di `infra_job.py`: `tenant_id` UUID, daftar role allowlist, `actions` allowlist; kuota per tipe di
  `/etc/infra-jobs/staging.conf`; RESULT keys tambahan (`org`, `kc_user`, `roles`, `state`).
- `odoo_sso_user` lama tetap jalan (kompatibel) sampai M10.

### W5 — UI platform-admin (control-plane-staging)
- **Tenants** (`/clients`): daftar + detail = layanan/environment, subscription, invoice, user, domain, 10 job terakhir;
  tombol Go-live, Suspend/Resume (override), buat tenant = **satu form** (slug, nama, brand, admin email, plan) →
  rantai job `kc_org_ensure` → `odoo_db_provision` → `odoo_route` → `odoo_sso_provision` → `kc_user_ensure` (admin) →
  `odoo_user_ensure`; status per langkah terlihat.
- **Users** (`/users`): filter per tenant (termasuk `platform`), buat/nonaktifkan/aktifkan, ubah role, reset password.
- **Subscriptions & Invoices**: buat subscription, Go-live, terbitkan/void invoice, tandai lunas (+ bukti).
- **Domains**: CRUD data domain + checklist DNS yang digenerate (verifikasi otomatis = Fase 2).
- **Audit**: tampilan `audit_logs` dengan filter aktor/tenant/aksi.

### W6 — Portal client (tenant-admin)
- `/portal` Ringkasan (layanan + status + invoice terbuka), `/portal/users` (tambah/nonaktifkan user tenant sendiri,
  sesuai limit plan), `/portal/domains` (baca + checklist). Setiap server action cek `client_id` sesi == baris target
  di server (bukan filter UI); tes unit lintas tenant wajib.

### W7 — `subscription_tick` + email
- pg-boss schedule harian 00:15 WIB; transisi persis brief §5.2; tenant `implementation`/`warranty` tidak pernah
  disuspend; enqueue `tenant_suspend`/`tenant_resume`; email H-14 garansi, H+0/H+14/H+45 past_due.
- Mode uji: tanggal disuntik (`TICK_NOW` hanya di staging) untuk menguji `past_due → suspended → active`.

### W8 — `sh_auth_oidc` 19.0.1.3.0 (staging)
- Baca klaim `tenant_id`; ICP `sh_auth_oidc.expected_tenant_id` (diisi `odoo_db_provision`/job baru) dan
  `sh_auth_oidc.tenant_check` (`off` default | `compat` | `strict`). Compat: klaim hilang/beda → login tetap + log
  WARNING terstruktur; strict: tolak (`oauth_error`).
- Tes unit/flow: klaim cocok, tidak cocok, hilang × tiga mode; tes yang ada (73) tetap hijau.
- Deploy hanya ke `odoo-staging` (restart staging di luar jam kerja). Prod = langkah M6 setelah Fase 1 lulus.

---

## 4. Kriteria selesai (staging; tiap butir punya bukti di `saas-progress.md`)

Mengikuti brief §6 Fase 1 + §2a. **Kecuali bila owner memutuskan lain (Q8)**, baris §2a "domain sendiri" dan
"mailbox" diuji di gate Fase 2/4 karena job router/DNS/mail memang dijadwalkan di sana.

1. Platform-admin, **tanpa terminal dan tanpa console Keycloak**, untuk tenant uji `demo` di staging:
   buat tenant (satu form) · tambah user internal (tenant `platform`) · tambah/nonaktifkan/aktifkan user client ·
   reset password (email aksi terkirim) · buat subscription → Go-live → warranty → active (tanggal disuntik) ·
   suspend/resume manual · lihat ringkasan tenant · `kc_realm_sync` dari UI — semua tercatat di `audit_logs`.
2. Admin client login ke portal, menambah user; user itu login ke `odoo-staging` via SSO dan masuk DB tenant yang
   benar; user tenant lain ditolak (Odoo `oauth_error`, portal 403).
3. `past_due → suspended → active` teruji dengan tanggal dimanipulasi; route menampilkan halaman ditangguhkan saat
   suspended dan normal setelah invoice ditandai lunas.
4. Semua job baru dijalankan dua kali tanpa perubahan kedua (diff/RESULT `changed=0`); kegagalan disuntik (KC 503,
   DB down) → status `failed` + `error_code` jelas.
5. `sh_auth_oidc` staging mode `compat`: 7 hari log tanpa mismatch palsu untuk user yang dibuat lewat CP.
6. Uji keamanan: portal tenant A tidak bisa membaca/menulis tenant B (server action + URL langsung); header
   `X-Sh-Odoo-Db` dari client diabaikan.

## 5. Risiko & mitigasi

| Risiko | Mitigasi |
|---|---|
| Mengaktifkan Organizations mengubah alur login/token client yang ada | Spike S1 + uji staging dulu; atribut realm reversibel (set `false`) |
| Dispatcher `/usr/local/sbin/infra-job` dipakai prod & staging | Tipe baru di-allowlist per instance (`staging.conf`); prod tetap 5 tipe; uji kontrak + fixture; deploy di luar jam kerja |
| Service account dengan hak terlalu besar | D6: dua SA terpisah; `kc-realm-sync` tidak dipakai job harian; secret hanya di host |
| Email pengingat salah kirim | Staging: SMTP ke mailpit / alamat internal saja; `TICK_NOW` hanya staging |
| Freeze/beban staging (pool staging 2 worker) | Restart `odoo-staging` di luar jam kerja; tidak menyentuh pool-a |
| Data user KC `platform-staging` (4 user) berubah | Backup `keycloak` sebelum W2; `kc_realm_sync` tidak mengimpor user |

## 6. Rollback

- CP staging: `CONTROL_PLANE_TAG=<tag lama>` + restore `control_plane_staging` dari dump W0 (migrasi aditif).
- Keycloak staging: `organizationsEnabled=false` via `kc_realm_sync` dengan desired-state lama; restore DB `keycloak`
  hanya bila perlu (berdampak ke semua realm → butuh persetujuan).
- Dispatcher: kembalikan `infra_job.py` versi sebelumnya (Ansible role `infra_jobs`); kill switch `staging.disabled`.
- `sh_auth_oidc`: submodule staging ke `4bd278a` + restart `odoo-staging`.

## 7. Kapasitas

Tidak ada container baru. CP staging: kode tambahan, memori tetap di limit 192 MiB (+ worker 128 MiB) — dipantau,
naikkan ke 256 MiB bila p95 > 80 %. Postgres: tabel aditif kecil. Disk: < 50 MB. Dispatcher: oneshot, tanpa beban
tetap.

## 8. Urutan & estimasi kasar

W1 (1 hari) → W2 + W3 paralel (3–4 hari) → W4 (3 hari) → W5 + W6 (5–6 hari) → W7 (1–2 hari) → W8 (2 hari, paralel
dengan W5) → uji gate (2 hari + 7 hari observasi compat). Estimasi ini ESTIMASI, dikoreksi setelah W2 spike.
