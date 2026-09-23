# ADR 0006 — Backup: restic repo lokal sementara + placeholder S3 + backup provider

- **Status:** proposed (menunggu GATE 1)
- **Tanggal:** 2026-09-23
- **Terkait:** CLAUDE.md §3 (Backup), §3.6 (Data); ADR 0001 (restic 0.19.1), 0004 (disk); keputusan user #7

## Context

- Keputusan user #7: S3 offsite **belum berlangganan**. Backup harus jalan sekarang dengan repo lokal,
  dan remote S3 tinggal diisi kemudian.
- Disk tunggal `/dev/sda` 200 G (`/` 193 G, 1% terpakai) — discovery §1.2.
- restic 0.19.1 docs (`raw.githubusercontent.com/restic/restic/v0.19.1/doc/...`, di-fetch 2026-09-23):
  - repo S3: `s3:https://server:port/bucket_name`, env `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
    opsional `AWS_DEFAULT_REGION` (030_preparing_a_new_repo.rst);
  - `restic copy --from-repo <src>`; env `RESTIC_FROM_REPOSITORY`, `RESTIC_FROM_PASSWORD_FILE`;
    `init --from-repo … --copy-chunker-params` agar deduplikasi efisien antar repo (045_working_with_repos.rst);
  - `backup --stdin-from-command -- <cmd>` + `--stdin-filename` (040_backup.rst) — dump DB tanpa file sementara;
  - `forget --keep-daily/--keep-weekly/--keep-monthly --prune` (060_forget.rst);
  - `check --read-data-subset=n/t` (045_working_with_repos.rst).
- Hostinger (https://www.hostinger.com/support/1583232-how-to-back-up-or-restore-a-vps, di-fetch 2026-09-23):
  snapshot "Only one can be stored at a time", "expires after 1 day", dihapus bila reinstall/restore;
  "Automated weekly backups (and daily if enabled)", "Up to four are retained, two daily and two weekly",
  "stored separately from your server"; daily = add-on berbayar; restore "will completely overwrite all
  current content on your VPS".

## Decision

### Lapisan backup (sementara, sampai S3 tersedia)

| Lapisan | Apa | Frekuensi | Lokasi | Melindungi dari |
|---|---|---|---|---|
| L1 restic lokal | dump DB + filestore + config/secrets + mail | harian | `/opt/infra/backups/restic` (disk sama) | salah hapus, korupsi logis, rollback deploy |
| L2 Hostinger automated backup | seluruh VPS | mingguan (daily jika add-on diaktifkan — **dianjurkan**) | infrastruktur Hostinger, terpisah dari server | disk/VPS hilang (RPO s.d. 7 hari, atau 1 hari dengan add-on) |
| L3 Hostinger snapshot | seluruh VPS | manual, **sebelum perubahan berisiko** (bootstrap Ansible, upgrade major) | Hostinger, kedaluwarsa 1 hari | gagal perubahan (rollback cepat) |
| L4 restic S3 (placeholder) | `restic copy` dari L1 | harian setelah L1 | S3-compatible (TBD) | kehilangan host + akun Hostinger |

**Risiko eksplisit:** L1 berada di disk yang sama → **bukan backup** terhadap kegagalan disk, kompromi
root, atau penghapusan VPS. Sampai L4 aktif, satu-satunya salinan off-host adalah L2 (mingguan,
dikelola provider, retensi pendek, restore = timpa seluruh VPS).

### Isi backup (L1)

1. Postgres: `pg_dumpall --globals-only` + `pg_dump -Fc` **per DB** (semua `<slug>_*`, `keycloak`,
   `control_plane`, `datamart`) dijalankan via `docker exec` dan dialirkan ke
   `restic backup --stdin-from-command --stdin-filename pg/<db>.dump -- …` (01:30, sesuai docs/00 §4.9).
2. Odoo filestore (volume data pool prod & staging) — diambil **setelah** dump DB (konsistensi DB ↔ filestore).
3. Konfigurasi non-git: `/opt/infra/**/.env`, `traefik/acme.json`, realm export Keycloak, DKIM keys,
   config DMS.
4. Data mail (maildir DMS), Uptime Kuma data, Grafana data (dashboard).
5. **Tidak** dibackup: Prometheus/Loki TSDB (bisa hilang), image Docker, cache.

### Konfigurasi (pseudo-config, ditandai ilustrasi — bukan final)

```
# /etc/restic/local.env   (root:root 600)    — ILUSTRASI
RESTIC_REPOSITORY=/opt/infra/backups/restic
RESTIC_PASSWORD_FILE=/etc/restic/password     # 600; salinan WAJIB di password manager user

