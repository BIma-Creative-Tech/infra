# Operasional — Traefik (edge, T03)

- **Stack:** `/opt/infra/traefik/` · image `traefik:v3.7.13` (pin tag + digest, ADR 0001)
- **Terkait:** ADR 0002 (HTTP-01 per hostname, tanpa wildcard), plan 02 §3–§4, CLAUDE.md §3.5.1

## Struktur

| Path | Isi | Git |
|---|---|---|
| `traefik.yml` | static config: entrypoints `web` :80 (redirect → https) & `websecure` :443, `traefik` 127.0.0.1:8080 di dalam container (hanya `/ping`), file provider, resolver `le-http-staging` & `le-http`, access log JSON | ya |
| `dynamic/middlewares/*.yml` | `security-headers`, `ratelimit-default`, `ratelimit-login`, `ipallowlist-admin`, `strip-odoo-db-headers` | ya |
| `dynamic/tls.yml` | TLS option `default` (min TLS 1.2) | ya |
| `dynamic/platform/<svc>.yml` | router layanan platform (T06 `auth.yml`, T14 `grafana.yml`/`status.yml`, …) — satu file per task | ya |
| `dynamic/clients/<slug>.yml` | router client Odoo (T10, dirender control plane) | ya |
| `dynamic/test/whoami-status.yml` | **router uji** `status.bimacreative.tech` → `whoami` (resolver staging). Hapus saat T14 memasang Uptime Kuma | ya |
| `acme/acme-staging.json`, `acme/acme.json` | akun ACME + private key sertifikat. Dir 700, file 600, owner 65532 | **tidak** (`traefik/.gitignore`) |
| `logs/access.log` | access log JSON (dibaca CrowdSec T05, Alloy T14) | **tidak** |
| `logrotate/traefik` | dipasang ke `/etc/logrotate.d/traefik` oleh bootstrap | ya |
| `scripts/bootstrap.sh` | idempoten: network `proxy`, dir/file acme & logs, logrotate | ya |

## Keputusan

- **Dashboard/API: tidak diaktifkan sama sekali** (`api` tidak diset, default `false`). `/dashboard/`
  dan `/api/rawdata` di IP publik → 404. Debug via `docker logs traefik` dan isi `dynamic/`.
- **File provider saja** — tidak ada mount `/var/run/docker.sock`.
- **Non-root tanpa capability**: `user: 65532:65532`, `cap_drop: [ALL]`, **tanpa** `cap_add`. Docker
  menset `net.ipv4.ip_unprivileged_port_start=0` di netns container (ditulis eksplisit di `sysctls`), jadi
  uid biasa boleh bind 80/443. Uji: dengan sysctl `1024` + `--cap-add NET_BIND_SERVICE` + non-root →
  `listen tcp :80: bind: permission denied` (capability tambahan tidak masuk effective set proses non-root),
  jadi `NET_BIND_SERVICE` tidak berguna di sini dan tidak dipasang.
- `read_only: true` + tmpfs `/tmp`; yang writable hanya `acme/` dan `logs/`.
- `aliasHeadersStrategy: delete` di semua entrypoint: header bernama alias (`X_Sh_Odoo_Db`,
  `X.Odoo.Database`, …) dibuang sebelum routing — backend WSGI (Odoo) membaca alias itu sebagai
  header asli (docs `entrypoints.md` §aliasHeadersStrategy).
- `forwardedHeaders` tidak diset → `X-Forwarded-For`/`X-Real-Ip` dari client **ditimpa** (diuji:
  kirim `X-Forwarded-For: 1.2.3.4` → backend menerima IP koneksi sebenarnya).
- Email ACME: **kosong** (LE menerima akun tanpa email; notifikasi kedaluwarsa LE sudah dihentikan).
  Isi `certificatesResolvers.*.acme.email` bila Lead menetapkan alamat.

## Network `proxy`

- Bridge, **subnet tetap `10.100.0.0/24`, gateway `10.100.0.1`**, dibuat `scripts/bootstrap.sh`
  (bukan oleh compose, agar `docker compose down` satu stack tidak menghapus network bersama).
