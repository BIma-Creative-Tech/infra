# Client — PT Expomedia Indo Karya (`expomedia`)

- Dibuat: 2026-09-25 (plan `docs/plans/07-expomedia-web-mail.md`, discovery `docs/discovery/2026-09-25-expomedia.md`).
- Slug platform: `expomedia`. Domain client: `expomedia.id` (registrar PT Digital Registra Indonesia, NS `ns1/ns2/ns3.dewaweb.com`,
  kedaluwarsa 2027-03-26 — `whois`, 2026-09-25).
- Prosedur yang dipakai: `docs/03-operations/mail.md` §Menambah domain client, `docs/runbooks/client-domain-onboarding.md` B,
  `docs/runbooks/web-client-onboarding.md`.

## 1. Profil singkat (riset publik — belum dikonfirmasi client)

| Item | Nilai |
|---|---|
| Nama | PT Expomedia Indo Karya |
| Bidang | Events Services — jasa pameran/event (kontraktor booth, produksi event, brand activation = **ASUMSI** dari bidang & lowongan) |
| Ukuran | 11–50 karyawan |
| Alamat | Jl. Kp. Pintu Air No. 12, RT 003/RW 008, Belendung, Kec. Benda, Kota Tangerang, Banten 15123 |
| Website lama | tidak ditemukan (`expomedia.id` belum aktif; `expomedia.com` = entitas lain) |
| Materi yang masih placeholder | logo, foto proyek, daftar klien, angka statistik, testimoni — wajib dikonfirmasi client |

## 2. Status (2026-09-25)

| Komponen | Status | Keterangan |
|---|---|---|
| Website staging | dalam proses (task B/C plan 07) | `https://expomedia.staging.bimacreative.tech` (wildcard platform, tanpa AAAA); container `web-expomedia-staging` |
| Website prod (`expomedia.id`, `www`) | **BELUM** — menunggu DNS client | router Traefik prod hanya dibuat setelah `dig` pre-check lulus (ADR 0002) |
| Mail di server (DMS) | **SIAP** | DKIM `mail._domainkey` (rsa-2048) dibuat & signing aktif; 5 mailbox + alias `abuse@`; uji lokal lulus (§6) |
| DNS mail di zona client | **BELUM** — zona `expomedia.id` di NS Dewaweb kosong | client (pemilik zona) harus mengisi record §3; sampai saat itu mail keluar ke domain luar gagal SPF/DKIM/DMARC dan mail masuk tidak sampai |
| Secret SMTP form kontak | tersedia | prod `web/clients/expomedia/secrets/smtp_password.secret` + staging `staging/web-clients/expomedia/secrets/…` (400, uid 1001) = password **`noreply@expomedia.id`** (sejak 2026-09-25, plan 08) |
| Odoo staging `https://expomedia-erp.staging.bimacreative.tech` | **AKTIF** 2026-09-29 (plan 13) | DB `expomedia_staging`, 52 modul platform (SPK, BAST, CRM, HR/payroll ID, akuntansi PSAK, Coretax), SSO Keycloak `platform-staging`; form kontak website staging → lead CRM |
| Dashboard SPK `https://cp.staging.bimacreative.tech/dashboard` | **AKTIF (staging)** 2026-09-29 | data mart ADR 0016, plan 14; Owner/Finance nilai, PM status, AE miliknya |
| Login Odoo bermerek + Quotation Tracker | **AKTIF (staging/Demo)** 2026-09-30 | plan 15: `cl_expomedia_web`, `cp.staging/dashboard/quotation` |
| Odoo prod `https://erp.expomedia.id` | **BELUM** | plan 15 §4 (host diganti dari `expomedia.erp.bimacreative.tech`); menunggu DNS `erp` + persetujuan deploy prod |
| Webmail `https://webmail.expomedia.id` | **AKTIF** 2026-09-25 | Roundcube 1.7.4 + ganti password self-service (ADR 0012, §11) |

## 3. Instruksi DNS untuk client (siap kirim)

Diisi di panel DNS Dewaweb untuk zona `expomedia.id`. **Jangan** membuat record `AAAA` (platform IPv4-only, ADR 0002/0005).
Salinan teks polos khusus mail: `docs/clients/expomedia-dns-mail.txt`.

