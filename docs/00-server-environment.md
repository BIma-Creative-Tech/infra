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

- OS: **Ubuntu Server 24.04 LTS** (fresh install).
- Virtualisasi KVM (bukan OpenVZ/LXC) agar Docker, cgroups v2, dan nested limit berjalan.
- IPv4 publik statis; IPv6 opsional tapi dianjurkan.
- **[USER] Pastikan provider tidak memblokir port 25 outbound** (tanya support; banyak
  provider blok default). Tanpa ini mail server tidak bisa kirim.
- **[USER] rDNS/PTR** IP → `mail.<platform-domain>` diset dari panel provider.
- **[USER] Snapshot/backup level provider** aktif sebagai lapisan tambahan.

## 2. Domain & DNS **[USER]**
- Domain platform (mis. `platform.id`) dikelola di provider DNS dengan API (Cloudflare
  dianjurkan; proxy Cloudflare **OFF** untuk `mail.*`, boleh ON untuk web). Token API
  scope DNS-edit disiapkan untuk Traefik DNS challenge (wildcard) dan verifikasi domain.
- Record awal:
  - `A  edge.platform.id → <IP VPS>` (target CNAME untuk domain client)
  - `A  *.erp.platform.id`, `*.staging.platform.id`, `cp.platform.id`, `auth.platform.id`,
    `grafana.platform.id`, `status.platform.id` → IP VPS (atau wildcard `*.platform.id`)
  - `A  mail.platform.id`, `MX platform.id → mail.platform.id`, SPF/DKIM/DMARC (diisi
    setelah docker-mailserver menghasilkan key DKIM)
- Domain client: client mengarahkan `A` ke IP VPS atau `CNAME → edge.platform.id`, plus
  TXT verifikasi yang diberikan control plane.

## 3. Akun & kredensial **[USER]** (simpan di password manager, jangan kirim via chat)
- GitHub organization/akun: repo `infra`, `control-plane`, `odoo-addons-shared`,
  `odoo-addons-<slug>`; GHCR aktif; GitHub Secrets: `VPS_HOST`, `VPS_SSH_KEY` (deploy key),
  `GHCR_TOKEN` (atau `GITHUB_TOKEN` default), `DNS_API_TOKEN`.
- Storage S3-compatible offsite untuk restic (Backblaze B2 / Wasabi / MinIO di lokasi lain):
  bucket + access key.
- Email/Telegram untuk alert (bot token & chat id jika Telegram).
- SSH keypair admin (ed25519) dan keypair terpisah untuk user `deploy`.

## 4. Bootstrap host **[ANSIBLE]** (`/opt/infra/ansible/site.yml`, idempotent)
1. User `admin` (sudo, key-only) dan `deploy` (sudo terbatas ke `docker compose` di `/opt/infra`).
2. `sshd`: `Port <non-default>`, `PermitRootLogin no`, `PasswordAuthentication no`,
   `AllowUsers admin deploy`, `MaxAuthTries 3`.
3. Paket: `docker-ce`, `docker-compose-plugin`, `ufw`, `fail2ban`, `unattended-upgrades`,
   `restic`, `git`, `auditd`, `chrony`, `crowdsec` (agent host) .
4. `ufw`: default deny incoming/allow outgoing; allow SSH(custom), 80, 443, 25, 465, 587, 993.
   Catatan: Docker mem-bypass ufw untuk port yang di-publish — karena itu **tidak ada** service
   selain Traefik dan mail yang publish port, dan verifikasi dengan `ss -tlnp`.
5. `sysctl`: `net.ipv4.ip_forward=1` (docker), `vm.swappiness=10`, `fs.inotify.max_user_watches`
   dinaikkan, `net.core.somaxconn=1024`.
6. Swap file 4 GB, timezone `Asia/Jakarta`, locale `en_US.UTF-8`.
7. Docker daemon.json: `log-driver json-file`, `max-size 10m`, `max-file 3`,
   `live-restore true`, `userland-proxy false`, `no-new-privileges true`, `icc false`
   (isolasi antar network default).
8. Struktur `/opt/infra` (owner `deploy:docker`, 750), `/opt/infra/*/data` 700.
9. Cron: `backup.sh` 02:00, `restic forget --prune` mingguan, `pg_dump` semua DB 01:30,
   restore test bulanan (laporan ke alert).
10. Verifikasi akhir playbook: cetak `ufw status`, `sshd -T` ringkas, `docker info`, `free -h`.

## 5. Platform services **[CLAUDE]** — urutan bring-up
1. `traefik` (network `proxy`, ACME DNS-challenge wildcard, dashboard hanya via IP allowlist
   + basic auth, middleware: `security-headers`, `ratelimit-default`, `ratelimit-login`,
   `crowdsec-bouncer`, `coraza-waf`).
2. `security/crowdsec` (agent + bouncer Traefik; collection `crowdsecurity/traefik`,
   `crowdsecurity/http-cve`, `crowdsecurity/sshd`, `crowdsecurity/postfix`).
3. `postgres` shared cluster (`postgres:16.x`, `pg_hba` hanya network internal, `shared_buffers`
   25% RAM alokasi, `max_connections` sesuai workers Odoo + pool). Pertimbangkan PgBouncer.
4. `identity/keycloak` (`quay.io/keycloak/keycloak:<pin>`, DB `keycloak`, realm `platform`,
   admin console hanya allowlist).
5. `odoo/pool-a` (Odoo CE 19.0, workers, addons path, `list_db=False`).
6. `mail` (docker-mailserver, rspamd, fail2ban internal, DKIM generate → isi DNS).
7. `web/control-plane` (Next.js + worker pg-boss + docker-socket-proxy).
8. `datamart` (DB `datamart`, dbt container, cron).
9. `observability` (Prometheus, node-exporter, cAdvisor, Loki, Promtail, Grafana, Uptime Kuma).
10. `staging/*` mirror untuk control-plane, odoo pool staging DB, web client.

## 6. Checklist sebelum menyerahkan ke Claude Code
- [ ] VPS Ubuntu 24.04 baru, akses SSH root/sudo awal (hanya untuk bootstrap; akan dinonaktifkan)
- [ ] Port 25 outbound dikonfirmasi terbuka; PTR diset
- [ ] Domain platform + token API DNS tersedia
- [ ] Repo GitHub dibuat (boleh kosong) + GitHub Secrets diisi
- [ ] Bucket offsite + kredensial restic tersedia
- [ ] Kanal alert (email/Telegram) ditentukan
- [ ] Daftar client awal: slug, domain, plan, env yang dibutuhkan (prod/demo/staging)
- [ ] Keputusan: threshold shared pool → dedicated (default usulan: > 25 user aktif atau
      > 2 GB RAM rata-rata per DB)
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
