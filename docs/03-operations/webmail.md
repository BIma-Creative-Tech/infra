# Webmail (Roundcube) — operasional

ADR 0012, plan 08. Instance pertama: **`https://webmail.expomedia.id`** (client Expomedia, hanya login `@expomedia.id`).

## Struktur

| Path | Isi |
|---|---|
| `webmail/docker-compose.yml` | container `webmail` — `roundcube/roundcubemail:1.7.4-apache-nonroot@sha256:38e4b529…` (uid 33, :8000) |
| `webmail/config/webmail.inc.php` | override Roundcube (IMAP/SMTP, filter login, sesi, plugin password → helper). Tanpa secret. |
| `webmail/config/apache-webmail.conf` | prefork 12 worker, `ServerTokens Prod` (→ `/etc/apache2/conf-enabled/zz-webmail.conf`) |
| `webmail/scripts/bootstrap.sh` | `data/db` (700 uid 33), `secrets/des_key` (32 char, 0400 uid 33), cek network |
| `webmail/data/db/sqlite.db` | user, preferensi, kontak, sesi (tidak di git; ikut backup restic `files`) |
| `webmail/secrets/{des_key,pwhelper_token}` | tidak di git |
| `traefik/dynamic/clients/webmail-expomedia.yml` | router `webmail-expomedia` + `webmail-expomedia-login`, middleware `webmail-security-headers` |
| `mail/config/user-patches.sh` | memasang program supervisord `pwhelper` di mailserver |
| `mail/config/pwhelper/{pwhelper.py,allowlist.txt}` | helper ganti password + allowlist alamat (→ `mail/data/config/pwhelper/`) |
| `mail/scripts/pwhelper-secrets.sh` | token Bearer + deny list PBKDF2 password default |
| `/var/log/mailserver/dms/pwhelper.log` | audit JSON helper (tanpa password) |

Network: `webmail-edge` 10.100.15.0/24 `--internal` (traefik + webmail), `webmail-mail` 10.100.16.0/24 `--internal`
(mailserver `.2` + webmail). Webmail **tanpa egress internet**.

## Start / stop / update config

```
sudo /opt/infra/webmail/scripts/bootstrap.sh
sudo docker compose -f /opt/infra/webmail/docker-compose.yml up -d
# setelah mengubah webmail.inc.php / apache-webmail.conf (bind mount file tunggal → WAJIB recreate):
sudo docker compose -f /opt/infra/webmail/docker-compose.yml up -d --force-recreate
```
Recreate webmail = sesi yang sedang login tetap valid (sesi di SQLite; des_key tetap). Start ±15 s (entrypoint menyalin
kode ke tmpfs + `initdb.sh --update`).

## Upgrade Roundcube

1. Baca release notes GitHub `roundcube/roundcubemail` (rilis keamanan → segera).
2. Cek tag nonroot: `curl -s 'https://hub.docker.com/v2/repositories/roundcube/roundcubemail/tags?name=<ver>'`, lalu
   `docker buildx imagetools inspect roundcube/roundcubemail:<ver>-apache-nonroot` → digest index.
3. Bandingkan `/docker-entrypoint.sh` versi baru dengan yang lama (nama env, path) dan `plugins/password/drivers/httpapi.php`.
4. Backup `webmail/data/db` (`cp -a` saat container stop) → ganti `image:` → `up -d` → log berisi
   `Checking for database schema updates...` tanpa error → uji login + kirim + ganti password (akun uji).
5. Rollback: tag/digest lama + restore salinan `data/db` (skema bisa sudah dinaikkan).

## Ganti password self-service (staf)

Pengaturan → Kata Sandi. Aturan (helper): 10–64 karakter; huruf **dan** angka/simbol; tanpa spasi, `:`, `|`; tidak sama
dengan password lama atau password default awal; tidak memuat nama mailbox (mis. `sales`). Pesan gagal umum:
"Tidak dapat menyimpan sandi baru." Setelah sukses sesi tetap aktif; klien email lain (HP/Outlook) harus diisi password baru.

Alamat yang diizinkan: `mail/config/pwhelper/allowlist.txt` (saat ini admin@, info@, sales@expomedia.id). Menambah alamat:
edit file → `sudo mail/scripts/bootstrap.sh` (dibaca helper tiap request) → `sudo mail/scripts/pwhelper-secrets.sh` (deny list).
`noreply@` tidak bisa login webmail; `postmaster@`/`dmarc@` bisa login, tidak bisa ganti password sendiri.

