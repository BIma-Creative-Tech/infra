# Plan 08 — Webmail Roundcube `webmail.expomedia.id` + ganti password self-service + mailbox teknis `noreply@`

- Status: **DONE 2026-09-25** (implementasi & verifikasi Infra/DevOps; lihat §7). Keputusan user 2026-09-25 (via Lead).
- ADR: `docs/adr/0012-webmail-roundcube.md`. Ops: `docs/03-operations/webmail.md`. Client: `docs/clients/expomedia.md`.

## 1. Scope

IN: stack `/opt/infra/webmail/` (Roundcube 1.7.4 nonroot, SQLite); network `webmail-edge` (traefik) & `webmail-mail`
(mail); helper `pwhelper` di mailserver (`mail/config/user-patches.sh`, `mail/config/pwhelper/`,
`mail/scripts/pwhelper-secrets.sh`, sinkron `mail/scripts/bootstrap.sh`); router `traefik/dynamic/clients/webmail-expomedia.yml`;
mailbox `noreply@expomedia.id` (200M) + re-provision form kontak website prod & staging; docs/CHANGELOG.
OUT: MX/SPF/DKIM/DMARC/TLS_LEVEL/SNI mail; Keycloak/Odoo/control plane; `/opt/src/**`; Uptime Kuma (hanya dicatat);
branding logo Roundcube (skin elastic default); webmail untuk domain lain.

## 2. Arsitektur

```
Internet ─443─▶ Traefik ──(webmail-edge 10.100.15.0/24 --internal)──▶ webmail:8000 (Roundcube, uid 33, ro rootfs)
                 │ crowdsec+AppSec → webmail-security-headers → ratelimit-default / ratelimit-login (POST login)
                                                                         │
                                  (webmail-mail 10.100.16.0/24 --internal)│ extra_hosts mail.expomedia.id → 10.100.16.2
                                                                         ▼
                              mailserver 10.100.16.2: IMAPS 993 / submission 587 (SNI mail.expomedia.id, verifikasi penuh)
                                                      pwhelper :8080 (HTTP + Bearer) → IMAP LOGIN 127.0.0.1:143 → setup email update
```
Webmail tidak punya egress internet. Kapasitas: webmail idle 84 MiB (limit 256m, 0.5 CPU, pids 64); helper ±15 MiB di dalam
limit mailserver (1 GiB; terpakai 268 MiB); disk image 1.0 GB, SQLite < 1 MB awal.

## 3. Dependency / urutan

`traefik/scripts/bootstrap.sh` (webmail-edge) + `network connect` → `mail` compose (webmail-mail) + `bootstrap.sh` +
`pwhelper-secrets.sh` → recreate mailserver (user-patches) → `webmail/scripts/bootstrap.sh` → `docker compose up -d` webmail →
DNS pre-check → router Traefik + HUP → uji. `noreply@` + re-provision website independen (paralel).

## 4. Threat model ganti password (STRIDE ringkas)

| Ancaman | Contoh | Mitigasi (diuji) |
|---|---|---|
| S — menyamar user lain | POST ubah password dengan `user=admin@` | Driver ambil user dari sesi; field tambahan diabaikan Roundcube (uji: `_user/user=admin@` → hanya sales@ berubah). Helper memverifikasi password lama alamat itu via IMAP (uji langsung: 401). |
| S — pemanggil selain webmail | container lain / internet ke `:8080` | Bind hanya `10.100.16.2` di network internal 2 anggota (uji dari `web-expomedia-prod`: timeout); token Bearer (uji tanpa/salah token: 403). |
| T — injeksi ke database akun | alamat `a|b`, newline, `:` di password | Regex `fullmatch` + allowlist; charset password tanpa `:`/`|`/spasi/kontrol (uji: 403/422). `setup` argv tetap, password via STDIN. |
| T — akun sistem/teknis | ganti password `noreply@`/`postmaster@` | Tidak di allowlist (403); tab Password disembunyikan; `noreply@` tidak bisa login. |
| R — penyangkalan | "bukan saya yang ganti" | Audit helper (ts, ip container, user, hasil, alasan) + `password_log`/`log_logins` Roundcube (IP asli). |
| I — bocor password | log/respons/argv host | Tidak ada password di log/respons; host tidak menyimpan password baru; deny list = hash PBKDF2 bersalt. |
| D — brute force password lama | tebak lewat form ganti password | Roundcube cek sesi dulu; helper 5 gagal/15 mnt per alamat → 429 (uji), 30 req/10 mnt per IP. |
| D — brute force login | 15 POST login | `ratelimit-login` 10/mnt → 429 (uji: 10×401 lalu 5×429); CrowdSec `http-generic-401-bf` untuk IP publik (uji `cscli explain` 6 event → bucket skenario). |
| E — RCE Roundcube → akun | penyerang eksekusi kode di webmail | Tidak ada file akun/socket; hanya helper yang tetap butuh password lama; tanpa egress; uid 33, cap_drop ALL, ro rootfs. |

## 5. Acceptance criteria

- [x] `curl -sI https://webmail.expomedia.id/` → 200, sertifikat LE `CN=webmail.expomedia.id` verify 0; HTTP → 301 HTTPS.
- [x] Login `sales@expomedia.id` → Kotak Masuk; login `admin` (tanpa domain) → OK; pratinjau pesan (iframe) tampil.
- [x] Login `x@bimacreative.tech`, `admin@bimacreative.tech`, `noreply@expomedia.id`, `NoReply` → 401, tanpa koneksi IMAP.
- [x] Kirim dari webmail ke admin@ + lampiran 270 KB → masuk maildir admin, `DKIM-Signature … d=expomedia.id`.
- [x] Ganti password sales@: lama salah → "Sandi saat ini salah."; < 10 → ditolak; huruf saja / memuat local-part → ditolak
      helper; sama dgn default → ditolak; sukses → password baru AUTH OK, lama AUTH FAIL; dikembalikan ke default.
- [x] Manipulasi akun lain → ditolak (lihat §4). Rate limit helper → 429.
- [x] Brute force 15× → 429 setelah 10. Tidak ada decision CrowdSec untuk IP VPS.
- [x] AppSec tidak memblok login/compose/upload/kirim (tidak ada 403 di access log host webmail) → tanpa pengecualian.
- [x] `POST /api/contact` prod & staging → 303 `status=sent`, SASL `noreply@expomedia.id`, masuk info@ dengan DKIM.
- [x] Hardening `docker inspect`: uid 33, ro, cap_drop ALL, no-new-privileges, 256m/0.5/pids 64, tanpa port host.

## 6. Rollback

ADR 0012 §Rollback. Downtime mail untuk recreate: ±25 s.

## 7. Hasil (2026-09-25)

Bukti ringkas di laporan sesi dan `docs/03-operations/webmail.md` §Uji. Screenshot (lokal sesi, tidak di git):
`webmail-login-{desktop,mobile}.png`, `webmail-inbox-{desktop,mobile}.png`, `webmail-compose-desktop.png`,
`webmail-preview-desktop.png`.
