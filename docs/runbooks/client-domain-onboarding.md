# Runbook — Onboarding Domain Client Baru (Web & Mail)

- **Kapan dipakai:** client baru ingin memakai domain sendiri untuk web (Odoo/Next.js) dan/
  atau mail di platform ini.
- **Terkait:** `docs/adr/0002-tls-dns-manual.md` (TLS HTTP-01, pre-check DNS),
  `docs/adr/0003-odoo-no-oca.md` (header `X-Sh-Odoo-Db`), `docs/adr/0005-mail-ipv4.md`
  (multi-domain mail), `docs/adr/0004-capacity.md` (threshold shared→dedicated).
- **Prasyarat:** client sudah menjadi `subscription` aktif di control plane (§3.4 CLAUDE.md);
  slug client (`^[a-z0-9-]{3,30}$`) sudah ditentukan.

## A. Onboarding domain web (Odoo dan/atau Next.js)

### A1. Kumpulkan instruksi DNS untuk client

Berikan salah satu dari dua opsi ke client (nilai target dari `docs/adr/0002-tls-dns-manual.md`):

| Tipe | Nama | Nilai |
|---|---|---|
| A | `<subdomain-atau-@>` | `31.97.50.221` |
| **atau** CNAME | `<subdomain>` | `edge.bimacreative.tech` |
| TXT | `_platform-verify.<domain-client>` | `<token verifikasi dari control plane>` |

