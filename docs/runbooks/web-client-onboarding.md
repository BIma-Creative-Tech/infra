# Runbook — Onboarding Website Next.js Client (web-starter / `web-<slug>`)

- **Kapan dipakai:** client mendapat website Next.js (repo `web-<slug>` dari `web-starter`, image di GHCR) di
  domain sendiri atau subdomain platform — prod maupun staging.
- **Terkait:** `docs/plans/03-web-client-template.md` (W2), `docs/adr/0002-tls-dns-manual.md` (HTTP-01, pre-check DNS),
  `CLAUDE.md` §3.5 (hardening), `docs/03-operations/traefik.md` (reload HUP, H7), `docs/runbooks/client-domain-onboarding.md`
  (bagian A: DNS domain client; bagian B: mailbox untuk form kontak).
- **Satu perintah:** `scripts/provision-web-client.sh` (root) — render stack + router, `docker compose up -d`, tunggu healthy,
  HUP Traefik, smoke test. Idempoten: run ulang tanpa perubahan → `changed=no`, tanpa HUP.

## Komponen

| Item | Sumber (git) | Hasil render |
|---|---|---|
| Stack compose | `templates/web-client/docker-compose.yml` (+ `docker-compose.contact.yml`, `.gitignore`, `.env.example`) | prod `web/clients/<slug>/`, staging `staging/web-clients/<slug>/` |
| `.env` (tanpa secret, 600 root) | dibuat skrip: `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, `WEB_CONTAINER`, `WEB_IMAGE`, `SITE_URL`, `CONTACT_ENABLED` (+ `SMTP_*`) | `<dir>/.env` — **tidak** di git |
| Password SMTP (opsional) | — | `<dir>/secrets/smtp_password.secret` (1001:1001, 0400) — **tidak** di git |
| Router Traefik | `templates/traefik-web-client.yml` | `traefik/dynamic/clients/web-<slug>-<env>.yml` |

Nama `web-<slug>-<env>` = project compose = `container_name` = router/service Traefik (`http://web-<slug>-<env>:3000`,
network `proxy`, tanpa port publik). Hardening container: uid 1001, `read_only` + tmpfs `/tmp` (16m) &
`/app/.next/cache` (64m), `cap_drop: [ALL]`, `no-new-privileges`, `mem_limit 256m`, `cpus 0.5`, `pids_limit 128`,
healthcheck `GET /api/health`, json-file 10m×3.

Router: `web-<slug>-<env>` (`Host()` kanonik) → `crowdsec` → `security-headers` (HSTS, nosniff, frame DENY, referrer,
permissions) → `ratelimit-default`; `web-<slug>-<env>-contact` (`POST /contact` & `POST /api/contact`) → limit
`web-<slug>-<env>-ratelimit-contact` 5/menit/IP (burst 5); opsional `web-<slug>-<env>-www` → 301 ke host kanonik.
Sertifikat `le-http` per hostname (tanpa wildcard). CSP dikirim aplikasi (nonce), bukan Traefik.

### Git — apa yang di-commit

Mengikuti pola stack/route yang sudah ada (router tenant Odoo `dynamic/clients/<slug>-<env>.yml` dan stack
`staging/drms-proyekkas/` di-commit): **commit** `docker-compose*.yml` + `.gitignore` hasil render dan file router
`dynamic/clients/web-<slug>-<env>.yml` setelah provision prod/staging yang permanen. **Jangan commit** `.env` (di-ignore
root `.gitignore`) dan `secrets/` (di-ignore `.gitignore` stack). Karena `.env` tidak di git, tag image yang sedang
berjalan dicatat di pesan commit / `provision_job` control plane (`docker inspect -f '{{.Config.Image}}' web-<slug>-<env>`).
Deploy uji/sementara: jangan commit; `--remove` lalu hapus direktori render.

## 1. Prasyarat

1. Image `web-<slug>` sudah ada di GHCR dengan **tag pin** (mis. `ghcr.io/bctech-adm/web-<slug>:0.1.0` atau
   `…@sha256:<digest>`). `latest` / tanpa tag ditolak skrip. Host sudah `docker login ghcr.io` bila repo private.
2. Slug client `^[a-z0-9-]{3,30}$` (sama dengan tenant Odoo).
3. DNS: lihat §2. Tanpa DNS benar skrip berhenti **sebelum** menulis apa pun.

## 2. DNS

**Subdomain platform** (`<slug>.staging.bimacreative.tech`): wildcard `*.staging` sudah mengarah ke VPS → tidak perlu
record baru. Hostname prod platform di luar wildcard → tambah A manual di Hostinger (ADR 0002).

**Domain client** — berikan ke client (sama dengan `client-domain-onboarding.md` A1):

| Tipe | Nama | Nilai |
|---|---|---|
| A | `@` (apex) | `31.97.50.221` |
| A **atau** CNAME | `www` (hanya bila `--www`) | `31.97.50.221` / `edge.bimacreative.tech` |
| TXT | `_platform-verify.<domain-client>` | token verifikasi dari control plane |

