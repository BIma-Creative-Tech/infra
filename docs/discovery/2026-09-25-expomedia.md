# Discovery — Client Expomedia Indo Karya (website + mail) — 2026-09-25

- Fase: FASE 0 DISCOVERY (Lead, read-only; tidak ada perubahan config/service)
- Waktu observasi: 2026-09-25 ±11:30 UTC
- Konvensi: fakta bersumber perintah dalam `backtick`; yang tidak terobservasi ditandai **ASUMSI** / **TIDAK DAPAT DIVERIFIKASI**.

## 1. Perusahaan (riset publik)

| Item | Nilai | Sumber |
|---|---|---|
| Nama | PT Expomedia Indo Karya | Glints (hasil pencarian), LinkedIn karyawan |
| Bidang | Events Services (jasa pameran/event) | Glints company profile (snippet pencarian) |
| Ukuran | 11–50 karyawan; terverifikasi Glints Juni 2024 | Glints (snippet) |
| Alamat | Jl. Kp. Pintu Air No. 12, RT 003/RW 008, Belendung, Kec. Benda, Kota Tangerang, Banten 15123 | Glints (snippet) |
| Posisi yang pernah dibuka | Admin, Account Executive, Desain Grafis (Tangerang) | Glints job listings |
| Website resmi | **TIDAK DITEMUKAN** (expomedia.id belum aktif; expomedia.com = entitas lain, Eropa) | `dig`, WebSearch |
| Deskripsi layanan, logo, tagline, portofolio, klien | **TIDAK DAPAT DIVERIFIKASI** — halaman Glints/LinkedIn mengembalikan 403/999 untuk fetch otomatis | WebFetch, `curl` dari VPS |

Kesimpulan: konten website harus **draf** (jasa kontraktor pameran/booth, produksi event, brand activation — **ASUMSI** dari
bidang "Events Services" + posisi Desain Grafis/AE) dengan placeholder yang wajib dikonfirmasi client (logo, foto proyek,
daftar klien, angka statistik, testimoni).

## 2. Domain `expomedia.id`

| Item | Nilai | Sumber |
|---|---|---|
| Registrar / status | PT Digital Registra Indonesia; clientTransferProhibited; kedaluwarsa 2027-03-26 | `whois expomedia.id` |
| Nameserver (registry) | ns1/ns2/ns3.dewaweb.com | `whois` |
| Zona di NS Dewaweb | **KOSONG** — SOA/A/MX/TXT/NS tidak ada jawaban | `dig SOA/A/MX/TXT expomedia.id @ns1.dewaweb.com` (dan ns2) |
| Resolusi publik | tidak ada A/MX/AAAA | `dig +short A/MX expomedia.id @1.1.1.1` |

Dampak: **prod (HTTP-01 & mail) terblokir** sampai client (pemilik zona di Dewaweb) menambahkan record. Staging memakai
wildcard platform `*.staging.bimacreative.tech` → `expomedia.staging.bimacreative.tech` = 31.97.50.221, tanpa AAAA
(`dig +short A/AAAA expomedia.staging.bimacreative.tech @1.1.1.1`).

## 3. Platform yang tersedia (fakta host)

| Item | Nilai | Sumber |
|---|---|---|
| Template website | `/opt/src/web-starter` @ `e216fee` (v0.1.0; Next 16.3.6, Motion, anime.js, Iconsax, Magic UI) | `git log` |
| Provisioning | `scripts/provision-web-client.sh <slug> <env> --host --image [--www] [--contact …]` | file skrip |
| Network `web-edge` | ada; anggota `web-starter-staging traefik` | `docker network inspect web-edge` |
| Demo berjalan | `starter.staging.bimacreative.tech`, image lokal `web-starter:dev-d5f6148`, RAM 55 MiB/256 MiB | `docker stats` |
| GHCR | host **belum** login ghcr.io; `gh` tidak terpasang; tidak ada deploy key `web-*` di `/root/.ssh/config` | `cat /root/.docker/config.json`, `which gh` |
| Node di host | tidak ada → build image via `docker build` di VPS (pola TEMPORARY web-starter) | README web-starter |
| Mail | `mailserver` DMS 16.0.1 healthy, 243 MiB/1 GiB; domain aktif hanya `bimacreative.tech` (5 mailbox + alias abuse) | `docker ps`, `setup email list` via config |
| DKIM | hanya `rsa-2048-mail-bimacreative.tech.*`; blok `expomedia.id` di `dkim_signing.conf` **sudah disiapkan sebagai komentar** | `ls data/config/rspamd/dkim`, `config/rspamd/override.d/dkim_signing.conf` |
| SPF platform | `_spf.bimacreative.tech` = `v=spf1 ip4:31.97.50.221 -all`; PTR 31.97.50.221 = mail.bimacreative.tech | `dig TXT _spf…`, `dig -x` |
| Prosedur mail client | `docs/03-operations/mail.md` §Menambah domain client (contoh `expomedia.id`), `runbooks/client-domain-onboarding.md` B | file docs |
| RAM tersisa (kasar) | total 15 GiB, used 4,4 GiB, available 11 GiB; website +256 MiB limit | `free -h` |

## 4. Referensi desain (skill ui-ux-pro-max @ dcc40ff, `/root/.claude/skills/ui-ux-pro-max`)

- `search.py "exhibition booth contractor event organizer …" --design-system --variance 7 --motion 7 --density 4` →
  pola **Hero + Testimonials + CTA**, gaya **Soft UI Evolution** (kontras baik, bayangan halus), motion "Stagger List"
  (300–450 ms), AVOID: "Generic templates + No portfolio". Palet yang dikeluarkan (pink romantis) **tidak relevan**
  (BM25 mengenai "wedding") → palet ditentukan manual di plan.
- `--domain typography "bold modern creative agency"` → Syne/Manrope (creative agency), Outfit/Rubik, Bebas Neue/Source Sans 3 (event pages).
- `--domain color "event exhibition creative agency"` → Creative Agency (pink+cyan) — tidak dipakai (alasan sama).
