# 04 — Development

## CI (GitHub Actions) — security, lint, test, build

Tiga repo (org `bctech-adm`, private) masing-masing punya satu workflow
`.github/workflows/security.yml` (nama workflow: **`security`**). Ditambahkan 2026-09-24
(menutup temuan QA-T17A-04, `docs/qa/2026-09-23-t17a-platform-core.md`).

### Trigger

| Event | Keterangan |
|---|---|
| `push` ke `main` | setiap merge/push ke `main` |
| `pull_request` | setiap PR (semua branch target) |
| `schedule` `17 2 * * 1` | Senin 02:17 UTC (09:17 WIB) — menangkap CVE/rule baru walau tidak ada commit |
| `workflow_dispatch` | jalankan manual dari tab Actions |

Hardening workflow: `permissions: contents: read` (token `GITHUB_TOKEN` hanya baca),
`actions/checkout` dengan `persist-credentials: false`, semua `uses:` di-pin ke commit SHA,
semua tool dijalankan sebagai container ter-pin **tag + digest** (tidak ada `latest`),
tidak ada secret yang dipakai, `concurrency` membatalkan run lama di ref yang sama,
`timeout-minutes` per job. Runner: `ubuntu-24.04`.

### Job per repo (= nama status check untuk branch protection)

| Job / check | infra | odoo-addons-shared | control-plane | Isi |
|---|:-:|:-:|:-:|---|
| `actionlint` | ✔ | ✔ | ✔ | lint workflow (+ shellcheck blok `run:`) |
| `gitleaks` | ✔ | ✔ | ✔ | secret scan **seluruh history** (`fetch-depth: 0`), memakai `.gitleaks.toml` bila ada |
| `semgrep` | ✔ | ✔ | ✔ | SAST; gagal bila ada temuan severity `ERROR`/`HIGH`/`CRITICAL` (WARNING/INFO hanya dilaporkan) |
| `trivy-fs-config` | ✔ | ✔ | ✔ | `trivy fs` (vuln + secret, HIGH/CRITICAL, `--ignore-unfixed`) + `trivy config` (Dockerfile/Containerfile/IaC, HIGH/CRITICAL) |
| `hadolint` | ✔ | — | ✔ | lint Dockerfile/Containerfile, gagal pada `warning` ke atas |
| `shellcheck` | ✔ | — | — | semua `*.sh` ter-track + `.githooks/*`, `-x` (ikuti `source`), gagal pada `warning` ke atas |
| `lint-python` | — | ✔ | — | compile semua `*.py` (Python 3.12) + `ruff check` (config `ruff.toml`) |
| `odoo-tests` | — | ✔ | — | `test/run-tests.sh sh_dbfilter_header sh_auth_oidc` (odoo:19.0-20260908 + postgres:16.15, jaringan internal) + cek log `0 failed, 0 error(s) of N tests` |
| `build-test` | — | — | ✔ | Node 24.21.0: `npm ci` → `npm audit --audit-level=high` → lint → typecheck → test → build |
| `docker-image` | — | — | ✔ | `docker build` + `trivy image` (HIGH/CRITICAL, `--ignore-unfixed`) |

Ruleset Semgrep:
- infra: `p/owasp-top-ten p/python p/javascript p/dockerfile p/docker-compose p/secrets r/bash`
  (catatan: `p/bash` tidak ada di registry — 404 — yang ada `r/bash`).
- odoo-addons-shared: `p/owasp-top-ten p/python p/secrets`.
- control-plane: `p/owasp-top-ten p/typescript p/javascript p/dockerfile p/secrets`.
- Semgrep default `.semgrepignore` melewati direktori `test/`/`tests/`.

Catatan: `trivy config` tidak mendukung file docker-compose; compose dicakup Semgrep
`p/docker-compose` (infra). Repo infra tidak men-checkout submodule `odoo-addons-shared`
(dipindai di repo-nya sendiri).

### Versi yang di-pin (diverifikasi 2026-09-24)

| Komponen | Pin |
|---|---|
| `actions/checkout` | `3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1) |
| `actions/setup-node` | `820762786026740c76f36085b0efc47a31fe5020` (v7.0.0) |
| actionlint | `rhysd/actionlint:1.7.12@sha256:b1934ee5…9315667` |
| gitleaks | `zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0…8abbb7f` |
| Semgrep | `semgrep/semgrep:1.177.0@sha256:acaac22f…d81198` |
| Trivy | `aquasec/trivy:0.74.0@sha256:62b1e65e…87187c1969` |
| Hadolint | `hadolint/hadolint:v2.15.1@sha256:32dac941…fe68a12d` |
| ShellCheck | `koalaman/shellcheck:v0.11.0@sha256:61862eba…f925a8d` |
| Ruff | `ghcr.io/astral-sh/ruff:0.13.0@sha256:300809dc…cb495706` |
| Python (compile) | `python:3.12-slim@sha256:2f17fc04…ebbe06a9` |
| Node (build-test) | `24.21.0` (sama dengan base image Dockerfile control-plane) |

Digest lengkap ada di blok `env:` tiap workflow. `gitleaks/gitleaks-action` **tidak** dipakai:
action itu mewajibkan `GITLEAKS_LICENSE` untuk repo milik organisasi — binary gitleaks
dijalankan langsung dari container resmi.

Update versi: cek rilis resmi, ambil digest (`docker buildx imagetools inspect <image:tag>`)
atau SHA tag (`git ls-remote https://github.com/actions/<nama> refs/tags/<tag>`), ubah `env:` /
`uses:`, jalankan actionlint + scan lokal, lalu PR.

### Cara membaca hasil

