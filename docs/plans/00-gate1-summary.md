# GATE 1 — Ringkasan untuk persetujuan (2026-09-23)

**Keputusan utama (detail di ADR 0001–0006, plan 01–02; semua status `proposed`):**
1. **TLS:** satu resolver `le-http` (HTTP-01 per hostname), tanpa wildcard cert, tanpa AAAA. Kuota LE: 50 sertifikat baru/minggu untuk `bimacreative.tech` (≈14 client baru/minggu).
2. **Odoo tanpa OCA:** modul sendiri `sh_dbfilter_header` (header `X-Sh-Odoo-Db` eksak, fail-closed; Traefik juga menghapus header bawaan Odoo 19 `X-Odoo-Database`) dan `sh_auth_oidc` (code+PKCE). Core `auth_oauth` ditolak: implicit flow, tanpa cek audience/state.
3. **Kapasitas (ESTIMASI):** platform + staging always-on ≈ 13,1 GiB dari 15,6 GiB; sisa ±2,5 GiB. Muat **3–5 client kecil** (±18 user konkuren di pool prod). Swap 4 GiB.
4. **Mail:** satu docker-mailserver, IPv4-only, `mail.bimacreative.tech` untuk semua domain (termasuk `expomedia.id`), DKIM per domain, rate limit per mailbox/domain.
5. **Backup:** restic ke repo lokal (disk yang sama = BUKAN backup sejati) + backup mingguan Hostinger + placeholder S3.
6. **Host:** SSH 2221 key-only, prosedur anti-lockout S0–S8 (kunci dibuktikan dulu, dead-man switch, konsol).
7. **Ganti versi di §3:** Next.js 16 + Node 24 (15.x/22 hampir habis dukungan), Alloy ganti Promtail (EOL), CrowdSec AppSec ganti Coraza (tidak aktif dirawat).

**Risiko top-5:**
1. SSH saat ini: password root aktif, port 22, tanpa firewall — dan kunci SSH belum pernah terbukti dipakai.
2. RAM tipis: satu lonjakan bisa memicu OOM; kapasitas client sangat terbatas tanpa upgrade.
3. Backup belum off-host sampai S3 ada (hanya backup mingguan Hostinger).
4. Satu IP mail untuk semua domain: satu mailbox bocor merusak reputasi semua; PTR belum diset.
5. Modul Odoo sendiri bergantung pada internal `odoo.http` → wajib dites ulang setiap update image.

**Pertanyaan terbuka:**
1. Setujui perbaikan DNS (ADR 0002): hapus AAAA apex, MX jadi hanya `10 mail.bimacreative.tech`, DMARC rua ke `dmarc@bimacreative.tech`, tambah `grafana`, `_spf`, SPF `mail`, CAA `issuewild`?
2. Akses konsol Hostinger sudah dicoba? Aktifkan add-on backup harian Hostinger?
3. Buat agent baru `infra-engineer` untuk tugas infra (belum ada agent untuk itu)?
4. Kanal alert (email/Telegram), GitHub remote, daftar client awal + jumlah mailbox/kuota `expomedia.id`, provider S3 — masih belum ada.
5. Satu kunci untuk `admin` + `deploy`: boleh sementara, kunci `deploy` terpisah saat CI dibuat?
6. Data prod boleh disalin ke staging (butuh anonimisasi)?

**Yang diminta disetujui:** ADR 0001–0006 → `accepted`; plan 01 (bootstrap) dan plan 02 (urutan FASE 2);
usulan perubahan CLAUDE.md (§3 versi/WAF/log shipper/SSO, §3.1 hapus `addons/oca/`, §3.2, §3.5.1 hapus `le-dns`, §0.10 lisensi GPL untuk tool host).