**Tanpa AAAA** — jangan minta atau terima record AAAA untuk domain client (IPv4-only,
ADR 0002 #4). Bila client sudah punya AAAA yang mengarah ke tempat lain, itu tidak masalah
selama tidak mengarah ke platform ini (Traefik akan menolak request tanpa hostname yang
dikenal — bukan celah keamanan, hanya 404).

### A2. Pre-check DNS sebelum router dibuat (WAJIB — ADR 0002 Decision #5)

```
dig +short A <domain-client> @1.1.1.1
dig +short A <domain-client> @8.8.8.8
dig +short AAAA <domain-client> @1.1.1.1     # harus kosong, atau tidak mengarah ke platform
dig +short TXT _platform-verify.<domain-client> @1.1.1.1
```

Lanjut **hanya jika**: A record dari kedua resolver = `31.97.50.221` (atau CNAME resolve ke
situ), tidak ada AAAA yang bertentangan, dan TXT verifikasi cocok dengan token yang
diterbitkan. Jangan membuat router Traefik sebelum semua ini lolos — router yang dibuat
sebelum DNS benar akan membakar kuota rate-limit Let's Encrypt (`5 authorization
failures/identifier/jam`, ADR 0002).

### A3. Buat router & sertifikat

1. Tulis dynamic config Traefik: `/opt/infra/traefik/dynamic/clients/<slug>.yml` — router
   `Host(\`<domain-client>\`)`, `certResolver: le-http`, middleware `headers.customRequestHeaders`
   yang men-set `X-Sh-Odoo-Db: <slug>_prod` (atau env yang sesuai) dan menghapus
   `X-Odoo-Database` (ADR 0003 D1) — hanya untuk router yang mengarah ke Odoo.
2. Uji dulu dengan resolver ACME **staging** (`le-http-staging`) sebelum pindah ke production
   (plan 02 §3).
3. Verifikasi sertifikat terbit:
   ```
   openssl s_client -connect <domain-client>:443 -servername <domain-client> </dev/null \
     | openssl x509 -noout -issuer -dates
   ```
4. Uji tenant isolation (wajib, ADR 0003 Security implications):
   ```
   curl -s -H 'X-Sh-Odoo-Db: other_prod' https://<domain-client>/web/login   # harus tetap DB <slug>_prod
   curl -s -H 'X-Odoo-Database: other_prod' https://<domain-client>/web/login # tidak berpengaruh
   ```

### A4. Selesai

- Update status `domain` di control plane → `active`.
- Catat di `docs/qa/<tanggal>-<fitur>.md` bila QA memverifikasi ulang.

### Rollback A

Hapus file `/opt/infra/traefik/dynamic/clients/<slug>.yml` → Traefik otomatis berhenti
melayani hostname tsb (hot-reload file provider). Sertifikat yang sudah terbit tidak perlu
dihapus dari `acme.json` segera (kedaluwarsa alami), tapi catat untuk dibersihkan saat
pembersihan berkala (`docs/adr/0002-tls-dns-manual.md` catatan `acme.md`: "Certificates that
are no longer used may still be renewed").

## B. Onboarding domain mail client

Satu hostname server (`mail.bimacreative.tech`) melayani semua domain mail (ADR 0005
Decision #9) — **tidak ada** `mail.<domain-client>` terpisah.

### B1. Instruksi DNS untuk client (template — ADR 0005)

| Tipe | Nama | Nilai | Catatan |
|---|---|---|---|
| MX | `@` | `10 mail.bimacreative.tech` | satu-satunya MX; koordinasikan penghapusan MX lama agar mail tidak hilang saat migrasi |
| TXT | `@` | `v=spf1 include:_spf.bimacreative.tech -all` | hanya **satu** record SPF; tambahkan `include:` lain sebelum `-all` bila client juga kirim dari layanan lain |
| TXT | `mail._domainkey` | `v=DKIM1; k=rsa; p=<kunci publik>` | diberikan **setelah** kunci DKIM dibuat (langkah B2) |
| TXT | `_dmarc` | `v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:dmarc@<domain-client>` | mulai `p=none` 2–4 minggu → `quarantine` → `reject` setelah laporan bersih |
| (klien email) | — | IMAP `mail.bimacreative.tech:993` (TLS); SMTP submission `:465` (TLS) atau `:587` (STARTTLS) | **jangan** pakai `mail.<domain-client>` — sertifikat tidak cocok |

### B2. Generate DKIM & aktifkan domain (di host, oleh infra-engineer/ops)

```
docker exec <dms-container> setup config dkim domain <domain-client>
```

Tambahkan blok domain baru ke `dkim_signing.conf` kustom (ADR 0005 #11), lalu restart Rspamd.
Ambil kunci publik dari output untuk diisikan ke record TXT `mail._domainkey` (langkah B1).

### B3. Buat mailbox client

```
docker exec <dms-container> setup email add <alamat>@<domain-client>
docker exec <dms-container> setup quota set <alamat>@<domain-client> 2G   # sesuai plan subscription
```

### B4. Verifikasi sebelum domain diaktifkan (WAJIB)

```
dig +short MX <domain-client> @1.1.1.1          # → 10 mail.bimacreative.tech.
dig TXT <domain-client> @1.1.1.1                 # SPF memuat include:_spf.bimacreative.tech
dig TXT mail._domainkey.<domain-client> @1.1.1.1 # cocok dengan output setup config dkim
```

Kirim uji ke penguji eksternal (mis. mail-tester — opsional) dan verifikasi header
`DKIM-Signature: d=<domain-client>` + SPF/DKIM/DMARC `pass` di penerima nyata sebelum
mengumumkan mailbox aktif ke client.

### B5. Kesadaran risiko (sampaikan ke client bila relevan)

- Semua domain berbagi satu IP (`31.97.50.221`) → reputasi terpengaruh bersama; satu mailbox
  bocor/spam dapat memengaruhi pengiriman domain lain (ADR 0005 Consequences).
- Rate limit outbound berlaku per mailbox dan per domain (ADR 0005 #13) — pengiriman massal
  di luar rencana akan tertunda/ditolak; hubungi ops untuk menaikkan batas bila perlu.

### Rollback B

Hapus mailbox: `setup email del <alamat>@<domain-client>`. Hapus DKIM: keluarkan blok domain
dari `dkim_signing.conf`, restart Rspamd (mail domain lain tidak terganggu). MX yang sudah
diarahkan client tetap ada sampai client mengubahnya sendiri — mail yang masuk setelah
mailbox dihapus akan bounce (pemberitahuan ke client diperlukan sebelum penghapusan).