Siapa yang pernah mengganti: `sudo ls -l /opt/infra/mail/data/config/pwhelper/state/changed/` (file = alamat, isi = waktu).
Untuk alamat itu `mail/secrets/<alamat>.password` = password AWAL (basi) — jangan diserahkan ke user.

## Reset password oleh ops (user lupa)

```
sudo /opt/infra/mail/scripts/mailbox-add.sh --rotate <alamat>     # acak 32 char → mail/secrets/<alamat>.password
sudo rm -f /opt/infra/mail/data/config/pwhelper/state/changed/<alamat>
sudo /opt/infra/mail/scripts/pwhelper-secrets.sh                  # deny list ikut password awal baru
```
Serahkan lewat jalur aman; minta user langsung mengganti via webmail. Untuk mengembalikan ke password default user:
`printf '%s\n%s\n' "$p" "$p" | docker exec -i mailserver setup email update <alamat>` dengan `p` dibaca dari file
(jangan diketik/echo di terminal bersama).

## Kill switch helper

| Tingkat | Perintah | Efek |
|---|---|---|
| Seketika | `sudo touch /opt/infra/mail/data/config/pwhelper/disabled` | helper 503 (UI: "Tidak dapat menyimpan sandi baru."); hapus file untuk aktif lagi |
| Proses | `sudo docker exec mailserver supervisorctl stop pwhelper` | helper mati sampai `start`/recreate (UI: "… Koneksi error.") |
| UI | `password_disabled` = teks alasan di `webmail.inc.php` + recreate webmail | tab tetap ada, simpan dinonaktifkan |
| Token | `sudo mail/scripts/pwhelper-secrets.sh --rotate-token` lalu recreate webmail | token lama tidak berlaku |

Kode helper berubah: `sudo mail/scripts/bootstrap.sh && sudo docker exec mailserver supervisorctl restart pwhelper`
(rate limit in-memory ikut reset). Konfigurasi supervisor (`user-patches.sh`) berubah: recreate mailserver (±25 s downtime,
cek `postqueue -p` kosong dulu). Status: `docker exec mailserver supervisorctl status pwhelper`; log
`/var/log/mailserver/dms/pwhelper.log`. Helper mati TIDAK membuat mailserver unhealthy.

## Brute force & CrowdSec

- Traefik: POST `/?_task=login` (atau POST tanpa `_task`) → `ratelimit-login` 10/menit/IP; lainnya `ratelimit-default`.
- CrowdSec: login gagal = HTTP 401 → `LePresidente/http-generic-401-bf` (POST+401, 6 dalam ±10 s) ban IP publik.
  Hapus ban salah: `docker exec crowdsec cscli decisions delete --ip <ip>`.
- Roundcube: `login_rate_limit` 3 gagal/menit per user (user yang sudah pernah login).
- Dovecot/Postfix melihat semua login webmail dari `10.100.16.3` (privat, whitelist CrowdSec) — ban mail per IP tidak berlaku
  untuk webmail; lihat IP asli di `docker logs webmail | grep userlogins`.
- AppSec: tidak ada pengecualian untuk webmail (uji 2026-09-25: login, compose, upload 270 KB, kirim → tanpa 403). Bila
  muncul 403 AppSec (mis. isi mail tertentu memicu CRS), buat pengecualian per host + rule, catat di `crowdsec.md`.

## Monitoring (Uptime Kuma — BELUM ditambahkan, perlu Lead)

- HTTP(s) `https://webmail.expomedia.id/` expect 200 + keyword `Webmail Expomedia`, interval 60 s, notifikasi sertifikat.
- (opsional) Docker/TCP tidak perlu — helper tidak terjangkau dari Kuma; cukup cek manual `supervisorctl status pwhelper`.

## Uji yang dijalankan (2026-09-25)

Ringkas (detail di laporan sesi / plan 08 §5): TLS verify 0; login positif/negatif; kirim + lampiran → DKIM d=expomedia.id;
ganti password (salah lama / pendek / lemah / local-part / default / sukses / kembali ke default); manipulasi akun lain;
token/allowlist/injeksi → 4xx; rate limit helper 429; brute force 10×401 + 5×429; iframe pratinjau tampil; RAM idle 84 MiB.

## Rollback

ADR 0012 §Rollback.

## Akun yang boleh login (update 2026-09-25, keputusan user)
`login_username_filter` menolak `noreply@`, `postmaster@`, `dmarc@` (akun teknis/sistem — tidak dibutuhkan di webmail). Diverifikasi: postmaster@/dmarc@ → 401, sales@ → 302 ke inbox.
