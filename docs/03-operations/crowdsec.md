# Operasional — CrowdSec (IPS + WAF AppSec, T05)

- **Stack:** `/opt/infra/security/crowdsec/` · image `crowdsecurity/crowdsec:v1.8.1` (tag + digest, ADR 0001)
- **Bouncer Traefik:** plugin `github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin` **v1.7.1**
  (`traefik/traefik.yml` → `experimental.plugins.bouncer`, `hash` di-pin), middleware `crowdsec`
  di `traefik/dynamic/middlewares/crowdsec.yml`, mode `stream` (sinkron 30 s) + AppSec.
- **Bouncer host:** paket `crowdsec-firewall-bouncer-nftables` **0.0.36** (hold), role Ansible
  `crowdsec_bouncer` (`--tags crowdsec_bouncer`). Set nftables `table ip crowdsec` / `ip6 crowdsec6`,
  hook `input` + `forward` prioritas `filter - 10` → blok SSH 2221 **dan** port publish Docker.
- **Terkait:** ADR 0001 (AppSec menggantikan Coraza), plan 02 §3–§5, CLAUDE.md §3.6

## Arsitektur & jaringan

| Komponen | Listen | Dicapai oleh |
|---|---|---|
| LAPI | `:8080` di container; publish **`127.0.0.1:8080`** saja | firewall bouncer host; Traefik via network `crowdsec` |
| AppSec | `:7422` di container, **tidak** di-publish | Traefik via network `crowdsec` |
| Prometheus | `:6060` di container, tidak di-publish | Prometheus (T14a) via network internal **`metrics`** (10.100.5.0/24) |

- Network **`crowdsec`**: bridge `10.100.2.0/24` (bukan `--internal`: CrowdSec butuh egress ke hub &
  CAPI), anggota hanya `crowdsec` + `traefik`. Container lain di `proxy` **tidak** bisa ke LAPI/AppSec.
- Network **`metrics`** (T14a): `--internal` `10.100.5.0/24`, anggota prometheus + traefik + crowdsec + keycloak — hanya
  untuk scrape metrics. Gateway crowdsec tetap `crowdsec` (network internal tidak punya gateway; diverifikasi `ip route`).
- Traefik join `proxy` (gw_priority 1) + `crowdsec`. **`gw_priority: 1` pada `proxy` wajib** — tanpa itu
  Docker memilih `crowdsec` sebagai gateway sehingga port 80/443 di-DNAT via bridge crowdsec dan akses
  dari host/SSH tunnel terlihat sebagai `10.100.2.1` (bukan `10.100.0.1` di `ipallowlist-admin`).
- Docker memasang `raw PREROUTING -d 127.0.0.1 ! -i lo --dport 8080 -j DROP` → LAPI tidak bisa dicapai dari luar host.

## Acquisition (`security/crowdsec/acquis.d/`, di-mount read-only)

| File | Sumber | Label | Parser |
|---|---|---|---|
| `traefik.yaml` | `/var/log/traefik/access.log` (= `traefik/logs/`, ro) | `type: traefik` | `crowdsecurity/traefik-logs` |
| `sshd.yaml` | `/var/log/host/auth.log` (= `/var/log` host, ro) | `type: syslog` | `syslog-logs` → `sshd-logs` |
| `appsec.yaml` | listener AppSec `0.0.0.0:7422` | `type: appsec` | configs `appsec-default` + `crs-inband` + `local/odoo-crs-exclusions` (T10) + `local/keycloak-admin-exclusions` (H4) |

- sshd → **`/var/log/auth.log`** (rsyslog aktif di host; journald tidak dipakai karena image alpine tanpa `journalctl`).
- Permission: container jalan sebagai root **tanpa capability** (tidak bisa bypass DAC). Membaca log lewat
  grup **`adm` (gid 4)**: `auth.log` = `syslog:adm 640`; `traefik/logs/` = `65532:adm 750` (diset
  `traefik/scripts/bootstrap.sh` & `security/crowdsec/scripts/bootstrap.sh`).

## Collections (env `COLLECTIONS`, dipasang entrypoint saat start)

`crowdsecurity/linux`, `crowdsecurity/sshd`, `crowdsecurity/traefik`, `crowdsecurity/http-cve`,
`crowdsecurity/appsec-virtual-patching`, `crowdsecurity/appsec-generic-rules`,
**`crowdsecurity/appsec-crs-inband`** (OWASP CRS blocking).