- Service HTTP lain join sebagai network external dan **tidak** publish port:
  ```yaml
  services:
    app:
      networks: [proxy]          # + network internal stack sendiri (mis. db)
  networks:
    proxy:
      external: true
      name: proxy
  ```
- Router ditulis di `dynamic/platform/<svc>.yml` (atau `dynamic/clients/<slug>.yml`), service
  `loadBalancer.servers[].url: http://<container_name>:<port>` (DNS Docker di network `proxy`).
- Template router platform:
  ```yaml
  http:
    routers:
      <svc>:
        entryPoints: [websecure]
        rule: "Host(`<fqdn>`)"          # FQDN eksplisit, bukan HostRegexp (ADR 0002 #2)
        middlewares: [security-headers, ratelimit-default]
        service: <svc>
        tls:
          certResolver: le-http-staging # ganti ke le-http HANYA setelah keputusan Lead
    services:
      <svc>:
        loadBalancer:
          servers:
            - url: "http://<container>:<port>"
  ```
- **Sebelum menulis router hostname baru**: `dig +short A <fqdn> @1.1.1.1` dan `@8.8.8.8` harus
  `31.97.50.221`, `dig +short AAAA <fqdn>` kosong (ADR 0002 #5).

## Start / stop / reload

```bash
cd /opt/infra/traefik
./scripts/bootstrap.sh            # sekali / idempoten
docker compose up -d
docker compose ps                 # traefik: (healthy)
docker logs --tail 50 traefik
docker compose down               # stop (network proxy & acme tetap)
```
- Perubahan `dynamic/**` di-reload otomatis (watch). Perubahan `traefik.yml` → `docker compose restart traefik`.
- Validasi sebelum restart: `docker compose config -q`.

## Cek sertifikat

```bash
echo | openssl s_client -connect 31.97.50.221:443 -servername <fqdn> 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# staging → issuer mengandung "(STAGING)"
docker logs traefik 2>&1 | grep -i -E 'acme|lego|certificate' | tail
```
Jangan me-restart berulang bila ACME gagal: baca log, perbaiki (DNS/port 80), baru ulang —
limit LE: 5 authorization failure / identifier / jam (ADR 0002).

## Pindah staging → production (keputusan Lead, BELUM dilakukan)

1. Backup: `cp -a acme/acme-staging.json acme/acme-staging.json.bak-$(date +%F)`.
2. Per router: `certResolver: le-http-staging` → `le-http` (file `dynamic/**`, reload otomatis).
3. Verifikasi issuer tidak lagi `(STAGING)`.
4. Naikkan HSTS di `security-headers.yml` (`stsSeconds: 31536000`) setelah semua host stabil.

## Rotasi / secret

- `acme*.json` berisi private key → 600, masuk backup terenkripsi (ADR 0006). Hapus akun/sertifikat
  staging = hapus isi `acme-staging.json` (**destruktif — konfirmasi Lead**), lalu restart.
- Access log: logrotate harian, simpan 14, `maxsize 100M`, `postrotate` mengirim USR1
  (`docker kill --signal=USR1 traefik`) — diuji `logrotate -f`, file baru dibuat Traefik.

## Admin via SSH tunnel (catatan penting)

Daemon Docker memakai `userland-proxy: false`. Koneksi yang berasal dari host itu sendiri
(termasuk `ssh -L 8443:127.0.0.1:443 …`) tiba di Traefik dengan IP sumber **gateway network
`proxy` = `10.100.0.1`**, bukan `127.0.0.1` (terlihat di `X-Real-Ip`/access log). Koneksi dari
internet tetap membawa IP asli client. Konsekuensi: `ipallowlist-admin` default (`127.0.0.1/32`)
**tidak** meloloskan SSH tunnel; agar tunnel berfungsi, tambahkan `10.100.0.1/32` — artinya "semua
proses di host". Menunggu keputusan Lead.

## Rollback

`docker compose down` → kembalikan file dari git (`git checkout <rev> -- traefik/`) → `up -d`.
`acme/` tidak tersentuh oleh rollback git (di-ignore). Menghapus stack sepenuhnya: `down` saja;
jangan hapus `acme/` tanpa konfirmasi.