### 3a. Website

| Tipe | Nama | Nilai | TTL | Catatan |
|---|---|---|---|---|
| A | `@` | `31.97.50.221` | 3600 | apex tidak boleh CNAME |
| A | `www` | `31.97.50.221` | 3600 | **atau** CNAME `www` → `edge.bimacreative.tech` (pilih satu) |

Setelah record ini aktif, tim platform menerbitkan sertifikat TLS otomatis (HTTP-01) dan mengaktifkan `https://expomedia.id`
+ `https://www.expomedia.id`. Nanti akan ada satu record TXT tambahan `_platform-verify.expomedia.id` (token dari control plane; belum ada).

### 3b. Email

| Tipe | Nama | Nilai | TTL | Catatan |
|---|---|---|---|---|
| MX | `@` | `10 mail.bimacreative.tech` | 3600 | satu-satunya MX; bila ada MX lama, koordinasikan waktu pemindahan |
| TXT | `@` | `v=spf1 include:_spf.bimacreative.tech -all` | 3600 | hanya **satu** record SPF; layanan pengirim lain ditambahkan `include:` sebelum `-all` |
| TXT | `mail._domainkey` | `v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvQCxEq0VoR5V6cp8iljWrY6vZG+lzZGzI02vnSzIQUDaICbpSpHAJ2JhEPaC0VxbPHvaD2/Hd6OfaObDRF1z0kumm5EwtpsyUSEFNrGhgHhyv0ZfUxM28FgnnKR1FmmX6loxqPmy0GzlFoscp0Z1PEddWI3O6cEibuNkXfseCQ3NrjI1rq9ni6yDj9sOuMgf+qGRz5QGz6zEO2RpUTG+8FJnR5/JkhFIY1w0Gb527qJb5/jsIitfEF46jVJsFnuB/AM1Nm+JK3aMvqFuZWrUkCTRG7ReN8yzYtPmcaCGFFr6JyAqeOMy+F0ruJesQ4ixz6Qdj/Sah1aIYgggoakKuwIDAQAB` | 3600 | kunci publik DKIM selector `mail` (sumber: `mail/data/config/rspamd/dkim/rsa-2048-mail-expomedia.id.public.dns.txt`); satu string, tanpa spasi tambahan |
| TXT | `_dmarc` | `v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:dmarc@expomedia.id` | 3600 | mulai `p=none` 2–4 minggu → `quarantine` → `reject` setelah laporan bersih |
| A | `mail` | `31.97.50.221` | 14400 | **sudah diisi 2026-09-25** — nama server klien email (ADR 0011); tanpa AAAA; **MX tetap** `10 mail.bimacreative.tech` |

Bila panel Dewaweb membatasi panjang TXT (255 karakter per string), nilai DKIM boleh dipecah menjadi beberapa string dalam satu
record (format `"v=DKIM1; k=rsa; " "p=…" "…"`), lihat `rsa-2048-mail-expomedia.id.public.txt`.

## 4. Mailbox & alias (di `mail.bimacreative.tech`)

| Alamat | Kuota | Fungsi |
|---|---|---|
| `postmaster@expomedia.id` | 2G | wajib (RFC 5321); target alias `abuse@` |
| `dmarc@expomedia.id` | 2G | penerima laporan DMARC (`rua`) |
| `info@expomedia.id` | 2G | kontak umum; **penerima** form kontak website (pengirim = `noreply@` sejak 2026-09-25) |
| `admin@expomedia.id` | 2G | administrasi |
| `sales@expomedia.id` | 2G | penjualan |
| `noreply@expomedia.id` | 200M | **akun teknis** pengirim form kontak website (SMTP AUTH, password acak 32 char); tidak bisa login webmail, tidak untuk staf |
| `abuse@expomedia.id` | alias → `postmaster@expomedia.id` | wajib (RFC 2142) |

Password: `/opt/infra/mail/secrets/<alamat>.password` (600 root; 32 karakter). Serahkan ke client lewat jalur aman (bukan email
biasa/chat); rotasi: `sudo /opt/infra/mail/scripts/mailbox-add.sh --rotate <alamat>`. Bila **`noreply@`** dirotasi, salin ulang
ke `web/clients/expomedia/secrets/smtp_password.secret` dan `staging/web-clients/expomedia/secrets/smtp_password.secret`
(1001:1001, 0400, tanpa newline), jalankan ulang `provision-web-client.sh` (prod & staging, opsi sama §11) dan uji `POST /api/contact`.

