# Operasional — Mail (docker-mailserver, T11)

> **Risk acceptance CVE image 16.0.1:** `docs/risk/2026-09-25-mailserver-16.0.1-cves.md` (review 2026-10-09; keluar saat
> DMS `16.0.2`/`16.1.0` rilis).

- **Stack:** `/opt/infra/mail/` · image `mailserver/docker-mailserver:16.0.1@sha256:d0fe7668…` (index multi-arch, ADR 0001)
- **Hostname:** `mail.bimacreative.tech` = HELO = PTR = MX = sertifikat default untuk **semua** domain (ADR 0005 #5, #9).
  Opsional per client (ADR 0011): nama server klien email `mail.<domain-client>` dengan sertifikat sendiri via TLS SNI —
  aktif: `mail.expomedia.id` (§Hostname mail per domain client).
- **Terkait:** ADR 0005 (keputusan utama), 0002 (DNS/TLS), 0004 (RAM), 0006 (backup); `traefik.md`, `crowdsec.md`,
  `backup.md`, `observability.md`
- Versi komponen di image (dicek 2026-09-23): Postfix 3.10.13, Dovecot 2.4.1, Rspamd 4.1.5, Redis internal, swaks 20240103.

> **STATUS 2026-09-23:** menerima & mengantar mail **lokal**. Pengiriman **keluar DITAHAN** (`defer_transports = smtp`)
> sampai PTR `31.97.50.221 → mail.bimacreative.tech` diset user — lihat §PTR. Jangan jalankan `postqueue -f` sebelum itu.

## Struktur

| Path | Isi | Git |
|---|---|---|
| `docker-compose.yml` | service `mailserver`, network `mail` 10.100.10.0/24 (compose-managed, tanpa IPv6) | ya |
| `config/postfix-main.cf` | override Postfix (di-append ke main.cf saat **start**) — `tls_server_sni_maps` (ADR 0011) | ya |
| `config/dovecot.cf` | override Dovecot 2.4 (→ `/etc/dovecot/local.conf` saat **start**) — blok SNI `local_name` (ADR 0011) | ya |
| `config/rspamd/override.d/dkim_signing.conf` | DKIM multi-domain (blok `domain { … }` per domain) | ya |
| `config/rspamd/override.d/ratelimit.conf` | rate limit outbound per mailbox & per domain | ya |
| `scripts/bootstrap.sh` | idempoten: `data/`, `/var/log/mailserver`, `secrets/`, sinkron `config/` → `data/config/` | ya |
| `scripts/mailbox-add.sh` | tambah mailbox (password acak → `secrets/`, kuota default 2G) / `--rotate` | ya |
| `scripts/tls-export.py` (+ `scripts/tests/`) | ekspor cert/key `mail.*` dari acme.json → `data/tls/` (QA-T17B-02/B18, §TLS); unit dari role Ansible `mail_tls_export` | ya |
| `data/config/` (= `/tmp/docker-mailserver`) | `postfix-accounts.cf` (hash SHA512-CRYPT), `postfix-virtual.cf` (alias), `dovecot-quotas.cf`, `rspamd/dkim/*.private.txt` (kunci DKIM privat), salinan override | **tidak** (`**/data/`) |
| `data/mail/` (= `/var/mail`) | maildir `<domain>/<local>/` (uid/gid 5000) | tidak |
| `data/state/` (= `/var/mail-state`) | antrean Postfix, Redis (bucket ratelimit, history), state Dovecot/Rspamd | tidak |
| `data/tls/` (= `/etc/dms-tls`, ro) | `fullchain.pem` 0644 + `privkey.pem` 0600 (kunci privat `mail.*` saja), dir root 0700; `<fqdn>/{privkey,chain,fullchain}.pem` 0600 per hostname SNI allowlist (ADR 0011) | **tidak** (`**/data/`) |
| `secrets/<alamat>.password` | password mailbox, 600 root, 32 char tanpa newline | **tidak** (`mail/.gitignore`) |
| `/var/log/mailserver/dms/` (= `/var/log/mail`) | `mail.log` (Postfix/Dovecot), `rspamd.log`; parent `root:adm 750` | — |
| `traefik/dynamic/platform/mail.yml` | router dummy sertifikat (redirect 307 → cp) | ya |
| `traefik/dynamic/platform/mail-clients.yml` | router dummy sertifikat per hostname mail client (ADR 0011), mis. `mail-cert-expomedia` | ya |
| `security/crowdsec/acquis.d/mail.yaml`, `security/crowdsec/scenarios/mail-postfix-sasl-bf.yaml` | acquisition log mail + skenario lokal brute force SASL | ya |

## Keputusan (implementasi T11, diverifikasi dari docs/source v16.0.1 — lihat komentar compose)

| Topik | Pilihan | Alasan / bukti |
|---|---|---|
| IPv4-only | `POSTFIX_INET_PROTOCOLS=ipv4`, `DOVECOT_INET_PROTOCOLS=ipv4`, publish `0.0.0.0:<port>`, network tanpa `enable_ipv6` | `postconf inet_protocols` = `ipv4`; `ss -tlnp` host tanpa `[::]:25/465/587/993`; koneksi ke `[2a02:4780:59:823e::1]:25/993` → refused |
| Relay | `PERMIT_DOCKER=none` → `mynetworks =` (kosong, bahkan tanpa loopback); relay hanya `permit_sasl_authenticated` | uji §Uji: 4 varian relay tanpa AUTH → `554 5.7.1 Relay access denied` |
| AUTH | hanya 465 (TLS implisit) & 587 (`smtpd_tls_security_level=encrypt`); port 25 `smtpd_sasl_auth_enable=no` | AUTH/MAIL tanpa STARTTLS di 587 → `530 5.7.0 Must issue a STARTTLS command first`; EHLO tanpa TLS tidak menawarkan AUTH |
| Spoof | `SPOOF_PROTECTION=1` → `reject_authenticated_sender_login_mismatch` (`smtpd_sender_login_maps`) | login postmaster, `MAIL FROM:<dmarc@…>` → `553 5.7.1 … not owned by user` |
| Spoof header lintas domain | `dkim_signing.conf` `allow_username_mismatch = false` (default DMS = true) | Postfix hanya memeriksa envelope; tanpa ini user domain A bisa mengirim `From: …@<domain B>` yang **ditandatangani kunci B**. Dengan false, domain login ≠ domain From → tidak ditandatangani (DMARC B gagal di penerima) |
| Rspamd user terautentikasi | `RSPAMD_CHECK_AUTHENTICATED=1` | default DMS (`settings.conf authenticated { groups_enabled = [dkim] }`) mematikan ratelimit & pemindaian untuk user login (ADR 0005 #13–14 butuh keduanya) |
| Rate limit | Rspamd ratelimit: `mailbox_outbound` selector `user.lower` burst 10 / 30 per jam; `domain_outbound` selector `user.lower.regexp('@([^@]+)$').last` burst 50 / 200 per jam; Redis global DMS | log start: `enabled ratelimit: mailbox_outbound … domain_outbound`, `use default Redis settings for ratelimit`; uji: setelah 10 token habis → `451 4.7.1 Ratelimit "mailbox_outbound" exceeded`; dua bucket `RL*` terbentuk di Redis |
| Brute force | **CrowdSec** (collections `crowdsecurity/postfix` + `crowdsecurity/dovecot` + skenario lokal `infra/mail-postfix-sasl-bf`), ban via firewall bouncer host yang sudah ada. `ENABLE_FAIL2BAN=0` | tidak perlu `cap_add: NET_ADMIN` (docs env ENABLE_FAIL2BAN); satu tempat ban/unban (`cscli`) + sinyal komunitas; bouncer nftables sudah memfilter hook `forward` (port publish Docker) — `crowdsec.md`. Menyimpang dari ADR 0005 #6 (dicatat di riwayat revisi ADR) |
| ClamAV / Amavis / SpamAssassin / Postgrey | OFF (`ENABLE_AMAVIS` default 1 → dimatikan eksplisit) | ADR 0004 (1 GiB). RAM terukur 247 MiB idle |
| DNSBL | `ENABLE_DNSBL=0`; RBL Rspamd tetap default | host memakai resolver publik → DNSBL tidak andal (docs rspamd.md §RBLs). Backlog: resolver rekursif privat |
| Guard kirim keluar | `defer_transports = smtp` (TEMPORARY) | `postqueue -p` → `(deferred transport)`, log `relay=none … status=deferred (deferred transport)` |
| Log | `/var/log/mailserver/dms` (parent 750) | DMS meng-chown dir mount → 755 & file 644/640; parent menutup akses user host lain |
| Update check | `ENABLE_UPDATE_CHECK=0` | versi di-pin; tanpa egress/mail otomatis |

### Capability & hardening
- `cap_drop: [ALL]` + `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, KILL, SYS_CHROOT]`; `no-new-privileges`.
  Diuji saat bring-up: container **healthy**, semua layanan supervisord RUNNING, `postfix check` bersih, `CapEff=00000000000400eb`.
  Bind port < 1024 tanpa `NET_BIND_SERVICE`: Docker menset `net.ipv4.ip_unprivileged_port_start=0` di netns container (dicek).
- **Tidak** `read_only` dan **tidak** non-root: entrypoint DMS menulis ulang `/etc/*` saat start, supervisord (root) men-drop
  hak ke user layanan. Pengecualian terhadap CLAUDE.md §3.5 — dicatat.
- `no-new-privileges` membuat binary setgid (`postdrop`) tidak bekerja untuk proses **non-root**. Jalur yang terdampak: Sieve
  `redirect`/`vacation` Dovecot (memanggil `sendmail` sebagai vmail). ManageSieve OFF → user tidak bisa memasang sieve sendiri.
  **BELUM diuji**; bila fitur forward/vacation dibutuhkan, uji dulu (alternatif: `submission_host` Dovecot).
- Rspamd controller mendengar `0.0.0.0:11334` **di dalam** network `mail` (default DMS `worker-controller.inc`), tidak di-publish,
  network tanpa anggota lain. Jangan menambahkan container lain ke network `mail`.

## TLS

- Router dummy `traefik/dynamic/platform/mail.yml` (`mail-cert`, entrypoint websecure, `crowdsec` + `security-headers` +
  `ratelimit-default` + redirect 307 → `https://cp.bimacreative.tech/`, service `deny-sink`) menuntut sertifikat `le-http`.
  Riwayat 2026-09-23: staging (`(STAGING) Baloney Bulgur YE2`, 17:49) → production (issuer `YE2`, 17:50; restart Traefik
  17:50:04–17:50:08 WIB tanpa respons).
- **Sejak QA-T17B-02 / B18 (2026-09-25, keputusan user "risk acceptance + hardening"):** DMS **tidak** lagi me-mount
  `acme.json` penuh (kunci privat SEMUA hostname). Host mengekspor HANYA sertifikat `mail.bimacreative.tech`:
  - `mail/scripts/tls-export.py` (root, Python stdlib + `/usr/bin/openssl`) membaca `traefik/acme/acme.json` resolver
    `le-http`, memvalidasi (tepat 1 entri untuk domain, PEM, `-checkhost`, belum kedaluwarsa, kunci cocok sertifikat), lalu
    menulis atomik (tmp + `rename`) `mail/data/tls/privkey.pem` (0600) dan `fullchain.pem` (0644), dir `root 0700`. Isi sama →
    tidak menyentuh file (DMS tidak reload). Validasi gagal → exit 1, file lama utuh. Kunci tidak pernah dicetak.
  - Unit (role Ansible `mail_tls_export`): `mail-tls-export.path` (`PathChanged=` acme.json — Traefik menulis di tempat) +
    `mail-tls-export.timer` (harian 04:30 + 5 menit setelah boot) → `mail-tls-export.service` (oneshot, `ProtectSystem=strict`,
    `ReadWritePaths=` dir ekspor saja, `CapabilityBoundingSet=CAP_DAC_READ_SEARCH`, `PrivateNetwork=yes`,
    `OnFailure=infra-unit-failure@` → email). Exit 2 bila sertifikat terpasang habis < 20 hari (perpanjangan Traefik gagal).
  - DMS: `SSL_TYPE=manual`, `SSL_CERT_PATH=/etc/dms-tls/fullchain.pem`, `SSL_KEY_PATH=/etc/dms-tls/privkey.pem`, mount
    **direktori** `./data/tls:/etc/dms-tls:ro` (docs DMS v16.0.1 `security/ssl.md` §Bring Your Own Certificates; mount dir,
    bukan file, agar rename atomik terlihat — §Caddy "Bind mounting a file directly … will mount by inode").
- **Perpanjangan otomatis:** change detection DMS memantau `SSL_CERT_PATH`/`SSL_KEY_PATH` (sha512, tiap `DMS_CONFIG_POLL`=2 s;
  `helpers/change-detection.sh`) → `_setup_ssl` (salin ke `/etc/dms/tls/{cert,key}`) + reload Postfix/Dovecot
  (`check-for-changes.sh` `_ssl_changes`). **Tanpa restart container.** Diuji 2026-09-25 di container DMS sekali-pakai (image &
  cap sama, network internal): ekspor sertifikat baru → ±2 s kemudian `postfix/master: reload` + `dovecot: SIGHUP`, serial di
  465/993/587 berganti; ekspor ulang isi sama → 0 reload. Kunci & cert di-rename berurutan (jendela ~µs); bila poll DMS jatuh
  tepat di antaranya, poll berikutnya (2 s) memuat pasangan lengkap.
- Perubahan sertifikat hostname lain mengubah `acme.json` → service jalan, `unchanged` → DMS **tidak** reload (dulu reload).
- Log: `journalctl -u mail-tls-export.service` (`exported|unchanged domain=… serial=… notAfter=…`, `ERROR: …`, `WARNING: …`).
- Uji skrip: `python3 -m unittest discover -s /opt/infra/mail/scripts/tests -v` (26 uji: 13 hostname utama + 13 SNI, acme.json sintetis). Lint:
  `docker run --rm --network none -v "$PWD:/src:ro" -w /src <RUFF_IMAGE> check --no-cache --config scripts/infra-job/ruff.toml mail/scripts`.

### SNI hostname mail client (ADR 0011)
- `tls-export.py --sni-domain <fqdn>` (berulang; unit dari `mail_tls_export_sni_domains` role Ansible) → `data/tls/<fqdn>/`
  `privkey.pem`, `chain.pem` (kunci + fullchain, format `smtpd_tls_chain_files`), `fullchain.pem` — semua 0600, dir 0700,
  urutan tulis privkey → chain → fullchain. Validasi sama dengan hostname utama; hostname gagal dilewati (file lamanya utuh,
  exit 1 → alert), hostname lain tetap diproses. Subdir di luar allowlist tidak dihapus otomatis (`NOTE: …`). Tidak `chmod`
  bila mode sudah benar (chmod = IN_ATTRIB → memicu `mail-tls-reload.path`).
- Postfix: `tls_server_sni_maps = inline:{ … }` di `config/postfix-main.cf` (docs postconf(5): tabel `inline` memuat file saat
  tabel dibuka → tanpa `postmap -F`). Berlaku untuk smtpd 25/465/587 (+ tlsproxy). SNI tak dikenal → log `TLS SNI … not matched,
  using default chain` + sertifikat default.
- Dovecot 2.4: `local_name <fqdn> { ssl_server_cert_file / ssl_server_key_file }` di `config/dovecot.cf` (docs Dovecot 2.4.1
  `core/config/ssl.html` §SNI; DMS v16.0.1 menyalinnya ke `/etc/dovecot/local.conf` saat start). Cek: `docker exec mailserver
  doveconf -n | grep -A4 ^local_name`.
- Renew: `mail-tls-reload.path` (`PathChanged=` `data/tls/<fqdn>/fullchain.pem`) → `mail-tls-reload.service`
  (`docker exec mailserver postfix reload` + `dovecot reload`, graceful). Diuji 2026-09-25: replace atomik fullchain →
  ±1 s kemudian `postfix/master: reload` + `dovecot: SIGHUP`; ekspor `unchanged` → 0 reload.
  Log: `journalctl -u mail-tls-reload.service`.

### Terapkan ekspor TLS (Lead — urutan wajib; mailserver di-recreate SEKALI di langkah 4)
```bash
# 0. Serial sebelum (catat): harus sama di keempat port
for t in "-connect 31.97.50.221:465" "-connect 31.97.50.221:993" "-starttls smtp -connect 31.97.50.221:587" "-starttls smtp -connect 31.97.50.221:25"; do
  echo "$t $(echo | timeout 20 openssl s_client $t -servername mail.bimacreative.tech -verify_hostname mail.bimacreative.tech 2>/dev/null | openssl x509 -noout -serial -enddate | tr '\n' ' ')"; done
# 1. Unit + ekspor pertama (tanpa menyentuh mailserver)
cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook site.yml --tags mail_tls_export --check --diff
/opt/ansible-venv/bin/ansible-playbook site.yml --tags mail_tls_export --diff
/opt/ansible-venv/bin/ansible-playbook site.yml --tags mail_tls_export          # run kedua: changed=0
# 2. Bukti ekspor
systemctl is-active mail-tls-export.path mail-tls-export.timer; journalctl -u mail-tls-export.service -n 3 --no-pager
stat -c '%U:%G %a %n' /opt/infra/mail/data/tls /opt/infra/mail/data/tls/*    # root:root 700 / 644 fullchain / 600 privkey
openssl x509 -in /opt/infra/mail/data/tls/fullchain.pem -noout -serial        # = serial langkah 0
# 3. Pasangan cocok dengan yang disajikan DMS sekarang (hash saja, tanpa isi)
docker exec mailserver sha256sum /etc/letsencrypt/live/mail.bimacreative.tech/fullchain.pem | cut -c1-16; sha256sum /opt/infra/mail/data/tls/fullchain.pem | cut -c1-16
# 4. Recreate mailserver dengan compose baru (gangguan ±1 menit — ESTIMASI: stop ≤60 s grace + start ±15–40 s)
cd /opt/infra/mail && docker compose config --quiet && docker compose up -d --force-recreate mailserver
docker compose ps mailserver                           # (healthy) — tunggu ≤120 s start_period
docker logs --since 5m mailserver 2>&1 | grep -iE "error|panic|ssl|cert" | head
# 5. Verifikasi
docker inspect mailserver --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} {{.RW}}{{"\n"}}{{end}}' | grep -E "tls|acme"   # hanya data/tls -> /etc/dms-tls false
docker exec mailserver sh -c 'ls /etc/letsencrypt 2>&1; postconf -h smtpd_tls_chain_files'   # tidak ada acme.json; /etc/dms/tls/key /etc/dms/tls/cert
# ulangi perintah langkah 0 → serial SAMA di 465/993/587/25, Verify return code 0 (tambahkan -verify_return_error)
```
**Rollback** (kembali ke mount acme.json): `git revert <commit compose>` (atau kembalikan `SSL_TYPE: letsencrypt`,
`SSL_DOMAIN: mail.bimacreative.tech`, volume `../traefik/acme/acme.json:/etc/letsencrypt/acme.json:ro`, hapus `SSL_*_PATH` dan
mount `data/tls`) → `docker compose up -d --force-recreate mailserver` (±1 menit) → cek serial seperti langkah 0. Unit ekspor
boleh tetap jalan (tidak berbahaya) atau `-e mail_tls_export_state=absent --tags mail_tls_export`; file `data/tls/` dihapus
manual bila perlu (`shred -u` privkey — konfirmasi Lead, §0.5).
- Deteksi kegagalan: monitor Kuma `Mail IMAPS (993)` memeriksa sertifikat (notifikasi kedaluwarsa).
```bash
for t in "-starttls smtp -connect 31.97.50.221:587" "-connect 31.97.50.221:465" "-connect 31.97.50.221:993" "-starttls smtp -connect 31.97.50.221:25"; do
  echo | openssl s_client $t -servername mail.bimacreative.tech -verify_hostname mail.bimacreative.tech -verify_return_error 2>&1 \
    | grep -E "^subject=|^issuer=|Verify return code"; done
```

## Start / stop / reload

```bash
cd /opt/infra/mail
sudo ./scripts/bootstrap.sh          # idempoten; juga setelah mengubah config/
docker compose up -d
docker compose ps                    # mailserver (healthy) — healthcheck `dms-healthcheck`
docker logs --tail 50 mailserver     # log DMS + Postfix/Dovecot
docker compose down                  # stop (data/ tetap; network mail dihapus)
```
- Start pertama menunggu ≤120 s sampai ada ≥1 akun (`You need at least one mail account…`), lalu keluar bila tidak ada.
- Perubahan `config/postfix-main.cf` atau compose → `bootstrap.sh` lalu `docker compose up -d --force-recreate mailserver`
  (gangguan mail ±1 menit — ESTIMASI: stop ≤60 s grace + start ±15 s; pengirim eksternal me-retry).
- Perubahan `config/rspamd/override.d/*` → `bootstrap.sh` saja (change detection DMS → reload Rspamd, tanpa downtime).
- Uji konfigurasi Rspamd: `docker exec mailserver rspamadm configtest`; efektif: `rspamadm configdump ratelimit|dkim_signing`.

## Akun (ACCOUNT_PROVISIONER=FILE)

```bash
cd /opt/infra/mail
sudo ./scripts/mailbox-add.sh user@bimacreative.tech          # password acak → secrets/user@….password, kuota 2G
sudo ./scripts/mailbox-add.sh user@bimacreative.tech 5G       # kuota lain (satuan B/k/M/G/T)
sudo ./scripts/mailbox-add.sh --rotate user@bimacreative.tech # rotasi password (file secret ditimpa)
docker exec mailserver setup email list                       # daftar + pemakaian kuota
docker exec mailserver setup alias add abuse@bimacreative.tech postmaster@bimacreative.tech
docker exec mailserver setup alias list
docker exec mailserver setup email del user@bimacreative.tech # DESTRUKTIF (tanya konfirmasi; maildir ikut dihapus) — konfirmasi Lead
```
- Password dikirim ke `setup email add|update` lewat **stdin** (bukan argv host). Berikan ke pemilik mailbox lewat kanal aman,
  lalu minta ganti; file `secrets/` boleh di-`shred -u` setelah diserahkan (tidak dipakai sistem).
- **Suspend mailbox bocor/spam (ADR 0005 #13):** `mailbox-add.sh --rotate <alamat>` (sesi IMAP lama: `docker exec mailserver
  doveadm kick <alamat>`), lalu periksa `rspamd.log` (`Ratelimit … exceeded`, `user: <alamat>`) dan antrean (`postqueue -p`).
- Kuota: default 2 GiB per mailbox (ADR 0005 #15); total janji kuota semua client ≤ ±40 GiB sampai ada data nyata.
- Akun saat ini: `postmaster@`, `dmarc@` (penerima `rua` DMARC), `alerts@` (H7: pengirim alert `infra-healthcheck`, kuota
  256M — password `secrets/alerts@bimacreative.tech.password` **dibaca sistem, jangan di-`shred`**; rotasi `--rotate` aman,
  skrip membaca file tiap kirim) — mailbox; `abuse@` → alias ke `postmaster@`. Penerima alert default = `postmaster@`
  (`observability.md` §Healthcheck & alert email).

## DKIM

- Kunci per domain, RSA 2048, selector `mail`: `docker exec mailserver setup config dkim domain <domain>` → file
  `data/config/rspamd/dkim/rsa-2048-mail-<domain>.{private,public,public.dns}.txt`. Script menolak menimpa kunci yang ada.
- Blok domain wajib ditambahkan di `config/rspamd/override.d/dkim_signing.conf` (file yang ada tidak ditimpa `setup`) →
  `bootstrap.sh`. Domain tanpa blok **tidak** ditandatangani (`try_fallback = false`).
- Nilai TXT publik: `cat /opt/infra/mail/data/config/rspamd/dkim/rsa-2048-mail-<domain>.public.dns.txt`.
- `check_pubkey = true` + `allow_pubkey_mismatch = true`: tetap menandatangani sebelum TXT dipublikasikan (hanya dicatat).
- Cek setelah user mempublikasikan: `dig +short TXT mail._domainkey.<domain> @1.1.1.1 | tr -d '" \n'` harus sama dengan isi
  file `.public.dns.txt` (tanpa spasi).
- **Rotasi** (tahunan / bila kunci bocor): buat selector baru (`setup config dkim domain <d> selector mail2026`), publikasikan TXT
  baru, tunggu propagasi (TTL), ganti `selector`/`path` di `dkim_signing.conf` → `bootstrap.sh`, biarkan TXT lama ±7 hari, lalu
  hapus TXT & file kunci lama.

### Record DKIM `bimacreative.tech` (dibuat 2026-09-23)
`TXT mail._domainkey.bimacreative.tech`:
```
v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwoiypQnkO8kVpxyKbto9FYQZCIyBQqLGVbeDMTaglMBQ1SFOgDpGCGp3lSqyPEFKtWv5Nb2K71pairG7wOKvawLKonGsrLC1xNUHc7La4Am36USuBeKqsw/UT24Ks6dTo6bE76Gu1fkCprwE6Ss2lEoFB+yKvHWy4nWknH7vcQuHS7T7gJxT7IkAsI0qkUR6OyjkOTNWsOrbiyMQYxhVbLNROo6EtpS999PCsAIA3Fr2k0DAqjE4sPJbRtpSAcy7+utLEDNe1TIn2FOmlEDCkV3i8LCaH42efgmgJjC6mfdB6s0Rb8YTJuy9a1PsfX7ni1MPGxPIVuG1KZ7DddVqpwIDAQAB
```
(kunci publik — aman dipublikasikan; panjang > 255 char: panel DNS Hostinger memecah string otomatis, bila tidak, isi apa adanya.)

## DNS yang harus diisi user (`bimacreative.tech`, panel Hostinger, manual)

| # | Tindakan | Record | Status 2026-09-23 |
|---|---|---|---|
| 1 | **TAMBAH** | `TXT mail._domainkey` = nilai §Record DKIM | belum |
| 2 | **HAPUS** | `MX @ 10 bimacreative.tech` (MX lama; `bimacreative.tech` tidak menjalankan SMTP → penundaan/bounce acak) | masih ada |
| 3 | pertahankan | `MX @ 10 mail.bimacreative.tech` (satu-satunya MX) | ada |
| 4 | pertahankan | `A mail 31.97.50.221`, **tanpa AAAA** | ada |
| 5 | pertahankan | SPF `@`, `_spf`, `mail` = `v=spf1 ip4:31.97.50.221 -all` (opsional: `@` → `v=spf1 include:_spf.bimacreative.tech -all`) | ada |
| 6 | pertahankan | `_dmarc` = `v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:dmarc@bimacreative.tech` | ada |
| 7 | **SET di panel VPS** (bukan DNS) | PTR `31.97.50.221` → `mail.bimacreative.tech` | `srv2001692.hstgr.cloud.` |

Verifikasi: `dig +short MX bimacreative.tech @1.1.1.1` (hanya `10 mail.bimacreative.tech.`), `dig -x 31.97.50.221 +short`
(`mail.bimacreative.tech.`), `dig +short A mail.bimacreative.tech` = `31.97.50.221` (FCrDNS).

## PTR → melepas guard pengiriman keluar (Lead + user)

1. `dig -x 31.97.50.221 +short @1.1.1.1` = `mail.bimacreative.tech.` **dan** DKIM TXT (#1) cocok.
2. Hapus blok `defer_transports` dari `config/postfix-main.cf` → `sudo ./scripts/bootstrap.sh` →
   `docker compose up -d --force-recreate mailserver` (gangguan ±1 menit, ESTIMASI). Cek `docker exec mailserver postconf defer_transports`
   = kosong.
3. `docker exec mailserver postqueue -p` — antrean seharusnya kosong (uji T11 sudah dihapus). Bila ada mail tertahan yang sah:
   `postqueue -f`; bila tidak: `postsuper -d <ID>`.
4. Uji eksternal pertama (opsional, dengan user): kirim dari `postmaster@` ke alamat penguji (mis. mail-tester) → SPF/DKIM/DMARC
   `pass`, header `Received` memakai `31.97.50.221`, HELO `mail.bimacreative.tech`.

## Menambah domain client (contoh `expomedia.id`) — JANGAN dijalankan sebelum DNS client siap

Prasyarat: domain terdaftar & DNS aktif (2026-09-23: `expomedia.id` **belum** aktif), plan subscription menentukan jumlah mailbox/kuota.

> **Status `expomedia.id` (2026-09-25, plan 07 — GATE 1: sisi server dikerjakan lebih dulu, DNS menyusul):** langkah 2–4 & 6 selesai —
> DKIM `mail` rsa-2048 dibuat, blok `expomedia.id` di `dkim_signing.conf` aktif (Rspamd reload otomatis), mailbox `postmaster@`, `dmarc@`,
> `info@`, `admin@`, `sales@` (2G) + alias `abuse@→postmaster@`; uji lokal lulus (DKIM `d=expomedia.id; s=mail`, cross-domain From tidak
> ditandatangani, envelope domain lain `553`). Langkah 1 & 5: instruksi DNS siap di `docs/clients/expomedia.md` /
> `docs/clients/expomedia-dns-mail.txt`, tetapi zona Dewaweb masih **kosong** → verifikasi DNS publik **BELUM**.

1. Kirim instruksi DNS ke client dari `templates/mail-client-dns.txt` (ganti `<CLIENT_DOMAIN>`; `<DKIM_PUBLIC>` diisi di langkah 3).
2. DKIM: `docker exec mailserver setup config dkim domain expomedia.id`.
3. Aktifkan blok `expomedia.id { … }` di `config/rspamd/override.d/dkim_signing.conf` (sudah disiapkan sebagai komentar) → commit →
   `sudo ./scripts/bootstrap.sh`. Kirim nilai `.public.dns.txt` ke client.
4. Mailbox wajib: `mailbox-add.sh postmaster@expomedia.id`, `mailbox-add.sh dmarc@expomedia.id` (target `rua`), alias
   `abuse@expomedia.id → postmaster@expomedia.id`; mailbox user sesuai plan (`mailbox-add.sh <user>@expomedia.id [kuota]`).
   Menambah akun pertama sebuah domain otomatis menjadikannya domain lokal (`virtual_mailbox_domains`).
5. Verifikasi (dari host): `dig +short MX expomedia.id @1.1.1.1` = `10 mail.bimacreative.tech.`; SPF memuat
   `include:_spf.bimacreative.tech`; `dig TXT mail._domainkey.expomedia.id` = kunci publik; `_dmarc` ada.
6. Uji: kirim lokal `postmaster@expomedia.id` → `dmarc@expomedia.id` (587 + AUTH) → header `DKIM-Signature: d=expomedia.id`;
   login `…@expomedia.id` dengan `From: x@bimacreative.tech` → **tidak** ditandatangani (`allow_username_mismatch=false`);
   envelope `MAIL FROM` domain lain → `553 … not owned by user`.
7. Klien email client: IMAP `mail.bimacreative.tech:993` (TLS), SMTP `mail.bimacreative.tech:465` (TLS) atau `:587`
   (STARTTLS), username = alamat email lengkap. **Bukan** `mail.<domain-client>` — kecuali hostname itu sudah diaktifkan lewat
   §Hostname mail per domain client (opsional, ADR 0011; `expomedia.id` → `mail.expomedia.id` aktif 2026-09-25).
8. Rate limit berlaku per mailbox (30/jam) dan per domain (200/jam); override per plan belum ada (backlog control plane).

## Hostname mail per domain client (opsional, ADR 0011) — contoh `mail.expomedia.id`

Nama server klien email per client; HELO/PTR/**MX tetap** `mail.bimacreative.tech` (MX client tidak diubah). Satu router + satu
sertifikat per hostname (tanpa SAN gabungan/wildcard). Recreate `mailserver` sekali (terukur 2026-09-25: IMAP ±9 s, SMTP 25
±22 s tanpa respons). Ganti `<fqdn>` (mis. `mail.expomedia.id`).

1. **DNS (client):** `A mail.<domain-client> 31.97.50.221`, tanpa AAAA/CNAME (instruksi: `templates/mail-client-dns.txt` record 5).
2. **Pre-check (wajib sebelum router):**
   ```bash
   for ns in <ns-otoritatif-1> <ns-otoritatif-2> 1.1.1.1 8.8.8.8; do
     echo "$ns A=$(dig +short A <fqdn> @$ns) AAAA=$(dig +short AAAA <fqdn> @$ns) CNAME=$(dig +short CNAME <fqdn> @$ns)"; done
   grep -rn '<fqdn>' /opt/infra/traefik/dynamic/          # harus kosong (hostname unik)
   ```
3. **Sertifikat:** tambah router di `traefik/dynamic/platform/mail-clients.yml` (salin blok `mail-cert-expomedia`, nama router
   `mail-cert-<slug>`, `Host(\`<fqdn>\`)`, `certResolver: le-http`) → `docker exec traefik kill -HUP 1` (H7). Bukti:
   `docker logs --since 2m traefik 2>&1 | grep -i '<fqdn>'` (`Server responded with a certificate`) dan
   `echo | openssl s_client -connect 127.0.0.1:443 -servername <fqdn> -verify_hostname <fqdn> -verify_return_error 2>&1 | grep -E '^subject=|Verify return'`.
4. **Ekspor (allowlist):** tambahkan `<fqdn>` ke `mail_tls_export_sni_domains` (`ansible/roles/mail_tls_export/defaults/main.yml`)
   → `cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook -i inventories/local/hosts.yml site.yml --tags mail_tls_export --check --diff`,
   lalu tanpa `--check`, run kedua `changed=0` → `systemctl start mail-tls-export.service` →
   `journalctl -u mail-tls-export.service -n 3` (`exported domain=<fqdn>`), `stat -c '%a %n' /opt/infra/mail/data/tls/<fqdn>/*` (600).
   **Langkah 4 WAJIB selesai sebelum langkah 5** (file harus ada sebelum Postfix/Dovecot merujuknya).
5. **SNI:** tambah `{ <fqdn> = /etc/dms-tls/<fqdn>/chain.pem }` di `tls_server_sni_maps` (`config/postfix-main.cf`) dan blok
   `local_name <fqdn> { … }` di `config/dovecot.cf` → `sudo ./scripts/bootstrap.sh` →
   `docker exec mailserver postqueue -p` (catat) + `dms-healthcheck` → `docker compose up -d --force-recreate mailserver` →
   `(healthy)`; `docker exec mailserver sh -c 'postconf tls_server_sni_maps; doveconf -n | grep -A4 ^local_name'`.
6. **Verifikasi:**
   ```bash
   for p in "993" "465" "587 -starttls smtp" "25 -starttls smtp"; do set -- $p; port=$1; shift
     for sn in <fqdn> mail.bimacreative.tech; do echo "$port $sn: $(echo | openssl s_client -connect 31.97.50.221:$port "$@" \
       -servername $sn -verify_hostname $sn -verify_return_error 2>&1 | grep -E '^subject=|Verify return code' | tr '\n' ' ')"; done; done
   echo | openssl s_client -connect 31.97.50.221:993 -noservername 2>/dev/null | openssl x509 -noout -subject   # default: mail.bimacreative.tech
   # AUTH (password via stdin, tidak pernah di argv host / output):
   sudo cat /opt/infra/mail/secrets/<user>.password | sudo docker exec -i mailserver sh -c 'SWAKS_OPT_auth_password="$(cat)"; \
     export SWAKS_OPT_auth_password; swaks --server 127.0.0.1 --port 587 --tls --tls-sni <fqdn> --tls-verify \
     --tls-verify-target <fqdn> --auth LOGIN --auth-user <user> --auth-hide-password --quit-after AUTH 2>&1' \
     | grep -E '^(<~  2|<~  5|=== TLS peer certificate)'
   ```
   Lalu update dokumen client (`docs/clients/<slug>.md` §klien email) dan kabari client: server = `<fqdn>`.
7. **Rollback** (urutan terbalik; staf kembali ke `mail.bimacreative.tech`): keluarkan entri dari `config/postfix-main.cf` +
   `config/dovecot.cf` → `bootstrap.sh` → recreate `mailserver` (atau live: `postconf -e` tanpa entri / `postconf -X
   tls_server_sni_maps` + `postfix reload`; hapus `/etc/dovecot/local.conf` bila kosong + `dovecot reload`) → hapus dari
   `mail_tls_export_sni_domains` → role (daftar kosong = unit `mail-tls-reload.*` dihapus) → hapus router di `mail-clients.yml` →
   HUP Traefik → hapus `data/tls/<fqdn>/` (`shred -u`, konfirmasi Lead). Uji kering 2026-09-25: ADR 0011 §Rollback.

Status: `mail.expomedia.id` aktif 2026-09-25 (bukti `docs/clients/expomedia.md` §7b).

## Cek reputasi & kesehatan

```bash
dig -x 31.97.50.221 +short                                   # PTR
docker exec mailserver postqueue -p                          # antrean (deferred menumpuk = masalah kirim / guard aktif)
grep -c "Ratelimit" /var/log/mailserver/dms/rspamd.log       # akun kena limit → selidiki (akun bocor?)
grep -E "reject|warning" /var/log/mailserver/dms/mail.log | tail
docker exec mailserver doveadm search -u dmarc@bimacreative.tech mailbox INBOX ALL | wc -l   # laporan DMARC masuk
```
- Blocklist IP (manual, mingguan setelah kirim keluar aktif): cek `31.97.50.221` di multirbl.valli.org / MXToolbox Blacklist;
  Spamhaus lookup. Daftarkan domain di Google Postmaster Tools (butuh TXT verifikasi dari user) — opsional.
- Laporan DMARC (`rua`) masuk ke `dmarc@bimacreative.tech` (XML terkompresi) — tinjau mingguan sebelum menaikkan
  `p=quarantine` → `reject`.
- Log mail juga di Loki: `{container="mailserver"}` (stdout DMS).

## CrowdSec (deteksi brute force & abuse)

- Acquisition `security/crowdsec/acquis.d/mail.yaml` → `/var/log/host/mailserver/dms/mail.log` (`type: syslog`).
- Skenario: hub `postfix-spam`, `postfix-relay-denied`, `postfix-helo-rejected`, `postfix-non-smtp-command`, `dovecot-spam`
  (4 gagal IMAP/6 menit → ban) + lokal `infra/mail-postfix-sasl-bf` (6 gagal SASL, bocor 1/5 menit → ban). Skenario lokal perlu
  karena Dovecot menahan ±10–17 s per AUTH gagal sehingga `postfix-spam` (leak 10 s) tidak pernah overflow.
- IP privat (hairpin dari host/container tiba sebagai `10.100.10.1`) di-whitelist parser → uji dari host tidak menghasilkan ban.
- Ban/unban sama seperti layanan lain (`crowdsec.md`): `docker exec crowdsec cscli decisions list|delete --ip <IP>`.
```bash
docker exec crowdsec cscli metrics show acquisition parsers | grep -E "mail.log|postfix|dovecot"
docker exec crowdsec cscli explain --log '<baris mail.log>' --type syslog      # uji parser + skenario satu baris
```

## Backup & restore

- `data/{mail,state,config}` + `secrets/` berada di `/opt/infra` → ikut snapshot restic `files` harian tanpa perubahan skrip
  (diverifikasi `restic backup --dry-run`: maildir, `postfix-accounts.cf`, `dovecot-quotas.cf`, `postfix-virtual.cf`, kunci DKIM,
  `dms-dump.rdb`, `secrets/*.password`). Dibaca saat layanan hidup (maildir aman: file per pesan + rename atomik).
- Restore (ke direktori baru dulu, **jangan** langsung menimpa `data/`):
  `restic restore latest --tag files --target /root/mail-restore --include /opt/infra/mail/data` → `docker compose down` →
  salin yang diperlukan → `docker compose up -d`. Menimpa `data/` = destruktif → konfirmasi Lead/user. **Belum diuji.**
- Kehilangan `data/config/rspamd/dkim/` = DKIM harus dibuat & dipublikasikan ulang.

## Monitoring

- Uptime Kuma (`observability/scripts/uptime-kuma-provision.sh`, idempoten): `Mail SMTP (25)` (TCP), `Mail IMAPS (993)`
  (TLS + sertifikat). Probe tiap 60 s tiba sebagai `10.100.10.1` → ±6 baris log/menit (`PASS OLD`, `lost connection after
  CONNECT`, `no auth attempts`) — noise yang diketahui.
- Healthcheck container: `dms-healthcheck` (semua layanan supervisord yang diaktifkan env harus RUNNING).
- Belum ada alert (antrean menumpuk, ratelimit terpicu) — backlog observability.

## Uji yang dijalankan (2026-09-23)

| Uji | Perintah (ringkas) | Hasil |
|---|---|---|
| Container | `docker compose ps` | `Up (healthy)` |
| Listener host | `ss -tlnp` | `0.0.0.0:25/465/587/993`, tanpa `[::]`; 143/110/995/4190 tidak di-publish (143 → refused) |
| TLS 587/465/993/25 | `openssl s_client … -verify_return_error` | subject `CN=mail.bimacreative.tech`, issuer LE `YE2`, `Verify return code: 0` |
| AUTH tanpa TLS (587) | EHLO → AUTH/MAIL mentah | AUTH tidak ditawarkan; `530 5.7.0 Must issue a STARTTLS command first` |
| Kirim lokal 587 + AUTH | swaks postmaster → dmarc | `250 queued`; LMTP `Saved`; IMAPS 993 login dmarc@ → pesan ditemukan |
| DKIM | header pesan | `DKIM-Signature: … d=bimacreative.tech; s=mail` |
| Open relay (25) | swaks tanpa AUTH → `test@example.com` (bridge→IP publik, dari network `mail`, dengan STARTTLS, dengan MAIL FROM domain lokal) | 4× `554 5.7.1 Relay access denied` |
| Spoof envelope (465) | login postmaster, MAIL FROM dmarc@ | `553 5.7.1 … not owned by user` |
| Guard keluar | AUTH → `test@example.com` (null MX) | `status=deferred (deferred transport)`, `relay=none`; pesan dihapus dari antrean |
| Ratelimit | 12 kiriman beruntun postmaster → dmarc | ke-9..12 `451 4.7.1 Ratelimit "mailbox_outbound" exceeded` (2 token terpakai uji sebelumnya); bucket Redis dihapus setelah uji |
| Brute force | 3× AUTH SMTP salah + 3× IMAP salah | tercatat (`SASL … authentication failed`, `auth_failed`); tanpa ban (IP privat whitelist); replay offline IP `203.0.113.10/.11` → ban `infra/mail-postfix-sasl-bf` & `crowdsecurity/dovecot-spam` |
| CrowdSec membaca | `cscli metrics` | `file:/var/log/host/mailserver/dms/mail.log` lines read/parsed/whitelisted |
| Backup | `restic backup --dry-run` | path mail ikut |
| Firewall | `ansible-playbook site.yml --tags firewall` ×2 | run 1 changed=1, run 2 changed=0; `ufw status` 25/465/587/993 (v4) |

## Rollback

- Stack: `cd /opt/infra/mail && docker compose down` — layanan lain tidak terpengaruh; pengirim eksternal me-retry (MX tetap).
  Data tetap di `data/`. Hapus `data/` / `secrets/` = destruktif → konfirmasi.
- Router sertifikat: hapus `traefik/dynamic/platform/mail.yml` → `docker exec traefik kill -HUP 1` (sertifikat tetap di
  `acme.json` sampai kedaluwarsa).
- Hostname mail per domain client (ADR 0011): §Hostname mail per domain client langkah 7.
- Firewall: hapus `ufw_allow_tcp_ports_mail` + task di role `firewall` **dan** `ufw delete allow from 0.0.0.0/0 to any port <p>
  proto tcp` per port (role hanya menambah).
- CrowdSec: hapus `acquis.d/mail.yaml`, `scenarios/mail-postfix-sasl-bf.yaml` (+ mount & baris `COLLECTIONS`), `cscli collections
  remove crowdsecurity/postfix crowdsecurity/dovecot` → `docker exec crowdsec kill -HUP 1` (403 fail-closed ±8 s) atau
  `docker compose up -d` (recreate ±40 s).
- Uptime Kuma: hapus dua entri MONITORS + hapus monitor di UI (skrip tidak menghapus).
