# Operasional — Backup restic (T13)

- **Keputusan:** `docs/adr/0006-backup.md` (lapisan L1–L4, isi, jadwal, retensi 7d/4w/3m)
- **Binary:** restic **0.19.1** resmi (`/usr/local/bin/restic`), dipasang role Ansible `backup`
  (`--tags backup`): unduh `SHA256SUMS` + `SHA256SUMS.asc` dari GitHub release, tanda tangan diverifikasi
  dengan kunci restic yang di-vendor di `ansible/roles/backup/files/restic-gpg-key-alex.asc`
  (VALIDSIG kunci primer harus = `CF8F18F2844575973F79D4E191A6868BD3F7A907`, docs v0.19.1
  `020_installation.rst`), lalu sha256 pin di `group_vars/all.yml` dicek dua kali (di `SHA256SUMS` dan
  `get_url checksum`). Diuji: fingerprint salah → task gagal, binary tidak berubah.
- **Terkait:** `postgres.md`, `odoo.md`, CLAUDE.md §3.6 Data

> ### PERINGATAN — password repo
> Repo restic terenkripsi. **Kehilangan `/etc/restic/password` = SELURUH backup TIDAK BISA DIBACA**
> (tidak ada recovery). Salin isinya ke **password manager user** sekarang juga:
> `sudo cat /etc/restic/password` (jalankan di terminal sendiri, jangan tempel ke chat/log/issue).
> File ini sengaja **tidak** ikut di-backup ke repo yang sama (tidak berguna bila repo tak terbaca).

> ### RISIKO — repo lokal = disk yang sama
> Repo `/opt/infra/backups/restic` ada di disk yang sama dengan data. Ini **bukan** backup terhadap
> kegagalan disk, kompromi root, atau VPS terhapus. Sampai remote S3 (L4) aktif, satu-satunya salinan
> off-host adalah backup otomatis Hostinger (L2, mingguan). Setiap run mencatat
> `WARNING: REMOTE NOT CONFIGURED …` ke journal sampai remote diisi.

## Lokasi

| Path | Isi | Mode | Git |
|---|---|---|---|
| `/usr/local/bin/restic` | binary 0.19.1 | 755 root | — |
| `/etc/restic/password` | password repo lokal (acak, dibangkitkan role sekali) | 600 root | **tidak** |
| `/etc/restic/local.env` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, `RESTIC_CACHE_DIR` (tanpa secret) | 600 root | template role |
| `/etc/restic/remote.env` | placeholder remote S3 (kosong) — dari `scripts/restic-remote.env.example`, tidak ditimpa role | 600 root | **tidak** |
| `/opt/infra/backups/restic` | repo restic lokal | 700 root | **tidak** (`backups/` di-ignore) |
| `/var/cache/restic` | cache restic | 700 root | — |
| `scripts/backup.sh` | `run` (default) · `prune` · `check` | 755 | ya |
| `scripts/restore.sh` | restore DB ke DB baru / file filestore ke direktori baru | 755 | ya |
| `scripts/restore-test.sh` | uji restore bulanan (DB + 1 file filestore + `check --read-data-subset`) | 755 | ya |
| `scripts/lib/restic-common.sh` | fungsi bersama, daftar volume filestore (`FILESTORE_VOLUMES`) | 644 | ya |

## Isi snapshot

| Snapshot (tag) | Path di repo | Sumber |
|---|---|---|
| `pg`,`pg-globals` | `/pg/globals.sql` | `docker exec postgres pg_dumpall -U postgres --globals-only` (role + hash password role) |
| `pg`,`db:<db>` — satu snapshot per DB | `/pg/<db>.dump` | `docker exec postgres pg_dump -U postgres -Fc -Z 0 -d <db>` — daftar DB **dinamis** (`pg_database`, bukan template, `datallowconn`; `*_restoretest` dilewati) |
| `files` | `/opt/infra` (kecuali `backups/`, `traefik/logs/`, `ansible/collections/`) + `/var/lib/docker/volumes/<vol>/_data/filestore` per pool | semua `.env`, `*/secrets/`, `traefik/acme/*.json`, `security/crowdsec/data`, realm export, repo git; filestore `odoo_pool_a_data`, `odoo_staging_data` |

- Dump dialirkan langsung (`restic backup --stdin-from-command -- …`, doc 0.19.1 `040_backup.rst`): tidak ada
  file dump sementara; exit code ≠ 0 dari `pg_dump` → restic membatalkan, **tidak ada snapshot** (bukan snapshot kosong).
