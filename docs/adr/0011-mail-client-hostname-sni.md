# ADR 0011 — Hostname mail per domain client via TLS SNI (`mail.<domain-client>`)

- **Status:** accepted — keputusan user 2026-09-25 (via Lead)
- **Tanggal:** 2026-09-25
- **Penulis:** Infra/DevOps Engineer
- **Terkait:** ADR 0005 (merevisi **#9**; #5 HELO/PTR dan #8 TLS tetap), ADR 0002 (TLS HTTP-01, tanpa wildcard, IPv4-only,
  DNS pre-check), CLAUDE.md §2, §3.5.1, §3.6 Mail; `docs/03-operations/mail.md` §TLS dan §Hostname mail per domain client;
  client pertama `docs/clients/expomedia.md`.

## Context

- ADR 0005 #9 memutuskan satu hostname server `mail.bimacreative.tech` untuk HELO, PTR, sertifikat, **dan** nama server di
  klien email semua domain, dengan alasan `mail.<domain-client>` butuh sertifikat per hostname + SNI di Postfix/Dovecot.
- User meminta staf Expomedia memakai `mail.expomedia.id` (IMAP 993, SMTP 465/587) dengan sertifikat TLS valid. Server tetap
  satu (DMS `mailserver`), HELO/PTR tetap `mail.bimacreative.tech`, **MX `expomedia.id` tetap `10 mail.bimacreative.tech`**.
- Fakta yang diverifikasi di sesi ini (2026-09-25):
  - Postfix di container 3.10.13 (`postconf mail_version`). `postconf(5)` `tls_server_sni_maps` (Postfix ≥ 3.4) berlaku
    untuk smtpd dan tlsproxy. Nilai tabel = daftar file PEM (kunci diikuti rantai, format `smtpd_tls_chain_files`). Untuk
    tabel `inline`/`texthash`/`regexp` "the table value is again a list files, that are loaded into memory when the table
    is opened". Untuk tabel berindeks (`hash`/`cdb`) isi file ditanam saat `postmap -F`. Image tidak punya `lmdb`
    (`postconf -m`: btree, hash, inline, texthash, …).
  - Dovecot 2.4.1 (`dovecot --version`). Docs 2.4.1 `core/config/ssl.html` §With Client TLS SNI Support: filter
    `local_name <host> { ssl_server_cert_file = …; ssl_server_key_file = … }`. `doveconf -n` menormalkan menjadi
    `local_name … { ssl_server { cert_file / key_file } }` (diuji).
  - DMS v16.0.1 `setup.d/dovecot.sh` (source di container dan tag v16.0.1 GitHub): `/tmp/docker-mailserver/dovecot.cf`
    disalin ke `/etc/dovecot/local.conf` saat start; `dovecot.conf` memuat `!include_try local.conf`. Docs v16.0.1
    `config/advanced/override-defaults/dovecot.md` sama. `postfix-main.cf` di-append ke `main.cf` saat start (`postconf -n`).
  - Change detection DMS (`helpers/change-detection.sh`) hanya memantau `SSL_CERT_PATH`/`SSL_KEY_PATH`/`SSL_ALT_*` untuk
    `SSL_TYPE=manual` — tidak ada mekanisme resmi untuk file SNI tambahan → reload harus dipicu dari host.
  - Unit `mail-tls-export.service` (QA-T17B-02/B18) di-sandbox (`PrivateNetwork`, `CapabilityBoundingSet=CAP_DAC_READ_SEARCH`,
    `ProtectSystem=strict`) dan tidak punya akses Docker — sengaja.

## Decision

1. **Hostname mail per domain client boleh ditambahkan (opsional, per client)** sebagai **alias nama untuk klien email**:
   `mail.<domain-client>` A → `31.97.50.221` (tanpa AAAA/CNAME, DNS pre-check ADR 0002 wajib). HELO, PTR, `myhostname`,
   banner SMTP tetap `mail.bimacreative.tech`; **MX domain client tetap `10 mail.bimacreative.tech`** (MX tidak diubah).
   `mail.bimacreative.tech` tetap berfungsi untuk semua domain.
