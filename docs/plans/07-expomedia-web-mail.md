# Plan 07 — Client Expomedia Indo Karya: website `web-expomedia` (staging) + domain mail `expomedia.id`

- Status: **STAGING DONE 2026-09-25** (web `0e87369`, mail commit `0997824`); prod menunggu DNS client.
- Riwayat: **GATE 1 APPROVED** (user, 2026-09-25): staging sekarang, prod menunggu DNS client; mailbox wajib + info@/admin@/sales@;
  desain bold-showroom **tema terang** (dark mode tetap via toggle); form kontak aktif via info@expomedia.id.
- Discovery: `docs/discovery/2026-09-25-expomedia.md`. Terkait: plan 03, ADR 0002/0005/0007, runbook `web-client-onboarding.md`,
  `client-domain-onboarding.md`, `docs/03-operations/mail.md` §Menambah domain client.

## 1. Scope
IN: repo `web-expomedia` (dari `web-starter` v0.1.0) di `/opt/src/web-expomedia`; image lokal `web-expomedia:dev-<sha7>` (TEMPORARY,
tanpa GHCR — sama seperti demo starter); provision staging `expomedia.staging.bimacreative.tech` dengan `--contact`; onboarding mail
`expomedia.id` (DKIM, rspamd, mailbox, alias, instruksi DNS); QA; docs/CHANGELOG/versi.
OUT: router prod `expomedia.id`/`www` (menunggu DNS: zona Dewaweb kosong); GHCR/CI repo GitHub `web-expomedia` (belum ada deploy key/token);
Odoo tenant; control plane record (manual nanti); logo/foto asli client (placeholder).

## 2. Arsitektur / keputusan
- Slug `expomedia`; container/router `web-expomedia-staging`; network `web-edge`; limit 256m/0.5 CPU (template).
- Desain (ui-ux-pro-max: pola Hero+Testimonials+CTA, gaya Soft UI Evolution, motion Stagger 300–450 ms; AVOID "generic template + no portfolio"):
  tema terang default; palet hangat berani: primary burnt-orange `#C2410C` (teks putih), accent amber `#F59E0B` (teks gelap), foreground stone-900,
  background stone-50; dark mode diturunkan manual; font **Syne** (heading) + **Manrope** (body) via `next/font/google`. Kontras ≥ 4.5:1 diuji `npm test`.
- Section: Hero (headline besar + kartu angka) → marquee klien (placeholder teks) → Layanan (bento) → **Portofolio grid** (baru; kartu CSS/gradien
  placeholder, kategori) → Proses kerja → Statistik → Testimoni (placeholder, ditandai) → CTA → Footer; `/contact` form aktif.
- Animasi hanya transform/opacity; `prefers-reduced-motion` dihormati; POST hanya Route Handler `/api/contact` (CRS 920420).
- Mail: DKIM selector `mail` (rsa-2048) `expomedia.id`; blok rspamd diaktifkan; mailbox postmaster@, dmarc@, info@, admin@, sales@ (2G);
  alias abuse@→postmaster@; SMTP form kontak = info@ (587 STARTTLS). DMARC awal `p=none` (runbook B1).

## 3. Dependency
```
A (mail: DKIM+mailbox+secret info@)  ─┐
B (web: repo+konten+build image)     ─┴→ C (provision staging --contact) → D (QA) → E (docs/changelog/version)
```
A ∥ B (file berbeda: `/opt/infra/mail/**` vs `/opt/src/web-expomedia/**`).

## 4. Acceptance criteria
- [ ] `docker exec mailserver setup email list` memuat 5 mailbox `@expomedia.id`; `setup alias list` memuat abuse@.
- [ ] Kirim lokal postmaster@→dmarc@ (587 AUTH) → header `DKIM-Signature: … d=expomedia.id; s=mail`.
- [ ] Login `@expomedia.id` + `From: x@bimacreative.tech` → tidak ditandatangani; `MAIL FROM` domain lain → `553`.
- [ ] `docs/clients/expomedia.md` berisi instruksi DNS (MX/SPF/DKIM p=/DMARC + A/www untuk web) siap dikirim ke client.
- [ ] `npm run lint && typecheck && test` hijau di container Node 24; `docker build` sukses; Trivy image tanpa CRITICAL/HIGH (bila image tersedia).
- [ ] `provision-web-client.sh expomedia staging --host expomedia.staging.bimacreative.tech --image web-expomedia:dev-<sha> --contact …` → `RESULT … changed=yes`;
      `curl -I https://expomedia.staging.bimacreative.tech/` 200 + HSTS/CSP/X-Frame; `/api/health` 200.
- [ ] Form kontak: POST JSON valid → 200 dan mail masuk ke info@ (Reply-To pengunjung); honeypot/Origin salah → ditolak.
- [ ] `docker inspect` container: ro rootfs, uid 1001, cap_drop ALL, mem 256m; RAM idle < 120 MiB.
- [ ] Lighthouse mobile (chromium headless lokal) ≥ 85 perf, A11y/BP/SEO ≥ 95.

## 5. Risiko & rollback
- DNS client kosong → prod tidak bisa; risiko client memakai `mail.expomedia.id` (sertifikat tidak cocok) → instruksi tegas.
- Reputasi IP bersama (ADR 0005). Rate limit 30/jam/mailbox, 200/jam/domain.
- Rollback web: `provision-web-client.sh expomedia staging --remove`. Rollback mail: `setup email del`, komentari blok DKIM, `bootstrap.sh`.
- Resource: +256 MiB (web) + ±0 (mail sudah jalan). Disk image ±220 MB.