> `appsec-virtual-patching` + `appsec-generic-rules` (daftar ADR 0001) **tidak** memblok SQLi/XSS generik —
> hanya CVE spesifik + beberapa rule generik (diuji: `?q=<script>` → 200). `appsec-crs-inband` ditambahkan
> agar payload generik → 403; **perlu ratifikasi ADR 0001 oleh Lead**. Uji false positive sudah dilakukan
> pada form login Keycloak (password dengan `' -- ; < > & #`) → tidak terblok. Tuning FP lanjutan di staging
> (Odoo, T10). Rollback CRS: hapus dari `COLLECTIONS` + `crs-inband` di `acquis.d/appsec.yaml` →
> `docker exec crowdsec cscli collections remove crowdsecurity/appsec-crs-inband` → `docker compose up -d`.

### Pengecualian CRS untuk Odoo (T10)

`appsec-configs/odoo-crs-exclusions.yaml` (di-mount ro ke `/etc/crowdsec/appsec-configs/`, nama
`local/odoo-crs-exclusions`): hook `pre_eval` → `RemoveInBandRuleByTag("attack-xss")` hanya untuk POST ke
endpoint JSON-RPC Odoo yang membawa HTML (`/web/dataset/call_kw/`, `/mail/message/`, …). Alasan & uji: `odoo.md`
§AppSec. Verifikasi dimuat: `docker exec crowdsec cscli appsec-configs list` → `local/odoo-crs-exclusions  enabled,local`.

### Pengecualian CRS 911100 untuk Admin REST Keycloak (H4, disetujui user 2026-09-23)

`appsec-configs/keycloak-admin-exclusions.yaml` (mount ro, nama `local/keycloak-admin-exclusions`): hook `pre_eval` →
`RemoveInBandRuleByID(911100)` **hanya** bila semua syarat terpenuhi: in-band, `req.Host` ∈ {`auth.bimacreative.tech`,
`auth.bimacreative.tech:8443`} (bentuk ber-port = admin via SSH tunnel; plugin bouncer meneruskan `Host` apa adanya),
`req.URL.Path` diawali `/admin/realms/`, dan `req.RemoteAddr` ∈ {`127.0.0.1`, `10.100.0.1`} (= isi `ipallowlist-admin`).
- Alasan: CRS 911100 "Method is not allowed by policy" (default `GET HEAD POST OPTIONS`) memblok setiap PUT/DELETE Admin REST
  API (ubah/hapus user, client, role) — termasuk admin console via tunnel.
- `req.RemoteAddr` = IP **tanpa port**: plugin v1.7.1 `pkg/ip.GetRemoteIP` (`net.SplitHostPort` pada RemoteAddr koneksi,
  tanpa `forwardedHeadersTrustedIPs`) → header `X-Crowdsec-Appsec-Ip` → crowdsec v1.8.1 `pkg/appsec/request.go`
  `originalHTTPRequest.RemoteAddr = clientIP`. Helper diverifikasi di `pkg/appsec/waf_helpers.go` (`GetPreEvalEnv`).
- Rule CRS lain tetap aktif di path admin (XSS/SQLi/RCE/…); 911100 tetap aktif di host/path lain (mis. `/realms/<r>/`).
- Rollback: hapus file + barisnya di `acquis.d/appsec.yaml` + mount di `docker-compose.yml` → `docker compose up -d`
  (recreate = fail-closed; terukur H4: 403 di semua router ber-`crowdsec` 17:00:43–17:01:22 WIB, ±40 s).
- **H5 (keputusan user 2026-09-23) — hook `pre_eval` kedua** untuk app ProyekKas via network `--internal` DRMS (router
  `traefik/dynamic/clients/drms-proyekkas-kc-admin.yml`): tetap **hanya** 911100, in-band, `req.Host ==
  "auth.bimacreative.tech"`, dan pasangan eksak `IpInRange(req.RemoteAddr, "10.100.8.0/24")` × path `/admin/realms/drms/`
  **atau** `IpInRange(req.RemoteAddr, "10.100.9.0/24")` × `/admin/realms/drms-staging/`. `IpInRange(ip, cidr)` diverifikasi
  dari source v1.8.1 (`pkg/exprhelpers/expr_lib.go`, `helpers.go`; hook dikompilasi dengan `exprhelpers.GetExprOptions` di
  `pkg/appsec/appsec.go`). Uji kompilasi sebelum recreate: `crowdsec -t` di container sementara (salinan `data/`) → exit 0;
  kontrol negatif (nama helper salah) → `fatal … unknown name IpInRangeX`. Recreate H5: 403 fail-closed
  17:20:43–17:21:27 WIB (±44 s). Rollback H5 saja: hapus entri hook kedua → `docker compose up -d --force-recreate`.

