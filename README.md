# Paket Prompt Claude Code — Multi-Client VPS Platform

## Isi
- `CLAUDE.md` — dibaca otomatis Claude Code; berisi peran LEAD, aturan anti-halusinasi,
  arsitektur, protokol multi-agent, definition of done.
- `.claude/agents/analyst.md` — Business & System Analyst
- `.claude/agents/odoo-developer.md` — Odoo Developer (CE 19.0)
- `.claude/agents/nextjs-developer.md` — Next.js Developer
- `.claude/agents/qa-security.md` — QA & Security (DevSecOps)
- `.claude/agents/docs-versioning.md` — Docs & Versioning
- `docs/00-server-environment.md` — spek VPS, DNS, akun, bootstrap, urutan bring-up, checklist

## Cara pakai
1. Salin seluruh isi folder ini ke root repo `infra` (yang di-clone dari GitHub).
2. Lengkapi checklist di `docs/00-server-environment.md` §6.
3. Jalankan `claude` di folder repo dengan model Opus, kirim pesan pembuka dari §7.
4. Kamu hanya bicara dengan Lead. Lead akan berhenti di GATE 1 (approval) dan GATE 2 (handover).

## Catatan versi Odoo
Odoo Community Edition tersedia sebagai `19.0` (bukan 19.4). Versi 19.1–19.4 hanya ada di
Odoo Online (saas). Prompt sudah mengunci ke CE 19.0 dengan verifikasi tag image.
