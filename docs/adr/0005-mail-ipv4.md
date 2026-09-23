# ADR 0005 — Mail (docker-mailserver): IPv4-only & multi-domain

- **Status:** proposed (menunggu GATE 1)
- **Tanggal:** 2026-09-23
- **Terkait:** CLAUDE.md §2, §3.6 (Mail); ADR 0001 (DMS 16.0.1), 0002 (DNS), 0004; keputusan user #3;
  requirement tambahan user (via Lead, 2026-09-23): satu DMS melayani beberapa domain (`bimacreative.tech` + domain client, pertama `expomedia.id`)

## Context

- Keputusan user #3: PTR/rDNS **hanya bisa diset untuk IPv4** di Hostinger. Tanpa PTR yang cocok
  (FCrDNS), mail yang dikirim via IPv6 berisiko ditolak/masuk spam.
- Fakta host: IPv6 global `2a02:4780:59:823e::1` aktif; port 25 keluar terbuka untuk IPv4 **dan** IPv6
  (discovery §1.4). rDNS saat ini `srv2001692.hstgr.cloud` (v4 & v6).
- Docs docker-mailserver v16.0.1 (di-fetch dari `raw.githubusercontent.com/docker-mailserver/docker-mailserver/v16.0.1/...`):
  - `docs/content/config/environment.md`: `POSTFIX_INET_PROTOCOLS` (`all` default | `ipv4` | `ipv6`, "ipv4 => Listen only on IPv4 interfaces. Most likely you want this behind Docker."), `DOVECOT_INET_PROTOCOLS` (sama), `PERMIT_DOCKER` (default aman `none`; peringatan open relay bila IPv6 host aktif tetapi tidak di Docker), `ENABLE_RSPAMD`, `ENABLE_OPENDKIM`, `ENABLE_OPENDMARC`, `ENABLE_POLICYD_SPF` ("likely want … 0 in case you're using Rspamd"), `ENABLE_FAIL2BAN` (butuh `cap_add: NET_ADMIN`), `ENABLE_CLAMAV` (default 0), `SSL_TYPE`.
  - `docs/content/config/advanced/ipv6.md`: tanpa AAAA untuk FQDN DMS, koneksi IPv6 tidak terjadi; dengan `userland-proxy: false` koneksi IPv6 ke container tanpa alamat IPv6 gagal; dengan `userland-proxy: true` IP client IPv6 terlihat sebagai gateway Docker (merusak fail2ban/SPF, risiko open relay).
  - `docs/content/config/advanced/override-defaults/postfix.md`: file `docker-data/dms/config/postfix-main.cf` di-append ke `/etc/postfix/main.cf` lalu `postconf -nf`.
  - `target/postfix/main.cf` (v16.0.1): `inet_protocols = all`, `inet_interfaces = all`.
  - `docs/content/config/security/ssl.md`: `acme.json` Traefik dibaca bila di-mount ke `/etc/letsencrypt/acme.json`; DMS memilih sertifikat untuk FQDN; perlu router Traefik yang "menuntut" sertifikat tsb.