1. GitHub → repo → tab **Actions** → workflow **security** → pilih run (per commit/PR).
2. Setiap job tampil sebagai check terpisah; di PR juga tampil di bagian "Checks".
3. Job merah → buka job → step yang gagal:
   - `gitleaks`: baris `Finding`/`RuleID`/`File`/`Commit` (nilai secret di-`--redact`). Secret
     nyata → **rotasi dulu**, baru bersihkan history. False positive → allowlist SEMPIT di
     `.gitleaks.toml` (regex eksak, dengan komentar alasan), bukan mematikan rule.
   - `semgrep`: step "gagal bila ada temuan…" mencetak `SEVERITY  rule-id  path:line`.
     False positive → komentar `# nosemgrep: <rule-id>` di baris tersebut + alasan.
   - `trivy-*`/`docker-image`: tabel paket/CVE/versi perbaikan. Perbaiki dengan bump
     dependency/base image. Pengecualian hanya via `.trivyignore` per-CVE dengan alasan + tanggal
     tinjau ulang.
   - `hadolint`/`shellcheck`: kode aturan (`DLxxxx`/`SCxxxx`) + baris. Pengecualian hanya
     per-baris/per-file (`# hadolint ignore=…`, `# shellcheck disable=…`) dengan alasan.
   - `odoo-tests`: cari `FAIL`/`ERROR` di log; log lengkap di output step.
4. VPS tidak punya token GitHub, jadi hasil Actions dibaca user di UI GitHub.

### Menjalankan setara secara lokal (VPS)

Gunakan clone bersih (sama seperti runner, tanpa file ter-ignore seperti `.env`):

```sh
git clone -q /opt/infra /tmp/ci-infra && cd /tmp/ci-infra
docker run --rm -u 0 -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:1.7.12@sha256:<digest> -color
docker run --rm -v "$PWD:/repo:ro" zricethezav/gitleaks:v8.30.1@sha256:<digest> git /repo --no-banner --redact
# semgrep / trivy / hadolint / shellcheck: salin perintah `docker run` dari step workflow
```

Skrip QA yang lebih luas (termasuk trivy image container live): `qa/pipeline-scans.sh`.

### Branch protection — langkah untuk user (butuh akses admin repo; VPS tidak punya token)

Lakukan untuk **ketiga** repo (`infra`, `odoo-addons-shared`, `control-plane`). Pastikan
workflow `security` sudah **pernah berjalan minimal sekali** di `main` (push commit ini),
supaya nama check muncul di daftar pencarian.

> **Cek plan GitHub dulu.** Menurut docs GitHub, branch protection/rulesets untuk repo
> **private** milik organisasi membutuhkan plan **GitHub Team** (atau Enterprise); di plan
> Free, fitur ini hanya untuk repo public (banner "availability" di halaman docs *About
> protected branches*; belum diverifikasi terhadap plan org `bctech-adm`). Bila menu di bawah
> tidak bisa disimpan/terkunci, pilihannya: upgrade org ke Team, atau tetap disiplin manual
> (PR + CI hijau) tanpa enforcement. Workflow CI tetap berjalan di plan Free (kuota menit
> Actions private repo berlaku).

GitHub → repo → **Settings → Branches → Add branch protection rule** (atau
**Settings → Rules → Rulesets → New branch ruleset** dengan target `main` — isinya setara):

1. **Branch name pattern**: `main`.
2. ✔ **Require a pull request before merging**.
   - **Require approvals**: pilih salah satu —
     - `1` approval: sesuai CLAUDE.md §3.6 (review oleh orang kedua). **Trade-off untuk solo
       dev:** GitHub tidak mengizinkan penulis PR meng-approve PR sendiri, jadi merge akan
       terblokir kecuali ada kolaborator kedua atau admin memakai bypass.
     - `0` approval (tetap wajib PR): alur tetap lewat PR + CI hijau, tanpa reviewer kedua.
       Direkomendasikan selama tim = 1 orang; naikkan ke 1 saat ada anggota kedua.
   - ✔ Dismiss stale approvals when new commits are pushed (bila approval ≥ 1).
3. ✔ **Require status checks to pass before merging** → ✔ *Require branches to be up to date
   before merging* → tambahkan check (ketik nama job):
   - **infra**: `actionlint`, `gitleaks`, `semgrep`, `trivy-fs-config`, `hadolint`, `shellcheck`
   - **odoo-addons-shared**: `actionlint`, `gitleaks`, `semgrep`, `trivy-fs-config`,
     `lint-python`, `odoo-tests`
   - **control-plane**: `actionlint`, `gitleaks`, `semgrep`, `trivy-fs-config`, `hadolint`,
     `build-test`, `docker-image`
4. ✔ **Require conversation resolution before merging** (opsional, dianjurkan).
5. ✔ **Require signed commits** (opsional, dianjurkan §3.7 — butuh kunci GPG/SSH signing
   di setiap mesin yang commit, termasuk VPS).
6. **Do not allow bypassing the above settings** / *Include administrators*: aktifkan bila
   ingin aturan berlaku juga untuk admin (lebih aman; admin tidak bisa push langsung).
   Konsekuensi: push langsung ke `main` dari VPS (deploy key) akan **ditolak** — semua
   perubahan harus lewat branch + PR. Bila alur VPS masih push langsung ke `main`, biarkan
   bypass untuk admin sementara dan catat sebagai TEMPORARY.
7. ✘ **Allow force pushes** — biarkan nonaktif (block force push).
8. ✘ **Allow deletions** — biarkan nonaktif.

Setelah aturan aktif, alur kerja: `git switch -c feat/…` → commit (hook gitleaks lokal) →
`git push origin feat/…` → buka PR di GitHub → tunggu semua check hijau → merge.
