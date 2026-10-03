# SaaS Fase 1 — Runbook deploy STAGING (W2–W5) + gate

Status 2026-10-03: **SIAP, BELUM DIJALANKAN.** Dijalankan hanya setelah owner menulis **"FREEZE DICABUT"**. Prod tidak
termasuk runbook ini (plan migrasi prod M3–M10 terpisah setelah gate lulus; K11 upgrade Keycloak 26.7.5 sebelum Organizations
di realm `platform`). Kontrak: `docs/plans/saas-phase-1-contract.md` v1.2. Branch:

| Repo | Branch | Isi |
|---|---|---|
| infra | `feat/infra-saas-p1` | dispatcher 1.2.0, skrip `kc-*`/`odoo-user`/`odoo-tenant-config`/`tenant-state`, realm-as-code, middleware `tenant-suspended`, role `infra_jobs` (`job_types`), compose CP staging (+ Mailpit) |
| control-plane | `feat/saas-p1` | migrasi 0004–0005, Users, onboarding tenant, billing/tick/email, portal, domain, audit, realm sync |
| odoo-addons-shared | `feat/sh-auth-oidc-tenant-check` | `sh_auth_oidc` 19.0.1.3.0 (`tenant_check`) |
| infra | `feat/backup-opt-src` | restic `/opt/src` (K3, terpisah dari runbook ini) |

Aturan: setiap langkah = perintah + cek; gagal → hentikan, rollback langkah itu, laporkan. Jam: di luar jam kerja client
untuk langkah yang me-restart `odoo-staging` atau me-reload Traefik.

## 0. Prasyarat
1. `systemctl start restic-backup.service` (backup manual) → `journalctl -u restic-backup -n 5` memuat `RESULT status=ok`.
2. `docker exec postgres pg_dump -Fc -d control_plane_staging` dan `-d keycloak` ke `/opt/infra/backups/saas-p1/<ts>/` (600 root).
3. Snapshot route: `cp -a traefik/dynamic/clients /opt/infra/backups/saas-p1/<ts>/clients`.

## 1. Infra (dispatcher + skrip)
1. Merge `feat/infra-saas-p1` → `main` di `/opt/infra` (`--no-ff`). Skrip baru live, tetapi **tidak dipakai** sampai tipe
   job di-allowlist. Perubahan pada jalur lama: `lib/keycloak-admin.sh` (default `automation` — perilaku sama),
   `lib/odoo_sso_kc.py` (tidak lagi melepas scope `tenant`), template route (keluaran byte-identik tanpa `--suspended`).
2. Cek jalur lama tidak berubah: `scripts/provision-odoo-sso.sh expomedia staging --host expomedia.staging.bimacreative.tech --dry-run` → exit 0, `blockers=0`.
3. `cd ansible && ansible-playbook site.yml --tags infra_jobs --check --diff` → diff hanya `/usr/local/sbin/infra-job` (1.2.0) dan
   `staging.conf` (`job_types`); `prod.conf` **tidak berubah**. Lalu tanpa `--check`.
4. Cek: `cmp /usr/local/sbin/infra-job scripts/infra-job/infra_job.py`; `grep -c job_types /etc/infra-jobs/prod.conf` = 0.
Rollback: role `infra_jobs` dari commit sebelum merge + `staging.disabled` sementara.

## 2. Odoo staging (`sh_auth_oidc` 19.0.1.3.0)
1. Merge `feat/sh-auth-oidc-tenant-check` → `main` di `/opt/src/odoo-addons-shared`; bump submodule
   `staging/odoo/addons/shared` (HANYA staging; pool-a tetap) → commit infra.
2. `docker compose -f staging/odoo/docker-compose.yml restart` (di luar jam kerja), lalu per DB staging
   (`expomedia_staging`, `demo_staging`, `ssotest_staging`): `odoo -u sh_auth_oidc --stop-after-init` lewat pola runbook odoo.md.
3. Cek: login SSO `expomedia.staging…` user uji berhasil; ICP `tenant_check` belum diset = `off` (tanpa perubahan perilaku).
Rollback: submodule ke `4bd278a` + restart.

## 3. Keycloak `platform-staging` (realm-as-code)
1. Bootstrap SEKALI client `kc-realm-sync` (console via tunnel, `docs/03-operations/keycloak.md` §Bootstrap) + secret file host.
2. `scripts/kc-realm-sync.sh platform staging --dry-run` → periksa rencana: sub-flow `Organization` → DISABLED, scope `tenant`,
   default scope `tenant` di `control-plane` + `odoo-*`, role `odoo_admin`, client SA `cp-admin` + role persis
   (`manage-organizations, manage-users, view-users, query-users, query-groups, view-clients`), label user profile literal.
