# Operasional — Mail (docker-mailserver, T11)

- **Stack:** `/opt/infra/mail/` · image `mailserver/docker-mailserver:16.0.1@sha256:d0fe7668…` (index multi-arch, ADR 0001)
- **Hostname:** `mail.bimacreative.tech` = HELO = PTR = CN sertifikat untuk **semua** domain (ADR 0005 #5, #9)
- **Terkait:** ADR 0005 (keputusan utama), 0002 (DNS/TLS), 0004 (RAM), 0006 (backup); `traefik.md`, `crowdsec.md`,
  `backup.md`, `observability.md`
- Versi komponen di image (dicek 2026-09-23): Postfix 3.10.13, Dovecot 2.4.1, Rspamd 4.1.5, Redis internal, swaks 20240103.

> **STATUS 2026-09-23:** menerima & mengantar mail **lokal**. Pengiriman **keluar DITAHAN** (`defer_transports = smtp`)
> sampai PTR `31.97.50.221 → mail.bimacreative.tech` diset user — lihat §PTR. Jangan jalankan `postqueue -f` sebelum itu.

## Struktur

| Path | Isi | Git |
|---|---|---|
| `docker-compose.yml` | service `mailserver`, network `mail` 10.100.10.0/24 (compose-managed, tanpa IPv6) | ya |
| `config/postfix-main.cf` | override Postfix (di-append ke main.cf saat **start**) — saat ini hanya guard `defer_transports` | ya |
| `config/rspamd/override.d/dkim_signing.conf` | DKIM multi-domain (blok `domain { … }` per domain) | ya |
| `config/rspamd/override.d/ratelimit.conf` | rate limit outbound per mailbox & per domain | ya |
| `scripts/bootstrap.sh` | idempoten: `data/`, `/var/log/mailserver`, `secrets/`, sinkron `config/` → `data/config/` | ya |
| `scripts/mailbox-add.sh` | tambah mailbox (password acak → `secrets/`, kuota default 2G) / `--rotate` | ya |
| `data/config/` (= `/tmp/docker-mailserver`) | `postfix-accounts.cf` (hash SHA512-CRYPT), `postfix-virtual.cf` (alias), `dovecot-quotas.cf`, `rspamd/dkim/*.private.txt` (kunci DKIM privat), salinan override | **tidak** (`**/data/`) |
| `data/mail/` (= `/var/mail`) | maildir `<domain>/<local>/` (uid/gid 5000) | tidak |
| `data/state/` (= `/var/mail-state`) | antrean Postfix, Redis (bucket ratelimit, history), state Dovecot/Rspamd | tidak |
| `secrets/<alamat>.password` | password mailbox, 600 root, 32 char tanpa newline | **tidak** (`mail/.gitignore`) |
| `/var/log/mailserver/dms/` (= `/var/log/mail`) | `mail.log` (Postfix/Dovecot), `rspamd.log`; parent `root:adm 750` | — |
| `traefik/dynamic/platform/mail.yml` | router dummy sertifikat (redirect 307 → cp) | ya |
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
- DMS (`SSL_TYPE=letsencrypt`, `SSL_DOMAIN=mail.bimacreative.tech`) membaca `traefik/acme/acme.json` (mount **file** read-only
  → `/etc/letsencrypt/acme.json`), mengekstrak cert/key ke `/etc/letsencrypt/live/mail.bimacreative.tech/` (`acme_extract.py`).
- **Perpanjangan otomatis:** change detection DMS memantau `/etc/letsencrypt/acme.json` (tiap `DMS_CONFIG_POLL`=2 s) → ekstrak
  ulang + reload Postfix/Dovecot (`check-for-changes.sh` `_ssl_changes`). Mount file tunggal aman karena Traefik menulis
  `acme.json` **di tempat** (`os.WriteFile`, `pkg/provider/acme/local_store.go` v3.7.13 → inode tetap). **Jika** `acme.json`
  pernah diganti dengan `mv`/restore (inode baru) → `docker compose up -d --force-recreate mailserver`.
- Perubahan sertifikat hostname lain juga mengubah `acme.json` → DMS ekstrak ulang + reload (tanpa efek bagi klien).
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
- Akun saat ini: `postmaster@`, `dmarc@` (penerima `rua` DMARC) — mailbox; `abuse@` → alias ke `postmaster@`.

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
   (STARTTLS), username = alamat email lengkap. **Bukan** `mail.expomedia.id` (sertifikat tidak cocok).
8. Rate limit berlaku per mailbox (30/jam) dan per domain (200/jam); override per plan belum ada (backlog control plane).

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
- Router sertifikat: hapus `traefik/dynamic/platform/mail.yml` → `docker kill --signal=HUP traefik` (sertifikat tetap di
  `acme.json` sampai kedaluwarsa).
- Firewall: hapus `ufw_allow_tcp_ports_mail` + task di role `firewall` **dan** `ufw delete allow from 0.0.0.0/0 to any port <p>
  proto tcp` per port (role hanya menambah).
- CrowdSec: hapus `acquis.d/mail.yaml`, `scenarios/mail-postfix-sasl-bf.yaml` (+ mount & baris `COLLECTIONS`), `cscli collections
  remove crowdsecurity/postfix crowdsecurity/dovecot` → `docker kill --signal=HUP crowdsec` (403 fail-closed ±8 s) atau
  `docker compose up -d` (recreate ±40 s).
- Uptime Kuma: hapus dua entri MONITORS + hapus monitor di UI (skrip tidak menghapus).