## 5. Pengaturan klien email (Outlook / Thunderbird / ponsel)

| Item | Nilai |
|---|---|
| Username | alamat email lengkap, mis. `info@expomedia.id` |
| IMAP masuk | **`mail.expomedia.id`**, port `993`, SSL/TLS |
| SMTP keluar | **`mail.expomedia.id`**, port `465` SSL/TLS **atau** port `587` STARTTLS |
| Autentikasi SMTP | wajib, username & password sama dengan IMAP |
| Alternatif | `mail.bimacreative.tech` (port sama) **tetap berfungsi** — perangkat yang sudah memakainya tidak wajib diubah |
| POP3 | tidak disediakan (port 110/995 tidak dipublikasikan) |

Sejak 2026-09-25 (ADR 0011): `mail.expomedia.id` memakai sertifikat Let's Encrypt sendiri yang dipilih lewat TLS SNI di server
yang sama (`mail.bimacreative.tech`). Banner/EHLO SMTP tetap `mail.bimacreative.tech` (normal). Klien email sangat tua tanpa SNI
akan melihat sertifikat `mail.bimacreative.tech` → pakai `mail.bimacreative.tech` untuk perangkat itu. Bukti: §7b.

## 6. Rate limit & batasan (ADR 0005 #13)

- Outbound per mailbox: burst 10, **30 mail/jam**; per domain `expomedia.id`: burst 50, **200 mail/jam**. Melebihi → `451 4.7.1 Ratelimit … exceeded`
  (klien email akan mencoba ulang). Kebutuhan blast/newsletter harus lewat layanan khusus (tambahkan `include:` di SPF).
- Ukuran pesan maksimum 10 MB (`SIZE 10240000`).
- IP pengirim `31.97.50.221` dipakai bersama domain lain di platform → reputasi bersama; akun yang bocor/spam memengaruhi domain lain.
- Envelope `MAIL FROM` harus milik akun login (`553 5.7.1 … not owned by user`); header `From:` domain lain **tidak** ditandatangani DKIM.

## 7. Bukti onboarding di server (2026-09-25, uji lokal `swaks` di container → `127.0.0.1:587` STARTTLS)

| Uji | Hasil |
|---|---|
| `setup config dkim domain expomedia.id` | `Successfully created DKIM keys`; `rspamadm configdump dkim_signing` memuat `expomedia.id { selector = "mail" }`; Rspamd reload (`rspamd_hup_handler`) 18:35:14 WIB |
| `setup email list` / `setup alias list` | 5 mailbox `@expomedia.id` (0 / 2.0G); `abuse@expomedia.id postmaster@expomedia.id` |
| postmaster@ → dmarc@ (AUTH) | `250 2.0.0 Ok: queued`; maildir `dmarc/new/…` memuat `DKIM-Signature: … d=expomedia.id; s=mail`; rspamd `DKIM_SIGNED … expomedia.id:s=mail` |
| login `info@`, `MAIL FROM x@bimacreative.tech` | `553 5.7.1 <x@bimacreative.tech>: Sender address rejected: not owned by user info@expomedia.id` |
| login `info@`, envelope `info@`, header `From: x@bimacreative.tech` → admin@ | terkirim, **tanpa** `DKIM-Signature` (rspamd `FORGED_SENDER`, tidak ada `DKIM_SIGNED`) |
| DNS publik (`dig MX/TXT expomedia.id @1.1.1.1`) | **BELUM** — zona kosong, menunggu client |

Sertifikat server = `mail.bimacreative.tech`; uji ke `127.0.0.1` memakai `swaks --tls` tanpa `--tls-verify` (nama host tidak cocok
dengan sertifikat, wajar untuk uji loopback; klien nyata memakai nama `mail.bimacreative.tech` dan verifikasi penuh).

### 7b. Hostname `mail.expomedia.id` (ADR 0011, 2026-09-25)