# /etc/restic/remote.env  (root:root 600)    — PLACEHOLDER, kosong sampai S3 dipilih
RESTIC_REPOSITORY=s3:https://<endpoint>/<bucket>
RESTIC_PASSWORD_FILE=/etc/restic/password-remote
AWS_ACCESS_KEY_ID=<isi-nanti>
AWS_SECRET_ACCESS_KEY=<isi-nanti>
RESTIC_FROM_REPOSITORY=/opt/infra/backups/restic
RESTIC_FROM_PASSWORD_FILE=/etc/restic/password
```
Skrip `scripts/backup.sh` menjalankan langkah copy **hanya jika** `remote.env` terisi (nilai bukan
placeholder); jika kosong → log "REMOTE NOT CONFIGURED" dan kirim alert harian (agar tidak terlupa).
Aktivasi S3 nanti: `restic init --from-repo … --copy-chunker-params` lalu `restic copy`.

### Jadwal & retensi (systemd timer, bukan cron — lebih mudah diamati; keputusan implementer boleh cron sesuai docs/00)

- 01:30 dump DB → 02:00 backup file → 02:30 `restic copy` (jika remote aktif).
- Mingguan (Minggu 03:00): `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune` (§3.6).
- Mingguan: `restic check`; bulanan: `restic check --read-data-subset=1/5` (rotasi subset).
- Bulanan: **restore test** — restore dump satu DB prod acak ke DB `restoretest_<slug>` di cluster
  (role terpisah), jalankan `odoo … -d restoretest_<slug> --stop-after-init` smoke, ukur waktu (RTO),
  drop DB, laporkan ke kanal alert.
- Semua waktu Asia/Jakarta (plan 01 set TZ).

### Target (ESTIMASI, perlu persetujuan user)

- RPO: 24 jam (L1/L4), 7 hari untuk skenario kehilangan host sebelum L4 aktif (1 hari dengan add-on daily Hostinger).
- RTO: ≤ 4 jam per client (restore DB + filestore), ≤ 1 hari rebuild host dari Ansible + L2/L4.

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Tunda backup sampai S3 ada | Tidak ada perlindungan sama sekali terhadap kesalahan logis |
| Hanya andalkan backup Hostinger | Mingguan, retensi pendek, restore all-or-nothing, tidak bisa restore per DB |
| Volume/disk kedua di Hostinger untuk repo lokal | Ketersediaan produk UNVERIFIED; bisa dievaluasi |
| restic dari APT (0.16.4) | Versi lama (ADR 0001) |

## Consequences

- Disk: repo lokal ≈ 1–1,5× data (dedup + kompresi) — masuk anggaran disk ADR 0004; alert `/` > 70%.
- Password repo hilang = backup tidak bisa dibaca → user wajib menyimpan password di password manager.
- Pertanyaan terbuka: provider S3 (Backblaze B2 / Wasabi / MinIO lain), aktifkan add-on daily Hostinger?

## Security implications

- Repo restic terenkripsi (AES-256 per desain restic — detail kriptografi tidak diverifikasi ulang di sesi ini).
- `/opt/infra/backups` 700 root; `/etc/restic/*` 600 root; tidak di git (`.gitignore` sudah mengecualikan `backups/`).
- Dump berisi PII client → hanya root; restore test memakai role DB terpisah dan di-drop setelahnya.
- Kredensial S3 kelak: key dengan scope satu bucket; pertimbangkan object lock/immutability bucket
  (fitur per provider — UNVERIFIED) untuk melindungi dari ransomware yang mendapat root.

## Rollback

Nonaktifkan timer backup (`systemctl disable --now restic-*.timer`). Repo lokal dapat dihapus hanya
dengan konfirmasi eksplisit user (§0.5). Tidak memengaruhi service lain.
