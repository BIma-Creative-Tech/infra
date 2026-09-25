# infra-job — jembatan job control plane → skrip root (DRAFT J1)

Status: **draft J1** (plan 05, ADR 0009) — belum diterapkan di host. Diterapkan Lead di J4 (staging) / J6 (prod).
Difinalkan docs-versioning di J7.

## Komponen

| Komponen | Path host | Sumber repo |
|---|---|---|
| Dispatcher (root 0755, Python 3 stdlib) | `/usr/local/sbin/infra-job <prod\|staging>` | `scripts/infra-job/infra_job.py` |
| Unit service (oneshot, hardening) | `/etc/systemd/system/infra-job@.service` | `ansible/roles/infra_jobs/templates/infra-job@.service.j2` |
| Unit path per instance | `/etc/systemd/system/infra-job-{prod,staging}.path` (`DirectoryNotEmpty=` spool/new) | `…/templates/infra-job.path.j2` |
| Kuota/timeout per instance (JSON) | `/etc/infra-jobs/<inst>.conf` (root 0644) | `…/templates/instance.conf.j2` (+ `infra_jobs_overrides`) |
| Kill switch file | `/etc/infra-jobs/<inst>.disabled` | var `infra_jobs_instances.<inst>.disabled` |
| Retensi + mode saat boot | `/etc/tmpfiles.d/infra-jobs.conf` | `…/templates/infra-jobs.tmpfiles.j2` |
| Kontrak (fixture bersama CP) | — | `scripts/infra-job/contract/fixtures.json` |
| Test | — | `scripts/infra-job/tests/test_infra_job.py` |

## Konstanta antarmuka (J2 control plane, J3 compose)

| Item | prod | staging |
|---|---|---|
| User/grup host penulis job | `cpjob-prod` uid **950** gid **950** | `cpjob-staging` uid **951** gid **951** |
| Compose worker `user:` | `"950:950"` | `"951:951"` |
| Bind mount spool (rw) | `/var/lib/infra-jobs/prod/spool:/jobs/spool` | `/var/lib/infra-jobs/staging/spool:/jobs/spool` |
| Bind mount hasil (ro) | `/var/lib/infra-jobs/prod/results:/jobs/results:ro` | `/var/lib/infra-jobs/staging/results:/jobs/results:ro` |
| env yang diterima | `prod`, `demo` | `staging` |
| Host yang diterima | `<label>.erp.bimacreative.tech` | `<label>.staging.bimacreative.tech` |

Web control plane **tidak** mendapat mount dan tetap uid 1001.

Tata letak (Ansible + tmpfiles; dicek ulang dispatcher setiap run — mode/owner beda → run gagal, email OnFailure):

```
/var/lib/infra-jobs/                     root:root 0755
  <inst>/                                root:root 0755
    spool/                               root:cpjob-<inst> 0730   → /jobs/spool (rw)
      tmp/                               cpjob-<inst>:cpjob-<inst> 0700  (age 1d)
      new/                               root:cpjob-<inst> 0730   (dipantau infra-job-<inst>.path)
    work/                                root:root 0700   (sedang diproses + ledger idempotensi/kuota + alert-state)
    rejected/                            root:root 0700   (file ditolak, forensik; age 30d)
    results/                             root:cpjob-<inst> 0750   → /jobs/results (ro); file <job_id>.json 0640 (age 7d)
/var/log/infra-jobs/                     root:root 0750
  <inst>/<job_id>.log                    root 0600 (stdout+stderr penuh, memuat email = PII; age 30d)
```

### Cara worker menulis job

1. Tulis `/jobs/spool/tmp/<job_id>.json` (mode ≤ 0644, mis. 0600; ≤ 8192 byte; ASCII saja), `fsync`.
2. `rename` → `/jobs/spool/new/<job_id>.json` (atomik, satu mount). Nama file **harus** `<job_id>.json`, UUID huruf kecil.
3. Tunggu `/jobs/results/<job_id>.json`: pertama `state=running`, lalu final (`succeeded`/`failed`). File diganti atomik
   (rename) — tidak pernah terbaca setengah. Hanya file `^<uuid>\.json$` yang muncul di `results/`.
4. Tidak ada hasil setelah deadline → CP menandai `failed` `no_result` (watchdog CP; dispatcher tidak pernah menulisnya).
   Terjadi bila: nama file tidak valid, dispatcher/path unit mati, kill switch `systemctl disable --now …path`, atau
   `job_id` duplikat (hasil lama dipertahankan, file baru dibuang ke `rejected/`).

### File job (v1) — skema ketat

```json
{"v":1,"job_id":"3f2c7a9e-1b4d-4e8a-9c3f-5a6b7c8d9e0f","type":"odoo_sso_user","slug":"acme-co","env":"prod",
 "dry_run":false,"actor":"user:6b1f0e2a-4c3d-4e5f-8a9b-0c1d2e3f4a5b","requested_at":"2026-09-25T10:00:00Z",
 "args":{"action":"grant","email":"budi@acme.co.id","login":"budi","admin":false,"create_kc":true}}
```

