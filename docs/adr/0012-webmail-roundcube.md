# ADR 0012 — Webmail Roundcube per domain client + ganti password self-service (`webmail.expomedia.id`)

- **Status:** accepted — keputusan user 2026-09-25 (via Lead): webmail di domain client + ganti password self-service
- **Tanggal:** 2026-09-25
- **Penulis:** Infra/DevOps Engineer (merangkap Analyst)
- **Terkait:** ADR 0005 (mail IPv4, rate limit, SPOOF_PROTECTION), ADR 0009 (pola jembatan ke aksi root — dibandingkan),
  ADR 0010 (segmentasi network: backend HTTP di edge khusus), ADR 0011 (SNI `mail.expomedia.id`), ADR 0002 (HTTP-01, DNS
  pre-check, tanpa AAAA); plan `docs/plans/08-webmail-expomedia.md`; ops `docs/03-operations/webmail.md`; client
  `docs/clients/expomedia.md`.

## Context

Fakta (diverifikasi 2026-09-25):

1. Staf Expomedia (5 mailbox `@expomedia.id`) belum punya cara membaca mail tanpa klien IMAP dan **tidak bisa mengganti
   password sendiri** — semua mailbox memakai password default yang sama (keputusan user, `docs/clients/expomedia.md` §10).
   DMS 16.0.1 (`ACCOUNT_PROVISIONER=FILE`) tidak punya fitur ganti password oleh user.
2. `info@expomedia.id` juga kredensial SMTP form kontak website (prod + staging) → bila staf mengganti password info@, form
   kontak rusak.
3. Roundcube 1.7.4 = rilis keamanan 2026-09-06 (GitHub release `1.7.4`, 12 perbaikan keamanan). Lisensi repo
   `roundcube/roundcubemail`: **GPL-3.0** (GitHub API), proyek sejak 2012, commit terakhir 2026-09-07, ±7.2k bintang.
   Image resmi `roundcube/roundcubemail` (repo `roundcubemail-docker`, push terakhir 2026-09-22) punya tag
   `1.7.4-apache-nonroot` (Docker Hub, 2026-09-21): `USER 33:33`, Apache `Listen 8000`. Digest index
   `sha256:38e4b529…f27cf4` (`docker buildx imagetools inspect`).
4. Entrypoint image (`/docker-entrypoint.sh`, dibaca): menyalin kode ke docroot `/var/www/html` saat start, menulis
   `config/config.docker.inc.php` dari env `ROUNDCUBEMAIL_*`, membaca `/run/secrets/roundcube_des_key`, lalu meng-include
   `/var/roundcube/config/*.php` **terakhir**; SQLite default di `/var/roundcube/db`.
5. Plugin `password` 1.7.4 punya driver `httpapi` (POST form `user/curpass/newpass`, opsi `password_http_client` = opsi
   Guzzle → header Bearer), `poppassd`, `dovecot_passwdfile` (menulis file password langsung), `sql`, dll. Plugin
   memverifikasi password lama hanya terhadap password di sesi (bukan server).
6. DMS `setup email update <alamat>` membaca password dari STDIN bila argumen ke-2 kosong (`_password_request_if_missing`,
   `read -r -s`) lalu `doveadm pw -s SHA512-CRYPT … -p` di dalam container. `user-patches.sh` di
   `/tmp/docker-mailserver/` dijalankan DMS saat setup container baru (`setup-stack.sh _setup_run_user_patches`).
   supervisord (PID 1) meng-include `/etc/supervisor/conf.d/*.conf`; `dms-healthcheck` hanya memeriksa layanan DMS.
7. Dovecot 143 di loopback menerima LOGIN cleartext (diuji: `AUTH=PLAIN` di CAPABILITY, `AUTHENTICATIONFAILED` untuk user
   palsu). CrowdSec memakai `crowdsecurity/whitelists` (10.0.0.0/8 dst.) → IP container tidak pernah di-ban; skenario
   `LePresidente/http-generic-401-bf` (POST + 401, kapasitas 5 / 10 s) aktif pada access log Traefik. Roundcube membalas
   **HTTP 401** untuk login gagal (diuji).

## Decision

1. **Roundcube 1.7.4 `apache-nonroot`** (tag + digest) sebagai stack `/opt/infra/webmail/`, container `webmail`, dijalankan apa
   adanya (GPL-3 diterima untuk tool yang tidak dimodifikasi/didistribusikan — CLAUDE.md §0.10). DB **SQLite** di
   `webmail/data/db` (tanpa kredensial/network Postgres baru; beban belasan user; ikut backup restic `files`).
2. **Hostname `webmail.<domain-client>`** (pertama: `webmail.expomedia.id`), router file Traefik `le-http` setelah DNS
   pre-check (ADR 0002). Login dibatasi **satu domain** per instance lewat mekanisme resmi Roundcube:
   `login_username_filter` (regex, dievaluasi sebelum domain ditambahkan) + `username_domain`/`username_domain_forced`.
