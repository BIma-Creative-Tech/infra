# ADR 0002 — TLS via HTTP-01 per hostname & DNS manual (Hostinger)

- **Status:** accepted (2026-09-23, GATE 1)
- **Tanggal:** 2026-09-23
- **Terkait:** CLAUDE.md §2, §3.5.1; ADR 0001, 0005; keputusan user #1

## Context

- Keputusan user #1: DNS domain platform dikelola **manual** di DNS manager Hostinger; **tidak ada
  API DNS**. Domain platform = **`bimacreative.tech`** (info Lead 2026-09-23; NS `apollo.dns-parking.com`,
  `athena.dns-parking.com` — terverifikasi `dig NS bimacreative.tech @1.1.1.1`).
- CLAUDE.md §3.5.1 mengasumsikan resolver `le-dns` (DNS-01, wildcard). Tanpa API DNS, DNS-01
  otomatis tidak mungkin (tidak ada cara bagi Traefik membuat record TXT `_acme-challenge`).
- IP VPS: IPv4 `31.97.50.221`; IPv6 `2a02:4780:59:823e::1` (discovery §1.4).

### Fakta Let's Encrypt (sumber: https://letsencrypt.org/docs/rate-limits/, "Last updated: August 5, 2026", di-fetch 2026-09-23)

| Limit | Nilai resmi |
|---|---|
| New Certificates per Registered Domain | 50 sertifikat / registered domain / 7 hari; refill 1 per 202 menit |
| New Certificates per Exact Set of Identifiers | 5 / set identik / 7 hari; refill 1 per 34 jam |
| New Orders per Account | 300 / 3 jam; refill 1 per 36 detik |
| Authorization Failures per Identifier per Account | 5 / identifier / jam; refill 1 per 12 menit |
| Consecutive Authorization Failures per Identifier per Account | 1.152; reset ke 0 setelah validasi sukses |
| New Registrations per IP Address | 10 akun / IP / 3 jam |
| Renewal | Renewal via ARI "exempt from all rate limits"; renewal lama (set identik) "may still be subject to certain rate limits" |

### Fakta Traefik v3.7 (sumber: `raw.githubusercontent.com/traefik/traefik/v3.7/docs/content/...`)

- `reference/install-configuration/tls/certificate-resolvers/acme.md`: `acme.httpChallenge.entryPoint`
  ("Must be reachable by Let's Encrypt through port 80"); `acme.caServer` (default
  `https://acme-v02.api.letsencrypt.org/directory`); `acme.storage`; `acme.certificatesDuration`
  (default 2160 jam); `acme.profile`; "Redirection is fully compatible with the HTTP-01 challenge".
  "Certificates that are no longer used may still be renewed" → hostname client yang dihapus harus dibersihkan dari `acme.json`.
- `reference/install-configuration/entrypoints.md` §allowACMEByPass: secara default Traefik membuat
  router internal ACME dengan prioritas tertinggi (`MaxInt`) → redirect HTTP→HTTPS
  (`http.redirections.entryPoint.to/scheme/permanent`) **tidak** memblokir `/.well-known/acme-challenge/`.
  Jangan set `allowACMEByPass`.
- Domain untuk sertifikat diambil dari matcher `Host()` router ("Every domain must have A/AAAA records pointing to Traefik. Each domain & SAN will lead to a certificate request.").
- Dukungan ARI di Traefik: **UNVERIFIED** (tidak ditemukan di acme.md v3.7).

## Decision

1. **Satu certresolver saja: `le-http`** (HTTP-01, `entryPoint: web` :80) untuk SEMUA hostname —
   platform maupun domain client. Resolver `le-dns` dihapus dari desain.
   Tambahan: resolver `le-http-staging` dengan `caServer` = server staging LE
   (URL persis diverifikasi saat implementasi dari docs LE — UNVERIFIED di sesi ini) untuk uji awal.