2. **Sertifikat terpisah per hostname** — router Traefik "dummy" per hostname di `traefik/dynamic/platform/mail-clients.yml`
   (pola `platform/mail.yml`: websecure, `crowdsec`+`security-headers`+`ratelimit-default`+redirect → cp, service
   `deny-sink`, `certResolver: le-http`). Satu router = satu sertifikat = satu hostname. File di `platform/` (bukan
   `clients/`) karena milik stack mail dan agar tidak tersapu tooling route client (`clients/<slug>-<env>.yml`).
3. **Ekspor dengan allowlist eksplisit** — `mail/scripts/tls-export.py --sni-domain <fqdn>` (berulang; daftar dari variabel
   role `mail_tls_export_sni_domains`) menulis HANYA hostname di allowlist ke `mail/data/tls/<fqdn>/`
   (`privkey.pem`, `chain.pem` = kunci+fullchain, `fullchain.pem`; semua 0600, dir 0700 root; tmp + rename; idempoten; tidak
   mencetak kunci). Path hostname utama (`/etc/dms-tls/{fullchain,privkey}.pem`) **tidak** berubah. Kegagalan satu hostname
   tidak menghentikan hostname lain (exit 1 → alert OnFailure).
4. **SNI Postfix** — `tls_server_sni_maps = inline:{ { mail.bimacreative.tech = /etc/dms/tls/key, /etc/dms/tls/cert },
   { mail.<client> = /etc/dms-tls/mail.<client>/chain.pem } }` di `mail/config/postfix-main.cf`. Tabel `inline` (bukan
   `hash` + `postmap -F`): file dibaca saat tabel dibuka → perpanjangan cukup `postfix reload`, tanpa langkah postmap dan
   tanpa `user-patches.sh`; entri hostname utama mengikuti sertifikat default DMS (saran postconf(5)).
5. **SNI Dovecot** — blok `local_name` di `mail/config/dovecot.cf` (→ `local.conf`), disinkron `scripts/bootstrap.sh`.
6. **Reload saat renew** — unit host `mail-tls-reload.path` (`PathChanged=` `data/tls/<fqdn>/fullchain.pem`, ditulis
   terakhir) → `mail-tls-reload.service` (`docker exec mailserver postfix reload` + `dovecot reload`; graceful). Terpisah dari
   unit ekspor agar sandbox ekspor tetap tanpa akses Docker. `tls-export.py` tidak `chmod` bila mode sudah benar (chmod =
   IN_ATTRIB memicu PathChanged → reload sia-sia; teramati saat implementasi).

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Satu sertifikat SAN gabungan (`mail.bimacreative.tech` + semua `mail.<client>`) | Kegagalan validasi/renew SATU domain client (DNS client berubah, record dihapus) menggagalkan penerbitan/perpanjangan sertifikat platform → semua domain kehilangan TLS valid; juga membocorkan daftar client di SAN |
| Alias `mail.<client>` tanpa sertifikat sendiri (CNAME/A saja) | Klien email menolak/memperingatkan sertifikat tidak cocok → staf dilatih mengabaikan peringatan TLS (anti-pattern keamanan) |
| Wildcard `*.<client>` | Dilarang ADR 0002 / CLAUDE.md §3.5.1 (DNS-01 tidak mungkin; tanpa wildcard) |
| `hash:` + `postmap -F` | Butuh map dibangun ulang di dalam container setiap start (`user-patches.sh`) dan setiap renew; lebih banyak bagian bergerak daripada `inline` yang docs-nya menyatakan file dibaca saat tabel dibuka |
| Reload dipicu dari `mail-tls-export.service` | Memberi unit ekspor (yang membaca `acme.json` semua hostname) akses Docker = root penuh; memperlebar dampak bug |
| `SSL_ALT_CERT_PATH` DMS | Untuk sertifikat alternatif algoritma lain (RSA+ECDSA) pada hostname yang sama, bukan SNI; dua kunci ECDSA bentrok |
| Instance DMS per client | RAM (ADR 0004/0005) |

