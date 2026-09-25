# QA T17b — Re-run penuh baseline keamanan platform (read-only)

- **Tanggal:** 2026-09-25 (±16:55–17:20 WIB) · **Basis:** `main` 9c0f411 · **Branch QA:** `feat/qa-t17b` (worktree `/opt/infra-wt/t17b`)
- **Penguji:** qa-security (agent) · **Acuan:** CLAUDE.md §0/§3.5/§3.6, plan 01 §4/§6/§7, plan 02 §3–§5, ADR 0001–0009,
  `docs/03-operations/*`, `docs/risk/*`, laporan sebelumnya `docs/qa/2026-09-23-t17a-platform-core.md` (40 PASS / 8 FAIL / 23 NOT TESTABLE)
- **Mode:** READ-ONLY. Tidak ada perubahan konfigurasi, tidak ada restart, tidak ada user/data yang dibuat, tidak ada ban/unban,
  tidak ada email yang dikirim, dan tidak ada uji beban. Tidak ada payload WAF (XSS/SQLi) yang dikirim, supaya tidak muncul alert/decision.
  Secret tidak pernah ditampilkan. Panjang dan hash dibandingkan tanpa mencetak nilainya.

## Ringkasan

| Status | Baris kontrol | Temuan unik |
|---|---|---|
| PASS | 97 | — |
| FAIL | 16 | **14** (High 2 · Medium 4 · Low 8) — A8+A9 = QA-T17B-11, D9+D10 = QA-T17B-10 |
| RISK-ACCEPTED | 11 | (keputusan user/Lead + `docs/risk/*`, bertanggal) |
| NOT TESTABLE (internal) | 1 | — |
| NOT TESTABLE-EXTERNAL (harus dari laptop user / internet) | 14 | — |
| **Total** | **139** | |

**Sign-off: TIDAK tercapai.** Masih ada 2 temuan **High** yang terbuka:

1. **QA-T17B-01 (High): jalur lateral ke Odoo dan Keycloak melewati edge.** Network `db` (internal) menghubungkan pool Odoo
   (`http_interface = 0.0.0.0`) dan Keycloak dengan container lain, termasuk app klien ProyekKas *staging* (`drms-pk-stg`) dan
   control plane. Dari `drms-pk-stg`, `GET http://odoo-pool-a:8069/web/login` dengan header `X-Sh-Odoo-Db: demo_demo` menghasilkan
   **200 form login DB prod `demo_demo`**. Tanpa header hasilnya 303. Artinya pemilihan DB tenant prod bisa dilakukan tanpa
   Traefik, sehingga CrowdSec/AppSec, rate limit, dan header override ikut terlewati. `keycloak:8080`/`:9000` juga terbuka dari
   `db` dan `proxy`: `GET http://keycloak:8080/realms/master/.well-known/openid-configuration` → 200 dari `drms-pk-stg`, padahal di
   :443 path ini 403. Klaim H1 di `odoo.md` §Keamanan ("container lain tidak bisa menghubungi `odoo-pool-a:8069` langsung")
   hanya berlaku untuk `proxy`, tidak untuk `db`.
2. **QA-T17B-02 (High): image `mailserver/docker-mailserver:16.0.1` memuat 24 CRITICAL (20 fixable) dan 338 HIGH (96 fixable).**
   Container ini terekspos internet (25/465/587/993), berjalan sebagai root dengan 7 capability, dan belum punya risk acceptance.

Hasil re-test T17a: **8 FAIL T17a tidak ada lagi yang terbuka tanpa status**. Rinciannya: 4 FIXED (whoami ×3 B9/D7/F4, kredensial
awal Keycloak C6), 1 FIXED lokal (pipeline C5: hook + workflow CI; status run CI belum bisa dicek), dan 3 RISK-ACCEPTED bertanggal
(Keycloak, Postgres, CrowdSec). Bagian `.npmrc` dari QA-T17A-08 masih terbuka (QA-T17B-14). Dari 23 NOT TESTABLE, **14 kini teruji
dari host**: 13 PASS, 1 FAIL (F20 cookie → QA-T17B-06). 1 masih NOT TESTABLE (F21, karena membuat user dilarang) dan 8 menjadi
NOT TESTABLE-EXTERNAL (lihat §X).

### Batasan metode
- Uji edge dilakukan **dari host** (`curl --resolve <host>:443:127.0.0.1`). Trafik ini tiba di Traefik sebagai **`10.100.0.1`**,
  yaitu IP privat yang di-whitelist parser CrowdSec. Uji yang hasilnya tidak bergantung IP (header, TLS, 403 `deny-all`,
  tenant crossing, host tak dikenal) tetap valid. Allowlist/ban/rate limit dari IP publik **tidak** bisa dibuktikan dari sini.
- Uji jangkauan jaringan dilakukan lewat `docker exec <container> node -e 'net.connect(...)'`: hanya TCP connect dan
  satu GET anonim, tanpa kredensial, tanpa mutasi.
- Trivy (`aquasec/trivy:0.74.0`, `--rm`, docker.sock **read-only**, sama dengan T17a) dan gitleaks (`v8.30.1`, `--redact`)
  berjalan di container sementara. Output mentah ada di scratchpad sesi dan tidak di-commit.

## Re-test temuan & NOT TESTABLE T17a

| T17a | Status T17a | Status T17b | Bukti T17b |
|---|---|---|---|
| B9 / QA-T17A-06 whoami tanpa healthcheck | FAIL | **FIXED** | `whoami` tidak ada di `docker ps -a`; 19/20 container healthy (loki: pengecualian terdokumentasi, B9) |
| C5 / QA-T17A-04 pipeline | FAIL | **FIXED (lokal)** | `core.hooksPath=.githooks` + `pre-commit` gitleaks di infra/odoo-addons-shared/control-plane/web-starter; `.github/workflows/security.yml` (actionlint, gitleaks, semgrep, trivy fs/config, hadolint, shellcheck). Status run CI & branch protection → NOT TESTABLE-EXTERNAL (X9) |
| C6 / QA-T17A-07 `.admin-credentials` | FAIL | **FIXED** | file tidak ada; `platform-admin` punya kredensial `otp,password` tanpa required action (tabel `credential`) |
| D4 / QA-T17A-01 Keycloak CVE | FAIL High | **RISK-ACCEPTED** s/d 2026-10-31 | Trivy ulang: 3/3 CRITICAL fixable (netty CVE-2026-75595, bcprov CVE-2026-8763), tidak berubah. `quay.io/keycloak/keycloak:26.7.5`/`26.8.0` belum ada (`imagetools inspect`, kontrol `26.7.4` ada) |
| D5 / QA-T17A-02 Postgres | FAIL | **RISK-ACCEPTED** (review ≤ 2026-10-23) | 16 CRITICAL (1 fixable), 99 HIGH, tidak berubah; `postgres:16.16-bookworm` belum ada |
| D6 / QA-T17A-03 CrowdSec | FAIL | **RISK-ACCEPTED** s/d 2026-10-31 | 0 CRITICAL, 26 HIGH (24 fixable), tidak berubah; `v1.8.2` belum ada |
| D7 / QA-T17A-05 whoami CVE | FAIL | **FIXED** | image/container dihapus |
| F4 / QA-T17A-08 whoami bocor header | FAIL | **FIXED** / `.npmrc` OPEN | `status.bimacreative.tech` kini Uptime Kuma, router publik hanya path status (F13). `.npmrc` control-plane masih tanpa `min-release-age` → QA-T17B-14 |
| A13 Ansible remote/`ssh -p 2221` dari laptop | NT | NOT TESTABLE-EXTERNAL | X1 |
| A14 nmap eksternal | NT | NOT TESTABLE-EXTERNAL | X2 (`ss`/ufw dicek di A3/A4) |
| A15 IPv6 eksternal | NT | NOT TESTABLE-EXTERNAL | X3; host punya IPv6 global `2a02:4780:59:823e::1`, sshd `[::]:22`/`[::]:2221` (A21) |
| E3 Postgres dari `proxy`/`odoo-edge` | NT | **PASS** | B17 |
| F5 header runtime | NT | **PASS** (HSTS 300 = RISK-ACCEPTED F3) | F3/F4 |
| F6 TLS versi | NT | **PASS** (host) + X4 eksternal | F2 |
| F7 redirect http→https | NT | **PASS** | F5 |
| F8 dashboard Traefik 404 | NT | **PASS** | F6 |
| F9 Keycloak admin 403 | NT | **PASS** | F7/F8 |
| F10 OIDC discovery | NT | **PASS** | F9 |
| F11 Odoo `/web/database/*` 403 | NT | **PASS** | F10 |
| F12 tenant crossing | NT | **PASS** (via edge) — **tetapi** bypass internal QA-T17B-01 | F11 |
| F13 host tak dikenal 404 | NT | **PASS** | F12 |
| F14 AppSec payload 403 | NT | NOT TESTABLE-EXTERNAL | X5 |
| F15 false positive | NT | NOT TESTABLE-EXTERNAL | X6 |
| F16 rate limit 429 | NT | NOT TESTABLE-EXTERNAL | X7 |
| F17 brute force Odoo + cleanup | NT | NOT TESTABLE-EXTERNAL | X8 |
| F18 `list_db=False` efektif | NT | **PASS** | F10 (`:8443` → "database manager has been disabled"), I4 (`db.list` → AccessDenied) |
| F19 password default ditolak | NT | **PASS** | C12 |
| F20 cookie `session_id` | NT | **FAIL Medium** | QA-T17B-06 |
| F21 brute force Keycloak runtime | NT | NOT TESTABLE (butuh user uji → dilarang membuat user) | konfigurasi PASS (H1) |
| F22 registration off | NT | **PASS** | H3 |
| F23 ban CrowdSec otomatis | NT | NOT TESTABLE-EXTERNAL | X8 |