- **Tanpa AAAA** di apex maupun `www` (IPv4-only, ADR 0002 #4) — skrip menolak host yang punya AAAA.
- Apex tidak boleh CNAME (aturan DNS) → pakai A.
- Skrip memeriksa A = `31.97.50.221` di 1.1.1.1 & 8.8.8.8 dan tidak ada AAAA (`scripts/lib/traefik-route.sh`
  `dns_precheck`), untuk host dan `www.<host>` bila `--www`. **TXT verifikasi belum diperiksa skrip** (token diterbitkan
  control plane, belum ada) → periksa manual dulu:
  `dig +short TXT _platform-verify.<domain-client> @1.1.1.1`.

## 3. Provision

```
sudo /opt/infra/scripts/provision-web-client.sh <slug> <prod|staging> \
  --host <fqdn-kanonik> --image ghcr.io/bctech-adm/web-<slug>:<tag> [--www]
```

Keluaran baris terakhir: `RESULT host=<fqdn> container=web-<slug>-<env> route=<file> changed=<yes|no>`.
Skrip gagal (exit ≠ 0) bila: argumen/DNS tidak valid, hostname sudah dipakai router lain di `traefik/dynamic/**`, container
tidak healthy dalam 120 s (route **tidak** ditulis), atau smoke test `https://<host>/api/health` (TLS divalidasi, lewat
Traefik lokal) tidak 200 dalam 120 s (biasanya sertifikat belum terbit — cek `docker logs traefik | grep -i acme`).

Verifikasi tambahan:
```
curl -sI https://<host>/ | grep -iE '^(HTTP|strict-transport|content-security|x-frame|x-content-type)'
docker inspect web-<slug>-<env> -f 'ro={{.HostConfig.ReadonlyRootfs}} user={{.Config.User}} caps={{.HostConfig.CapDrop}} mem={{.HostConfig.Memory}}'
docker stats --no-stream web-<slug>-<env>
```

**Uptime Kuma:** tambahkan monitor HTTP `https://<host>/api/health` (UI via tunnel :8443, atau entri `MONITORS` di
`observability/scripts/uptime-kuma-provision.js` + `uptime-kuma-provision.sh` dengan password sementara — lihat
`docs/03-operations/observability.md`). Skrip provision tidak membuat monitor (password admin Kuma dipegang user).

### Form kontak (opsional, default OFF)

1. Buat mailbox pengirim untuk domain client (`client-domain-onboarding.md` bagian B; batas outbound per mailbox berlaku).
2. Taruh password SMTP (tidak pernah lewat argumen/riwayat shell):
   ```
   sudo install -d -m 700 /opt/infra/<web/clients|staging/web-clients>/<slug>/secrets
   sudo install -m 400 /dev/stdin /opt/infra/<...>/<slug>/secrets/smtp_password.secret   # ketik password, Ctrl+D
   ```
3. Provision ulang dengan `--contact --smtp-host mail.bimacreative.tech --smtp-user <mailbox> --smtp-from <mailbox>
   [--smtp-port 587]`. Skrip set owner `1001:1001` mode `0400`, menambah `docker-compose.contact.yml` ke `COMPOSE_FILE`
   (secret `/run/secrets/smtp_password`, `SMTP_PASSWORD_FILE`, `CONTACT_ENABLED=true`) dan me-recreate container.
4. Mematikan: provision ulang tanpa `--contact` (secret tidak lagi di-mount; hapus file password bila mailbox dicabut).

## 4. Upgrade tag image

```
sudo /opt/infra/scripts/provision-web-client.sh <slug> <env> --host <fqdn> --image ghcr.io/bctech-adm/web-<slug>:<tag-baru> [--www] [--contact …]
```
Opsi lain **harus sama** dengan provision sebelumnya (skrip merender ulang dari argumen; `--www`/`--contact` yang
terlewat akan dilepas). Hanya `.env` yang berubah → `compose up -d` me-recreate container; route identik → tanpa HUP.
Ada jeda singkat (stop → start container, ±beberapa detik 502) — satu replika, tanpa rolling update.

## 5. Rollback

- **Image bermasalah:** jalankan ulang §4 dengan tag lama (tag lama tetap di GHCR). Tag lama: riwayat commit / provision_job,
  atau `docker image ls ghcr.io/bctech-adm/web-<slug>`.
- **Lepas website:** `sudo /opt/infra/scripts/provision-web-client.sh <slug> <env> --remove` → hapus route + HUP Traefik
  (host → 404), `docker compose down` (**tanpa** `-v`), direktori render dipertahankan dengan penanda `.removed`.
  Run ulang `--remove` → `changed=no`. Provision lagi dengan argumen semula menghapus `.removed` dan menghidupkan kembali.
- **Template rusak:** `git checkout <rev> -- templates/` lalu provision ulang.
- Sertifikat yang sudah terbit tetap di `acme.json` (kedaluwarsa alami; lihat `client-domain-onboarding.md` Rollback A).

## 6. Catatan keamanan

- Server Action Next.js yang di-POST dengan `Content-Type: text/plain` diblok CrowdSec AppSec (CRS 920420 → 403 → **ban
  4 jam** IP pengguna) — insiden H6/H7(a), `docs/03-operations/crowdsec.md`. Pengecualian yang ada hanya untuk host cp dan
  ProyekKas. Form kontak sebaiknya Route Handler `POST /api/contact` (JSON/multipart), atau Server Action dengan argumen
  `FormData` (multipart). Server Action tanpa argumen FormData butuh pengecualian AppSec per host (keputusan Lead) — uji di
  staging sebelum prod.
- Container berada di network `proxy` (bersama Traefik, control-plane, Grafana, Uptime Kuma). Website tidak butuh akses
  ke layanan tsb; isolasi per network edge (pola `odoo-edge`/`drms-kas-edge`) = perbaikan lanjutan.
- HSTS mengikuti `security-headers` (`stsSeconds` platform, saat ini 300) — naik otomatis ketika nilai platform dinaikkan.
- Nama file route `web-<slug>-<env>.yml` bisa sama dengan route tenant Odoo bila slug Odoo diawali `web-`; kedua skrip
  menolak menimpa/menghapus file yang bukan hasil render-nya sendiri.
