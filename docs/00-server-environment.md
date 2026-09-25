# 00 — Server Environment yang Harus Disiapkan

Dokumen ini adalah prasyarat sebelum Claude Code (Lead) memulai FASE 0. Item bertanda
**[USER]** harus disiapkan oleh pemilik VPS; item **[ANSIBLE]** dikerjakan playbook
bootstrap; item **[CLAUDE]** dikerjakan agent setelah discovery.

## 1. Spesifikasi VPS
| Skenario | vCPU | RAM | Disk (NVMe/SSD) | Catatan |
|---|---|---|---|---|
| Minimum uji (platform + 1–2 client kecil) | 4 | 16 GB | 120 GB | Baseline platform ±9 GB |
| **Rekomendasi awal** (platform + 5–8 client di shared pool) | 8 | 32 GB | 240 GB | Ruang tumbuh, swap 4 GB |
| Skala lanjut | Pindahkan mail/observability ke VPS-2, atau dedicated Odoo per client besar | | | |

> UPDATED 2026-09-23 (T07, analyst — `docs/adr/0004-capacity.md` § "Pengukuran T07"): **spek VPS
> aktual = 4 vCPU (AMD EPYC 9354P) / RAM 15,6 GiB (15 992 MiB, `free -m`) / disk `/` 193 GB**, setara
> baris "Minimum uji" di atas — **diputuskan tetap, tanpa upgrade** (keputusan user #4). Pengukuran
> `docker stats` T07 atas 5 service yang sudah bring-up (traefik, crowdsec, postgres, keycloak,
> +whoami uji) menunjukkan pemakaian nyata jauh di bawah `mem_limit` (≈664 MiB terpakai dari
> 4 080 MiB cap, RAM `available` host 14 295 MiB) — namun ini beban **idle**, belum termasuk Odoo
> pool/mail/control-plane/observability/datamart yang belum di-deploy. Proyeksi kapasitas
> "platform + 3–5 client kecil" pada baris "Minimum uji" **belum berubah** dari ADR 0004 (revisi
> penuh menunggu T19). Baris "Rekomendasi awal" (8 vCPU/32 GB) tetap sebagai opsi upgrade bila
> threshold § 6 di bawah terpicu, bukan kebutuhan saat ini.
> UPDATED 2026-09-25 (T19, analyst — `docs/adr/0004-capacity.md` § "Pengukuran ulang T19"): semua service
> berjalan (20 container). **NYATA:** jumlah `mem_limit` 12 400 MiB, pemakaian container ≈ 3 033 MiB (24%), RAM used
> host p95 48 j 5 029 MiB (puncak 10 767 MiB + swap 1,19 GiB saat **build image lokal**), CPU busy rata-rata 16% /
> p95 48%, disk `/` 95 G/193 G (49%) naik ±30–50 GB/hari karena image/build cache/worktree build (data platform
> < 0,2 GB/hari) → runway ke 80% ≈ 1,3–2 hari sampai build dibersihkan. Sisa perencanaan RAM ≈ 1 160 MiB
> (≈ 584 setelah DRMS prod) dengan cadangan host **2 048 MiB** (keputusan user 2026-09-25; sebelumnya 1 536 → ≈ 1 672 /
> ≈ 1 096): **+3–4 tenant Odoo kecil** (pembatas: RAM odoo-staging) dan **≤ 2 website Next.js baru** (sebelumnya ≤ 3–4).
> Spek "Minimum uji" tetap cukup untuk target itu; pemicu VPS-2/upgrade di ADR 0004 T19 §6.

- OS: **Ubuntu Server 24.04 LTS** (fresh install).
- Virtualisasi KVM (bukan OpenVZ/LXC) agar Docker, cgroups v2, dan nested limit berjalan.
- IPv4 publik statis.
  > UPDATED 2026-09-23: lihat `docs/adr/0002-tls-dns-manual.md` #4 dan
  > `docs/adr/0005-mail-ipv4.md` — platform ini **IPv4-only di edge** (tanpa AAAA, tanpa
  > jalur IPv6 di container mail/Traefik) untuk fase 1. IPv6 boleh diaktifkan kembali lewat
  > ADR baru bila PTR IPv6 dan jalur mail IPv6 sudah aman.
- **[USER] Pastikan provider tidak memblokir port 25 outbound** (tanya support; banyak
  provider blok default). Tanpa ini mail server tidak bisa kirim.
- **[USER] rDNS/PTR** IP → `mail.<platform-domain>` diset dari panel provider.
- **[USER] Snapshot/backup level provider** aktif sebagai lapisan tambahan.

## 2. Domain & DNS **[USER]**
> UPDATED 2026-09-23: lihat `docs/adr/0002-tls-dns-manual.md`. Keputusan user: DNS domain
> platform dikelola **manual** di DNS manager Hostinger, **tanpa API**. Domain platform yang
> dipakai = **`bimacreative.tech`**. Karena tidak ada API DNS, TLS diterbitkan via **HTTP-01
> per hostname** (resolver `le-http`), **bukan** DNS-01/wildcard — lihat CLAUDE.md §3.5.1.
> Daftar record DNS lengkap (status nyata vs target, termasuk perbaikan MX/SPF/DMARC/CAA
> yang diperlukan) ada di ADR 0002 §"Daftar record DNS".

- Domain platform (`bimacreative.tech`) dikelola manual (tanpa API) di Hostinger DNS manager.
- Record awal (lihat ADR 0002 untuk nilai & status persis):
  - `A  edge.bimacreative.tech → 31.97.50.221` (target CNAME untuk domain client)
  - `A  *.erp.bimacreative.tech`, `*.staging.bimacreative.tech`, `cp.bimacreative.tech`,
    `auth.bimacreative.tech`, `grafana.bimacreative.tech`, `status.bimacreative.tech` →
    IP VPS (via wildcard atau record eksplisit)
  - `A  mail.bimacreative.tech`, `MX bimacreative.tech → mail.bimacreative.tech` (satu-satunya
    MX), SPF/DKIM/DMARC (DKIM diisi setelah docker-mailserver menghasilkan key)
  - **Tidak ada AAAA** untuk hostname mana pun (IPv4-only, ADR 0002/0005); CAA
    `0 issue "letsencrypt.org"` + `0 issuewild ";"`.
- Domain client: client mengarahkan `A` ke IP VPS atau `CNAME → edge.bimacreative.tech`, plus
  TXT verifikasi yang diberikan control plane, **tanpa AAAA**. Router untuk domain client
  hanya dibuat setelah pre-check `dig` lulus (ADR 0002 Decision #5).

## 3. Akun & kredensial **[USER]** (simpan di password manager, jangan kirim via chat)
> UPDATED 2026-09-23: `DNS_API_TOKEN` **dihapus** dari kebutuhan — DNS dikelola manual tanpa
> API (`docs/adr/0002-tls-dns-manual.md`). Tidak ada token DNS yang perlu disimpan sebagai
> GitHub Secret atau di host (nilai plus keamanan: tidak ada secret DNS yang bisa dicuri).
- GitHub organization/akun: repo `infra`, `control-plane`, `odoo-addons-shared`,
  `odoo-addons-<slug>`; GHCR aktif; GitHub Secrets: `VPS_HOST`, `VPS_SSH_KEY` (deploy key),
  `GHCR_TOKEN` (atau `GITHUB_TOKEN` default).
- Storage S3-compatible offsite untuk restic (Backblaze B2 / Wasabi / MinIO di lokasi lain):
  bucket + access key.
- Email/Telegram untuk alert (bot token & chat id jika Telegram).
- SSH keypair admin (ed25519) dan keypair terpisah untuk user `deploy`.

## 4. Bootstrap host **[ANSIBLE]** (`/opt/infra/ansible/site.yml`, idempotent)
> UPDATED 2026-09-23: lihat `docs/plans/01-host-bootstrap.md` untuk prosedur anti-lockout
> S0–S8 (wajib diikuti persis, tidak boleh lompat langkah) dan detail role Ansible dua
> inventory (`local` + `remote`).
1. User `admin` (sudo, key-only) dan `deploy` (**tanpa** grup `sudo`/`docker`; sudo hanya ke
   skrip wrapper root-owned `/usr/local/sbin/infra-deploy <stack>` — lihat catatan §4.8).
2. `sshd`: `Port 2221`, `PermitRootLogin no`, `PasswordAuthentication no`,
   `AllowUsers admin deploy`, `MaxAuthTries 3`.
3. Paket: `docker-ce`, `docker-compose-plugin`, `ufw`, `fail2ban`, `unattended-upgrades`,
   `restic`, `git`, `auditd`, `chrony`, `crowdsec` (agent host) .
4. `ufw`: default deny incoming/allow outgoing; allow SSH(custom), 80, 443, 25, 465, 587, 993.
   Catatan: Docker mem-bypass ufw untuk port yang di-publish — karena itu **tidak ada** service
   selain Traefik dan mail yang publish port, dan verifikasi dengan `ss -tlnp`.
5. `sysctl`: `net.ipv4.ip_forward=1` (docker), `vm.swappiness=10`, `fs.inotify.max_user_watches`
   dinaikkan, `net.core.somaxconn=4096` (nilai host saat ini; **jangan diturunkan** —
   `docs/plans/01-host-bootstrap.md` §2).
6. Swap file 4 GB, timezone `Asia/Jakarta`, locale `en_US.UTF-8`.
7. Docker daemon.json: `log-driver json-file`, `max-size 10m`, `max-file 3`,
   `live-restore true`, `userland-proxy false`, `no-new-privileges true`, `icc false`
   (isolasi antar network default); sejak T19 (2026-09-25) juga `builder.gc` (build cache ≤ 10 GiB,
   lantai 2 GiB, pangkas bila Bfree < 56 GiB — `docs/adr/0004-capacity.md` § "Pengukuran ulang T19" §8.1).
8. Struktur `/opt/infra` (owner `root:admin`, 750; `*/data` 700 owner service).
   > UPDATED 2026-09-23: owner **`deploy:docker`** yang diusulkan sebelumnya **ditolak** —
   > anggota grup `docker` setara root di host, dan `deploy` yang bisa menulis skrip yang
   > dieksekusi via sudo/cron root membuka eskalasi hak. Lihat
   > `docs/plans/01-host-bootstrap.md` (catatan §4 & threat model E).
9. Backup (systemd timer, boleh cron — lihat `docs/adr/0006-backup.md`): dump DB 01:30,
   backup file 02:00, `restic copy` ke remote 02:30 (jika remote dikonfigurasi),
   `restic forget --prune` mingguan, `restic check` mingguan/bulanan, restore test bulanan
   (laporan ke alert). Repo restic **lokal dulu** (bukan backup sejati terhadap kehilangan
   host) sampai S3 offsite tersedia.
10. Verifikasi akhir playbook: cetak `ufw status`, `sshd -T` ringkas, `docker info`, `free -h`.

## 5. Platform services **[CLAUDE]** — urutan bring-up
> UPDATED 2026-09-23: lihat `docs/plans/02-platform-bringup.md` untuk dependency graph
> lengkap (task, agent, depends_on) dan urutan gelombang paralel.
1. `traefik` (network `proxy`, resolver `le-http` **HTTP-01 per hostname** — tanpa
   DNS-challenge/wildcard (`docs/adr/0002-tls-dns-manual.md`), dashboard hanya via IP allowlist
   + basic auth, middleware: `security-headers`, `ratelimit-default`, `ratelimit-login`,
   `crowdsec-bouncer` (termasuk CrowdSec AppSec — **bukan** Coraza, `docs/adr/0001-stack.md`)).
2. `security/crowdsec` (agent + bouncer Traefik; collection `crowdsecurity/traefik`,
   `crowdsecurity/http-cve`, `crowdsecurity/sshd`, `crowdsecurity/postfix`).
3. `postgres` shared cluster (`postgres:16.x`, `pg_hba` hanya network internal, `shared_buffers`
   25% RAM alokasi, `max_connections` sesuai workers Odoo + pool). Pertimbangkan PgBouncer.
4. `identity/keycloak` (`quay.io/keycloak/keycloak:<pin>`, DB `keycloak`, realm `platform`,
   admin console hanya allowlist).
5. `odoo/pool-a` (Odoo CE 19.0, workers, addons path — **tanpa** `oca/`, modul sendiri
   `sh_dbfilter_header`/`sh_auth_oidc`, `docs/adr/0003-odoo-no-oca.md`, `list_db=False`).
6. `mail` (docker-mailserver, IPv4-only, rspamd, fail2ban internal, DKIM per domain generate
   → isi DNS, `docs/adr/0005-mail-ipv4.md`).
7. `web/control-plane` (Next.js + worker pg-boss + docker-socket-proxy).
8. `datamart` (DB `datamart`, dbt container, cron).
9. `observability` (Prometheus, node-exporter, cAdvisor, Loki, **Grafana Alloy** — bukan
   Promtail (EOL, `docs/adr/0001-stack.md`), Grafana, Uptime Kuma).
10. `staging/*` mirror untuk control-plane, odoo pool staging DB, web client.

## 6. Checklist sebelum menyerahkan ke Claude Code
- [ ] VPS Ubuntu 24.04 baru, akses SSH root/sudo awal (hanya untuk bootstrap; akan dinonaktifkan)
- [ ] Port 25 outbound dikonfirmasi terbuka; PTR diset
- [ ] Domain platform tersedia (DNS boleh dikelola manual tanpa API — `docs/adr/0002-tls-dns-manual.md`)
- [ ] Repo GitHub dibuat (boleh kosong) + GitHub Secrets diisi
- [ ] Bucket offsite + kredensial restic tersedia
- [ ] Kanal alert (email/Telegram) ditentukan
- [ ] Daftar client awal: slug, domain, plan, env yang dibutuhkan (prod/demo/staging)
- [ ] Keputusan: threshold shared pool → dedicated
      > UPDATED 2026-09-23 (T07, analyst): default usulan lama (**"> 25 user aktif atau > 2 GB
      > RAM rata-rata per DB"**) di baris ini **sudah usang** — diselaraskan dengan
      > `docs/adr/0004-capacity.md` § "Threshold shared → dedicated" (accepted, GATE 1):
      > client dipindah ke dedicated bila salah satu terpenuhi 7 hari berturut-turut —
      > **> 10 user konkuren puncak** (≈55% kapasitas pool prod) **atau > 25 user aktif
      > terdaftar**; DB **> 5 GB** atau filestore **> 20 GB**; CPU pool prod rata-rata **> 70%**
      > dengan client tsb **> 40%** kontribusi request; atau butuh versi/addon Odoo berbeda/SLA
      > terpisah. Angka Odoo pool ini masih ESTIMASI (belum diukur nyata — Odoo belum bring-up
      > saat T07), direvisi di T19.
- [ ] File `CLAUDE.md` dan `.claude/agents/*` disalin ke root repo `infra`

## 7. Cara memulai sesi Claude Code (Opus)
```
cd /opt/infra
claude   # pastikan model Opus dipilih (/model)
```
Pesan pertama ke Lead (contoh):
```
Kamu Lead. Baca CLAUDE.md dan docs/00-server-environment.md. Mulai FASE 0: minta Analyst
melakukan discovery pada VPS ini (Claude Code berjalan langsung di VPS, repo di /opt/infra), lalu
kembali ke saya dengan ringkasan fakta, pertanyaan terbuka, dan usulan rencana FASE 1.
Jangan implementasi apa pun sebelum saya setujui.
```