| Uji | Hasil |
|---|---|
| DNS pre-check 19:4x WIB | `A mail.expomedia.id` = `31.97.50.221` @ns1.mysrsx.com, @ns1.mysrsx.net, @1.1.1.1, @8.8.8.8; AAAA kosong; tanpa CNAME |
| Sertifikat (router `mail-cert-expomedia`, `le-http`) | terbit 19:43:51 WIB, `CN = mail.expomedia.id`, issuer `YE2`, notAfter `Dec 24 11:45:17 2026 GMT` |
| `openssl s_client -servername mail.expomedia.id` 993 / 465 / 587 STARTTLS / 25 STARTTLS (127.0.0.1 & 31.97.50.221) | `subject=CN = mail.expomedia.id`, `-verify_hostname mail.expomedia.id -verify_return_error` → `Verify return code: 0 (ok)` |
| Tanpa SNI / SNI `mail.bimacreative.tech` / SNI tak dikenal | `CN = mail.bimacreative.tech`, verify 0 (tidak regresi) |
| `swaks` 587 STARTTLS `--tls-sni mail.expomedia.id --tls-verify` AUTH `admin@expomedia.id` | CA + host verification passed; `235 2.7.0 Authentication successful`; `250 2.0.0 Ok: queued`; terkirim ke maildir (`status=sent`) |
| `swaks` 465 (TLS implisit) sama | verification passed; `235` |
| IMAP 993 SNI `mail.expomedia.id` `a LOGIN admin@expomedia.id` | rantai terverifikasi (`depth=0 CN=mail.expomedia.id`), `a OK`, `SELECT INBOX` OK |
| Regresi `bimacreative.tech` | `alerts@` → `dmarc@bimacreative.tech` (587, SNI `mail.bimacreative.tech`, verify) → `status=sent` |

## 8. Verifikasi setelah client mengisi DNS (langkah 5 runbook)

```
dig +short A expomedia.id @1.1.1.1                 # 31.97.50.221
dig +short A www.expomedia.id @1.1.1.1             # 31.97.50.221 (atau CNAME edge.bimacreative.tech)
dig +short AAAA expomedia.id @1.1.1.1              # harus KOSONG
dig +short MX expomedia.id @1.1.1.1                # 10 mail.bimacreative.tech.
dig +short TXT expomedia.id @1.1.1.1               # "v=spf1 include:_spf.bimacreative.tech -all"
dig +short TXT mail._domainkey.expomedia.id @1.1.1.1   # cocok dengan .public.dns.txt
dig +short TXT _dmarc.expomedia.id @1.1.1.1        # "v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:dmarc@expomedia.id"
docker exec mailserver grep -i 'expomedia.id' /var/log/mail/rspamd.log | grep -i pubkey | tail   # tidak ada lagi mismatch DKIM
```

Lalu: kirim uji ke penerima eksternal (mis. Gmail / mail-tester) → header `Authentication-Results` SPF/DKIM/DMARC `pass`;
provision router prod web (`provision-web-client.sh expomedia prod --host expomedia.id --www …`, Lead); umumkan mailbox aktif ke client.

## 9. Rollback

- Hostname `mail.expomedia.id` (ADR 0011 §Rollback): keluarkan entri SNI dari `mail/config/postfix-main.cf` + `mail/config/dovecot.cf`
  → `bootstrap.sh` → recreate `mailserver`; hapus dari `mail_tls_export_sni_domains` → role `mail_tls_export`; hapus router
  `mail-cert-expomedia` di `traefik/dynamic/platform/mail-clients.yml` → `docker exec traefik kill -HUP 1`. Staf kembali memakai
  `mail.bimacreative.tech` (tetap berfungsi selama ini).

- Mail: `setup email del <alamat>` per mailbox, `setup alias del abuse@expomedia.id postmaster@expomedia.id`, komentari blok
  `expomedia.id` di `mail/config/rspamd/override.d/dkim_signing.conf`, `sudo mail/scripts/bootstrap.sh` (Rspamd reload otomatis).
  Hapus `secrets/*@expomedia.id.password` dan `staging/web-clients/expomedia/secrets/`. Kunci DKIM di `data/` boleh dibiarkan.
- Web staging: `provision-web-client.sh expomedia staging --remove`.

## 10. Kepemilikan & password awal (keputusan user 2026-09-25)