- Postfix `postconf(5)` (https://www.postfix.org/postconf.5.html): `inet_protocols` = protokol yang dipakai
  "when making **or accepting** connections" (jadi `ipv4` juga membatasi koneksi keluar);
  `smtp_address_preference` "has no effect unless the inet_protocols setting enables both IPv4 and IPv6".

## Decision

1. **Tidak ada AAAA** untuk `mail.bimacreative.tech` (dan untuk hostname lain di fase ini — ADR 0002).
2. DMS env: `POSTFIX_INET_PROTOCOLS=ipv4`, `DOVECOT_INET_PROTOCOLS=ipv4` → Postfix hanya menerima **dan
   mengirim** via IPv4 (sesuai semantik `inet_protocols`).
3. Jaringan Docker untuk mail **tanpa** `enable_ipv6`; daemon.json **tanpa** `ipv6`/`ip6tables` diaktifkan
   dan `userland-proxy: false` (plan 01). Dengan begitu container mail tidak punya jalur IPv6 keluar
   sama sekali (lapisan kedua setelah #2).
4. `PERMIT_DOCKER=none` (eksplisit), sehingga relay hanya untuk klien terautentikasi.
5. PTR IPv4 `31.97.50.221 → mail.bimacreative.tech` diset user di panel Hostinger; FQDN container DMS
   = `mail.bimacreative.tech` (hostname = HELO). SPF `ip4:31.97.50.221`, DKIM (selector dari output
   `setup config dkim`), DMARC (ADR 0002 record #10–14).
6. Proteksi anomali (§3.6): Rspamd ON (`ENABLE_RSPAMD=1`, `ENABLE_OPENDKIM=0`, `ENABLE_OPENDMARC=0`,
   `ENABLE_POLICYD_SPF=0` — Rspamd menangani DKIM/DMARC/SPF; kombinasi persis diverifikasi implementer
   di docs `config/security/rspamd.md`), `ENABLE_FAIL2BAN=1` + `cap_add: [NET_ADMIN]`, ClamAV/Amavis/
   SpamAssassin OFF (RAM, ADR 0004). Rate-limit outbound per user/jam: mekanisme (Rspamd ratelimit
   module vs Postfix policy) **UNVERIFIED** — implementer wajib memilih dari docs resmi.
7. Port publik: 25, 465, 587, 993 (ufw, §3.6). POP3/143 tidak dibuka.
8. TLS: `SSL_TYPE=letsencrypt` + mount `acme.json` read-only; router Traefik `Host(\`mail.bimacreative.tech\`)`
   (redirect ke `cp`) dengan `certResolver: le-http` agar sertifikat terbit.

### Multi-domain (requirement tambahan 2026-09-23)

Fakta docs DMS v16.0.1 (di-fetch 2026-09-23):
- `docs/content/config/best-practices/dkim_dmarc_spf.md`: dengan `ENABLE_RSPAMD=1` + `ENABLE_OPENDKIM=0`,
  kunci dibuat **per domain**: `setup config dkim domain example.com`, `setup config dkim domain another-example.com`;
  "If you have multiple domains, you need to … Provide a custom `dkim_signing.conf` … as the default config
  only supports one domain"; contoh `dkim_signing.conf` memakai blok `domain { <domain> { path = …; selector = …; } }`,
  `sign_authenticated = true`, `use_domain = "header"`, `check_pubkey = true`; kunci disimpan di
  `/tmp/docker-mailserver/rspamd/dkim/`; file default ditulis ke `/tmp/docker-mailserver/rspamd/override.d/dkim_signing.conf`.
- `docs/content/config/account-management/provisioner/file.md`: `setup email add <addr>`, `setup quota set <addr> 10M`,
  file `postfix-accounts.cf`, `dovecot-quotas.cf`.
- `docs/content/config/environment.md`: `ENABLE_QUOTAS` (default 1; hanya dengan `ACCOUNT_PROVISIONER=FILE`),
  `POSTFIX_MAILBOX_SIZE_LIMIT` (default 0 = tanpa batas), `POSTFIX_MESSAGE_SIZE_LIMIT` (default ≈10 MB).
- Rspamd ratelimit module (https://docs.rspamd.com/modules/ratelimit/, di-fetch 2026-09-23): bucket
  predefined `user` ("limit per authenticated user (useful for outbound limits)"), bucket berbasis
  `selector` (contoh `selector = 'user.lower'`), `rate = "10 / 1min"` + `burst`; modul butuh `servers`
  (Redis) — "By default, no cache servers are specified … the module will not work until this option is added".
  Apakah DMS otomatis mengarahkan modul ke Redis internal (`ENABLE_RSPAMD_REDIS`): **UNVERIFIED**.

Keputusan:
9. **Satu hostname server** `mail.bimacreative.tech` untuk semua domain: HELO, PTR, sertifikat TLS, dan
   host IMAP/SMTP yang dipakai klien email **semua** domain. Tidak ada `mail.<domain-client>` (butuh
   sertifikat per hostname + SNI di Dovecot/Postfix — di luar scope).
10. `ACCOUNT_PROVISIONER=FILE` (default) → mailbox via `setup email add`; kuota via `setup quota set`.
11. DKIM **per domain** (selector `mail`, RSA 2048 — docs menyatakan tidak perlu > 2048) + `dkim_signing.conf`
    kustom dengan blok `domain { … }` per domain; `check_pubkey = true` saat onboarding.
12. **SPF terpusat**: record platform `_spf.bimacreative.tech TXT "v=spf1 ip4:31.97.50.221 -all"`;
    domain client memakai `include:_spf.bimacreative.tech` → bila IP berubah, cukup ubah satu record.
13. **Rate limit outbound** (Rspamd ratelimit, perlu Redis): per mailbox (`user`) mis. 30/jam burst 10, dan
    per domain pengirim (selector domain — sintaks selector **UNVERIFIED**) mis. 200/jam; batas awal
    konservatif, dinaikkan per plan. Plus `POSTFIX_MESSAGE_SIZE_LIMIT` default (≈10 MB). Alert bila
    mailbox kena limit (indikasi akun bocor) → suspend mailbox (ganti password) oleh ops.
14. **Isolasi reputasi**: Rspamd memindai mail keluar dari user terautentikasi; mailbox yang mengirim spam
    diblokir; DMARC per domain dengan `rua` ke mailbox domain itu sendiri; pemantauan blocklist IP.
    Keterbatasan: semua domain tetap berbagi satu IP → satu client nakal bisa merusak reputasi semua
    (risiko diterima; mitigasi final = relay/IP terpisah, ADR baru).
15. **Kuota & disk (ESTIMASI)**: default 2 GiB/mailbox (`setup quota set`), maks per domain ditentukan plan
    subscription. Contoh: 20 mailbox × 2 GiB = 40 GiB **batas atas**; pemakaian awal realistis ±1–5 GiB.
    Disk host 193 G dibagi dengan Postgres/filestore/backup (ADR 0004/0006) → total kuota mail yang
    dijanjikan ke semua client **maks ±40 GiB** sampai ada data nyata; maildir ikut backup restic (menambah
    ukuran repo lokal ±1×). RAM tidak berubah signifikan (Dovecot per koneksi IMAP ±beberapa MB — ESTIMASI).
16. **Scope control plane (plan berikutnya, tidak dirancang detail sekarang):** entitas `mail_domain`
    (status verifikasi DNS MX/SPF/DKIM/DMARC) dan `mailbox` (kuota, status, rate-limit override), aksi
    `mailbox add/suspend/delete`, `dkim generate` via job antrean (docker-socket-proxy / skrip) — dicatat
    sebagai kebutuhan untuk plan control plane.

#### Template instruksi DNS untuk domain mail client (dirender control plane kelak)

Untuk domain `<client-domain>` (contoh pertama: `expomedia.id`, DNS dikelola client; saat ini tanpa MX):

| Tipe | Nama | Nilai | Catatan |
|---|---|---|---|
| MX | `@` | `10 mail.bimacreative.tech` | satu-satunya MX; hapus MX lama bila migrasi (koordinasi agar mail tidak hilang) |
| TXT | `@` | `v=spf1 include:_spf.bimacreative.tech -all` | jika client juga kirim via layanan lain, tambahkan `include:` layanan itu **sebelum** `-all`; hanya boleh **satu** record SPF |
| TXT | `mail._domainkey` | `v=DKIM1; k=rsa; p=<kunci publik>` | nilai dari `setup config dkim domain <client-domain>`; diberikan setelah kunci dibuat |
| TXT | `_dmarc` | `v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:dmarc@<client-domain>` | mulai `p=none` 2–4 minggu, lalu `quarantine` → `reject` setelah laporan bersih |
| — | (klien email) | IMAP `mail.bimacreative.tech:993` (TLS), SMTP submission `mail.bimacreative.tech:465` (TLS) atau `:587` (STARTTLS) | jangan pakai `mail.<client-domain>` (sertifikat tidak cocok) |

Verifikasi sebelum domain diaktifkan: `dig +short MX <client-domain> @1.1.1.1` = `10 mail.bimacreative.tech.`;
SPF memuat include; DKIM publik cocok (`check_pubkey`); lalu kirim uji ke penguji eksternal (mis. mail-tester — opsional).

Record tambahan platform untuk mendukung ini (tambahkan ke ADR 0002): `TXT _spf.bimacreative.tech "v=spf1 ip4:31.97.50.221 -all"`;
record SPF root `bimacreative.tech` boleh menjadi `v=spf1 include:_spf.bimacreative.tech -all`.

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Dual-stack dengan `smtp_address_preference = ipv4` | Tetap bisa kirim via IPv6 ke tujuan IPv6-only / saat v4 gagal → tanpa PTR v6; opsi itu hanya preferensi |
| `smtp_bind_address` ke IPv4 | Di dalam container alamat yang terlihat adalah IP bridge Docker; tidak relevan; `inet_protocols` lebih tegas |
| Relay keluar via SMTP pihak ketiga | Tidak diminta; menambah biaya/ketergantungan (bisa jadi opsi bila reputasi IP Hostinger buruk) |
| Menonaktifkan IPv6 di seluruh host (`disable_ipv6`) | Terlalu luas; tidak perlu karena #2 dan #3 sudah cukup |
| Instance DMS per client | RAM ±1 GiB per instance (ADR 0004) — tidak muat |
| Hostname mail per client (`mail.<client-domain>`) | Sertifikat per hostname + konfigurasi SNI Postfix/Dovecot; kompleks; tidak memperbaiki reputasi karena IP tetap sama |
| OpenDKIM (default DMS) | Rspamd sudah dipakai untuk spam/ratelimit; satu komponen lebih sedikit |

## Consequences

- Penerima mail yang hanya IPv6 (jarang) tidak bisa dijangkau — risiko diterima.
- Reputasi IP Hostinger (range hosting) tetap faktor di luar kendali; pantau blocklist & laporan DMARC.
- DMS membutuhkan router HTTP dummy di Traefik untuk sertifikat.
- Setiap domain client baru = langkah manual (DKIM generate + update `dkim_signing.conf` + restart Rspamd) sampai control plane mengotomatisasi.
- Reputasi IP dibagi semua domain; satu mailbox bocor dapat memengaruhi semua (mitigasi #13–14).

## Security implications

- Tanpa AAAA & tanpa IPv6 di container, masalah "IP client = gateway Docker" (open relay, fail2ban buta)
  dari docs DMS tidak terjadi.
- `PERMIT_DOCKER=none` mencegah container lain di host relay tanpa auth.
- QA wajib: uji open relay dengan `swaks` dari luar (§3.6), cek `postconf inet_protocols` = `ipv4`,
  cek header mail keluar memakai IP `31.97.50.221`, cek PTR `dig -x 31.97.50.221 +short`.
- QA multi-domain: kirim dari mailbox `bimacreative.tech` dan `expomedia.id` → header `DKIM-Signature: d=<domain>` benar,
  SPF/DKIM/DMARC `pass` di penerima eksternal; user domain A tidak bisa kirim dengan `From:` domain B
  (sender login mismatch — mekanisme Postfix `smtpd_sender_login_maps`/`reject_sender_login_mismatch` di DMS **UNVERIFIED**, wajib dicek implementer);
  uji ratelimit: kirim > limit per jam → ditolak/ditunda.

## Rollback

Hapus env `*_INET_PROTOCOLS` (kembali `all`) → recreate container. Mail stack dapat dihentikan
(`docker compose down` di `mail/`) tanpa memengaruhi layanan lain; MX tetap ada → pengirim akan
retry (antrian pengirim) selama beberapa hari.