Semua kunci top-level **wajib**, kunci lain ditolak; kunci JSON duplikat, float, NaN, byte non-ASCII, NUL ditolak.

| Field | Aturan (regex `fullmatch`, ASCII) |
|---|---|
| `v` | integer `1` (bukan `true`/`1.0`) |
| `job_id` | `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}` = nama file |
| `type` | `odoo_db_provision` · `odoo_route` · `odoo_sso_provision` · `odoo_sso_disable` · `odoo_sso_user` |
| `slug` | `[a-z0-9][a-z0-9-]{1,28}[a-z0-9]` (**lebih ketat** dari skrip: tidak diawali/diakhiri `-`) |
| `env` | prod-inst: `prod`\|`demo`; staging-inst: `staging` (lintas instance = ditolak + email) |
| `dry_run` | boolean |
| `actor` | `(user\|system):[A-Za-z0-9._@:-]{1,128}` (hanya untuk log host; tanpa email) |
| `requested_at` | `YYYY-MM-DDTHH:MM:SSZ` (UTC, **tanpa** pecahan detik), tanggal valid |

`args` per tipe (`R` = wajib, `O` = opsional, kunci lain ditolak):

| type | args | dry_run | Catatan |
|---|---|---|---|
| `odoo_db_provision` | `host` O (R untuk `demo`) | harus `false` | kuota 3/24 jam |
| `odoo_route` | `remove` R bool, `host` O (R untuk `demo` bila `remove=false`; dilarang bila `remove=true`) | harus `false` | `remove=true` → email |
| `odoo_sso_provision` | `hosts` R 1..5 unik, `rotate_secret` R bool, `skip_smoke` R bool | bebas | dry-run pendahulu; `rotate_secret` → email + kuota 5/24 jam |
| `odoo_sso_disable` | `hosts` R 1..5 unik | bebas | dry-run pendahulu; selalu email |
| `odoo_sso_user` | `action` R `grant`\|`revoke`\|`resend_invite`, `email` R, `login` O, `admin` R bool, `create_kc` R bool | bebas | dry-run pendahulu untuk grant/resend_invite; `revoke` → `admin=false`, `create_kc=false`; `resend_invite` → `create_kc=false`; kuota 30/jam |

- Host: `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.erp\.bimacreative\.tech` (prod/demo) atau `…\.staging\.bimacreative\.tech`.
  `odoo_sso_*`: setiap host **harus** ada sebagai ``Host(`…`)`` di `traefik/dynamic/clients/<slug>-<env>.yml` (root-owned,
  header `render-client-route.sh`), kecuali `odoo_sso_provision` + `skip_smoke=true` untuk host default
  `<slug>.erp.bimacreative.tech` / `<slug>.staging.bimacreative.tech` (bukan demo).
- Email: `[a-z0-9_%+][a-z0-9._%+-]{0,63}@(label\.)+[a-z]{2,63}`, ≤ 254, **huruf kecil** (CP wajib me-lowercase; huruf
  besar ditolak, tidak diubah diam-diam). Login: `[A-Za-z0-9._@+][A-Za-z0-9._@+-]{0,253}` (= CP `LOGIN_REGEX`).
- Kuota (per instance, jendela bergulir; menghitung job yang **diterima**, termasuk job `dry_run`): total 60/jam,
  `odoo_db_provision` 3/24 jam, `odoo_sso_user` 30/jam, `rotate_secret` 5/24 jam. Ubah di `/etc/infra-jobs/<inst>.conf`
  lewat var Ansible (`infra_jobs_quota`, `infra_jobs_overrides`).

argv persis per tipe: lihat `valid[].argv` di `scripts/infra-job/contract/fixtures.json`. Fixture CP (J2) disalin ke
`scripts/infra-job/tests/fixtures/control-plane/` (asal di `ORIGIN.txt`) dan diuji terhadap dispatcher. Environment skrip hanya
`PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, `LANG=C.UTF-8`; cwd `/opt/infra`; stdin `/dev/null`.

### File hasil

```json
{"v":1,"job_id":"…","instance":"staging","type":"odoo_sso_provision","dry_run":true,"state":"succeeded",
 "phase":"dry_run","exit_code":0,"error_code":null,"error_detail":null,
 "started_at":"2026-09-25T05:44:01Z","finished_at":"2026-09-25T05:44:05Z","duration_ms":3668,
 "result":{"db":"ssotest_staging","realm":"platform-staging","client":"odoo-ssotest-staging","provider":"4",
           "hosts":"ssotest.staging.bimacreative.tech","changed":"0","mode":"dry-run","blockers":"0"},
 "tail":["[ssotest_staging] … ", "[redacted]", "…"]}
