# Claude Code permission policy — VPS Athera

Tujuan: auto mode tetap dipakai (classifier menilai yang abu-abu), tetapi
(1) perintah read-only dan semua pekerjaan di staging **tidak prompt**,
(2) guardrail brief §0.1 **tidak bisa dilewati** apa pun modenya,
(3) perubahan ke prod **tetap minta persetujuan** (bukan diblokir).

## Berkas

| Berkas | Fungsi |
|---|---|
| `.claude/hooks/bash-policy.sh` | PreToolUse hook: deny / allow / ask berdasarkan teks perintah penuh + `cwd` sesi |
| `.claude/hooks/test-bash-policy.sh` | Uji regresi hook (87 kasus). **Wajib hijau sebelum commit perubahan hook.** |
| `.claude/settings.json` | Permissions + registrasi hook untuk sesi yang dibuka dari `/opt/infra` |
| `~/.claude/settings.json` (root, di luar repo) | Hook + deny/ask yang sama untuk sesi dari `/opt/src/*` dan `/opt/infra-wt/*`, plus `autoMode` |
| `.claude/logrotate/claude-bash-policy` | Rotasi `/var/log/claude-bash-policy.log` |

`autoMode` **hanya** dibaca dari user/managed settings atau `--settings`, **tidak** dari
`.claude/settings.json` proyek. Karena itu blok `autoMode` ada di `~/.claude/settings.json`.

## Pasang / perbarui

```bash
# dari checkout /opt/infra (setelah merge ke main)
.claude/hooks/test-bash-policy.sh                     # harus: fail=0
install -m 600 /dev/null /var/log/claude-bash-policy.log   # sekali; jangan 666 (log memuat teks perintah)
install -m 644 .claude/logrotate/claude-bash-policy /etc/logrotate.d/claude-bash-policy
```

Registrasi hook di `~/.claude/settings.json` menunjuk path absolut
`/opt/infra/.claude/hooks/bash-policy.sh`, jadi berlaku dari direktori mana pun.
Setelah mengubah settings: buka `/hooks` sekali atau mulai sesi baru.

## Urutan evaluasi

1. `permissions.deny`: selalu blok (contoh: `docker volume prune`, Read `*.secret`, `.env`, `acme/`).
2. Hook `bash-policy.sh`:
   - **deny**: prod `compose down/stop/rm/kill` (via `-f`, `cd X &&`, atau cwd sesi);
     `docker restart/stop/rm` container prod (nama persis); `rm -r`/`find -delete` di infra/data;
     dropdb prod; ufw/iptables/nft/`ip link|route` mutasi; cetak/salin/timpa secret;
     `docker compose config` tanpa `--quiet` (mencetak nilai `.env` hasil interpolasi);
     cetak env container; `curl|bash`; `git push --force/--delete`; kcadm realm prod.
   - **allow**: hanya perintah **tunggal** (tanpa `;` `&&` `||` `$(` `` ` `` `>`; pipe hanya ke
     filter read-only) yang read-only, atau semua operasi di staging (`/opt/infra/staging/*`,
     container `*-staging`/`*-stg*`, DB `*_staging`/`demo_*`/`ssotest_*`/`pk_drms_stg`).
   - **ask**: mutasi prod: compose `up/restart/run/build/pull/exec` pada project prod,
     `docker exec/cp` ke container prod, `systemctl` mutasi, `git push`, image/builder prune.
     `ask` dari hook **mengalahkan allow rule** yang lebar (mis. `Bash(docker compose *)` di
     `settings.local.json` lama), jadi prod tetap minta persetujuan.
3. `permissions.ask`: `git push`, `sudo`, `ufw`, `systemctl restart/stop/enable/disable`,
   edit `.claude/` dan `~/.claude/settings.json`.
   **Sengaja tidak ada** `docker compose ... up/down` di sini: ask rule mengalahkan `allow`
   dari hook, sehingga staging ikut prompt. Pemisahan prod/staging hanya di hook.
4. `permissions.allow`: prefix read-only. Interpreter (`python3`/`node`/`npx`/`pnpm`), `find`,
   dan `awk` sengaja tidak di-allow karena bisa menjalankan/menghapus apa saja. Read-only `find`
   di-allow oleh hook (tanpa `-delete/-exec`).
5. Classifier auto mode untuk sisanya, dibantu `autoMode.environment` dan `autoMode.allow`
   di `~/.claude/settings.json`.

## Kalau masih ada yang terblokir padahal sah

- Lihat alasan di prompt atau denial. Riwayat lengkap: `tail -f /var/log/claude-bash-policy.log`.
- Dari classifier: tambah kalimat di `autoMode.allow` / `autoMode.environment` di
  `~/.claude/settings.json` (format: "X diizinkan: alasan").
- Dari hook: tambah pola di bagian **2. ALLOW**, tambahkan kasus di `test-bash-policy.sh`,
  jalankan tes. Jangan hapus bagian hard-deny.
- Dari `ask`: disengaja untuk prod; jawab prompt-nya.
- Kerja panjang di staging tanpa pengawasan:
  `claude -p "..." --permission-mode dontAsk` (prompt otomatis ditolak; allow dari hook
  dan settings tetap berlaku). Flag `--permission-prompts` tidak ada.

## Jangan

- `--dangerously-skip-permissions` di VPS ini. Deny rule dan hook `deny` tetap berlaku di
  mode itu, tetapi semua `ask` (compose up prod, git push, sudo) lolos tanpa tanya.
- `chmod 666` log hook: teks perintah bisa memuat token (`PGPASSWORD=...`, header Authorization).