## Tabel kontrol

Kolom: ID · kontrol · perintah (ringkas) · status · bukti · severity (hanya untuk FAIL/RISK) · owner.

### A. Host (plan 01 §4/§7)

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| A1 | sshd hardening | `sshd -T \| grep -E '^(port\|permitrootlogin\|password…\|kbd…\|maxauthtries\|allowusers\|allowagentforwarding\|x11forwarding\|logingracetime) '` | PASS | permitrootlogin no, passwordauthentication no, kbdinteractive no, maxauthtries 3, allowusers admin deploy, agent/X11 no, logingrace 30; `Match User deploy` AllowTcpForwarding/StreamLocal no, PermitTTY no | — | infra |
| A2 | sshd hanya :2221 | `ss -tlnp` | RISK-ACCEPTED | sshd `0.0.0.0:22`, `0.0.0.0:2221`, `[::]:22`, `[::]:2221` — port 22 fallback permanen (keputusan user 2026-09-24, CLAUDE.md §3.7) | Low | user/Lead |
| A3 | Port listen vs ufw | `ss -tlnp` ↔ `ufw status verbose` | PASS | publik: 22, 2221 (sshd), 80, 443, 25, 465, 587, 993 (dockerd). Lokal: 127.0.0.1:8080 (LAPI), 127.0.0.1:8443 (Traefik `admin`), 127.0.0.53/54:53. Setiap port publik punya rule ALLOW yang cocok; tidak ada 5432/8069/8072/3000/9000 | — | infra |
| A4 | ufw | `ufw status verbose` | PASS | active; deny incoming/routed, allow outgoing; ALLOW 2221, 80, 443, 25, 465, 587, 993, 22 (komentar "sshd fallback"); v6: 2221, 80, 443, 22 | — | infra |
| A5 | fail2ban sshd | `fail2ban-client status sshd`; `jail.d/infra-sshd.local` | PASS | jail aktif, `port = 2221,22`, backend systemd, journalmatch `_SYSTEMD_UNIT=sshd.service + _COMM=sshd` (OR, cocok via `_COMM`), bantime 1h naik s/d 1w | — | infra |
| A6 | Service host | `systemctl is-active auditd chrony fail2ban docker containerd crowdsec-firewall-bouncer` | PASS | active ×6 | — | infra |
| A7 | auditd rules | `auditctl -l` | PASS | watch `/etc/ssh`, `/etc/sudoers(.d)`, `/etc/docker`, `/etc/restic`, `infra-deploy`, **`infra-job`**, **`/etc/infra-jobs`**, exec `docker`/`sudo` | — | infra |
| A8 | auditd watch `.env` (plan 01 §4) | `grep TODO ansible/roles/auditd/templates/50-infra.rules.j2` | FAIL | tidak ada watch `.env`; template masih `TODO(T03+)` | Low | infra → QA-T17B-11 |
| A9 | Retensi audit log | `grep num_logs /etc/audit/auditd.conf`; `aureport -k --summary` | FAIL | 5 × 8 MB, log tertua 2026-09-24 21:22 (±20 jam). `docker_exec` 4 122 event per ±4 jam (healthcheck 5 menit) | Low | infra → QA-T17B-11 |
| A10 | swap/sysctl/TZ/locale | `swapon --show; sysctl …; timedatectl; localectl` | PASS | /swapfile 4G; 10 · 1 · 4096 · 524288; Asia/Jakarta; en_US.UTF-8 | — | infra |
| A11 | Docker daemon | `docker version`; `daemon.json` | PASS | 29.8.1; compose v5.5.1; json-file, live-restore true; `no-new-privileges`, `userland-proxy:false`, `icc:false`, 10m×3 | — | infra |
| A12 | User deploy | `id deploy; sudo -l -U deploy` | PASS | tanpa grup docker/sudo; hanya `(root) NOPASSWD: /usr/local/sbin/infra-deploy`; grup `docker` tanpa anggota | — | infra |
| A13 | sudoers | `ls /etc/sudoers.d; visudo -c` | PASS | `50-deploy-infra` (440), `90-cloud-init-users` (root saja), parse OK; `%sudo` = `admin` | — | infra |
| A14 | Tidak ada path root yang writable oleh deploy/cpjob | `sudo -u <u> find /opt/infra /usr/local/sbin /usr/local/bin /etc/infra-jobs /etc/systemd /var/lib/infra-jobs /opt/src -writable` | PASS | hanya symlink unit ter-mask (→ /dev/null) dan spool masing-masing cpjob; `/opt/infra` 750 root:admin | — | infra |
| A15 | cloud-init | `grep -r ssh_pwauth /etc/cloud/cloud.cfg.d/` | PASS | `ssh_pwauth: false` | — | infra |
| A16 | Ansible idempoten | `ansible-playbook -i inventories/local/hosts.yml site.yml --check --diff` | PASS (catatan) | `ok=101 changed=1 failed=0`; satu-satunya `changed` = `docker : Unduh GPG key Docker` (`get_url` di mode check), fingerprint tetap diverifikasi `ok` | — | infra |
| A17 | Kunci SSH admin = deploy | `awk '{print $NF}' /home/*/.ssh/authorized_keys` | RISK-ACCEPTED | kunci ed25519 sama; deploy `restrict` + Match tanpa forwarding/TTY (plan 01 §8 #3) | Low | Lead |
| A18 | unattended-upgrades | `systemctl is-active unattended-upgrades`; log | PASS | aktif, run terakhir 2026-09-25 06:32 (curl, libexpat), `Automatic-Reboot "false"`, 0 paket security tertunda (7 paket `-updates` non-security, termasuk auditd) | — | infra |
| A19 | Reboot tertunda | `ls /var/run/reboot-required`; `uname -r` | PASS | tidak ada; kernel berjalan 6.8.0-142 = terbaru terpasang | — | infra |
| A20 | Disk/RAM | `df -h /; free -h; docker stats; docker system df` | PASS (catatan) | disk 95/193 G (49 %); RAM 4.8/15 G, swap 416 M/4 G; semua container < limit (maks grafana 67 %); build cache 30 G (23 G reclaimable), image 35.6 G (19 G reclaimable) | — | infra |
| A21 | IPv6 host | `ip -6 addr show scope global; ss -tlnp6` | PASS (catatan) | IPv6 global aktif; hanya sshd listen di v6 (docker publish v4 saja); tanpa AAAA DNS. Eksposur v6 dari luar → X3 | — | infra |

### B. Container & Docker (CLAUDE.md §3.5)

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| B1 | `Privileged=false` | `docker inspect` (20 container) | PASS | 20/20 | — | infra |
| B2 | `CapDrop=[ALL]`, `CapAdd` minimal | idem | PASS | 20/20 drop ALL; `CapAdd` hanya `mailserver` (CHOWN, DAC_OVERRIDE, FOWNER, KILL, SETGID, SETUID, SYS_CHROOT; `mail.md`) | — | infra |
| B3 | `no-new-privileges:true` | idem | PASS | 20/20 | — | infra |
| B4 | `ReadonlyRootfs` | idem | PASS | 19/20; `mailserver` false (DMS, terdokumentasi) | — | infra |
| B5 | `mem_limit` + `cpus` | idem | PASS | 20/20 (mis. odoo-pool-a 2560m/2.0, keycloak 1360m/1.0, mailserver 1024m/0.75, web-starter-staging 256m/0.5) | — | infra |
| B6 | Non-root | idem `.Config.User` | RISK-ACCEPTED | 18/20 non-root; `crowdsec` root tanpa capability (`crowdsec.md`), `mailserver` root + 7 cap (DMS) | Low | infra |
| B7 | docker.sock tidak di-mount | `docker inspect … .Mounts` | PASS | tidak ada mount `docker.sock`/`containerd` di container mana pun; alloy hanya `/var/lib/docker/containers:ro` + cgroup ro | — | infra |
| B8 | restart + logging | idem | PASS | `unless-stopped` (traefik & crowdsec `always`, H7); json-file 10m×3 semua | — | infra |
| B9 | Healthcheck | `docker ps` | RISK-ACCEPTED | 19/20 healthy; `loki` `healthcheck.disable` (distroless, dipantau `up{job="loki"}`, `observability.md`) | Low | infra |
| B10 | Image ter-pin, tanpa `latest` | `grep -rn 'image:\|FROM ' **/docker-compose.yml Containerfile`; `.env` | PASS | semua image registry tag + `@sha256`; image lokal pakai tag (`control-plane:6d94d2b`, `infra/keycloak:26.7.4-optimized` FROM ber-digest, `proyekkas-web:0.1.0-stg-e7e997a`, `web-starter:dev-d5f6148` TEMPORARY terdokumentasi); tidak ada `:latest` | — | infra |
| B11 | Port binding | `docker inspect … PortBindings` | PASS | traefik 0.0.0.0:80/443 + 127.0.0.1:8443; crowdsec 127.0.0.1:8080; mailserver 25/465/587/993 | — | infra |
| B12 | Network internal | `docker network inspect` | PASS | `db`, `metrics`, `observability`, `drms-kc-admin(-stg)` = internal; `proxy`/`odoo-edge`/`web-edge`/`drms-kas-edge`/`crowdsec`/`mail` = bridge (terdokumentasi) | — | infra |
| B13 | `odoo-edge` hanya traefik + pool | idem | PASS | `odoo-pool-a traefik odoo-staging` | — | infra |
| B14 | **Isolasi `web-edge`** | anggota + `docker exec web-starter-staging node net.connect` | PASS | anggota hanya `web-starter-staging`, `traefik`. Dari website: control-plane:3000, keycloak:8080, grafana:3000, uptime-kuma:3001, postgres:5432, odoo-pool-a:8069, crowdsec:8080, mailserver:587 → **tidak terjangkau** (timeout). Hanya Traefik (80/443/8443/8082) + gateway host (22/2221) + IP publik:587 (SMTP hairpin sesuai desain). `traefik:8443` → 403 (`ipallowlist-admin`), `:8082` lihat B16 | — | infra |
| B15 | **Tidak ada jalur ke Odoo/Keycloak yang melewati edge** | `docker exec drms-pk-stg\|control-plane\|keycloak node net.connect …`; `fetch(http://odoo-pool-a:8069/web/login, {X-Sh-Odoo-Db})`; idem `uptime-kuma` (proxy) | **FAIL** | Dari `drms-pk-stg`, `control-plane`, `keycloak` (network `db`): `odoo-pool-a:8069`, `odoo-staging:8069`, `keycloak:8080`, `keycloak:9000` → **OPEN**. `drms-pk-stg` → `GET odoo-pool-a:8069/web/login` + `X-Sh-Odoo-Db: demo_demo` → **200 form login DB prod** (tanpa header: 303). `drms-pk-stg` → `keycloak:8080/realms/master/.well-known/…` → 200 (di :443 → 403). Dari `uptime-kuma` (proxy): `keycloak:8080`, `control-plane:3000`, `grafana:3000` OPEN | **High** | infra → **QA-T17B-01** |
| B16 | Metrics Traefik tidak terjangkau selain Prometheus | `docker exec web-starter-staging node fetch http://traefik:8082/metrics` | **FAIL** | 200, 2 784 baris: nama router/service semua tenant (`auth-admin@file`, `odoo-demo-demo…`), jumlah request, kode status. Entrypoint `:8082` listen di semua network Traefik (`proxy`, `odoo-edge`, `web-edge`, `drms-kas-edge`, …), bukan hanya `metrics` seperti klaim komentar `traefik.yml` | Medium | infra → QA-T17B-03 |
| B17 | Postgres tidak terjangkau dari `proxy`/`odoo-edge` (T17a E3) | `docker exec uptime-kuma node net.connect postgres:5432 / 10.100.1.2:5432`; `docker exec traefik nc -z postgres 5432` | PASS | kuma: `EAI_AGAIN` / timeout; traefik: closed (traefik → odoo-pool-a:8069 OPEN = normal) | — | infra |
| B18 | `acme.json` di-mount ke mailserver | `docker inspect mailserver` | RISK-ACCEPTED | `/opt/infra/traefik/acme/acme.json → /etc/letsencrypt/acme.json:ro` = private key **semua** hostname ada di container root yang terekspos internet (plan 02 §4 "DMS mount read-only") | Medium | infra |

### C. Secret di disk & repo

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| C1 | Mode `.env` | `find / -xdev -name '.env' -o -name '*.env' …` | PASS | 12 `.env` platform + `/etc/restic/*.env` + `/etc/infra-healthcheck/alert.env` = **600 root**. Tidak ada `.env` yang world-readable di jalur produksi | — | infra |
| C2 | Direktori secret | `find … -name 'secrets*' -o -name acme -o -name oidc -o -name tenants` | PASS | `*/secrets`, `tenants`, `traefik/acme`, `traefik/secrets` = 700; `odoo/*/secrets/oidc` = 750 root:messagebus (gid 101 = odoo container); `staging/drms-proyekkas/secrets` 750 root (file 400 uid 1001 container) | — | infra |
| C3 | File bernama secret/password/key/token/credential | `find /opt/infra /etc /var/lib/infra-jobs … -iname '*secret*' …` | PASS | 29 file secret platform (Keycloak client secrets, mail passwords, master-password, tenant admin, restic, bouncer key, acme) = 600/400/440; **tidak ada yang world-readable** | — | infra |
| C4 | File sensitif 644 di bawah dir 700 | `find /opt/infra -perm -o+r -path '*/data/*'` | PASS (catatan) | `mail/data/config/postfix-accounts.cf` (hash) 644 di bawah `mail/data` 700; `kuma.db` 644 di bawah `data/uptime-kuma` 700; `/opt/infra` 750 root:admin | — | infra |
| C5 | Kredensial awal admin Keycloak dihapus (T17a C6) | `ls identity/keycloak/`; query `credential` | PASS | `.admin-credentials` tidak ada; `platform-admin` = `otp,password,password-history`, tanpa required action | — | — |
| C6 | Salinan secret di luar jalur yang dikelola | `find /tmp/claude-0 /root /home /opt/src -name '*.env' …`; bandingkan `sha256` baris dengan live | **FAIL** | `/tmp/claude-0/-root/<sesi>/scratchpad/cc/{odoo/pool-a,staging/odoo}/.env` (644, di bawah dir 700 root; `PGPASSWORD` & `ODOO_ADMIN_PASSWD` **≠ live**, jadi basi); `/tmp/claude-0/-home-admin/…/scratchpad/{pg.env,env/.env}` (isi tidak dibaca); `/opt/src/control-plane/.env` (600, tidak dipakai sejak T16a) + `/opt/src/control-plane/.next/standalone/.env` (600, artefak build) | Low | Lead/infra → QA-T17B-08 |
| C7 | gitleaks riwayat penuh | `gitleaks git /repo --redact` (infra, odoo-addons-shared, control-plane, web-starter) | PASS | 0 temuan ×4 (memakai `.gitleaks.toml` repo bila ada) | — | — |
| C8 | Hook pre-commit + workflow CI (T17a C5) | `git config core.hooksPath`; `ls .githooks .github/workflows` | PASS | 4 repo: `.githooks/pre-commit` + `security.yml`/`ci.yml`. Catatan: `/opt/src/proyekkas` tanpa hook lokal (repo klien) | — | infra |
| C9 | `.npmrc` supply chain (T17a-08) | `cat /opt/src/control-plane/.npmrc` | FAIL | hanya `save-exact`, `engine-strict`, `fund`; tanpa `min-release-age` | Low | nextjs-dev → QA-T17B-14 |
| C10 | Tidak ada secret di `NEXT_PUBLIC_*` | `docker exec <c> env \| grep ^NEXT_PUBLIC` | PASS | control-plane, control-plane-staging, drms-pk-stg, web-starter-staging: tidak ada `NEXT_PUBLIC_*` | — | — |
| C11 | Master password Odoo kuat | `wc -c secrets/master-password`; prefix env | PASS | prod & staging 48 char; env `ODOO_ADMIN_PASSWD` = hash `$pbkdf2-sha512` (≥ 32 char, CLAUDE.md §3.6) | — | — |
| C12 | Password default Odoo ditolak (T17a F19) | hash `res_users` → `passlib.verify` di container (tanpa mencetak) | PASS | `demo_demo` (admin, demo, portal), `demo_staging` (admin), `ssotest_staging` (admin): tidak cocok dengan `admin`/`demo`/`portal`; admin tenant 40 char | — | — |

### D. Image scan (Trivy 0.74.0, HIGH/CRITICAL, 16 image berjalan)

| ID | Image | CRIT (fixable) | HIGH (fixable) | Status | Sev | Owner |
|---|---|---|---|---|---|---|
| D1 | `traefik:v3.7.13` | 0 | 0 | PASS | — | — |
| D2 | `odoo:19.0-20260908` | 0 | 0 | PASS | — | — |
| D3 | `control-plane:6d94d2b` | 0 | 0 | PASS | — | — |
| D4 | `infra/keycloak:26.7.4-optimized` | 3 (3) | 7 (3) | RISK-ACCEPTED (`docs/risk/2026-09-23-keycloak-crowdsec-upstream-cves.md`, kedaluwarsa 2026-10-31; tag 26.7.5/26.8.0 belum ada) | High | infra |
| D5 | `postgres:16.15-bookworm` | 16 (1) | 99 (21) | RISK-ACCEPTED (`docs/risk/2026-09-23-postgres-unfixed-cves.md`, review ≤ 2026-10-23) | Medium | infra |
| D6 | `crowdsecurity/crowdsec:v1.8.1` | 0 | 26 (24) | RISK-ACCEPTED (s/d 2026-10-31; v1.8.2 belum ada) | Medium | infra |
| D7 | `mailserver/docker-mailserver:16.0.1` | **24 (20)** — perl/libperl5.40 CVE-2026-13221 (fix deb13u1), libunbound8, libglib2.0, libxml2; 3 liblmdb0 unfixed | 338 (96) | **FAIL** (terekspos internet, root; tanpa risk acceptance) | **High** | infra → **QA-T17B-02** |
| D8 | `louislam/uptime-kuma:2.5.5-rootless` | **164 (145)** — 120 di `chromium`/`chromium-common`, sisanya perl, gnutls, mariadb-client, Go stdlib | 1 688 (1 513) | FAIL | Medium | infra → QA-T17B-04 |
| D9 | `grafana/grafana:13.2.2` | 0 | 104 (104) — Go stdlib/x/net/grpc di plugin bundled | FAIL | Low | infra → QA-T17B-10 |
| D10 | `prom/prometheus:v3.13.3` · `prom/node-exporter:v1.12.1` · `grafana/alloy:v1.19.2` | 0 | 4 (4) · 9 (9) · 4 (2) | FAIL | Low | infra → QA-T17B-10 |
| D11 | `grafana/loki:3.7.8` · `proyekkas-web:0.1.0-stg-e7e997a` · `web-starter:dev-d5f6148` | 0 | 0 | PASS | — | — |

### E. Postgres & backup

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| E1 | pg_hba | `select … from pg_hba_file_rules` | PASS (catatan) | `postgres` hanya peer lokal; tiap role → DB sendiri dari `10.100.1.0/24`; sisanya reject. Catatan: regex `odoo_staging` `/^[a-z0-9_]+_staging$/` juga cocok `control_plane_staging` (ditahan CONNECT, E2) | — | infra |
| E2 | Privilege CONNECT | `has_database_privilege` semua role × DB | PASS | tiap role hanya DB miliknya (+ `postgres` untuk role pool); `datacl` tanpa PUBLIC | — | — |
| E3 | Postgres tanpa port/SSL publik | `show listen_addresses; ssl`; B11/B17 | PASS | tanpa publish; hanya network `db` internal; `password_encryption=scram-sha-256` | — | — |
| E4 | Snapshot harian | `restic snapshots --no-lock` | PASS | 38 snapshot; run terjadwal 2026-09-24 01:30 & 2026-09-25 01:30 `RESULT status=ok dbs_ok=9`; tag `db:` untuk 9 DB (`ssotest_staging` baru dibuat setelah run 01:30, masuk run berikutnya) | — | — |
| E5 | `restic check` | journal `restic-prune.service` | PASS | check terakhir 2026-09-23 12:25 `no errors were found` (prune mingguan berikutnya 2026-09-27). `restic check` tidak dijalankan ulang (butuh lock) | — | — |
| E6 | Restore test | `journalctl -t infra-restore-test \| grep RESULT` | PASS | 2026-09-23 `db=demo_demo db_compare=ok filestore=ok check_subset=5/5:ok rto_seconds=14`; berikutnya 2026-10-01 | — | — |
| E7 | Backup offsite | journal `remote=` | RISK-ACCEPTED | `remote=not-configured`; repo = disk yang sama (keputusan user: backup lokal saja; L2 Hostinger mingguan) | Medium | user/Lead |
| E8 | Timer | `systemctl list-timers 'restic-*'` | PASS | backup harian 01:30, prune Minggu 03:00, restore-test tanggal 1 04:00; `OnFailure` alert (backup.md) | — | — |

### F. Edge Traefik (dari host, `--resolve …:127.0.0.1`, sumber 10.100.0.1)

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| F1 | Sertifikat semua host yang di-route | `openssl s_client -connect 127.0.0.1:443 -servername <h> -verify_hostname <h>` | PASS | 11 host (auth, cp, cp.staging, demo.erp, demo.staging, drms-kas.staging, grafana, mail, ssotest.staging, starter.staging, status): LE production (YE1/YE2), `Verify return code: 0`, sisa 87–89 hari | — | — |
| F2 | TLS ≥ 1.2 (T17a F6) | `openssl s_client -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0'` ke 443/465/993 | PASS | TLS 1.1 → `alert protocol version` (70) di ketiganya; TLS 1.2/1.3 OK (`dynamic/tls.yml` `minVersion: VersionTLS12`) | — | — |
| F3 | HSTS | `curl -sI` 10 host | RISK-ACCEPTED (sementara) | `max-age=300` di semua host (sesuai `security-headers`/`auth-security-headers`/`odoo-security-headers` `stsSeconds: 300`, "dinaikkan Lead setelah QA"); grafana tanpa router di :443 | Medium | Lead → remediasi M3 |
| F4 | Header keamanan | idem | PASS (catatan) | `nosniff` + `Referrer-Policy strict-origin-when-cross-origin` + XFO di semua host; CSP ada di cp, cp.staging, Odoo ×3, drms-kas, starter; **tanpa CSP**: status (Uptime Kuma) dan discovery Keycloak (JSON; halaman Keycloak mengirim CSP `frame-ancestors 'self'`) | — | — |
| F5 | Redirect http→https + ACME (T17a F7) | `curl http://demo.erp…/web/login`; `…/.well-known/acme-challenge/x` | PASS | 301 → https; path ACME tidak di-redirect (404 dari Traefik) | — | — |
| F6 | Dashboard/API Traefik (T17a F8) | `curl -k https://127.0.0.1/dashboard/`, `/api/rawdata` | PASS | 404 / 404 | — | — |
| F7 | Admin Keycloak hanya :8443 (T17a F9) | `curl` auth :443 & :8443 | PASS | :443 `/admin/`, `/admin/master/console/`, `/realms/master/.well-known/…`, `POST /realms/master/…/token` → **403**; `/`, `/metrics`, `/health/ready` → 404; :8443 `/admin/` → 302 `…:8443/admin/master/console/` | — | — |
| F8 | Spoof header forwarded | `-H 'X-Forwarded-For: 127.0.0.1' -H 'X-Real-Ip: …'`; `-H 'X_Forwarded_For: …'` | PASS | tetap 403 (`forwardedHeaders` tidak diset, `aliasHeadersStrategy: delete` di semua entrypoint) | — | — |
| F9 | OIDC discovery (T17a F10) | `curl …/realms/platform/.well-known/openid-configuration` | PASS | 200 | — | — |
| F10 | DB manager Odoo 403 di :443 (T17a F11/F18) | `curl` `/web/database/{manager,selector,list,backup}` demo.erp + demo.staging; varian path | PASS | 8× **403**; `/web//database/manager`, `/web/%64atabase/manager`, `/web/./database/manager` → 403; `/WEB/…` → 404. Via :8443: "database manager has been disabled by the administrator" | — | — |
| F11 | Tenant crossing lewat edge (T17a F12) | `POST https://demo.staging…/web/session/authenticate` `db=ssotest_staging` + `X-Sh-Odoo-Db`/`X-Odoo-Database` (juga alias `_`); `GET /web/login?db=…` | PASS | `AccessError: Database not found.` (sebelum percobaan login); `?db=` tidak berpindah DB. **Namun** header yang sama berhasil memilih DB bila dikirim langsung ke `odoo-pool-a:8069` → B15 | — | — |
| F12 | Host tak dikenal (T17a F13) | `curl -k --resolve tidakada.erp…` | PASS | 404 | — | — |
| F13 | Grafana & dashboard Kuma tidak di :443 | `curl` grafana `/login`; status `/dashboard`, `/metrics`, `/socket.io/`, `/setup`, `/settings/general`, `/manage-status-page`, `/add`, `/upload/` | PASS | semua 404; hanya `/status/*`, `/api/status-page/*`, `/api/entry-page` → 200 | — | — |
| F14 | Middleware per router | parse `dynamic/**/*.yml` | PASS | 43 router: semua ber-`crowdsec` dan `entryPoints` eksplisit; tanpa ratelimit/header hanya router `*-deny` (403 `deny-all` → `deny-sink`); router admin hanya di entrypoint `admin` | — | — |
| F15 | Endpoint service `db` Odoo tanpa autentikasi | `POST /jsonrpc {"service":"db","method":…}` demo.erp | FAIL | `db_exist("demo_demo")` → `true`, `db_exist("nonexistent_prod")` → `false` (oracle nama DB tenant); `server_version` → `19.0-20260908`; `list` → AccessDenied (OK). Error JSON-RPC anonim memuat field `debug` = traceback Python | Low | odoo-dev/infra → QA-T17B-07 |
| F16 | Cookie sesi Odoo (T17a F20) | `curl -sD - …/web/login \| grep set-cookie` | FAIL | `session_id=…; Expires=…; Max-Age=604800; HttpOnly; Path=/`, **tanpa `Secure` dan `SameSite`** (sudah diketahui `odoo.md`; "butuh keputusan Lead"); HSTS hanya 300 s | Medium | odoo-dev/Lead → QA-T17B-06 |
| F17 | CAA DNS | `dig +short CAA bimacreative.tech @1.1.1.1 @8.8.8.8` | FAIL | hanya `0 issue "letsencrypt.org"`; **tanpa** `0 issuewild ";"` (CLAUDE.md §3.5.1) | Low | user (DNS manual) → QA-T17B-09 |
| F18 | Tidak ada AAAA | `dig +short AAAA mail.… auth.…` | PASS | kosong | — | — |

### G. CrowdSec & fail2ban

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| G1 | CrowdSec sehat + collections | `cscli version; collections list` | PASS | v1.8.1 healthy; linux, sshd, traefik, http-cve, base-http, appsec-virtual-patching, appsec-generic-rules, appsec-crs-inband, postfix, dovecot, whitelist-good-actors | — | infra |
| G2 | Bouncer aktif | `cscli bouncers list` | PASS (catatan) | `traefik-bouncer@10.100.2.2` & `host-firewall-bouncer` pull terakhir 10:02 UTC. Entri basi `traefik-bouncer` (10.100.2.3, pull terakhir 2026-09-23) masih terdaftar | — | infra |
| G3 | Firewall bouncer | `systemctl is-active …; nft list tables` | PASS | active; `table ip crowdsec` & `ip6 crowdsec6`, hook input+forward prio −10, set CAPI ±20 k IP | — | — |
| G4 | Kebijakan AppSec tidak memblok host (H6) | `grep scenarios_not_containing …yaml.local` | PASS | kunci ada (tidak diuji dengan decision, supaya tidak ada ban/unban) | — | — |
| G5 | Parser sshd hidup | `cscli explain --type syslog --log '<baris Invalid user>'` | PASS | `syslog-logs` → `sshd-logs` → 6 skenario `ssh-*bf*`. 137 baris "unparsed" di metrics = baris auth.log non-sshd (sudo) | — | — |
| G6 | Exclusion `local/odoo-crs-exclusions` | baca file | FAIL | `RemoveInBandRuleByTag("attack-xss")` untuk POST ke 7 prefix path (`/web/dataset/call_kw/`, `/mail/message/`, …) **tanpa syarat Host** → berlaku di semua router ber-`crowdsec` (cp, auth, drms-kas, website klien), bukan hanya host Odoo | Low | infra → QA-T17B-12 |
| G7 | Exclusion `local/keycloak-admin-exclusions` | baca file vs `crowdsec.md` §H4/H5 | PASS | hanya 911100; hook 1: host auth(:8443) + `/admin/realms/` + RemoteAddr ∈ {127.0.0.1, 10.100.0.1}; hook 2: host auth + pasangan eksak 10.100.8.0/24×`/admin/realms/drms/`, 10.100.9.0/24×`/admin/realms/drms-staging/` — sama dengan dokumen | — | — |
| G8 | Exclusion `local/controlplane-crs-exclusions` + rule 19100/19101 | idem §H6 | PASS | hanya 920420; POST, host cp/cp.staging, bukan `/api/`/`/_next/`, `Next-Action` hex 40–64 tunggal, CT `text/plain` tunggal; JSON processor + 403 bila `REQBODY_ERROR` | — | — |
| G9 | Exclusion `local/drms-payload-crs-exclusions` + rule 19102/19103 | idem §H7(a) | FAIL (dokumen) | hook 1 = sesuai dokumen. **Hook 2 (2026-09-24, commit `3e049dc`)**: `RemoveInBandRuleByID(911100)` untuk PATCH/DELETE, host drms-kas(.staging), path `/api/`, dari **IP mana pun**. Cakupannya sempit dan tercatat di komentar YAML, tetapi **tidak ada di `crowdsec.md`** | Low | infra/docs → QA-T17B-13 |
| G10 | Exclusion `local/oidc-backchannel-exclusions` | idem §BUG-S5-01 | PASS (catatan) | hanya tag `attack-sqli`; POST, host auth, path eksak token `platform`/`platform-staging`, `RemoteAddr == 10.100.0.1`. Catatan: 10.100.0.1 = semua proses host + hairpin container mana pun (terdokumentasi) | — | — |
| G11 | fail2ban DMS | `docker exec mailserver fail2ban-client status` | PASS | tidak berjalan, sesuai ADR 0005 #6 (brute force → CrowdSec postfix/dovecot + skenario lokal `infra/mail-postfix-sasl-bf`) | — | — |

### H. Keycloak (query read-only ke DB `keycloak`)

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| H1 | Brute force | `realm_attribute` | PASS | 5 realm (master, platform, platform-staging, drms, drms-staging): `bruteForceProtected=true`, failureFactor 5, wait 60 s naik s/d 900 s | — | — |
| H2 | Password policy | `realm.password_policy` | PASS | master `length(16)`, lainnya `length(12)` + maxLength 128, upper/lower/digit/special, notUsername, notEmail, passwordHistory(5) | — | — |
| H3 | Registration/SSL/event (T17a F22) | `realm` | PASS | `registration_allowed=f` ×5, `ssl_required=EXTERNAL`, event login+admin aktif | — | — |
| H4 | Admin console hanya :8443 | F7 + `frontendUrl` master | PASS | `frontendUrl=https://auth.bimacreative.tech:8443`; :443 403 | — | — |
| H5 | Direct access grants: client aplikasi | `client.direct_access_grants_enabled` | RISK-ACCEPTED | hanya `drms-staging/proyekkas-mobile` (public, standard flow ON) — keputusan user 2026-09-25; `drms/proyekkas-mobile` OFF | Low | user |
| H6 | Direct access grants: `admin-cli` bawaan | idem | **FAIL** | `admin-cli` DAG **ON** di `platform`, `platform-staging`, `drms`, `drms-staging` (dan `master`, dibutuhkan kcadm; `/realms/master/*` 403 di :443). Token endpoint realm non-master publik lewat router `auth-login` → oracle password tanpa browser flow | Medium | infra → QA-T17B-05 |
| H7 | Admin master | `user_entity`/`credential` | PASS | 1 user `platform-admin` (password + OTP) | — | — |
| H8 | Service account | `user_role_mapping` | PASS | `automation`: view-realm, manage-users, manage-clients (tanpa manage-realm, ADR 0008); `proyekkas-admin-api`: manage/view-users realm drms saja | — | — |
| H9 | Redirect URI wildcard | `redirect_uris like '%*%'` | PASS | hanya client bawaan (`account`, `account-console`, `security-admin-console`) dengan path relatif `/realms/<r>/account/*`, `/admin/<r>/console/*` | — | — |

### I. Odoo pool

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| I1 | `odoo.conf` | `grep` pool-a & staging | PASS | `proxy_mode = True`, `list_db = False`, `server_wide_modules = …,sh_dbfilter_header`, dbfilter `^[a-z0-9_]+_(prod\|demo)$` / `^[a-z0-9_]+_staging$`, workers/limit_* sesuai ADR 0004 | — | — |
| I2 | Proteksi database manager di source | `grep check_db_management_enabled odoo/service/db.py` | PASS | create/duplicate/drop/dump/restore/rename/change_admin_password/migrate semuanya `@check_db_management_enabled` (butuh `list_db`) | — | — |
| I3 | `db.list` diblok | `POST /jsonrpc service=db method=list` | PASS | `AccessDenied` | — | — |
| I4 | Fungsi fail-closed `sh_dbfilter_header` | `dbfilter.py` | PASS (catatan) | header dipercaya setiap kali `proxy_mode=True`, tanpa cek IP sumber. Karena itu isolasi bergantung sepenuhnya pada "hanya Traefik yang bisa mencapai :8069" → dilanggar B15 | — | — |

### J. infra-job (ADR 0009)

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| J1 | Dispatcher | `stat; cmp scripts/infra-job/infra_job.py /usr/local/sbin/infra-job` | PASS | root 0755, identik dengan repo | — | — |
| J2 | Tata letak spool/results/work/log | `find /var/lib/infra-jobs /var/log/infra-jobs /etc/infra-jobs -printf '%m %u:%g'` | PASS | persis `infra-jobs.md`: spool & new `root:cpjob-<i> 0730`, tmp `cpjob 0700`, work/rejected `root 0700`, results `root:cpjob 0750` (file 0640), log dir 0700 + file 0600, `/etc/infra-jobs/*.conf` 0644 root. `rejected/` berisi artefak forensik QA J5 (symlink/FIFO/0666) — tertahan di dir root 0700 | — | — |
| J3 | User cpjob | `getent passwd; id` | PASS | `cpjob-prod` 950, `cpjob-staging` 951, `/usr/sbin/nologin`, tanpa grup tambahan | — | — |
| J4 | Hardening unit | `systemctl show infra-job@prod.service -p …` | PASS | NoNewPrivileges, ProtectSystem=full, PrivateTmp, RestrictSUIDSGID, UMask 0077, CapabilityBoundingSet 5 cap (sesuai dokumen) | — | — |
| J5 | Path unit | `systemctl is-enabled/is-active infra-job-{prod,staging}.path` | PASS | enabled/active ×2; `systemctl --failed` kosong | — | — |
| J6 | auditd | A7 | PASS | watch `infra-job` + `/etc/infra-jobs/` | — | — |
| J7 | Riwayat job 24 jam | `journalctl -t infra-job --since -24h` | PASS (info) | 33 succeeded, 2 `blocked_dry_run`, 1 `timeout_state_unknown` (uji AC-J8 terdokumentasi) | — | — |

### K. Mail

| ID | Kontrol | Perintah | Status | Bukti | Sev | Owner |
|---|---|---|---|---|---|---|
| K1 | Tidak open relay (konfigurasi + bukti lama) | `postconf mynetworks smtpd_relay_restrictions smtpd_sasl_auth_enable`; `postconf -P` | PASS | `mynetworks =` kosong; port 25 `permit_mynetworks permit_sasl_authenticated defer_unauth_destination`, SASL off; submission(s) `permit_sasl_authenticated,reject` + TLS `encrypt`. Bukti uji lama `mail.md` §Uji: 4 varian relay → `554 5.7.1 Relay access denied`. Uji swaks dari internet → X10 | — | — |
| K2 | TLS mail | `openssl s_client` 465/993, `-starttls smtp` 25/587 | PASS | `CN=mail.bimacreative.tech`, verify 0; TLS 1.1 ditolak | — | — |
| K3 | SPF/DKIM/DMARC DNS | `dig TXT` | PASS (catatan) | SPF `v=spf1 ip4:31.97.50.221 -all`; DKIM `mail._domainkey` ada; DMARC `p=quarantine; adkim=s; aspf=s` (target CLAUDE.md: naik ke `reject`); rDNS `mail.bimacreative.tech.` | — | — |
| K4 | IPv4-only | `postconf inet_protocols`; `dig AAAA` | PASS | `ipv4`; tanpa AAAA | — | — |
| K5 | Guard kirim keluar & antrean | `postconf defer_transports; postqueue -p` | PASS (info) | `defer_transports =` (guard TEMPORARY sudah dicabut); antrean kosong | — | — |

### X. NOT TESTABLE

| ID | Kontrol | Alasan / cara uji | Status |
|---|---|---|---|
| X0 | Lockout brute force Keycloak runtime (T17a F21) | butuh user uji, padahal membuat user dilarang di tugas ini. Konfigurasi PASS (H1) | NOT TESTABLE |
| X1 | `ssh -p 2221 admin@31.97.50.221 true`, `ssh -p 22 …` (fallback), Ansible remote `--check` dari laptop | butuh laptop user | NOT TESTABLE-EXTERNAL |
| X2 | `nmap -Pn -p 1-65535 31.97.50.221` (v4) → harapan hanya 22, 25, 80, 443, 465, 587, 993, 2221 | butuh IP luar | NOT TESTABLE-EXTERNAL |
| X3 | `nmap -6 -Pn -p- 2a02:4780:59:823e::1` → harapan hanya 22/2221 (ufw v6 juga ALLOW 80/443, tanpa listener) | butuh IPv6 luar | NOT TESTABLE-EXTERNAL |
| X4 | `testssl.sh` / `nmap --script ssl-enum-ciphers` 443/465/587/993 | butuh IP luar (tool tidak ada di host) | NOT TESTABLE-EXTERNAL |
| X5 | AppSec: `?q=<script>`, `/.env`, SQLi → 403 (edge-external.ps1 §6) | payload dari host tidak menghasilkan ban (IP privat) dan sengaja tidak dikirim (tanpa alert) | NOT TESTABLE-EXTERNAL |
| X6 | False positive: login Odoo/Keycloak/cp (edge-external.ps1 §6–7) | butuh IP publik | NOT TESTABLE-EXTERNAL |
| X7 | Rate limit 429 `ratelimit-login` (edge-external.ps1 §5) | bucket per IP; dari host = 10.100.0.1 (bucket bersama) | NOT TESTABLE-EXTERNAL |
| X8 | Brute force → decision CrowdSec + ban firewall; fail2ban SSH ban | butuh IP publik + cleanup ban oleh Lead | NOT TESTABLE-EXTERNAL |
| X9 | Status run CI GitHub + branch protection (`main`: PR + 1 review + CI) | butuh akses GitHub | NOT TESTABLE-EXTERNAL |
| X10 | `swaks` open relay dari internet + mail-tester (SPF/DKIM/DMARC pass) | mengirim mail dilarang di tugas ini; butuh IP luar | NOT TESTABLE-EXTERNAL |
| X11 | Allowlist admin dari IP publik: `https://auth…/admin/` → 403 dari internet; `:8443` publik tertutup | edge-external.ps1 §2 | NOT TESTABLE-EXTERNAL |
| X12 | ZAP baseline ke staging | uji aktif | NOT TESTABLE-EXTERNAL |
| X13 | Firewall panel Hostinger (aturan panel vs ufw) | butuh hPanel | NOT TESTABLE-EXTERNAL |
| X14 | SSO penuh dari browser user (Odoo/cp) + tunnel admin `ssh -L 8443` | butuh laptop | NOT TESTABLE-EXTERNAL |

**Catatan untuk `qa/edge-external.ps1`** (dibaca, tidak diubah): §4 memeriksa `Port 22 tertutup`. Sejak port 22 jadi fallback
permanen (keputusan user 2026-09-24), cek ini akan **FAIL** walaupun sesuai keputusan, jadi skrip perlu diperbarui (QA-T17B-13).
Payload §6 bisa memicu ban AppSec untuk IP penguji (HTTP saja, bukan SSH, sejak H6). Setelah dijalankan, beri tahu Lead.
Skrip belum mencakup X2–X4, X8–X10, X12.

Hitungan per baris tabel (diverifikasi dengan skrip parse tabel):
- **PASS 97:** A1, A3–A7, A10–A16, A18–A21 (17) · B1–B5, B7, B8, B10–B14, B17 (13) · C1–C5, C7, C8, C10–C12 (10) · D1–D3, D11 (4) ·
  E1–E6, E8 (7) · F1, F2, F4–F14, F18 (14) · G1–G5, G7, G8, G10, G11 (9) · H1–H4, H7–H9 (7) · I1–I4 (4) · J1–J7 (7) · K1–K5 (5)
- **FAIL 16 baris / 14 temuan:** A8, A9, B15, B16, C6, C9, D7, D8, D9, D10, F15, F16, F17, G6, G9, H6
- **RISK-ACCEPTED 11:** A2, A17, B6, B9, B18, D4, D5, D6, E7, F3, H5
- **NOT TESTABLE 1:** X0 · **NOT TESTABLE-EXTERNAL 14:** X1–X14

## Daftar temuan (bug report)

### QA-T17B-01 · High · Jaringan internal `db`/`proxy` membuka Odoo :8069 dan Keycloak :8080/:9000 tanpa melewati edge
- **Komponen:** network `db` (anggota: postgres, odoo-pool-a, odoo-staging, keycloak, control-plane, control-plane-worker,
  control-plane-staging, control-plane-staging-worker, drms-pk-stg, drms-pk-stg-worker), network `proxy` (keycloak, control-plane(-staging),
  grafana, uptime-kuma, traefik); `odoo.conf` `http_interface = 0.0.0.0`; `sh_dbfilter_header` mempercayai header bila `proxy_mode`.
- **Reproduksi (read-only):**
  ```
  docker exec drms-pk-stg node -e "fetch('http://odoo-pool-a:8069/web/login',{headers:{'X-Sh-Odoo-Db':'demo_demo'},redirect:'manual'}).then(r=>console.log(r.status))"   # 200 (tanpa header: 303)
  docker exec drms-pk-stg node -e "fetch('http://keycloak:8080/realms/master/.well-known/openid-configuration').then(r=>console.log(r.status))"                       # 200 (di :443 → 403)
  docker exec <c> node -e "require('net').connect({host:'keycloak',port:9000},…)"   # OPEN dari drms-pk-stg, control-plane, uptime-kuma
  ```
- **Aktual:** app klien ProyekKas *staging* dan control plane (lewat `db`), serta grafana/uptime-kuma (lewat `proxy`), bisa
  memilih DB tenant **prod** mana pun yang lolos `dbfilter`, lalu mencoba login tanpa CrowdSec/AppSec/ratelimit/header override.
  Mereka juga bisa mencapai realm `master` + endpoint admin Keycloak (sebagian di-deny H5 di :443) dan port management `:9000`
  (metrics/health) tanpa `ipallowlist-admin`.
- **Diharapkan:** plan 02 §4 (S: "client memalsukan `X-Sh-Odoo-Db` … memilih DB tenant lain") dan klaim H1 `odoo.md` §Keamanan:
  hanya Traefik yang bisa mencapai :8069/:8072; panel admin hanya lewat `admin` :8443 (H5).
- **Dampak:** kompromi satu container klien/staging (RCE, dependency jahat) menjadi akses langsung ke login semua tenant ERP prod
  (brute force tanpa rate limit edge) dan ke plane admin IdP. Pemisahan staging ↔ prod pun terlewati.
- **Rekomendasi (tidak diterapkan):** (a) pisahkan network DB per konsumen: `db-odoo` (postgres + pool), `db-kc` (postgres + keycloak),
  `db-cp`, `db-drms`, … dengan postgres join semuanya (atau minimal keluarkan `drms-pk-stg*` & `control-plane*` dari network yang juga dihuni
  Odoo/Keycloak); (b) Keycloak ke network `kc-edge` khusus (traefik + keycloak), keluar dari `proxy`; ingat control plane memanggil issuer lewat
  URL publik; (c) sebagai defense-in-depth, `sh_dbfilter_header` bisa menolak header bila `REMOTE_ADDR` bukan IP Traefik di `odoo-edge`
  (butuh subnet/IP tetap Traefik, ADR baru); (d) setelah diubah, ulangi uji B15 dari setiap container `db`/`proxy`.
- **Agent tujuan:** infra-engineer (+ odoo-developer untuk opsi c) · **Lead:** perbarui klaim `odoo.md` §Keamanan.

### QA-T17B-02 · High · `mailserver/docker-mailserver:16.0.1` — 20 CRITICAL fixable di container publik
- **Reproduksi:** `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro aquasec/trivy:0.74.0 image --scanners vuln --severity CRITICAL mailserver/docker-mailserver:16.0.1`
- **Aktual:** 24 CRITICAL (20 fixable: perl/libperl5.40 CVE-2026-13221 fix `5.40.1-6+deb13u1`, libunbound8, libglib2.0, libxml2; 3 liblmdb0
  unfixed), 338 HIGH (96 fixable). Container berjalan sebagai root + 7 capability, terekspos 25/465/587/993, dan me-mount `acme.json` (B18).
- **Diharapkan:** 0 CRITICAL fixable, atau risk acceptance bertanggal seperti Keycloak/Postgres (CLAUDE.md §3.6, DoD §5).
- **Rekomendasi:** cek rilis DMS terbaru (tag `16.0.2`/`16.1.0` belum ada saat dicek dengan `imagetools inspect`; lihat GitHub releases/
  `edge` digest) → pin tag+digest baru → Trivy ulang. Bila belum ada rilis: tulis `docs/risk/…-mailserver-cves.md` (paket mana yang ada di
  jalur SMTP/IMAP; perl dipakai skrip DMS, bukan daemon postfix/dovecot) dengan tanggal kedaluwarsa. Pertimbangkan juga mengganti mount
  `acme.json` penuh dengan ekspor sertifikat `mail.*` saja (B18).
- **Agent tujuan:** infra-engineer

### QA-T17B-03 · Medium · Metrics Traefik `:8082` terbaca dari network tenant/app
- **Reproduksi:** `docker exec web-starter-staging node -e "fetch('http://traefik:8082/metrics').then(r=>r.text()).then(t=>console.log(t.split('\n').length))"` → 2 784 baris.
- **Aktual:** website klien (web-edge), ProyekKas (drms-kas-edge), pool Odoo (odoo-edge), dan semua anggota `proxy` bisa membaca nama router/service
  (= daftar tenant & hostname), volume request, dan kode status. Komentar `traefik.yml` (“hanya bisa dicapai lewat network internal `metrics`”) tidak akurat.
- **Rekomendasi:** batasi entrypoint `metrics` ke IP Traefik di network `metrics` (mis. `address: "10.100.5.x:8082"` dengan IP tetap di compose)
  atau pakai router `prometheus@internal` di entrypoint khusus + `ClientIP(10.100.5.0/24)`. Nama opsi harus diverifikasi di docs v3.7.
- **Agent tujuan:** infra-engineer

### QA-T17B-04 · Medium · `louislam/uptime-kuma:2.5.5-rootless` — 145 CRITICAL fixable
- **Aktual:** 164 CRITICAL (120 di chromium untuk monitor "real browser"), 1 688 HIGH. Proses Node yang sama melayani halaman status publik.
- **Rekomendasi:** ganti ke varian tanpa chromium `louislam/uptime-kuma:2.5.5-slim-rootless` (tag ada, dicek `imagetools inspect`) bila monitor
  browser tidak dipakai → pin digest → Trivy ulang. Butuh keputusan Lead karena varian berubah.
- **Agent tujuan:** infra-engineer

### QA-T17B-05 · Medium · `admin-cli` direct access grants aktif di realm aplikasi
- **Bukti:** `select … from client where direct_access_grants_enabled` → `admin-cli` di `platform`, `platform-staging`, `drms`, `drms-staging` (+ master).
- **Aktual:** siapa pun bisa `POST /realms/<realm>/protocol/openid-connect/token grant_type=password client_id=admin-cli` lewat router publik
  `auth-login`. Ini oracle password non-browser (brute force protection & `ratelimit-login` 10/menit/IP tetap berlaku). Yang diharapkan hanya
  `drms-staging/proyekkas-mobile`.
- **Rekomendasi:** matikan "Direct access grants" untuk `admin-cli` di 4 realm non-master (console via tunnel, atau `automation` bila diberi hak).
  Skrip platform tidak memakai `admin-cli` realm aplikasi (memakai `automation` client_credentials). Uji: token endpoint → `unauthorized_client`.
- **Agent tujuan:** infra-engineer / user (console)

### QA-T17B-06 · Medium · Cookie `session_id` Odoo tanpa `Secure`/`SameSite` (+ HSTS 300 s)
- **Bukti:** `set-cookie: session_id=…; Max-Age=604800; HttpOnly; Path=/`.
- **Rekomendasi:** keputusan Lead (odoo.md): (a) naikkan HSTS ke `31536000` sekarang (semua host sudah LE prod, F1), yang menutup sebagian besar
  risiko downgrade; (b) tambahkan flag cookie di modul shared server-wide (patch `Response.set_cookie` untuk `session_id` bila
  `proxy_mode`; perlu verifikasi source `odoo/http.py`) atau uji apakah Odoo 19 punya opsi config resmi. **Jangan** menebak nama opsi.
- **Agent tujuan:** odoo-developer + Lead

### QA-T17B-07 · Low · Service `db` Odoo: oracle nama DB + versi + traceback anonim
- **Reproduksi:** `curl --resolve demo.erp.bimacreative.tech:443:127.0.0.1 -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"call","params":{"service":"db","method":"db_exist","args":["demo_demo"]}}' https://demo.erp.bimacreative.tech/jsonrpc` → `true`.
- **Rekomendasi:** blok `PathPrefix(/xmlrpc/2/db)` di router tenant (`deny-all`). Untuk `/jsonrpc`, pertimbangkan rule AppSec lokal yang menolak body
  `"service":"db"` bila external API tidak dipakai tenant. Traceback: override handler error JSON-RPC di modul shared (Low).
- **Agent tujuan:** infra-engineer / odoo-developer

### QA-T17B-08 · Low · Salinan secret di luar jalur yang dikelola
- **Bukti:** C6 (tanpa isi). Salinan di scratchpad sesi agent sudah basi (hash ≠ live), jadi dampak nyata rendah.
- **Rekomendasi:** hapus (`shred -u`) salinan scratchpad dan `/opt/src/control-plane/.env` + `.next/standalone/.env` setelah Lead memastikan tidak
  dipakai (§0.5, konfirmasi). Tambahkan aturan agent: jangan menyalin `.env` ke scratchpad.
- **Agent tujuan:** Lead

### QA-T17B-09 · Low · CAA tanpa `issuewild ";"`
- **Rekomendasi:** user menambah `CAA 0 issuewild ";"` di DNS Hostinger (CLAUDE.md §3.5.1, ADR 0002).

### QA-T17B-10 · Low · HIGH fixable di image observability (internal)
- Grafana 104, node-exporter 9, Prometheus 4, Alloy 2 fixable. Semuanya hanya di network internal (Grafana via tunnel :8443).
- **Rekomendasi:** upgrade patch saat tersedia, dengan Trivy bulanan bersama risk review Postgres.

### QA-T17B-11 · Low · auditd: watch `.env` belum ada + retensi ±20 jam
- **Rekomendasi:** tambahkan `-w /opt/infra/<stack>/.env -p wa -k secret_env` per stack (role `auditd`); naikkan `num_logs`/`max_log_file`
  (mis. 10 × 32 MB) atau kecualikan exec `docker` dari `infra-healthcheck` (`-a never,exit … -F auid=unset` — sintaks harus diverifikasi di `man auditctl`).

### QA-T17B-12 · Low · `local/odoo-crs-exclusions` tanpa syarat Host
- **Rekomendasi:** tambahkan `req.Host endsWith ".erp.bimacreative.tech" || req.Host endsWith ".staging.bimacreative.tech"` (plus domain klien
  kelak, idealnya daftar yang dirender dari route), lalu uji kompilasi `crowdsec -t` seperti H4–H7. Cakupan exclusion lain sudah sesuai dokumen.

### QA-T17B-13 · Low · Drift dokumentasi/skrip
- `crowdsec.md` belum mencatat hook 911100 PATCH/DELETE `/api/` drms (G9); `odoo.md` §Keamanan klaim isolasi H1 (B15); komentar `traefik.yml`
  metrics (B16); `qa/edge-external.ps1` §4 mengharapkan port 22 tertutup.
- **Agent tujuan:** docs-versioning (+ QA untuk skrip)

### QA-T17B-14 · Low · `.npmrc` control-plane tanpa `min-release-age` (carry-over QA-T17A-08)
- **Agent tujuan:** nextjs-developer (nama opsi harus diverifikasi di docs npm yang dipakai)

## Daftar remediasi berprioritas (tanpa perbaikan oleh QA)

| Prioritas | Item | Saran konkret | Owner |
|---|---|---|---|
| **Critical** | — | tidak ada temuan Critical | — |
| **High** | H-1 QA-T17B-01 | Pisahkan network `db` per konsumen; keluarkan app klien/staging dari network yang dihuni pool Odoo/Keycloak; Keycloak ke `kc-edge` (traefik + keycloak); opsional: `sh_dbfilter_header` cek IP sumber. Uji ulang B15 dari setiap container | infra-engineer, odoo-developer, Lead (ADR) |
| **High** | H-2 QA-T17B-02 | Upgrade DMS ke rilis dengan Debian patch terbaru; bila belum ada, risk acceptance bertanggal + ekspor sertifikat mail saja (B18) | infra-engineer, Lead/user |
| **High** | H-3 D4 (risk-accepted) | Kedaluwarsa **2026-10-31**: pantau Keycloak 26.7.5+ mingguan (belum ada per 2026-09-25) | infra-engineer |
| **Medium** | M-1 QA-T17B-03 | Batasi entrypoint `metrics` ke network `metrics` | infra-engineer |
| **Medium** | M-2 QA-T17B-05 | Matikan DAG `admin-cli` di platform, platform-staging, drms, drms-staging | user/infra |
| **Medium** | M-3 F3 + QA-T17B-06 | Naikkan HSTS ke 31536000 (semua host sudah LE prod); flag `Secure`/`SameSite=Lax` cookie Odoo lewat modul shared | Lead, odoo-developer |
| **Medium** | M-4 QA-T17B-04 | `uptime-kuma:2.5.5-slim-rootless` (tanpa chromium) | infra-engineer |
| **Medium** | M-5 E7 (risk-accepted) | Aktifkan remote S3 (L4) saat anggaran/keputusan tersedia; sampai itu, pastikan snapshot Hostinger mingguan aktif | user |
| **Medium** | M-6 B18 (risk-accepted) | Ganti mount `acme.json` penuh di mailserver dengan file sertifikat/kunci `mail.*` saja (mis. `traefik-certs-dumper` atau ekspor terjadwal; ADR baru) | infra-engineer |
| **Low** | L-1 QA-T17B-07 | Deny `/xmlrpc/2/db` di router tenant; WAF rule untuk `service":"db"`; sembunyikan traceback | infra, odoo-developer |
| **Low** | L-2 QA-T17B-11 | Watch `.env` per stack + perpanjang retensi audit | infra-engineer |
| **Low** | L-3 QA-T17B-12 | Tambahkan syarat Host di exclusion Odoo | infra-engineer |
| **Low** | L-4 QA-T17B-08 | Bersihkan salinan secret (konfirmasi Lead) | Lead |
| **Low** | L-5 QA-T17B-09 | CAA `issuewild ";"` | user |
| **Low** | L-6 QA-T17B-10 | Upgrade image observability | infra-engineer |
| **Low** | L-7 QA-T17B-13 | Sinkronkan `crowdsec.md`, `odoo.md`, komentar `traefik.yml`, `edge-external.ps1` (port 22) | docs-versioning, QA |
| **Low** | L-8 QA-T17B-14 | `.npmrc` `min-release-age` | nextjs-developer |
| **Low** | L-9 (saran) | pg_hba: ganti regex `odoo_staging` `_staging$` dengan daftar/regex yang tidak mencakup `control_plane_staging`; hapus entri bouncer basi `traefik-bouncer` (10.100.2.3); prune build cache Docker (23 G reclaimable, konfirmasi §0.5); DMARC `p=quarantine` → `reject` setelah laporan rua bersih; kunci SSH `deploy` terpisah untuk CI (A17) | infra-engineer, user |
| **Low** | L-10 (risk-accepted) | Port 22 fallback (A2): pertimbangkan membatasi ke IP admin di ufw bila IP admin statis | user |

## Artefak & metode

- Perintah host: `qa/host-checks.sh`, `qa/container-inspect.sh`-setara (`docker inspect`), plus perintah di kolom tabel. Semua read-only.
- Tool sementara (`--rm`): `aquasec/trivy:0.74.0` (docker.sock **ro**, cache di scratchpad), `zricethezav/gitleaks:v8.30.1` (`--redact`).
  Image sudah ada lokal, tidak ada pull baru.
- `restic snapshots --no-lock` (tanpa lock, tanpa write ke repo). `restic check` tidak dijalankan (butuh lock); bukti diambil dari journal.
- Query Keycloak dan Postgres: `docker exec postgres psql -U postgres … -c 'select …'` (SELECT saja, kolom secret tidak dipilih kecuali hash
  password Odoo yang dialirkan langsung ke `passlib.verify` di container tanpa ditampilkan).
- Uji jaringan: `docker exec <container> node -e` (TCP connect / 1 GET anonim). Uji edge: 1–3 request per kasus dari host.
- Tidak ada konfigurasi/container/decision yang diubah; tidak ada email yang dikirim; tidak ada user/DB yang dibuat.
