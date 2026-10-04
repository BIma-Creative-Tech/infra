# ADR 0017 — Identitas platform: Organizations per tenant, atribut `tenant_id`, realm sebagai kode, admin hanya lewat job

- **Status:** accepted (owner 2026-10-02: "lanjutkan sesuai rekomendasi") — arah disetujui owner 2026-10-02 (K7, K8, K9, §13 usulan 1–8). Bagian **Organizations (D2, D6
  hak org)** tetap *proposed* sampai **spike S1** (§Spike S1) dijawab tertulis di ADR ini (syarat owner Fase 1 #1).
- **Tanggal:** 2026-10-02
- **Penulis:** Lead (SaaS Fase 1 W1)
- **Terkait:** brief owner "Platform SaaS Odoo 19 CE" 2026-10-02 §2 #2, §2a, §5.1, §6a; `docs/plans/saas-inventory.md` §4–§5;
  `docs/plans/saas-phase-1.md` D1–D6; ADR 0008 (**sebagian digantikan**, lihat §Hubungan dengan ADR lain); ADR 0009 (eksekusi job);
  `docs/03-operations/keycloak.md`.

## Context

Fakta (inventaris 2026-10-02, read-only):

1. Keycloak 26.7.4 (`infra/keycloak:26.7.4-optimized`) dibangun `kc.sh build` tanpa `--features`/`--features-disabled`;
   `show-config` tanpa override fitur. Fitur Organizations **tersedia** (default 26.x): tabel `org` ada (0 baris), client
   scope `organization`/`saml_organization` dengan `oidc-organization-membership-mapper` ada di realm `platform` dan
   `platform-staging`. Setelan realm `organizationsEnabled=false` di kedua realm.
2. Realm `platform`/`platform-staging`: client `automation` (service account; `view-realm`, `manage-clients`,
   `manage-users`, **tanpa** `manage-realm`), `control-plane` (client role `superadmin|ops|client_admin|client_user`),
   `odoo-<slug>-<env>` (role `odoo_access`, satu per tenant-env). Tanpa grup; realm role hanya default; tanpa mapper
   `tenant_id`; tabel `user_attribute` kosong; user profile default.
3. Isolasi tenant Odoo hari ini (ADR 0008) fail-closed tanpa klaim tenant: `aud`/`azp` = client per tenant-env, secret
   dipilih dari `cr.dbname`, gate `odoo_access` pada client itu, `sub` harus ter-link ke `res.users` di DB itu.
   `sh_auth_oidc` 19.0.1.2.0 tidak membaca `tenant_id`/`organization`.
4. Control-plane hanya login OIDC (Auth.js); **tidak** memanggil Admin API. Perubahan Keycloak dilakukan skrip root
   (`provision-odoo-sso.sh`, `odoo-sso-user.sh`) via `automation`, dipicu job dispatcher (ADR 0009) atau manual.
5. Setelan realm, client non-Odoo (`control-plane`), dan export realm hanya bisa lewat console (SSH tunnel `:8443`);
   `realm-export/*.json` (2026-09-25) **usang**.
6. Target brief §2a: operasi harian user/tenant **tanpa console Keycloak**; staging tidak pernah diedit manual.

## Decision

1. **Realm per environment tetap**: `platform` (prod/demo) dan `platform-staging`. Realm `drms`/`drms-staging` dan `master`
   tidak disentuh oleh ADR ini.
2. **Tenant = Organization** di realm: `alias` = `clients.id` (UUID), `name` = slug, atribut `slug`; id org disimpan di
   `clients.kc_org_id`. Domain org diisi dari `domains.purpose='sso'` bila ada (untuk IdP per org di masa depan, belum
   dipakai). *Proposed sampai S1.*
3. **Atribut user `tenant_id`** (= `clients.id`) dideklarasikan di user profile realm: hanya admin yang boleh view/edit,
   user tidak bisa mengubah. Client scope baru `tenant` (mapper `oidc-usermodel-attribute-mapper` → klaim `tenant_id`,
   di ID token, access token, userinfo) menjadi **default scope** pada `control-plane` dan setiap `odoo-<slug>-<env>`.
   Scope `organization` **tidak** dijadikan default dan tidak diminta client (S1.1: scope default mengikat refresh token ke
   org → refresh gagal saat keanggotaan berubah); identitas tenant hanya dari klaim `tenant_id`. User internal memakai
   `tenant_id` tenant khusus `platform` (ADR 0018).
4. **Odoo tetap satu client per tenant-env** (ADR 0008, keputusan owner K8). Klaim `tenant_id` adalah **lapisan kedua**:
   `sh_auth_oidc` 19.0.1.3.0 membandingkan klaim dengan ICP `sh_auth_oidc.expected_tenant_id` per DB, mode
   `sh_auth_oidc.tenant_check` = `off` (default) | `compat` (log WARNING, login tetap) | `strict` (tolak). Prod pindah
   `compat` → `strict` setelah 7 hari log bersih (brief §6a M6). Amandemen 2026-10-04: 19.0.1.4.0 juga menerima klaim =
   tenant `platform` (ICP `sh_auth_oidc.platform_tenant_id`) — tanpa itu `strict` mengunci staf dari Odoo tenant; role gate
   client tetap membatasi staf.
5. **Role** (keputusan owner K9): client role `control-plane` yang ada dipertahankan — `superadmin` (label UI
   *platform-admin*), `ops` (*platform-viewer*/operator), `client_admin` (*tenant-admin*), `client_user` (*tenant-user*).
   Client `odoo-<slug>-<env>`: `odoo_access` (tetap) + `odoo_admin` (baru → group Settings/Administration oleh job
   `odoo_user_ensure`). Tidak ada realm role baru.
6. **Dua service account** (keputusan owner K7: kredensial di host, bukan di CP):
   - `cp-admin` — job harian (user/org): `manage-organizations`, `manage-users`, `view-users`, `query-users`,
     `query-groups`, `view-clients` (S1.4: role org khusus sejak 26.7.0; tambah member = `manage-organizations` +
     `manage-users`; `view-clients` wajib untuk membaca id client & role mapping — diverifikasi di Keycloak 26.7.4 sekali
     pakai 2026-10-03). **Bukan** `realm-admin`, **bukan** `manage-realm`/`manage-clients`.
   - `kc-realm-sync` — **hanya** job `kc_realm_sync`: `manage-realm`, `manage-clients`, `view-realm`, `manage-users`
     (`manage-users` wajib untuk membaca/memetakan role SA `cp-admin`; diverifikasi 2026-10-03). Prod hanya dengan flag
     persetujuan eksplisit di job.
   - Secret: `identity/keycloak/secrets/{cp-admin,kc-realm-sync}-<realm>.secret` (600 root, tidak di-commit), dibaca skrip
     job. `automation` dipertahankan sampai langkah M10 (skrip lama), lalu dipensiunkan.
7. **Realm sebagai kode**: desired-state `identity/keycloak/realm/platform.json` (tanpa secret, tanpa user) +
   `platform-staging.overrides.json` (redirect URI, hostname, SMTP). Skrip `kc_realm_sync.py` (Python stdlib, pola
   `scripts/lib/odoo_sso_kc.py`) menerapkan: atribut realm (termasuk `organizationsEnabled`), user profile, client scope &
   mapper, client non-tenant, role client, dan **requirement sub-flow `Organization` di flow `browser` = DISABLED**
   (S1.3: tanpa ini, begitu org pertama ada, SEMUA user realm mendapat halaman identity-first; routing IdP per org tidak
   dipakai). Selalu `dry-run` (diff) dulu; apply idempoten (diff kedua kosong). Client
   `odoo-<slug>-<env>` tetap dikelola `provision-odoo-sso.sh` (bukan file realm). **Staging tidak diedit manual.**
8. **Administrasi user/org hanya lewat job dispatcher** (ADR 0009 amandemen 2026-10-02): `kc_org_ensure`,
   `kc_user_ensure`, `kc_user_set_enabled`, `kc_user_set_roles`, `kc_user_action_email`, `kc_realm_sync`. Console
   Keycloak hanya untuk insiden + **satu kali bootstrap** client `kc-realm-sync` per realm (dicatat di
   `docs/03-operations/keycloak.md`).

## Spike S1 (WAJIB sebelum W2 langkah 2 — syarat owner)

Status: **TERJAWAB dari dokumentasi resmi + kode sumber Keycloak tag `26.7.4`** (riset 2026-10-03, tanpa menyentuh server);
**uji live di `platform-staging` menyusul setelah freeze dicabut** (W2 langkah 2 baru jalan setelah uji live §Uji live lulus).
Sumber: `github.com/keycloak/keycloak/blob/26.7.4/…`, server_admin "Managing organizations", release notes 26.7.0, upgrading 26.6.1.

| # | Pertanyaan | Jawaban | Bukti utama | Keyakinan |
|---|---|---|---|---|
| S1.1 | Isi token client lama berubah? | **Tidak**, selama client tidak meminta / tidak punya default scope `organization` (scope dibuat realm default-*optional*; klaim hanya dari mapper scope itu). Bila scope dijadikan default: klaim `organization: ["alias"]` hanya untuk user dengan tepat 1 org, alias org ditulis ke refresh token → refresh gagal bila user dikeluarkan/org dinonaktifkan; perilaku multi-org belum pasti (issue #39298) | `OIDCLoginProtocolFactory.java#L395-L403`, `TokenManager.java#L563-L717`, `OrganizationMembershipMapper.java`, `OrganizationTokenPostProcessor.java` | tinggi (tanpa scope) / sedang (default scope) |
| S1.2 | Sesi/refresh token lama terputus? | **Tidak** — hanya atribut realm; tidak ada logout massal/revoke | `DefaultExportImportManager.java#L837`, `TokenManager.java#L1637-L1660` | tinggi (kode) |
| S1.3 | Browser flow berubah? | **Ya, setelah org pertama dibuat**: flow `browser` bawaan 26.6.1+ memuat sub-flow `Organization` (identity-first). Realm disabled → dilewati; enabled tanpa org → login biasa; enabled + ≥ 1 org → halaman "username dulu" untuk **semua** user (member atau bukan) di semua client. **Keputusan: sub-flow di-set DISABLED lewat realm-as-code (D7)** | `DefaultAuthenticationFlows.java#L837-L893`, `MigrateTo26_6_1.java`, `OrganizationAuthenticator.java`, docs `authenticating-members.adoc` | tinggi |
| S1.4 | Hak minimum Admin API org | `manage-organizations` (create/update), `view-organizations`/`query-organizations` (baca), tambah member = `manage-organizations` + `manage-users`; **tidak perlu `manage-realm`**. Org disabled → 404 | `AdminRoles.java`, `MigrateTo26_7_0.java`, `OrganizationMemberResource.java#L106-L110`, release notes 26.7.0 | tinggi |
| S1.5 | Eskalasi via `manage-users`? | Role `realm-management` hanya bisa dipetakan bila pemanggil memegangnya (FGAP v2 default). **Namun** `manage-users` bisa reset password user mana pun (termasuk admin realm), memasukkan user ke grup ber-role admin, dan memetakan composite kustom berisi role admin → **secret `cp-admin` diperlakukan setara kredensial admin realm** | `RolePermissionsV2.java#L49-L196`, `UserPermissionsV2.java`, `GroupPermissionsV2.java`, docs `fine-grain-v2.adoc` | sedang-tinggi (kode, belum diuji) |
| S1.6 | Bentuk klaim org | `organization: ["alias"]` (default, ID+access token, tanpa userinfo); objek per alias bila opsi id/atribut/domain diaktifkan | `OrganizationMembershipMapper.java#L60-L229`, docs `mapping-organization-claims.adoc` | tinggi |
| S1.7 | Bug terkenal 26.x | #52309 (filter admin permission bocor ke lookup org saat login) **fix 26.7.5**; CVE-2026-4633 enumerasi via identity-first (fix lengkap 26.8.0; dimitigasi bila sub-flow DISABLED); #50882 (500 bila scope default diminta eksplisit) fix 26.7.1 — sudah termasuk; #50458 jangan matikan fitur di level server | issue tracker keycloak/keycloak | sedang |

### Uji live (setelah freeze, `platform-staging`, sebelum W2 langkah 2)
1. Pastikan flow `browser` yang ter-bind memuat sub-flow `Organization`; set DISABLED via `kc_realm_sync` (plan → apply → diff kosong).
2. Toggle `organizationsEnabled=true` → login `control-plane-staging` + `odoo-expomedia-staging`: tidak ada perubahan halaman/klaim.
3. Buat 1 org uji → login member & non-member: tetap form username+password biasa; SSO antar-client normal.
4. Decode ID/access/refresh token user 0/1 org: tidak ada klaim `organization`, klaim `tenant_id` ada setelah scope `tenant`.
5. Endpoint org/member dengan SA berole minimal S1.4; rollback toggle → login normal.

Hasil: **D2 (Organizations) tetap**, fallback grup tidak diperlukan, dengan dua penyesuaian: scope `organization` tidak
default (D3) dan sub-flow `Organization` DISABLED (D7). **Keputusan baru untuk owner (K11)**: upgrade Keycloak ke
26.7.5 (fix #52309) sebelum Organizations diaktifkan di realm prod `platform`.

## Alternatives

| Alternatif | Ditolak / ditunda karena |
|---|---|
| Realm per tenant | Administrasi berlipat (client, flow, SMTP, kebijakan per realm); bertentangan dengan brief §2 #2 |
| Satu client `odoo` untuk semua tenant + verifikasi `tenant_id` saja | Owner K8: isolasi per client yang ada sudah fail-closed dan teruji; satu client = satu kebocoran secret membuka semua tenant |
| CP memanggil Admin API langsung dengan `cp-admin` | Owner K7 / ADR 0009: CP terekspos internet dan sengaja tanpa secret infra |
| Grup alih-alih Organizations | **Fallback** bila S1 negatif; Organizations lebih cocok untuk domain/IdP per tenant di masa depan |
| `keycloak-config-cli` (adorsys) untuk realm-as-code | Dependensi baru (image JVM) + pin/verifikasi ADR 0001; cakupan kita kecil. Dipertimbangkan ulang bila `kc_realm_sync.py` membengkak |
| Partial import Keycloak | Tidak mencakup atribut realm, user profile, organization |

## Consequences

- (+) Operasi harian user/tenant tanpa console; jejak lengkap di `audit_logs` CP + log job host.
- (+) Staging = hasil sync dari repo → tidak ada drift manual; export realm tidak lagi usang.
- (+) Klaim `tenant_id` memberi CP/insight/Payload satu sumber identitas tenant yang sama.
- (−) Kode root baru (skrip `kc-*.sh`, `kc_realm_sync.py`) → tes dispatcher + negatif seperti ADR 0009.
- (−) Bootstrap `kc-realm-sync` tetap butuh console satu kali per realm.
- (−) `sh_auth_oidc` harus dirilis 19.0.1.3.0 dan pool di-restart (staging Fase 1; prod = M6 di jendela perawatan).

## Security implications

- `cp-admin` dan `kc-realm-sync` hanya dibaca root di host; CP tertembus tetap terbatas pada job allowlist + kuota (ADR 0009).
- `manage-users` mampu menonaktifkan/mengubah user mana pun di realm (termasuk internal) — mitigasi: kuota per tipe job,
  alert email untuk disable massal, user `superadmin` tidak bisa dinonaktifkan lewat job (validator dispatcher).
- S1.5: `manage-users` praktis setara admin realm (reset password user mana pun) → secret `cp-admin` = kredensial admin;
  role yang boleh dipetakan job dibatasi allowlist di dispatcher + skrip; tidak ada grup/composite kustom berisi role
  `realm-management` di realm `platform*` (dicek `kc_realm_sync` plan).
- Atribut `tenant_id` hanya bisa ditulis admin (user profile); klaim tidak bisa dipalsukan user.

## Rollback

`organizationsEnabled=false` + desired-state lama via `kc_realm_sync` (reversibel tanpa restart); hapus scope `tenant` dari
client; `sh_auth_oidc.tenant_check=off`; nonaktifkan client `cp-admin`/`kc-realm-sync`. Data org yang sudah dibuat dibiarkan
(tidak dipakai) sampai diputuskan.

## Hubungan dengan ADR lain

- **ADR 0008**: digantikan **sebagian** — keputusan "Organizations ditunda" dan "SA `automation` satu-satunya" digantikan
  D2/D6; keputusan satu client per tenant-env, secret per DB, gate `odoo_access` **tetap berlaku**.
- **ADR 0009**: tetap; tipe job baru lewat amandemen 0009 (2026-10-02).

## Riwayat revisi

- 2026-10-02: dibuat (proposed) — SaaS Fase 1 W1; arah disetujui owner (K7–K9).
- 2026-10-02: proposed → accepted (owner "lanjutkan sesuai rekomendasi"); D2 dan hak org D6 tetap menunggu spike S1.
- 2026-10-03: spike S1 terjawab dari dokumen + kode 26.7.4 — D3 scope `organization` tidak default, D6 role `manage-organizations`, D7 sub-flow `Organization` DISABLED; uji live menyusul (freeze); K11 upgrade 26.7.5.
- 2026-10-03: D6 diamandemen setelah uji Keycloak 26.7.4 sekali pakai — `cp-admin` + `view-clients`, `kc-realm-sync` + `manage-users`; label default user profile ditulis literal (bukan `${...}`, diblok WAF CRS 932130); tautan email aksi 72 jam.