- Tidak ada password di argv: `pg_dump` via peer auth socket lokal container; password repo via file.
- `-Z 0`: dump tidak dikompresi pg_dump agar deduplikasi restic antar hari efektif (restic mengompresi sendiri).
- `files` diambil **setelah** semua dump DB (urutan ADR 0006). Filestore Odoo content-addressed → file yang ada
  saat snapshot identik dengan yang dirujuk DB.
- **Belum** di-backup (stack belum ada): data mail DMS (T11), Uptime Kuma/Grafana (T14) — tambahkan volumenya
  saat stack itu hadir. Tidak di-backup: TSDB Prometheus/Loki, image Docker, sesi Odoo.
- `/opt/src/control-plane/.env` (di luar `/opt/infra`) **tidak** ikut — lihat pertanyaan terbuka di laporan T13.

## Jadwal (systemd, Asia/Jakarta eksplisit di `OnCalendar`, `Persistent=true`)

| Timer | Kapan | Menjalankan |
|---|---|---|
| `restic-backup.timer` | setiap hari 01:30 | `backup.sh run` — dump DB (01:30) lalu file (± beberapa menit, serial) + remote bila aktif |
| `restic-prune.timer` | Minggu 03:00 | `backup.sh prune` — `forget --host <host> --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune` lalu `check` |
| `restic-restore-test.timer` | tanggal 1, 04:00 | `restore-test.sh` — lihat §Restore test |

Semua job memakai lock `/run/infra-backup.lock` (tidak berjalan bersamaan).
```bash
systemctl list-timers 'restic-*'
journalctl -u restic-backup.service -n 50          # log lengkap run terakhir
journalctl -t infra-backup -t infra-restore -t infra-restore-test -p warning --since -7d   # hanya warning/error
journalctl -t infra-backup --since today | grep RESULT
```
Alert: belum ada kanal alert (observability T14). Sampai itu, `REMOTE NOT CONFIGURED` dan kegagalan tercatat di
journal (prioritas `warning`/`err`) dan unit berstatus `failed` (`systemctl --failed`). T14 wajib mengambil keduanya.

## Menjalankan manual

```bash
sudo systemctl start restic-backup.service          # sama dengan jadwal (disarankan)
sudo /opt/infra/scripts/backup.sh run               # atau langsung (output ke terminal + journal)
sudo /opt/infra/scripts/backup.sh check
```
Sebelum `-u` modul Odoo / perubahan berisiko: jalankan `restic-backup.service` lalu pastikan `RESULT status=ok`.

## Cek snapshot

```bash
sudo -i
set -a; . /etc/restic/local.env; set +a
restic snapshots                                    # semua
restic snapshots --tag db:demo_demo                 # satu DB
restic snapshots --tag files --latest 1
restic ls latest --tag files /opt/infra/traefik     # isi direktori di snapshot
restic check                                        # integritas metadata
restic check --read-data-subset=1/5                 # baca sebagian data
restic stats --mode raw-data                        # ukuran repo
```

## Restore

### Database → DB BARU (aman, default)
```bash
sudo /opt/infra/scripts/restore.sh <db> <target_db> [--snapshot <id>] [--owner <role>]
# contoh uji: sudo /opt/infra/scripts/restore.sh demo_demo demo_demo_restoretest
```
- Target dibuat `TEMPLATE template0`, owner `--owner` (default `postgres`), `REVOKE ALL … FROM PUBLIC`, lalu
  `restic dump … | pg_restore --no-owner --no-acl [--role=<owner>] --exit-on-error`.
- Target **sudah ada → ditolak.** Menimpa hanya dengan `--overwrite` **dan** konfirmasi (ketik nama DB di TTY,
  atau `--confirm <target_db>` persis). Restore dilakukan ke `<target>__rst` dulu; DB lama baru di-`DROP … WITH
  (FORCE)` + rename setelah restore sukses. **Menimpa DB tenant/layanan = destruktif → konfirmasi Lead/user (§0.5).**
- Restore DB tenant Odoo sungguhan (prod): `--owner odoo_pool_a` (atau `odoo_staging`) agar objek dimiliki role
  pool; ekstensi yang butuh superuser bisa gagal di bawah `--role` — **belum diuji**, uji di DB baru dulu.
  Setelah itu filestore (di bawah) dan cek router (`odoo.md`).
- Rebuild cluster total: restore `pg/globals.sql` dulu (`restic dump latest --tag pg-globals /pg/globals.sql |
  docker exec -i postgres psql -U postgres`) lalu tiap DB — **belum diuji**.