2. **Tidak ada sertifikat wildcard.** Setiap router memakai `Host(\`<fqdn>\`)` eksplisit (bukan
   `HostRegexp`) agar Traefik bisa meminta sertifikat per hostname.
3. **Record DNS wildcard tetap dipakai untuk routing** (`*.erp`, `*.staging`): hostname platform baru
   langsung resolve tanpa menunggu user mengedit DNS; sertifikatnya diterbitkan HTTP-01 per host.
4. **Tidak mempublikasikan AAAA** untuk hostname mana pun di fase ini (IPv4-only di edge). Alasan:
   (a) mail wajib IPv4-only (ADR 0005); (b) dengan `userland-proxy: false` (daemon.json, plan 01)
   dan container tanpa IPv6, koneksi IPv6 ke port yang di-publish gagal (docs docker-mailserver
   `config/advanced/ipv6.md` v16.0.1); dengan `userland-proxy: true` IP asli client IPv6 hilang
   (terlihat sebagai gateway Docker) sehingga CrowdSec/rate-limit tidak efektif. Jika AAAA ada tetapi
   jalur IPv6 rusak, validasi HTTP-01 bisa gagal dan membakar limit "5 failures/identifier/jam".
   IPv6 edge dapat diaktifkan kemudian dengan ADR baru.
5. **Router hanya dibuat setelah DNS lolos pre-check** (berlaku untuk domain client DAN hostname
   platform di luar wildcard): control plane/skrip menjalankan `dig +short A <fqdn> @1.1.1.1` dan
   `@8.8.8.8` → harus = `31.97.50.221` dan tidak ada AAAA yang mengarah ke tempat lain, plus TXT
   verifikasi untuk domain client. Baru kemudian file dynamic config router ditulis.
6. **CAA** `0 issue "letsencrypt.org"` + `0 issuewild ";"` (larang wildcard) — identifier
   `letsencrypt.org` diverifikasi di https://letsencrypt.org/docs/caa/.

### Konvensi hostname (usulan)

| Fungsi | Hostname |
|---|---|
| Control plane prod | `cp.bimacreative.tech` |
| Keycloak | `auth.bimacreative.tech` (admin console via allowlist) |
| Odoo prod client | `<slug>.erp.bimacreative.tech` |
| Odoo demo client | `<slug>-demo.erp.bimacreative.tech` |
| Odoo staging client | `<slug>.staging.bimacreative.tech` |
| Control plane staging | `cp.staging.bimacreative.tech` |
| Grafana | `grafana.bimacreative.tech` (allowlist) |
| Uptime Kuma status | `status.bimacreative.tech` |
| Mail | `mail.bimacreative.tech` |
| Target CNAME client | `edge.bimacreative.tech` |

### Daftar record DNS — status nyata vs target (Hostinger DNS manager, manual)

Status diobservasi Analyst 2026-09-23 via `dig +short <tipe> <nama> @1.1.1.1` (sesuai laporan Lead).
TTL: **300** selama setup/migrasi, **3600** setelah stabil (TTL minimum Hostinger: UNVERIFIED).