Uji H5 (2026-09-23, container sementara `curlimages/curl:8.22.0` di `drms-kc-admin-stg` 10.100.9.3 / `drms-kc-admin`
10.100.8.3, token service account `proyekkas-admin-api` realm env masing-masing):

| Request | Harapan | Hasil (stg / prod) |
|---|---|---|
| `PUT …/admin/realms/<realm env>/users/<uuid acak>` | 404 Keycloak (bukan 403 911100) | 404 `User not found` / 404 |
| `DELETE …/users/<uuid acak>` | 404 Keycloak | 404 / 404 |
| `GET …/users?search=<script>alert(1)</script>` | 403 AppSec | 403 (alert `xss: 40`) / 403 |
| `PUT …/users/<uuid>` body `<script>` | 403 AppSec | 403 (alert `xss: 20`) / 403 |
| `GET …/<realm env>/..%2Fplatform/users` | 403 | 403 (alert `lfi: 15`) / 403 |

Uji H4 (2026-09-23, dari host = 10.100.0.1, `--resolve …:443:127.0.0.1`, token service account `automation` realm
`platform-staging`):

| Request | Harapan | Hasil |
|---|---|---|
| `PUT /admin/realms/platform-staging/users/<id>` `{"enabled":false}` | 204 (sebelumnya 403, alert 911100) | 204, user `enabled=false` |
| `DELETE /admin/realms/platform-staging/users/<id>` → `GET` | 204 → 404 | 204 → 404 |
| `GET /admin/realms/…/users?search=<script>alert(1)</script>` | 403 AppSec | 403, alert `xss: 40` (Origin 0) |
| `GET /admin/realms/…/users?search=' OR 1=1--` | 403 AppSec | 403, alert `sql_injection: 10` |
| `PUT /admin/realms/…/users/<id>` body `<script>` | 403 AppSec | 403, rule 941100/941110/941160/941390 — **tanpa** 911100 |
| `TRACE`/`PROPFIND https://status.bimacreative.tech/` | 403 (911100) | 403, alert `native_rule:911100` |
| `TRACE`/`PROPFIND https://auth.bimacreative.tech/realms/platform/` | 403 (911100) | 403, alert `native_rule:911100` |
| `PUT https://auth.bimacreative.tech/realms/platform-staging/` | 403 (911100) | 403, alert `native_rule:911100` |
| Odoo: POST HTML ke `/web/dataset/call_kw/…` vs `/web/session/get_session_info` | 200 vs 403 | 200 vs 403 (T10 utuh) |
| cp / cp.staging / auth discovery / demo.erp / demo.staging / status | 307/307/200/200/200/200 | sesuai |

Alert uji (`waf`, 10.100.0.1) tidak menghasilkan decision (parser whitelist IP privat) — `cscli decisions list -i 10.100.0.1`
→ `No active decisions`.

## Start / stop

```bash
cd /opt/infra/security/crowdsec
./scripts/bootstrap.sh            # sekali / idempoten: network crowdsec, data/, traefik/secrets, grup logs
docker compose up -d
docker compose ps                 # crowdsec: (healthy)  — healthcheck `cscli lapi status`
./scripts/materialize-data.sh     # SEKALI setelah start pertama (lihat catatan read_only)
docker compose down               # stop (data/ tetap)
```
- `read_only: true`: entrypoint image membuat symlink datafile ke `/staging` (layer image) → `cscli hub
  upgrade` gagal (`chtimes …: read-only file system`). `materialize-data.sh` mengganti symlink dengan salinan
  nyata di `data/db` (idempoten).
- State: `data/config` (= `/etc/crowdsec`, termasuk kredensial machine & CAPI) dan `data/db` (SQLite +
  datafile) — mode 700 root, di-ignore git (`**/data/`). Masuk backup (ADR 0006).
- Urutan start: crowdsec **sebelum** traefik bila keduanya mati (plugin `streamStartupBlock: true` menunggu
  LAPI; `crowdsecAppsecUnreachableBlock: true` → selama AppSec tidak terjangkau semua request ke router ber-
  middleware `crowdsec` = **403 (fail-closed)**). Restart crowdsec = gangguan singkat ±20–40 s.
