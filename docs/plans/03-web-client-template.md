# Plan 03 — Template web client Next.js (website per client)

- Status: **EXECUTED (W1–W4, 2026-09-25), W5 docs di branch `docs/docs-versioning-w5`. Open items:** CI GitHub `web-starter`
  belum terkonfirmasi hijau (cek user); token baca GHCR untuk VPS (dari user) → demo pindah dari image lokal ke GHCR;
  PageSpeed Insights final (Lighthouse staging median 87 < 90); HSTS platform `max-age=300` (pre-existing, di luar plan ini).
  Lihat §8.
- Riwayat status: APPROVED GATE 1 (user, 2026-09-25): semua pertanyaan §7 sesuai rekomendasi — 1 ya (web-starter → web-<slug>), 2 GHCR, 3 style-src unsafe-inline (style saja), 4 pasang skill, 5 form kontak default off
- Tanggal: 2026-09-25 · Lead: infra Lead · CLAUDE.md §2, §3.1 (`web/clients/<slug>/`), §3.5, §3.6 Next.js, §3.7
- Permintaan user (2026-09-25): template web client Next.js; setiap website memakai Iconsax, anime.js,
  framer-motion (Motion), ui-ux-pro-max-skill, 21st.dev agar tampil modern/outstanding.

## 1. Scope

**IN**
1. **Repo starter `web-starter`** (GitHub `bctech-adm`, private) — basis setiap `web-<slug>` (§3.7).
   Next.js 16.3.x App Router + TypeScript, Node 24, `output: standalone`, Tailwind v4 + shadcn/ui,
   paket UI di §2, halaman contoh (landing: hero animasi, fitur, testimoni, CTA, kontak; 404; sitemap/robots; OG image),
   design token per client (`brand.config.ts`: warna, font, radius, gaya dari ui-ux-pro-max),
   Dockerfile multi-stage non-root, CI (lint, typecheck, test, gitleaks, Semgrep, Hadolint, Trivy, build → GHCR).
2. **Template infra** (repo `infra`):
   - `templates/web-client/docker-compose.yml` (hardening §3.5: read_only + tmpfs, uid 1001, cap_drop ALL,
     no-new-privileges, mem_limit 256m, cpus 0.5, healthcheck, json-file 10m×3, hanya network `proxy`, tanpa port publik).
   - `templates/traefik-web-client.yml` (router `Host()` eksplisit, crowdsec → security-headers → ratelimit-default,
     opsi redirect `www`→apex, sertifikat `le-http`).
   - `scripts/provision-web-client.sh <slug> <prod|staging> --host <fqdn> --image <ref>` (+ `--remove`):
     validasi argumen, DNS pre-check (pola `render-client-route.sh`), render compose ke
     `web/clients/<slug>/` atau `staging/web-clients/<slug>/`, render route, `compose up -d`, smoke test, `RESULT …`.
   - Runbook `docs/runbooks/web-client-onboarding.md`; update `client-domain-onboarding.md` bagian A.
3. **Demo di staging**: `starter.staging.bimacreative.tech` (DNS wildcard `*.staging` sudah ada → tidak perlu DNS baru).
4. **Skill Claude `ui-ux-pro-max`** dipasang di `/root/.claude/skills/ui-ux-pro-max` (pin commit `dcc40ff`, MIT).

**OUT**: website client nyata (per client = task sendiri), CMS/headless, database per website (opsional nanti),
integrasi control plane "provision website" (plan terpisah), payment.

## 2. Library UI — verifikasi (§0.10), 2026-09-25

| Paket | Versi pin | Lisensi | Maintenance | Catatan |
|---|---|---|---|---|
| `motion` (penerus/identik `framer-motion`, repo motiondivision/motion) | 13.4.3 | MIT | rilis 2026-09-24 | pakai `motion/react`; `framer-motion` 13.4.3 = paket yang sama |
| `animejs` | 4.5.0 | MIT | rilis 2026-06-22 | timeline/scroll/SVG di hero; import modular (tree-shake) |
| `iconsax` (resmi iconsax.io, repo iconsax/iconsax-npm) | 0.1.1 | MIT | rilis 2026-07-14 | web component `<iconsax-icon>`, 1200+ ikon gratis, tanpa network runtime; **0.x masih muda**. Paket React komunitas (`iconsax-react` 2021, `iconsax-reactjs` 2025-04) **ditolak** — tidak aktif > 6 bulan. Hanya ikon free (Pro butuh API key berbayar). |
| shadcn/ui CLI + komponen **21st.dev** | pin versi CLI | per komponen | — | komponen **disalin** ke repo (bukan dependency runtime), satu per satu; lisensi + dependensi tiap komponen dicek dan dicatat di `COMPONENTS.md`; komponen tanpa lisensi jelas ditolak |
| ui-ux-pro-max-skill | commit `dcc40ff` (2026-09-21) | MIT | aktif | hanya folder skill `ui-ux-pro-max` (data CSV + skrip Python lokal, tanpa network). **TIDAK** memasang `stack/.mcp.json` (`@latest` tak di-pin) maupun `stack/.claude/settings.json` (`enableAllProjectMcpServers`, izin luas) |

## 3. Keamanan

- CSP via middleware + nonce: `script-src 'self' 'nonce-…' 'strict-dynamic'`, `object-src 'none'`, `frame-ancestors 'none'`.
  **Keputusan dibutuhkan:** Motion & anime.js menulis inline `style` (SSR Motion merender atribut `style`) →
  `style-src 'self' 'unsafe-inline'` (hanya style; script tetap ketat). Risiko: CSS injection terbatas; tidak ada eksekusi script.