```

- `state`: `running` → `succeeded` | `failed`. `succeeded` = exit 0 **dan** baris `RESULT` ada.
- `phase`: `dry_run` | `apply` | `null` (ditolak sebelum eksekusi). Gagal di dry-run pendahulu → `phase=dry_run`.
- `error_code`: `rejected_validation`, `rejected_quota`, `disabled`, `blocked_dry_run`, `locked`, `timeout_state_unknown`,
  `script_exit` (`no_result` hanya CP). `error_detail` = teks tetap dispatcher (tidak menggemakan nilai dari file job).
- `type`/`dry_run` bisa `null` bila file tidak ter-parse.
- `result`: baris `RESULT` terakhir fase terakhir, kunci allowlist `db realm client provider hosts changed kc_user odoo_user
  action mode blockers route host created pool`, nilai `[A-Za-z0-9._,:@/=-]{0,512}`; `secret`, `secret_file` dibuang.
- Job `dry_run=true` dengan `blockers>0` tetap `succeeded` (rencana untuk ditampilkan; cek `result.blockers`).
- `tail`: ≤ 40 baris / ≤ 8 KiB, baris ≤ 400 char; baris cocok `(?i)secret|token|password|passwd|bearer|authorization`
  → `[redacted]`; karakter non-printable (ESC, bidi override) → `?`.

## Operasi

- Log host: `journalctl -t infra-job` (satu baris START + satu baris selesai per job: `inst id type slug env actor state
  error exit dur_ms sha256(payload)` — **tanpa email**); log penuh `/var/log/infra-jobs/<inst>/<id>.log` (root).
- Email alert (lewat `scripts/lib/infra_alert_mail.py` + `/etc/infra-healthcheck/alert.env`): semua `rejected_*`, nama file
  tidak valid, `job_id` duplikat, konfigurasi invalid, `odoo_sso_disable`, `rotate_secret`, `odoo_route remove`. Satu email per
  run; maks 6 email/jam/instance (sisanya hanya journal, jumlahnya disebut di email berikutnya). Unit gagal
  (tata letak salah, trigger/start limit) → `OnFailure=infra-unit-failure@%n` → email healthcheck.
- Kill switch (urut dari paling cepat): `touch /etc/infra-jobs/<inst>.disabled` (job ditolak `disabled`, CP langsung tahu) ·
  `systemctl disable --now infra-job-<inst>.path` (job tertahan, CP `no_result`) · Ansible `path_enabled: false` /
  `disabled: true` · `infra_jobs_state: absent`.
- Timeout per tipe (detik): `odoo_db_provision` 900, `odoo_sso_provision` 300, `odoo_sso_user` 180, `odoo_sso_disable` 120,
  `odoo_route` 60, dry-run pendahulu 60. Timeout → SIGTERM grup proses, 30 s → SIGKILL, `timeout_state_unknown`.
  **UNVERIFIED (AC-J8, J4):** apakah proses `odoo` di dalam container ikut berhenti.
- Tabrakan lock skrip (`… sedang berjalan (lock)`) → `locked` (boleh diulang).
- Satu run: maks 100 file / 30 menit; sisanya diproses run berikutnya (path unit memicu ulang selama `new/` berisi).

## Hardening unit (diverifikasi 2026-09-25)

`NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectSystem=full ProtectKernel{Tunables,Modules,Logs}
ProtectControlGroups ProtectClock ProtectHostname RestrictSUIDSGID RestrictRealtime RestrictNamespaces LockPersonality
SystemCallArchitectures=native RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_FOWNER CAP_FSETID UMask=0077`.

Verifikasi: transient unit `systemd-run --wait --pipe -p <properti di atas>` menjalankan seluruh unit test dispatcher +
`INFRA_JOB_LIVE_DRYRUN=1` (dispatcher → `provision-odoo-sso.sh` dry-run, `--disable --dry-run`, `odoo-sso-user.sh` grant
dry-run terhadap container/Keycloak staging live) → 180 test OK (1 skip: fixture setuid diblok `RestrictSUIDSGID`).
**Belum diverifikasi:** jalur apply (`install -o/-g`, `chown` file secret OIDC, `mv` route, `docker exec … odoo -i`) di bawah
`CapabilityBoundingSet`/`ProtectSystem=full` → AC-J6 di J4. Gagal karena hardening → hapus direktif yang terbukti menghalangi
(bukan semuanya) dan catat di sini.

## Test

```
python3 -m unittest discover -s scripts/infra-job/tests -v                        # tanpa efek samping (tmp + skrip palsu)
INFRA_JOB_LIVE_DRYRUN=1 python3 -m unittest discover -s scripts/infra-job/tests   # + dry-run skrip asli (root, read-only;
                                                                                   #   wrapper menolak non --dry-run)
```

## Apply (J4, Lead)

```
cd /opt/infra/ansible
/opt/ansible-venv/bin/ansible-playbook site.yml --tags infra_jobs,auditd --check --diff
/opt/ansible-venv/bin/ansible-playbook site.yml --tags infra_jobs,auditd
/opt/ansible-venv/bin/ansible-playbook site.yml --tags infra_jobs,auditd      # run kedua: changed=0
```

Rollback: `infra_jobs_instances.<inst>.path_enabled: false` (atau `systemctl disable --now infra-job-<inst>.path`);
penuh: `-e infra_jobs_state=absent` (unit, `/usr/local/sbin/infra-job`, tmpfiles, user/grup dihapus; spool/log/etc tetap).
