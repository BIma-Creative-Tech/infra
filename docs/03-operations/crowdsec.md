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
| `appsec.yaml` | listener AppSec `0.0.0.0:7422` | `type: appsec` | configs `appsec-default` + `crs-inband` + `local/odoo-crs-exclusions` (T10) |

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