## Consequences

- Staf client memakai `mail.<domain-client>` di klien email; `mail.bimacreative.tech` tetap bisa dipakai (tanpa migrasi paksa).
- Setiap hostname mail client = +1 sertifikat LE (renew otomatis Traefik), +1 entri allowlist, +1 entri SNI Postfix/Dovecot.
  Menambah/menghapus butuh **recreate** `mailserver` (±9 s IMAP / ±22 s SMTP tanpa respons, terukur 2026-09-25) sampai
  control plane mengotomatisasi.
- Banner/EHLO SMTP tetap `mail.bimacreative.tech` (bukan masalah: klien memverifikasi sertifikat, bukan banner).
- Pengirim MX eksternal (port 25) yang mengirim SNI `mail.bimacreative.tech` tetap mendapat sertifikat platform; SNI
  hostname client di port 25 juga dijawab (tidak berbahaya).
- **Urutan wajib (kehati-hatian):** file sertifikat SNI harus ada sebelum entri SNI Postfix/Dovecot aktif, dan saat menghapus:
  keluarkan entri SNI + recreate **dulu**, baru hapus file. Postfix membaca file saat tabel dibuka (postconf(5)); `doveconf -n`
  tidak memeriksa keberadaan file (diuji). Perilaku runtime Postfix/Dovecot bila file hilang **BELUM diverifikasi** — anggap
  dapat menggagalkan TLS di proses tersebut.
- Klien email sangat tua tanpa SNI mendapat sertifikat `mail.bimacreative.tech` (host mismatch) → gunakan `mail.bimacreative.tech`.

## Security implications

- Kunci privat hostname client hanya ada di `acme.json` (Traefik) dan `mail/data/tls/<fqdn>/` (root 0700/0600, mount ro) —
  allowlist eksplisit, validasi nama FQDN (tanpa `/`, `..`, wildcard; bukan symlink), tidak pernah dicetak.
- `mail-tls-reload.service` berjalan root dengan akses Docker, argumen tetap (tanpa shell/input eksternal), hanya dipicu
  perubahan file di dir root 0700.
- Tidak ada perubahan TLS_LEVEL, cipher, AUTH, relay, IPv4-only, SPF/DKIM/DMARC/MX, capability container.
- Router Traefik hostname client memakai middleware sama dengan `mail-cert` (CrowdSec/AppSec, rate limit, redirect) — tidak
  ada backend baru yang terekspos.

## Rollback

1. Hapus hostname dari `mail/config/postfix-main.cf` (`tls_server_sni_maps`) dan `mail/config/dovecot.cf` (blok `local_name`)
   → `sudo mail/scripts/bootstrap.sh` → `docker compose up -d --force-recreate mailserver` (atau live: `postconf -X
   tls_server_sni_maps` / `postconf -e` tanpa entri itu + `postfix reload`; hapus `/etc/dovecot/local.conf` + `dovecot reload`).
2. `mail_tls_export_sni_domains: []` (atau tanpa hostname itu) → `ansible-playbook site.yml --tags mail_tls_export` (unit
   `mail-tls-reload.*` dihapus bila daftar kosong; ekspor kembali single-host). File `mail/data/tls/<fqdn>/` dihapus manual
   (`shred -u` — konfirmasi Lead, §0.5); `tls-export.py` melaporkan `NOTE: subdirektori di luar allowlist`.
3. Hapus router di `traefik/dynamic/platform/mail-clients.yml` → `docker exec traefik kill -HUP 1` (H7).
4. Staf kembali memakai `mail.bimacreative.tech`. Record DNS `mail.<client>` boleh dihapus client.
Uji kering 2026-09-25: `ansible-playbook … --check -e '{"mail_tls_export_sni_domains": []}'` (hentikan+hapus unit reload),
`postconf -c <salinan> -X tls_server_sni_maps` (kembali ke `smtpd_tls_chain_files` default), `doveconf` tanpa `local.conf`
(rc 0, tanpa `local_name`).