- Pemilik mailbox `admin@expomedia.id`: **am.ademaryadi@gmail.com** (kontak/pemulihan; alamat Gmail bukan mailbox di server ini).
- Kelima mailbox `@expomedia.id` memakai **password default yang sama** (nilai di `mail/secrets/<alamat>.password`, TIDAK di git),
  diputuskan user setelah diberi tahu risikonya (password mudah ditebak dan sama untuk semua + port mail terbuka ke internet). Penggantian password
  **tidak dipaksa oleh sistem** (DMS tidak punya fitur itu, dan belum ada webmail); user memberi tahu staf secara pribadi untuk mengganti password.
  Ganti password saat staf meminta: `sudo /opt/infra/mail/scripts/mailbox-add.sh --rotate <alamat>` (acak) atau `setup email update`.
- ~~info@ dipakai form kontak~~ — **sejak 2026-09-25 (plan 08) form kontak memakai `noreply@expomedia.id`** (password acak,
  hanya di file secret web). Password info@ bebas diganti staf tanpa memengaruhi website.
- **Sejak 2026-09-25 staf bisa mengganti password sendiri di webmail** (§11) — admin@, info@, sales@. `postmaster@`/`dmarc@`
  (akun sistem) dan `noreply@` (teknis) dikelola ops. Setelah staf mengganti, file `mail/secrets/<alamat>.password` = password
  AWAL (basi); penanda: `mail/data/config/pwhelper/state/changed/<alamat>`. Ops tidak mengetahui password baru.

## 11. Webmail `https://webmail.expomedia.id` (ADR 0012, plan 08 — aktif 2026-09-25)

- DNS: `A webmail` → `31.97.50.221` (diisi user; pre-check 20:31 WIB lulus, tanpa AAAA/CNAME). Sertifikat LE `le-http`.
- Login: alamat lengkap (`sales@expomedia.id`) atau cukup `sales`. Hanya `@expomedia.id`; `noreply@` ditolak.
- Batas: lampiran 5 MB per file, pesan 10 MB; kirim 30 mail/jam per mailbox (sama dengan klien email); satu identitas pengirim
  (alamat tidak bisa diganti); sesi berakhir setelah 30 menit tidak aktif.
- Operasi/reset/kill switch: `docs/03-operations/webmail.md`.

### Panduan staf: mengganti password (siap kirim)

1. Buka **https://webmail.expomedia.id**, masuk dengan alamat email dan password saat ini.
2. Klik **Pengaturan** (ikon roda gigi) → **Kata Sandi**.
3. Isi *Sandi saat ini*, lalu *Sandi baru* dua kali → **Simpan**. Muncul "Berhasil disimpan".
4. Syarat password baru: minimal **10 karakter**, mengandung **huruf dan angka/simbol**, tanpa spasi dan tanpa tanda `:` atau `|`,
   tidak sama dengan password lama/password awal, dan tidak memuat nama mailbox (mis. `sales`). Bila muncul "Tidak dapat
   menyimpan sandi baru.", periksa syarat ini; setelah 5 kali gagal tunggu 15 menit.
5. Perbarui password di aplikasi email lain (HP, Outlook, Thunderbird) — server `mail.expomedia.id`, lihat §5.
6. Lupa password: hubungi admin platform (reset hanya oleh ops, lewat jalur aman).

### Form kontak website (re-provision 2026-09-25)

```
sudo /opt/infra/scripts/provision-web-client.sh expomedia prod --host expomedia.id --www --image web-expomedia:dev-148b002 \
  --contact --smtp-host mail.bimacreative.tech --smtp-port 587 --smtp-user noreply@expomedia.id --smtp-from noreply@expomedia.id
sudo /opt/infra/scripts/provision-web-client.sh expomedia staging --host expomedia.staging.bimacreative.tech \
  --image web-expomedia:dev-148b002 --contact --smtp-host mail.bimacreative.tech --smtp-port 587 \
  --smtp-user noreply@expomedia.id --smtp-from noreply@expomedia.id
```
Bukti: `POST /api/contact` prod → `303 /?status=sent`, staging → `303 /contact?status=sent`; log `sasl_username=noreply@expomedia.id`,
`to=<info@expomedia.id> status=sent`, header `From: noreply@expomedia.id`, `Reply-To` pengunjung, `DKIM-Signature d=expomedia.id`.