3. **Network (ADR 0010):** `webmail-edge` (10.100.15.0/24, `--internal`, traefik + webmail, dibuat
   `traefik/scripts/bootstrap.sh`, traefik di-`network connect` tanpa recreate) dan `webmail-mail` (10.100.16.0/24,
   `--internal`, mailserver `10.100.16.2` + webmail, dimiliki `mail/docker-compose.yml`). Webmail **tanpa egress internet**.
   IMAP/SMTP ke `ssl://mail.expomedia.id:993` / `tls://mail.expomedia.id:587` dengan `extra_hosts
   mail.expomedia.id:10.100.16.2` → sertifikat SNI `mail.expomedia.id` diverifikasi penuh (CA sistem + nama), bukan hairpin
   ke IP publik.
4. **Ganti password = helper sempit `pwhelper` di DALAM container `mailserver`** (Python stdlib, supervisord, dipasang
   `mail/config/user-patches.sh`), listen HANYA `10.100.16.2:8080`, dipanggil driver `httpapi` Roundcube dengan token Bearer.
   Helper: kill switch file → validasi method/Content-Type/panjang → token (`hmac.compare_digest`) → rate limit per IP
   (30/10 mnt) & per alamat (5 gagal/15 mnt, 3 sukses/jam) → regex alamat ketat (`fullmatch`) **dan** allowlist file →
   kebijakan password (10–64 char ASCII tercetak tanpa spasi/`:`/`|`, huruf + non-huruf, ≠ lama, tidak memuat local-part,
   tidak ada di deny list PBKDF2 password default) → **verifikasi password lama independen** (IMAP LOGIN loopback) →
   `setup email update` via STDIN → tunggu Dovecot menerima password baru → marker `state/changed/<alamat>` → audit JSON
   tanpa password (`/var/log/mailserver/dms/pwhelper.log`).
5. **Allowlist ganti password** = `admin@`, `info@`, `sales@expomedia.id`. `noreply@` **tidak bisa login webmail** (filter)
   dan tidak di allowlist. `postmaster@` & `dmarc@` = akun sistem: **boleh login webmail** (membaca abuse/DMARC tanpa klien
   IMAP) tetapi **tidak boleh ganti password sendiri** (dikelola ops; RFC 5321/abuse harus tetap bisa diakses platform) —
   tab Password disembunyikan (`password_login_exceptions`) dan helper menolak.
6. **File secret host `mail/secrets/<alamat>.password` = password AWAL/default** dan TIDAK diperbarui oleh helper (ops tidak
   perlu/tidak boleh tahu password pilihan user). Marker `mail/data/config/pwhelper/state/changed/<alamat>` menandai
   "password saat ini dipilih user; file secret basi". Reset oleh ops tetap `mailbox-add.sh --rotate` / `setup email update`.
7. **Form kontak website memakai mailbox teknis `noreply@expomedia.id`** (password acak 32 char, kuota 200M) — tidak lagi
   bergantung pada password info@. Penerima tetap info@ (brand config).
8. Edge: `crowdsec` (AppSec) → `webmail-security-headers` (salinan `security-headers` dengan `X-Frame-Options: SAMEORIGIN` —
   pratinjau pesan Roundcube adalah iframe same-origin — + CSP minimal `frame-ancestors 'self'; object-src 'none';
   base-uri 'self'; form-action 'self'`) → `ratelimit-default`; router POST login (query `_task=login` atau tanpa `_task`)
   → `ratelimit-login` (10/menit/IP). Tanpa pengecualian AppSec (tidak ada 403 pada login/kirim/lampiran saat uji).

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Mount `postfix-accounts.cf` rw ke Roundcube (driver `dovecot_passwdfile`) | Roundcube (PHP, permukaan serangan web besar) memegang tulis ke database akun SEMUA domain; kompromi webmail = ambil alih semua mailbox. Dilarang Lead. |
| Docker socket / `docker exec` dari Roundcube atau sidecar | Setara root host (plan 01 §4 E, ADR 0009). Dilarang. |
| Dispatcher host pola ADR 0009 (spool + systemd path + `docker exec`) | Password baru (dan lama) harus ditulis ke file spool di disk host; butuh jalur file baru dari container web ke host; latensi path unit; tetap perlu verifikasi password lama. Lebih banyak komponen & password tersimpan sementara di disk. |
| Sidecar container sendiri yang menulis `postfix-accounts.cf` | Menduplikasi logika DMS (hash, locking, format) dan tetap butuh mount rw database akun. |
| Driver `poppassd` | Protokol teks tanpa autentikasi klien, password lama/baru dalam baris perintah protokol; butuh daemon tambahan dengan kontrak sama → tidak lebih kecil dari HTTP stdlib + token. |
| Hairpin ke `31.97.50.221:993/587` | Tetap tiba sebagai IP privat (MASQUERADE) → tidak ada manfaat ban per IP; webmail butuh egress (network non-internal). Network internal lebih sempit. |
| Postgres shared untuk Roundcube | Perlu `db-webmail` + role + pg_hba (ADR 0010) untuk beban sangat kecil; SQLite cukup. Pindah bila > ±50 user aktif/instance lain. |
| Varian `1.7.4-apache` (root) | Tersedia `-nonroot` resmi → tidak perlu cap `SETUID/SETGID/NET_BIND_SERVICE`. |
| SnappyMail/RainLoop | Roundcube = paling luas dipakai, rilis keamanan aktif, plugin password resmi; keputusan user. |

