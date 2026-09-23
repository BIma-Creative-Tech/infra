# infra — Multi-Client VPS Platform (Odoo CE 19.0 · Next.js · Postgres · Docker)

Repo ini **adalah** `/opt/infra` di VPS (`31.97.50.221`, domain platform
`bimacreative.tech`) — bukan paket untuk disalin ke tempat lain. Semua path di dokumentasi
relatif terhadap root repo ini.

Status: **GATE 1 disetujui** (2026-09-23) — ADR 0001–0006 `accepted`, plan 01–02 disetujui.
Implementasi FASE 2 (bring-up) sedang berjalan; lihat `CHANGELOG.md` untuk progres per rilis.

## Cara pakai

1. **Baca dulu**: `CLAUDE.md` (peran Lead, aturan anti-halusinasi §0, tim & protokol §1,
   arsitektur §3), lalu ADR & plan terkait task yang sedang dikerjakan.
2. **Jalankan Claude Code di repo ini** (model Opus dianjurkan untuk Lead):
   ```
   cd /opt/infra
   claude
   ```
   Lead hanya bicara dengan user dan berhenti di **GATE 1** (approval rencana) dan
   **GATE 2** (handover hasil). Lead mendelegasikan implementasi ke subagent di
   `.claude/agents/*.md` — lihat tabel tim di `CLAUDE.md` §1.
3. **Alur kerja** (§1 CLAUDE.md): FASE 0 Discovery → FASE 1 Planning (ADR + plan) →
   GATE 1 → FASE 2 Execution (per agent, branch `feat/<agent>-<task>`) → FASE 3 QA →
   FASE 4 Docs + Release → GATE 2.
4. **Sebelum implementasi apa pun yang menyentuh sshd/ufw**: ikuti prosedur anti-lockout
   `docs/plans/01-host-bootstrap.md` §5 (S0–S8) persis, tidak boleh lompat langkah.
5. **Darurat / terkunci dari SSH**: `docs/runbooks/emergency-console-access.md`.
6. **Onboarding domain client baru** (web dan/atau mail): `docs/runbooks/client-domain-onboarding.md`.

## Peta dokumen

```
CLAUDE.md                          # peran Lead, aturan §0, tim §1, arsitektur & stack §3
.claude/agents/*.md                # definisi subagent (analyst, infra-engineer, odoo-developer,
                                    # nextjs-developer, qa-security, docs-versioning)
docs/
  00-server-environment.md         # prasyarat VPS (spek, DNS, akun) — beberapa bagian
                                    # ditandai "UPDATED <tanggal>" mengikuti ADR yang disetujui
  discovery/<tanggal>.md           # fakta environment nyata (FASE 0), bukan asumsi
  adr/NNNN-<slug>.md               # keputusan arsitektur — status proposed/accepted/superseded
    0001-stack.md                  #   pin versi seluruh stack + lisensi
    0002-tls-dns-manual.md         #   TLS HTTP-01 per hostname, DNS manual Hostinger
    0003-odoo-no-oca.md            #   dbfilter & SSO Odoo tanpa modul OCA
    0004-capacity.md                #   alokasi RAM/CPU, swap, threshold shared→dedicated
    0005-mail-ipv4.md              #   mail IPv4-only, multi-domain
    0006-backup.md                 #   restic lokal + placeholder S3 + backup provider
  plans/
    00-gate1-summary.md            #   ringkasan yang disetujui user di GATE 1
    01-host-bootstrap.md           #   Ansible bootstrap host + prosedur anti-lockout S0–S8
    02-platform-bringup.md         #   dependency graph FASE 2 (task → agent → depends_on)
  runbooks/
    emergency-console-access.md    #   akses darurat via konsol Hostinger, rollback sshd/ufw
    client-domain-onboarding.md    #   onboarding domain web & mail client baru
  qa/<tanggal>-<fitur>.md          # laporan QA (dibuat saat FASE 3 berjalan)
  _templates/{adr,runbook,bug-report,plan}.md   # template dokumen baru
CHANGELOG.md                       # Keep a Changelog + semver
VERSION                            # versi repo infra saat ini
```

Struktur direktori operasional (`ansible/`, `traefik/`, `postgres/`, dll.) dibuat bertahap
selama FASE 2 sesuai `CLAUDE.md` §3.1 dan `docs/plans/02-platform-bringup.md`; belum semua
ada di repo pada commit ini.

## Catatan versi Odoo

Odoo Community Edition tersedia sebagai `19.0` (bukan 19.4). Versi 19.1–19.4 hanya ada di
Odoo Online (SaaS). Stack ini terkunci ke CE `19.0` dengan tag image yang diverifikasi —
lihat `docs/adr/0001-stack.md`.
