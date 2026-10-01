# Plan 09 — Website company profile client pertambangan (`web-tambang`, demo staging)

- Status: **DIHAPUS 2026-10-01** (keputusan user: `provision-web-client.sh tambang staging --remove`; router & container
  dihapus, render dir + `.env` + image `web-tambang:dev-59dcd4c` + repo tetap ada → hidupkan lagi dengan provision ulang).
  Sebelumnya: **STAGING LIVE 2026-09-26** — `https://tambang.staging.bimacreative.tech`, image lokal `web-tambang:dev-59dcd4c`
  (repo `/opt/src/web-tambang` main `59dcd4c`, 117 test lulus). Lighthouse mobile (12.8.2, 6 halaman): perf 86–94, A11y 100, BP 100,
  SEO 66–69 **hanya** karena `noindex` staging (audit is-crawlable, disengaja); CLS 0. RAM idle ±69 MiB.
  Sertifikat sempat gagal (CAA accounturi tidak cocok akun ACME baru; ditangani infra Lead, CAA di-unpin 2026-09-26).
- Riwayat: **GATE 1 APPROVED** (user, 2026-09-25: "ok lanjut" atas usulan default).
- Konteks: opportunity client pertambangan; fokus **hanya** company profile (Odoo diabaikan, mail di luar scope).
  Identitas client **belum diberikan** (nama PT, domain, komoditas, lokasi) → dibangun sebagai **demo pitch** dengan
  brand fiktif `PT Contoh Tambang Nusantara` + komoditas asumsi **batubara**; semua identitas di `src/config/brand.ts`
  dan teks di `src/config/content.<lang>.ts` sehingga penggantian = edit config, bukan kode.
- Terkait: plan 03 (template), plan 07 (pola Expomedia), ADR 0007, runbook `web-client-onboarding.md`.

## 1. Scope
IN: repo `/opt/src/web-tambang` dari `web-starter` (seperti Expomedia); dwibahasa **ID (default, `/`) + EN (`/en`)**;
halaman: Beranda, Tentang (visi-misi, sejarah, manajemen), Operasi & Layanan, Wilayah Operasi (peta konsesi ilustratif),
K3/HSE & Lingkungan, Keberlanjutan/CSR, Legalitas & Sertifikasi, Berita (statis), Karier (statis), Kontak;
foto stok berlisensi Unsplash License (diunduh ke `public/`, atribusi di `docs/photos.md`) — diganti foto asli client;
image lokal `web-tambang:dev-<sha7>` (TEMPORARY tanpa GHCR, sama seperti Expomedia); staging `tambang.staging.bimacreative.tech`.
OUT: prod/domain client, mailbox & form kontak SMTP (form **mati**, tampil email/WhatsApp), CMS, Odoo, GHCR/CI GitHub.

## 2. Desain
Korporat-industrial "kokoh & terpercaya": tema **terang** default + dark via toggle; palet charcoal + tembaga/amber;
foto lapangan besar, angka pencapaian beranimasi (produksi, luas konsesi, jam kerja aman), timeline sejarah.
Dipilih via skill ui-ux-pro-max, dicatat di `docs/design.md`. Kontras WCAG ≥ 4.5:1 diuji `npm test`.

## 3. Task
A (build web: repo + konten + i18n + foto + test + image) → B (provision staging) → C (QA: header, Lighthouse, reduced motion) → D (docs/CHANGELOG).

## 4. Acceptance criteria
- [ ] `npm run lint && typecheck && test` hijau (container Node 24); `docker build` sukses; image < 250 MB.
- [ ] Semua halaman ID & EN → 200; `hreflang` alternates + sitemap memuat kedua bahasa; staging `noindex`.
- [ ] `provision-web-client.sh tambang staging --host tambang.staging.bimacreative.tech --image web-tambang:dev-<sha>` → RESULT ok;
      `curl -I` 200 + HSTS/CSP/X-Frame; `/api/health` 200.
- [ ] Container: ro rootfs, uid 1001, cap_drop ALL, mem 256m; RAM idle < 120 MiB.
- [ ] Lighthouse mobile ≥ 85 perf, A11y/BP/SEO ≥ 95; 0 error console; reduced motion dihormati.

## 5. Kapasitas, risiko, rollback
+256 MiB RAM (available 11 GiB, 2026-09-25), disk image ±250 MB + foto (dikompres, total < 5 MB).
Risiko: konten/angka fiktif terbaca sebagai fakta → footer staging "Situs demo — konten contoh" + semua nilai ditandai PLACEHOLDER.
Rollback: `provision-web-client.sh tambang staging --remove`.