### File filestore → direktori BARU
```bash
sudo /opt/infra/scripts/restore.sh --filestore <volume> <db> <target_dir> [--snapshot <id>] [--path <relpath>]
# contoh: satu file
sudo /opt/infra/scripts/restore.sh --filestore odoo_pool_a_data demo_demo /root/fs-restore --path d5/d5a76a0e…
```
Hasil di `<target_dir>/var/lib/docker/volumes/<volume>/_data/filestore/<db>/…`. Skrip menolak target di bawah
`/var/lib/docker` dan direktori yang tidak kosong. Menyalin ke volume live (setelah dicek) = langkah manual,
mis. `docker cp` / `tar` ke container pool (lihat `odoo.md` §Rollback) — destruktif, konfirmasi dulu.

### Config/secret
`restic restore latest --tag files --target /root/cfg-restore --include /opt/infra/postgres/.env` lalu salin
manual. Jangan restore langsung ke `/opt/infra` (menimpa working tree git).

## Restore test

- Otomatis bulanan (`restic-restore-test.timer`) atau manual: `sudo /opt/infra/scripts/restore-test.sh [<db>]`.
- Langkah: pilih DB (acak `*_prod`, fallback `*_demo`) → restore ke `<db>_restoretest` → bandingkan jumlah tabel
  `public` + count `res_users`, `res_partner`, `ir_module_module` → `DROP` DB uji → restore 1 file filestore acak
  (lebih tua dari snapshot) dan bandingkan sha256 → `restic check --read-data-subset=<bulan mod 5 + 1>/5`.
- Hasil: `journalctl -t infra-restore-test | grep RESULT` (`rto_seconds` = durasi total).
- Beda dengan ADR 0006: smoke `odoo -d restoretest_… --stop-after-init` tidak dijalankan — `pg_hba`/`dbfilter`
  pool tidak mengizinkan nama DB `*_restoretest`. Nama DB uji `<db>_restoretest` (bukan `restoretest_<slug>`).

## Menambah remote S3 (L4) nanti

1. Pilih provider + bucket khusus; buat key dengan scope satu bucket (object lock bila tersedia — ADR 0006).
2. Password repo remote: `sudo sh -c 'umask 077; openssl rand -base64 48 | tr -d "\n" > /etc/restic/password-remote'`
   → **simpan juga di password manager**.
3. Isi `/etc/restic/remote.env` (600 root): `RESTIC_REPOSITORY_REMOTE=s3:https://<endpoint>/<bucket>`,
   `RESTIC_PASSWORD_FILE_REMOTE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` (bila perlu).
4. Init remote dengan chunker yang sama (dedup efisien; doc 0.19.1 `045_working_with_repos.rst`):
   ```bash
   sudo -i; set -a; . /etc/restic/remote.env; set +a
   RESTIC_REPOSITORY="$RESTIC_REPOSITORY_REMOTE" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE_REMOTE" \
     restic init --from-repo /opt/infra/backups/restic --from-password-file /etc/restic/password --copy-chunker-params
   ```
5. `systemctl start restic-backup.service` → log harus `remote=ok` (bukan `not-configured`). Jalur `restic copy`
   di `backup.sh` (`copy_to_remote`) **belum pernah dijalankan** — verifikasi saat aktivasi.
6. Tambahkan retensi remote (`forget --prune` ke repo remote) — belum diimplementasikan.

## Rotasi password repo

restic mendukung beberapa key per repo (`restic key list|add|remove`):
```bash
sudo -i; set -a; . /etc/restic/local.env; set +a
umask 077; openssl rand -base64 48 | tr -d '\n' > /etc/restic/password.new
restic key add --new-password-file /etc/restic/password.new
restic key list                                     # catat ID key lama (bukan yang bertanda *)
RESTIC_PASSWORD_FILE=/etc/restic/password.new restic snapshots >/dev/null && echo "key baru OK"
mv /etc/restic/password.new /etc/restic/password
restic key remove <ID-key-lama>
```
Perbarui salinan di password manager **sebelum** `key remove`. (Flag `--new-password-file` dicek di
`restic key add --help` 0.19.1; prosedur rotasi ini belum dijalankan di host.)

## Rollback

`systemctl disable --now restic-backup.timer restic-prune.timer restic-restore-test.timer` (ADR 0006). Repo lokal
dan `/etc/restic/password` **hanya** dihapus dengan konfirmasi eksplisit user (§0.5). Tidak memengaruhi service lain.