| # | Tipe | Nama | Nilai target | TTL | Status 2026-09-23 | Aksi user |
|---|---|---|---|---|---|---|
| 1 | A | `@` | `31.97.50.221` | 300 | ADA | — |
| 1b | **AAAA** | `@` | — (hapus) | — | ADA `2a02:4780:59:823e::1` (juga terwarisi `www` via CNAME) | **HAPUS** (Decision #4; bila apex/www dilayani Traefik, LE memvalidasi via IPv6 → gagal) |
| 1c | CNAME | `www` | `bimacreative.tech` | 300 | ADA | — (ikut apex) |
| 2 | A | `edge` | `31.97.50.221` | 300 | ADA | — |
| 3 | A | `cp` | `31.97.50.221` | 300 | ADA | — |
| 4 | A | `auth` | `31.97.50.221` | 300 | ADA | — |
| 5 | A | `grafana` | `31.97.50.221` | 300 | **BELUM** | TAMBAH sebelum observability |
| 6 | A | `status` | `31.97.50.221` | 300 | ADA | — |
| 7 | A | `mail` | `31.97.50.221` (tanpa AAAA) | 300 | ADA, tanpa AAAA (benar) | — |
| 8 | A | `*.erp` | `31.97.50.221` | 300 | ADA (uji `x1.erp` → IP VPS) | — |
| 8b | A | `erp` | `31.97.50.221` | 300 | **BELUM** (wildcard tidak mencakup `erp` itu sendiri) | TAMBAH hanya jika `erp.bimacreative.tech` akan dipakai (mis. halaman pilih login); tidak wajib |
| 9 | A | `*.staging` | `31.97.50.221` | 300 | ADA (mencakup `cp.staging`) | — |
| 10 | MX | `@` | `10 mail.bimacreative.tech` (**satu-satunya MX**) | 300 | **SALAH**: `10 mail.expomedia.id` + `10 bimacreative.tech` (`mail.expomedia.id` tanpa A record) | **HAPUS kedua MX lama, TAMBAH** `10 mail.bimacreative.tech` sebelum mail stack |
| 11 | TXT | `@` | `v=spf1 ip4:31.97.50.221 -all` | 300 | ADA `v=spf1 mx -all` | UBAH (disarankan): `mx` saat ini ikut MX yang salah dan membawa AAAA apex; `ip4:` eksplisit tidak bergantung MX |
| 11b | TXT | `_spf` | `v=spf1 ip4:31.97.50.221 -all` (SPF terpusat, di-`include` oleh domain mail client — ADR 0005 #12) | 300 | BELUM | TAMBAH sebelum mail; lalu root boleh diganti `v=spf1 include:_spf.bimacreative.tech -all` |
| 12 | TXT | `mail` | `v=spf1 ip4:31.97.50.221 -all` (SPF HELO) | 300 | BELUM | TAMBAH sebelum mail |
| 13 | TXT | `_dmarc` | `v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:dmarc@bimacreative.tech` | 300 | ADA `v=DMARC1; p=quarantine; rua=mailto:dmarc@expomedia.id` | UBAH rua ke `dmarc@bimacreative.tech` (lihat catatan RFC 7489) |
| 14 | TXT | `mail._domainkey` | **diisi setelah mail stack jalan** (output `setup config dkim`; selector default `mail` per docs DMS `best-practices/dkim_dmarc_spf.md` — konfirmasi dari output nyata) | 300 | BELUM (memang belum waktunya) | setelah mail up |
| 15 | CAA | `@` | `0 issue "letsencrypt.org"` | 3600 | ADA | — |
| 16 | CAA | `@` | `0 issuewild ";"` | 3600 | **TIDAK BISA** — DNS Hostinger menolak nilai `;` ("CAA record content is not valid", 2026-09-25) | Digantikan #15b: tanpa `issuewild`, `issue` berlaku juga untuk wildcard (RFC 8659 §4.3) → wildcard hanya untuk akun kita |
| 15b | CAA | `@` | ~~`0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/3788309616"`~~ → `0 issue "letsencrypt.org"` (TTL 300) | 300 | **DILEPAS 2026-09-26 ~00:20 WIB** (keputusan user): `le-http` tanpa `email` di traefik.yml → akun ACME berganti setelah restart Traefik (riwayat acme.json 3780257956→3780483356→…→3788309616→3790657356; akun baru 2026-09-25 15:12Z setelah recreate Traefik plan 06) → semua sertifikat BARU gagal CAA 403. Pin ulang hanya setelah email ACME dikonfigurasi & akun terbukti stabil melewati restart. (Semula ADA 2026-09-25, menggantikan #15) | RFC 8657: hanya akun ACME `le-http` Traefik yang boleh menerbitkan. Latar: ACME pihak tak dikenal mencoba HTTP-01 `bimacreative.tech`/`www` tiap ±100 menit sejak 2026-09-23 (log Traefik "Cannot retrieve the ACME challenge") |
| — | AAAA | semua nama lain | **jangan dibuat** | — | tidak ada AAAA di `mail`, `x1.erp` (benar) | — |
| — | PTR | `31.97.50.221` | `mail.bimacreative.tech` | — | **BELUM** (`srv2001692.hstgr.cloud.`) | SET di panel VPS Hostinger sebelum mail kirim keluar |

**Catatan DMARC `rua` lintas domain (RFC 7489 §7.1, https://www.rfc-editor.org/rfc/rfc7489.txt):**
bila domain `rua` berbeda Organizational Domain dengan domain kebijakan, penerima laporan
memeriksa TXT di `<domain-kebijakan>._report._dmarc.<domain-tujuan>` yang memuat `v=DMARC1`.
`dig TXT bimacreative.tech._report._dmarc.expomedia.id @1.1.1.1` → kosong, jadi laporan ke
`dmarc@expomedia.id` tidak akan dikirim oleh penerima yang patuh. Rekomendasi: `rua=mailto:dmarc@bimacreative.tech`
(mailbox dibuat di DMS); alternatif: pemilik `expomedia.id` menambah record otorisasi tersebut.

**Catatan MX:** dua MX berprioritas sama, salah satunya tanpa A record, menyebabkan pengirim mencoba
host tak valid secara acak (penundaan/bounce). Perbaiki sebelum mail stack aktif; selama mail stack belum
jalan, mail masuk ke domain ini akan gagal/tertunda apa pun MX-nya.

Catatan: Record wildcard DNS (RFC 4592) juga mencocokkan label bertingkat
(`a.b.erp.bimacreative.tech`); router Traefik yang tidak dikenal akan 404 — bukan masalah keamanan.

Domain milik client (diinstruksikan control plane): `A erp.clientdomain.com → 31.97.50.221` **atau**
`CNAME erp.clientdomain.com → edge.bimacreative.tech`, plus TXT verifikasi dari control plane, dan
**tanpa AAAA**.

## Dampak rate limit (ESTIMASI berbasis angka resmi di atas)

- Semua hostname platform berbagi kuota **50 sertifikat baru / 7 hari** untuk `bimacreative.tech`.
  Bring-up awal ≈ 7 sertifikat (cp, auth, grafana, status, mail, cp.staging, + satu uji).
  Onboarding per client ≈ 3 sertifikat (prod, demo, staging) → **maks ±14 client baru / minggu**
  sebelum menyentuh limit (cukup untuk skala host ini — ADR 0004 membatasi jauh di bawah itu).
- Domain client dihitung terhadap registered domain milik client (kuota terpisah).
- Limit yang paling mungkin terkena: **5 authorization failures / identifier / jam** bila router
  dibuat sebelum DNS benar → Decision #5 (pre-check) + LE staging untuk uji pertama.
- Renewal: tidak menambah kuota bila terdeteksi renewal; ARI support Traefik UNVERIFIED.

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| DNS-01 manual (TXT diisi tangan) | Tidak otomatis; renewal tiap ≤ 90 hari butuh intervensi manusia → pasti lupa |
| Pindah DNS ke provider ber-API (mis. Cloudflare) | Diputuskan user: tetap Hostinger. Bisa dibuka lagi via ADR baru |
| Delegasi `_acme-challenge` via CNAME ke zona ber-API (acme-dns) | Tambah komponen & zona lain; tidak diminta |
| TLS-ALPN-01 | Sama-sama per hostname; tidak memberi keuntungan dibanding HTTP-01, dan HTTP-01 sudah wajib untuk domain client |

## Consequences

- Hostname platform baru di bawah `*.erp`/`*.staging` langsung bisa dilayani (DNS wildcard), sertifikat
  terbit dalam hitungan detik–menit setelah router dibuat. Hostname di luar wildcard (mis. layanan
  platform baru) butuh user menambah record A manual **dan menunggu propagasi** sebelum router dibuat.
- Port 80 wajib terbuka permanen (ufw) — sudah sesuai §3.5.1.
- `acme.json` berisi private key semua sertifikat → mode 600, masuk backup terenkripsi (ADR 0006).
- Router untuk `mail.bimacreative.tech` harus ada di Traefik agar sertifikat mail diterbitkan
  (docs DMS `config/security/ssl.md`: "Traefik will not issue a certificate without a service / router demanding it"); DMS membaca `acme.json` di `/etc/letsencrypt/acme.json` (read-only).

## Security implications

- Tanpa wildcard cert, kompromi satu private key hanya berdampak ke satu hostname.
- CAA membatasi CA penerbit; `issuewild ";"` mencegah wildcard dari CA mana pun.
- Pre-check DNS mencegah abuse "client menambahkan domain milik orang lain" (TXT verifikasi) dan
  mencegah lockout rate-limit.
- Tanpa API token DNS di server → tidak ada secret DNS yang bisa dicuri dari host (nilai plus).

## Rollback

Konfigurasi resolver ada di static config Traefik; rollback = kembalikan file + restart Traefik.
`acme.json` di-backup sebelum perubahan resolver. Record DNS: user mengembalikan dari catatan
(simpan screenshot/ekspor zona sebelum mengubah).

## Perubahan CLAUDE.md yang diusulkan

- §3.5.1: hapus baris `le-dns`; semua hostname memakai `le-http`; tambah aturan "tidak ada AAAA
  fase 1" dan "router dibuat setelah DNS pre-check, juga untuk hostname platform di luar wildcard".
- §2: "Traefik menerbitkan TLS otomatis via HTTP-01" tetap; tambah "DNS platform manual (Hostinger)".
- docs/00-server-environment.md §2/§3: hapus kebutuhan `DNS_API_TOKEN` dan wildcard DNS challenge.

## Riwayat revisi

- 2026-09-23 (H5, keputusan user): router panel admin (`auth-admin`, `auth-other`, `grafana`, `status-admin`) dipindah ke
  entrypoint baru `admin` (:8443, publish `127.0.0.1:8443` host saja). Router tetap `certResolver: le-http`: challenge HTTP-01
  memakai `certificatesResolvers.le-http.acme.httpChallenge.entryPoint: web` (:80), tidak bergantung pada entrypoint router,
  sehingga pembaruan sertifikat hostname itu tetap berjalan. Tidak ada hostname/sertifikat baru; sertifikat yang ada di
  `acme.json` dipakai di :8443 (diverifikasi `openssl s_client -connect 127.0.0.1:8443 -servername grafana.bimacreative.tech`
  → issuer Let's Encrypt). Detail: `docs/03-operations/traefik.md` §Entrypoint `admin`.

## Riwayat revisi — 2026-09-25 (CAA accounturi)
- CAA apex diganti menjadi `0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/3788309616"` (akun
  `le-http` dari `traefik/acme/acme.json`), keputusan user. `issuewild ";"` tidak dapat disimpan di DNS Hostinger — tidak diperlukan
  karena `issue` berlaku untuk wildcard bila `issuewild` absen (RFC 8659 §4.3).
- **Konsekuensi:** bila akun ACME Traefik berganti (acme.json hilang/dibuat ulang, atau pindah ke resolver/akun lain termasuk
  `le-http-staging` untuk hostname `*.bimacreative.tech`), penerbitan/perpanjangan semua hostname platform DITOLAK Let's Encrypt
  (error CAA) sampai record CAA diperbarui dengan account URI baru. Domain client tidak terpengaruh (CAA di zona mereka).
