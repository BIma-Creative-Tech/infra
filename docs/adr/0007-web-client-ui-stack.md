# ADR 0007 — Stack UI website client (web-starter): Motion, anime.js, Iconsax, komponen 21st.dev/Magic UI, ui-ux-pro-max

- **Status:** accepted (2026-09-25, GATE 1 plan 03 — keputusan user §7 #1–#5; keputusan lanjutan user/Lead dicatat di bawah)
- **Tanggal:** 2026-09-25
- **Penulis:** Docs & Versioning (W5), dari plan 03 + repo `web-starter` @ `d5f6148` + commit infra `039440f`/`42b0ebf`/`ecdafb8`
- **Terkait:** `docs/plans/03-web-client-template.md`; CLAUDE.md §0.10 (lisensi/maintenance), §3.5, §3.6 Next.js, §3.7;
  ADR 0001 (Next.js 16.3.6 / Node 24); repo `web-starter` (`/opt/src/web-starter`, GitHub `bctech-adm/web-starter`, private)
  `COMPONENTS.md`, `docs/design.md`, `src/lib/csp.ts`, `src/app/api/contact/route.ts`;
  `docs/runbooks/web-client-onboarding.md`; `docs/03-operations/web-clients.md`; `docs/03-operations/traefik.md` §Network web-edge

## Context

- Permintaan user (2026-09-25): template website Next.js per client yang memakai Iconsax, anime.js, framer-motion
  (Motion), ui-ux-pro-max-skill dan 21st.dev agar tampil modern.
- CLAUDE.md §0.10: library wajib berlisensi terbuka yang diterima, maintenance aktif (< 6 bulan), alasan dicatat di ADR.
- Verifikasi library dilakukan di plan 03 §2 (2026-09-25); komponen 21st.dev diverifikasi di `web-starter/COMPONENTS.md`:
  registry `https://21st.dev/r/<author>/<component>` mengembalikan `403 {"error":"Authentication required"}` dan file kode
  komponen menunjuk storage privat — kode tidak bisa diambil dari 21st.dev tanpa akun.
- Motion (SSR) dan anime.js menulis atribut `style` inline → CSP `style-src` ketat tanpa `'unsafe-inline'` tidak praktis.
- CrowdSec AppSec memblok Server Action Next.js yang dikirim `Content-Type: text/plain` (CRS 920420 → ban; insiden H6/H7(a),
  `docs/03-operations/crowdsec.md`).
- Sebelum W2b website client akan berada di network `proxy` bersama control plane, Grafana, Uptime Kuma, Keycloak.

## Decision

### 1. Pin library (repo `web-starter`, `package.json` @ `d5f6148`)

| Paket | Versi | Peran |
|---|---|---|
| `next` | 16.3.6 | App Router, `output: standalone` (ADR 0001) |
| `react` / `react-dom` | 19.3.0 | |
| `tailwindcss` / `@tailwindcss/postcss` | 4.3.3 | styling, design token per client (`brand.config.ts`) |
| `motion` | 13.4.3 | animasi React (`motion/react`), penerus/identik `framer-motion` |
| `animejs` | 4.5.0 | animasi intro hero (via adapter WAAPI sejak `d5f6148`) |
| `iconsax` | 0.1.1 | web component resmi `<iconsax-icon>`; subset SVG diekstrak saat build (`scripts/iconsax-subset.mjs`) |
| shadcn/ui CLI `shadcn@4.21.0` | — | komponen `button`, `input`, `textarea`, `label` disalin ke repo |

### 2. Komponen "21st.dev" — disalin dari upstream Magic UI

Empat komponen (Marquee, Bento Grid, Number Ticker, Animated Grid Pattern) dipilih dari halaman 21st.dev; lisensi/author
diambil dari data halaman publik 21st.dev, **kode diambil dari repo upstream** yang ditunjuk halaman tersebut
(`magicuidesign/magicui`, commit `d7207e5692d14c00dceafa8488d6d01f197fa0e4`, MIT), disalin ke
`src/components/ui-21st/` dan dimodifikasi (token brand, a11y, reduced motion, performa). Bukan dependency runtime, tanpa
request runtime ke 21st.dev. Border Beam ditolak (menganimasikan `offset-distance`, bukan transform/opacity). Detail per
komponen: `web-starter/COMPONENTS.md`.

### 3. Skill desain `ui-ux-pro-max`

Dipasang hanya folder skill di `/root/.claude/skills/ui-ux-pro-max` (pin commit `dcc40ff`, MIT; keputusan user §7 #4).
Konfigurasi MCP (`stack/.mcp.json`, memakai `@latest`) dan `stack/.claude/settings.json` (`enableAllProjectMcpServers`)
**sengaja tidak** dipasang. Skill hanya alat desain saat development — tidak ada di image/runtime.

### 4. Lisensi

| Komponen | Lisensi | Sumber verifikasi |
|---|---|---|
| Next.js 16.3.6 | MIT | ADR 0001 |
| React 19.3.0 | MIT | UNVERIFIED di sesi ini (lisensi React umum diketahui MIT; tidak di-fetch ulang) |
| Tailwind CSS 4.3.3 | MIT | UNVERIFIED di sesi ini |
| `motion` 13.4.3 | MIT | plan 03 §2 |
| `animejs` 4.5.0 | MIT | plan 03 §2 |
| `iconsax` 0.1.1 | MIT | plan 03 §2, `COMPONENTS.md` |
| Magic UI @ `d7207e5` (4 komponen) | MIT (`Copyright (c) Magic UI`) | `COMPONENTS.md` (GitHub API `license.spdx_id` + `LICENSE.md` pada commit) |
| shadcn/ui CLI 4.21.0 | MIT | `COMPONENTS.md` |
| `radix-ui` 1.6.7 | MIT | `COMPONENTS.md` |
| `class-variance-authority` 0.7.1 | Apache-2.0 | `COMPONENTS.md` |
| ui-ux-pro-max skill @ `dcc40ff` | MIT | plan 03 §2 |

### 5. CSP (`src/lib/csp.ts`)

- `script-src`: nonce per request + `'strict-dynamic'`, tanpa `'unsafe-inline'`.
- `style-src 'unsafe-inline'` — **disetujui user** (plan 03 §7 #3), khusus style, karena Motion/anime.js menulis `style` inline.
- CSP dikirim aplikasi (nonce), bukan Traefik; header keamanan lain dari middleware `security-headers` platform.

### 6. Form kontak

Route Handler `POST /api/contact` (JSON/multipart) — **tanpa Server Action** (menghindari CRS 920420 `text/plain` →
ban). Default **off** (keputusan user §7 #5; aktif per client dengan mailbox SMTP, `docs/runbooks/web-client-onboarding.md`).
Proteksi: pemeriksaan `Origin` (same-origin terhadap `SITE_URL`) + body JSON/multipart (lainnya 415), validasi Zod,
honeypot, rate-limit in-app (per IP & global) + Traefik 5/menit/IP. **Tanpa token CSRF** — website tidak punya session/cookie auth (keputusan Lead).

### 7. Animasi & performa

- `prefers-reduced-motion: reduce` dihormati (media query di `globals.css`, `src/lib/use-motion-prefs.ts`,
  `scroll-enhancer.tsx`, `hero/hero-animator.tsx`); diverifikasi di Chromium headless dengan reduced motion dipaksa.
- Layar < 768px: hero tanpa animasi ambient (gradien statis) — **keputusan user** (`abf60f2`).
- Pengurangan hydration (`fec4c76`: server component, pulau client kecil, kerja saat idle; `d5f6148`: intro anime.js
  via adapter WAAPI): first-load JS `/` 160 → 146 KB gzip, `/contact` 249 → 149 KB gzip.

### 8. Isolasi network `web-edge` (W2b, `42b0ebf`, keputusan user 2026-09-25)

Website client hanya di network `web-edge` (bridge 10.100.11.0/24; traefik + website client), bukan `proxy`. Diverifikasi:
container website tidak bisa menjangkau control-plane, Grafana, Uptime Kuma, Keycloak, Postgres.

### 9. Model repo & image

`web-starter` → disalin menjadi `web-<slug>` per client (§7 #1). Image dibangun GitHub Actions → GHCR
`ghcr.io/bctech-adm/web-starter` (§7 #2): push `main` → `:sha-<12>`, tag `vX.Y.Z` → `:X.Y.Z` (harus = `version` di
`package.json`).

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| `iconsax-react` (2021), `iconsax-reactjs` (2025-04) — paket React komunitas | Tidak aktif > 6 bulan (§0.10); bukan paket resmi |
| Iconsax Pro | Butuh API key berbayar |
| Menarik komponen via registry 21st.dev (`shadcn add https://21st.dev/r/...`) | Registry kini butuh autentikasi (403) dan kode di storage privat → tidak bisa di-pin/diaudit; diganti sumber upstream Magic UI ter-pin commit |
| Border Beam (Magic UI, MIT) | Menganimasikan `offset-distance` (bukan transform/opacity) → melanggar aturan animasi template |
| `framer-motion` sebagai nama paket | Paket yang sama dengan `motion` 13.4.3; `motion/react` dipakai |
| CSP `style-src` tanpa `'unsafe-inline'` (nonce/hash style) | Motion SSR & anime.js menulis atribut `style` inline; nonce tidak berlaku untuk atribut style |
| Form kontak via Server Action | Server Action `text/plain` kena CRS 920420 → ban IP 4 jam; butuh pengecualian AppSec per host |
| Token CSRF untuk form kontak | Tidak ada session/cookie auth yang bisa dibajak; Origin check + JSON/multipart dianggap cukup (keputusan Lead) |
| Website di network `proxy` | Website bisa menjangkau control-plane/Grafana/Kuma/Keycloak |
| Network per client (`web-edge-<slug>`) | Ditunda: butuh `docker network connect` traefik per client; opsi masa depan |
| Memasang MCP config & settings ui-ux-pro-max | `@latest` tidak di-pin (§0.12) dan `enableAllProjectMcpServers` memberi izin luas |

## Consequences

- Komponen yang disalin = kode milik repo: update upstream harus di-port manual (catat commit baru di `COMPONENTS.md`).
- `iconsax` 0.x masih muda — API bisa berubah; subset build-time membatasi dampak.
- Ukuran image web-starter ±219 MB (layer tak terkompresi) / 68.7 MB terkompresi; RAM idle ±52–63 MiB (limit 256m).
- Lighthouse mobile (lokal, median): `80f452f` 86, `abf60f2` 85, `d5f6148` 92 (TBT 258 ms); A11y/BP/SEO 100, CLS 0.
  Staging `d5f6148` diukur dari VPS (load host 2.2–4.6): 83/87/91/92/87, median 87. PageSpeed Insights final belum dijalankan.
- Sampai VPS punya token baca GHCR, demo staging memakai image lokal `web-starter:dev-d5f6148` (TEMPORARY).
- Tim harus memakai Route Handler (bukan Server Action) untuk POST publik di website client, atau meminta pengecualian AppSec.

## Security implications

- `style-src 'unsafe-inline'`: risiko CSS injection terbatas (mis. exfiltrasi via selector/background URL bila ada injeksi
  HTML); tidak ada eksekusi script — `script-src` tetap nonce + `strict-dynamic`.
- Tanpa CSRF token: bergantung pada pemeriksaan `Origin` (403 bila bukan same-origin) — `multipart/form-data` bisa dikirim
  form lintas situs, jadi pemeriksaan Origin adalah kontrol utamanya; content-type selain JSON/multipart → 415. Rate-limit
  Traefik + rate-limit in-app (per IP & global) + honeypot membatasi spam.
- Sisa risiko diterima (W2b): website di `web-edge` saling bisa menjangkau `:3000` satu sama lain.
- HSTS dari `security-headers` platform saat ini `max-age=300` (pre-existing, bukan bagian plan 03).
- Tidak ada secret di `NEXT_PUBLIC_*`; password SMTP lewat Docker secret file; gitleaks pre-commit + CI.

## Rollback

- Library: kembalikan versi di `package.json`/`package-lock.json` repo `web-<slug>` → build ulang → deploy tag lama
  (`docs/03-operations/web-clients.md` §Rollback).
- Komponen 21st.dev/Magic UI: hapus file di `src/components/ui-21st/` + barisnya di `COMPONENTS.md`.
- Skill: hapus `/root/.claude/skills/ui-ux-pro-max` (tidak berdampak ke runtime).
- `web-edge`: lihat `docs/03-operations/traefik.md` §Network web-edge.

## Perubahan CLAUDE.md yang diusulkan (butuh persetujuan user; penulis ADR tidak mengedit)

Tidak ada (tabel §3 hanya memuat stack platform; library UI website client dicatat di ADR ini).