## Consequences

- (+) Staf punya webmail berbahasa Indonesia; bisa mengganti password sendiri; ops tidak melihat password baru.
- (+) Tidak ada akses Docker/akun rw di webmail; kompromi Roundcube terbatas pada: sesi user yang login, dan panggilan helper
  yang **tetap memerlukan password lama yang benar** per alamat allowlist (dengan rate limit).
- (+) Form kontak website independen dari password staf.
- (−) Semua koneksi IMAP/SMTP webmail tiba di Dovecot/Postfix sebagai `10.100.16.3` (privat, di-whitelist CrowdSec) →
  brute force via webmail **tidak** di-ban oleh skenario mail; ditangani di edge (ratelimit-login, CrowdSec 401-bf pada IP
  asli di access log Traefik) + `login_rate_limit` Roundcube. Rate limit Rspamd per user tetap berlaku (30/jam/mailbox).
- (−) Helper berjalan root di container mailserver (dibutuhkan `setup`). Mitigasi: kode stdlib < 350 baris, hanya di network
  internal 2 anggota, token, single-thread, timeout socket 10 s, body ≤ 1 KiB, kill switch file.
- (−) Password dalam jaringan internal `webmail-mail` lewat HTTP polos (bridge 2 anggota, tidak keluar host) dan sesaat di
  argv `doveadm pw` di dalam container (perilaku DMS `setup`, sama dengan `mailbox-add.sh`).
- (−) `user-patches.sh` hanya dijalankan saat container baru → perubahan helper = `supervisorctl restart pwhelper` (kode) atau
  recreate mailserver (konfigurasi supervisor). Recreate terukur ±25 s downtime mail.
- (−) Lampiran maksimal 5 MB/file (php `upload_max_filesize` bawaan image; rootfs read-only); pesan ≤ 10 MB (DMS).
- Kapasitas: RAM idle webmail 84 MiB (limit 256m), tmpfs docroot 33 MiB; disk image ±1.0 GB (tidak dibagi dengan image lain).

## Security implications (ringkas — threat model lengkap di plan 08 §4)

- Aset: password mailbox, database akun DMS, sesi webmail. Entry point: HTTPS publik webmail, helper `10.100.16.2:8080`.
- Spoofing identitas → helper memverifikasi password lama ke Dovecot sendiri; token Bearer; allowlist.
- Tampering akun lain → alamat dari sesi Roundcube (bukan input form); helper menolak alamat lain tanpa password lama
  alamat itu (diuji: `user=admin@` + password sales@ → 401).
- Injeksi ke `postfix-accounts.cf`/`setup` → regex `fullmatch` alamat, charset password tanpa `:`/`|`/spasi/newline, argv
  tetap, password via STDIN.
- Repudiation → audit JSON helper + `log_logins`/`password_log` Roundcube (IP asli via `proxy_whitelist`).
- DoS/brute force → rate limit berlapis (Traefik, CrowdSec, Roundcube, helper).
- Elevation → webmail non-root, rootfs ro, cap_drop ALL, no-new-privileges, tanpa egress; helper tidak terjangkau
  container lain (diuji dari `web-expomedia-prod`: timeout).

## Rollback

1. Matikan ganti password saja: `touch /opt/infra/mail/data/config/pwhelper/disabled` (helper 503 seketika) dan/atau
   `password_disabled` di `webmail/config/webmail.inc.php` + recreate webmail.
2. Matikan webmail: hapus `traefik/dynamic/clients/webmail-expomedia.yml` → `docker exec traefik kill -HUP 1`;
   `docker compose -f /opt/infra/webmail/docker-compose.yml down`.
3. Lepas helper & network dari mail: kembalikan `mail/docker-compose.yml`, hapus `data/config/user-patches.sh` dan
   `data/config/pwhelper/`, recreate mailserver (±25 s). `docker network disconnect webmail-edge traefik`.
4. Form kontak kembali ke info@ (tidak dianjurkan): taruh password info@ di kedua file secret web, provision ulang dengan
   `--smtp-user info@expomedia.id --smtp-from info@expomedia.id`.