- Firewall bouncer: `systemctl status crowdsec-firewall-bouncer`, log `/var/log/crowdsec-firewall-bouncer.log`.

## Perintah harian

```bash
docker exec crowdsec cscli metrics show acquisition parsers appsec bouncers
docker exec crowdsec cscli bouncers list          # traefik-bouncer & host-firewall-bouncer, "Last API pull"
docker exec crowdsec cscli alerts list -l 20
docker exec crowdsec cscli decisions list          # decision lokal (cscli/crowdsec)
docker exec crowdsec cscli decisions list -a       # termasuk blocklist CAPI
nft list table ip crowdsec                         # set yang diterapkan firewall bouncer
```

### Ban / unban manual
```bash
docker exec crowdsec cscli decisions add --ip <IP> --duration 4h --reason "<alasan>"
docker exec crowdsec cscli decisions delete --ip <IP>
```
Efek: Traefik ≤ 30 s (sinkron stream), nftables ≤ 10 s (`update_frequency`).

### Terkunci dari SSH (IP admin ter-ban)
Firewall bouncer menerapkan **semua** decision ban, termasuk blocklist komunitas (CAPI) dan skenario sshd.
IP admin **tidak** di-whitelist (keputusan Lead: belum). Pemulihan: login via **konsol VPS Hostinger**
(bukan SSH) → `docker exec crowdsec cscli decisions delete --ip <IP-admin>` (atau `--all` bila perlu) →
cek `nft list table ip crowdsec`. Darurat terakhir: `systemctl stop crowdsec-firewall-bouncer` lalu pastikan dengan
`nft list tables` bahwa tabel `crowdsec`/`crowdsec6` hilang (perilaku saat stop BELUM diuji; bila masih ada:
`nft delete table ip crowdsec` dan `nft delete table ip6 crowdsec6`) — nyalakan lagi setelah pulih.

## Rotasi API key bouncer

**Traefik** (key di `traefik/secrets/crowdsec-bouncer.key`, 600 uid 65532, di-ignore git):
```bash
docker exec crowdsec cscli bouncers delete traefik-bouncer
K=/opt/infra/traefik/secrets/crowdsec-bouncer.key; umask 077
docker exec crowdsec cscli bouncers add traefik-bouncer -o raw | tr -d '\n' > "$K"
chown 65532:65532 "$K"; chmod 600 "$K"
docker compose -f /opt/infra/traefik/docker-compose.yml restart traefik
docker exec crowdsec cscli bouncers list   # Last API pull baru
```
**Firewall host** (key di `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.key`, 600 root; dirender ke
`crowdsec-firewall-bouncer.yaml.local` oleh Ansible):
```bash
docker exec crowdsec cscli bouncers delete host-firewall-bouncer
rm /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.key
cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook site.yml --tags crowdsec_bouncer   # key baru, daftar, restart
```

## Verifikasi yang sudah dijalankan (2026-09-23)

- Ban memakai IP koneksi asli, bukan `X-Forwarded-For`: container uji sementara di network `proxy` dengan IP
  tetap `10.100.0.250` → langsung ke Traefik. Decision `10.100.0.250` → 403 (juga dengan `X-Forwarded-For:
  1.2.3.4`); dari host (10.100.0.1) dengan `X-Forwarded-For: 10.100.0.250` / `203.0.113.50` (ter-ban) → 200.
  Setelah `decisions delete` → 200.
- Firewall bouncer: decision `10.100.0.250` → elemen muncul di set `crowdsec-blacklists-cscli`, request dari
  IP itu timeout (drop L3); setelah delete → set kosong, 200.
- AppSec: `/?q=<script>alert(1)</script>`, `/?id=1' OR 1=1--`, `/.env`, path traversal → 403; normal → 200.

## Catatan

- CAPI aktif (default image): sinyal serangan dikirim ke CrowdSec dan blocklist komunitas ditarik. Console
  (`app.crowdsec.net`) **tidak** di-enroll (log `Machine is not enrolled in the console` = normal).
- Parser whitelist bawaan (`crowdsecurity/whitelists`) mengabaikan IP privat untuk alert/skenario — serangan
  dari host sendiri / 10.100.x.x tidak menghasilkan ban otomatis (decision manual tetap berlaku).
- Upgrade plugin: ubah `version` + `hash` di `traefik.yml` (hash = sha256 zip dari katalog; bandingkan isi zip
  dengan arsip tag GitHub sebelum mem-pin).