- `prefers-reduced-motion` dihormati (Motion `MotionConfig reducedMotion="user"`, anime.js cek media query).
- Form kontak: Zod server-side, honeypot + rate-limit per IP, SMTP mailbox per client (opsional, default **off**).
- Tidak ada secret di `NEXT_PUBLIC_*`; gitleaks pre-commit + CI.

## 4. Acceptance criteria

1. `web-starter` CI hijau (lint, typecheck, unit test, gitleaks, Semgrep, Hadolint, Trivy tanpa CRITICAL/HIGH).
2. Image < 250 MB, RSS idle < 150 MiB (`docker stats`), healthcheck hijau.
3. `https://starter.staging.bimacreative.tech` → 200, sertifikat LE production, header CSP/HSTS ada, 0 error console.
4. Lighthouse mobile: Performance ≥ 90, Accessibility ≥ 95, Best Practices ≥ 95, SEO ≥ 95; CLS < 0.1.
5. `provision-web-client.sh` idempoten (run ke-2 → `changed=no`), `--remove` membersihkan route + container; DNS salah → ditolak.
6. Reduced motion: animasi non-esensial mati (uji emulasi DevTools).

## 5. Task & urutan

| # | Task | Agent | Depend |
|---|---|---|---|
| W1 | Scaffold `web-starter` + paket UI + design token + halaman contoh + Dockerfile | nextjs-developer | GATE 1 |
| W2 | Template compose + route + `provision-web-client.sh` | infra-engineer | GATE 1 (paralel W1) |
| W3 | CI `web-starter` → GHCR | nextjs-developer | W1, repo GitHub dibuat user |
| W4 | Deploy demo `starter.staging` + QA (Lighthouse, header, idempoten) | infra + qa-security | W1–W3 |
| W5 | Docs, runbook, ADR 0007 (UI stack web client), CHANGELOG | docs-versioning | W4 |

## 6. Kapasitas & rollback

- RAM per website ±128–256 MiB (limit 256m). ADR 0004: sisa ≈ 2,5 GiB → 6–8 website (diukur ulang T19).
- Rollback: `provision-web-client.sh <slug> <env> --remove` (hapus route + container, HUP Traefik); image tag lama tetap di GHCR.

## 7. Pertanyaan GATE 1

1. Model repo: satu `web-starter` → di-copy menjadi `web-<slug>` per client? (rekomendasi: ya)
2. Build image: GitHub Actions → GHCR (butuh repo `web-starter` dibuat user + deploy key) — atau build lokal di VPS sementara?
3. CSP `style-src 'unsafe-inline'` (khusus style) untuk Motion/anime.js — setuju?
4. Pasang skill `ui-ux-pro-max` (hanya folder skill, pin commit) di Claude VPS ini — setuju?
5. Form kontak default off (aktif per client bila ada mailbox)?

## 8. Hasil eksekusi (2026-09-25)

- ADR: `docs/adr/0007-web-client-ui-stack.md`. Operasional: `docs/03-operations/web-clients.md`.
- **W1/W3** repo `web-starter` (`bctech-adm/web-starter`, private) `main` = `d5f6148`: `4743b15` scaffold → `3d4444e` CI/GHCR →
  `99301fd` docs → `80f452f` fix tmpfs cache → `abf60f2` hero statis < 768px (keputusan user) → `fec4c76` kurangi hydration
  → `d5f6148` intro anime.js via WAAPI. Rilis `v0.1.0` (tag lokal, W5).
- **W2** infra `039440f` (templates, `provision-web-client.sh`, `lib/traefik-route.sh`, runbook); **W2b** `42b0ebf` network
  `web-edge` 10.100.11.0/24 (keputusan user).
- **W4** `ecdafb8` demo `https://starter.staging.bimacreative.tech`, image **lokal** `web-starter:dev-d5f6148`
  (TEMPORARY sampai VPS punya token baca GHCR).
- Di luar plan 03 tetapi sesi yang sama: `a6024cd` + `5b27540` Keycloak `drms-staging` client `proyekkas-mobile` direct
  access grants (staging saja, keputusan user).

| # | Acceptance (§4) | Status | Bukti / catatan |
|---|---|---|---|
| 1 | CI hijau | **BELUM TERKONFIRMASI** | workflow `.github/workflows/ci.yml` ada; hasil run GitHub menunggu cek user |
| 2 | Image < 250 MB, RSS idle < 150 MiB, healthy | LULUS | ±219 MB (layer tak terkompresi) / 68.7 MB terkompresi; idle ±52–63 MiB; healthcheck `healthy` |
| 3 | staging 200, LE production, CSP/HSTS, 0 error console | LULUS | HSTS dari `security-headers` platform hanya `max-age=300` (pre-existing) |
| 4 | Lighthouse mobile ≥ 90 / ≥ 95 / ≥ 95 / ≥ 95, CLS < 0.1 | LULUS lokal, staging di bawah target | lokal median `d5f6148` 92 (TBT 258 ms), A11y/BP/SEO 100, CLS 0 (`80f452f` 86, `abf60f2` 85); staging diukur dari VPS (load 2.2–4.6) 83/87/91/92/87 median 87; PageSpeed Insights final **pending** |
| 5 | provision idempoten, `--remove`, DNS salah ditolak | LULUS | run ke-2 `changed=no`; `--remove` bersih; DNS salah ditolak |
| 6 | Reduced motion | LULUS | Chromium headless dengan reduced motion dipaksa |

Keputusan tambahan saat eksekusi: form kontak = Route Handler `POST /api/contact` (JSON/multipart, tanpa Server Action —
risiko CRS 920420), Origin check tanpa token CSRF (website tanpa session, keputusan Lead); isolasi `web-edge` terverifikasi
(website tidak menjangkau control-plane/Grafana/Kuma/Keycloak/Postgres; sisa risiko: antar-website saling menjangkau `:3000`).