3. Apply (tanpa `--dry-run`), lalu `--dry-run` lagi → `changed=0 blockers=0`. Ambil secret `cp-admin` ke
   `identity/keycloak/secrets/cp-admin-platform-staging.secret` (prosedur keycloak.md, 600 root, tidak dicetak).
4. **Uji live S1** (ADR 0017 §Uji live) dengan `organizationsEnabled` masih false: login CP staging + `odoo-expomedia-staging`
   normal; decode token → ada `tenant_id` (kosong untuk user tanpa atribut), tidak ada `organization`.
5. Ubah `identity/keycloak/realm/platform-staging.overrides.json` → `organizationsEnabled: true` (commit), sync plan/apply.
   Buat 1 org uji lewat `scripts/kc-org.sh` → login member & non-member tetap form username+password biasa (sub-flow DISABLED);
   SSO antar-client normal; endpoint org/member dengan `cp-admin` OK. Verifikasi endpoint baru perbaikan F1
   (`/organizations/members/{id}/organizations`, role composite) — belum pernah diuji live.
Rollback: override `organizationsEnabled: false` + sync; restore DB `keycloak` hanya dengan persetujuan (semua realm).

## 4. Traefik
`docker exec traefik kill -HUP 1` sekali agar `dynamic/middlewares/tenant-suspended.yml` termuat; cek log Traefik tanpa error
konfigurasi dan semua host prod tetap 200/302 seperti sebelumnya (`infra-healthcheck.sh`).

## 5. Control-plane staging
1. Build image dari commit `feat/saas-p1` (pola `control-plane.md` §Deploy: `git archive <commit> | docker build -t
   control-plane:<sha7> --label …revision=… -`). Catatan: build butuh egress ke Google Fonts.
2. Compose staging (sudah di `main` dari langkah 1): `INFRA_JOBS_TYPES`, `PLATFORM_PUBLIC_IPV4`, SMTP→Mailpit, layanan
   `mailpit`. Pin `CONTROL_PLANE_TAG:-<sha7>` di compose (commit).
3. `docker compose -f staging/control-plane/docker-compose.yml run --rm migrate` → migrasi 0004, 0005 + seed 7 plan + tenant
   `platform`; `up -d`. Cek health web/worker/mailpit; `/users`, `/clients`, `/subscriptions`, `/audit`, `/realm` terbuka untuk
   superadmin.
Rollback: `CONTROL_PLANE_TAG=3d4aa7c` (migrasi aditif) + restore dump langkah 0 bila perlu.

## 6. Data awal staging
1. `/realm` → Rencana → Terapkan (memastikan CP ↔ dispatcher ↔ Keycloak jalan).
2. `/users` → setiap staf (baris "tanpa tenant") → **Ikat ke tenant… → platform** (adopt) — langkah wajib pertama (QA F1).
3. Tenant uji `demo` (Q6: `demo_staging`): ikat environment yang ada; `odoo_tenant_config compat`; tetapkan tenant-admin uji.

## 7. Gate Fase 1 (bukti → `saas-progress.md`)
Brief §6 Fase 1 + §2a (kecuali domain sendiri & mailbox → gate Fase 2/4, K10). Semua **tanpa terminal dan tanpa console KC**:
1. Onboarding tenant baru satu form (prod-like rantai 14 langkah di staging) → DB, route, SSO, admin, user Odoo jadi; status per langkah.
2. Tambah user internal (tenant `platform`); tambah/nonaktifkan/aktifkan user client; reset password (email di Mailpit).
3. Subscription → Go-live → warranty → active → past_due → suspended → bayar → active dengan `TICK_NOW`; halaman ditangguhkan
   tampil saat suspended; email pengingat di Mailpit.
4. Tenant-admin login portal, menambah user; user itu login ke `odoo-staging` dan masuk DB tenant yang benar; user tenant lain
   ditolak (Odoo `oauth_error`, portal 403/`not_found`).
5. Ulang job → `changed=0`; kegagalan disuntik (stop sementara container uji, bukan prod) → `failed` + `error_code` jelas.
6. `odoo_tenant_config compat` 7 hari tanpa mismatch palsu (log `sh_auth_oidc tenant_check=compat mismatch`).
7. `audit_logs` memuat semua aksi di atas dengan `actor_user_id` terisi.
