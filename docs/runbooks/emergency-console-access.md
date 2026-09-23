# Runbook — Akses Darurat via Konsol Hostinger & Rollback SSH/UFW

- **Kapan dipakai:** SSH ke VPS (`31.97.50.221`) tidak bisa diakses di port manapun (2221
  maupun 22 transisi), atau ufw memblokir akses yang seharusnya dibolehkan.
- **Terkait:** `docs/plans/01-host-bootstrap.md` §5 (prosedur anti-lockout S0–S8) dan §9
  (rollback per role); `docs/adr/0006-backup.md` (snapshot L3).
- **Prasyarat sebelum prosedur hardening SSH dijalankan** (harus sudah dipenuhi — plan 01 §5
  P1–P4): akses konsol Hostinger sudah diverifikasi, snapshot Hostinger dibuat, sesi SSH root
  lama dibiarkan terbuka. Jika prasyarat ini belum ada saat lockout terjadi, restore snapshot
  (langkah 6) adalah satu-satunya jalan.

## 1. Buka konsol Hostinger

1. Masuk ke hPanel Hostinger → VPS → pilih server → menu **Console/Browser Terminal** (atau
   **VNC**, tergantung yang tersedia di paket).
2. Login sebagai `root` dengan password root yang tersimpan di password manager (dibuat/
   diverifikasi pada plan 01 §5 P2). Ini **bukan** login SSH — jalur ini terpisah dari sshd.
3. Verifikasi kamu benar-benar masuk ke host yang tepat: `hostname` harus mengembalikan
   `srv2001692` (atau hostname yang berlaku saat itu).

## 2. Diagnosa cepat (read-only dulu)

```
systemctl status ssh.socket ssh.service
ss -tlnp | grep -E ':(22|2221)\b'
ufw status verbose
cat /etc/ssh/sshd_config.d/00-hardening.conf 2>/dev/null
journalctl -u ssh --since "-30min" | tail -50
```

Tentukan penyebab sebelum mengubah apa pun: drop-in sshd salah (port/`PermitRootLogin`/
`AllowUsers`), ufw menutup port yang dipakai, atau `ssh.socket` tidak restart dengan benar
setelah perubahan (README.Debian openssh-server: perubahan port butuh
`systemctl daemon-reload && systemctl restart ssh.socket`, bukan `restart ssh` saja).

## 3. Rollback sshd (kembalikan ke port 22, key atau password sesuai kondisi awal)

```
# Dari konsol, sebagai root:
rm -f /etc/ssh/sshd_config.d/00-hardening.conf
sshd -t                                  # pastikan config valid sebelum restart
systemctl daemon-reload
systemctl restart ssh.socket
ss -tlnp | grep sshd                     # harus tampil :22
```

Verifikasi dari laptop (bukan dari konsol):
```
ssh root@31.97.50.221        # harus berhasil (kondisi pra-bootstrap: password auth aktif)
```

Jika `sshd -t` gagal (config lain juga rusak): periksa file di
`/etc/ssh/sshd_config.d/*.conf` satu per satu, pindahkan (jangan hapus) file yang mencurigakan
ke `/root/sshd-backup-<tanggal>/`, ulangi `sshd -t`.

## 4. Rollback ufw (bila ufw penyebabnya)

```
ufw allow 22/tcp
ufw status verbose
```

Jika masih terblokir dan waktu mendesak:
```
ufw disable
```
**Ini menurunkan keamanan host** (§0.9 CLAUDE.md) — catat sebagai insiden di laporan
berikutnya (kapan, alasan, siapa yang mengaktifkan kembali dan kapan `ufw enable` dijalankan
ulang setelah root cause diperbaiki).

## 5. Verifikasi pemulihan penuh

```
# Dari laptop:
ssh root@31.97.50.221 'echo OK'          # atau ssh -p 2221 admin@31.97.50.221 sesuai kondisi
```

Setelah akses pulih, **ulangi prosedur anti-lockout dari S0** (`docs/plans/01-host-bootstrap.md`
§5) — jangan melompat ke tengah prosedur. Investigasi root cause kegagalan sebelumnya dan
catat di ADR/issue bila perlu perubahan desain (mis. urutan role Ansible, dead-man switch).

## 6. Restore snapshot Hostinger (upaya terakhir)

Hanya jika langkah 3–5 tidak memulihkan akses (mis. filesystem rusak, bukan sekadar
konfigurasi). Ini **menimpa seluruh isi VPS** dengan snapshot L3 (`docs/adr/0006-backup.md`),
yang kedaluwarsa 1 hari sejak dibuat — snapshot dari plan 01 §5 P3 hanya valid pada hari
prosedur hardening itu dijalankan.

1. hPanel Hostinger → VPS → **Backups/Snapshots** → pilih snapshot yang dibuat sebelum
   prosedur hardening (P3) → **Restore**.
2. **Konfirmasi eksplisit dari user wajib sebelum langkah ini** (§0.5 CLAUDE.md, destruktif).
3. Setelah restore selesai, verifikasi host kembali ke kondisi pra-bootstrap:
   ```
   ssh root@31.97.50.221
   uname -a; cat /var/run/reboot-required 2>/dev/null; docker version 2>/dev/null
   ```
4. Ulangi seluruh alur dari FASE 0 Discovery bila perlu (state host mungkin berbeda dari
   sebelum restore untuk perubahan yang terjadi setelah snapshot dibuat).

## Catatan

- Firewall panel Hostinger (bila ada fitur firewall terpisah di hPanel, di luar `ufw` di
  dalam VPS) **belum diverifikasi** dampaknya terhadap port 2221 — cek ini juga saat
  diagnosa (langkah 2) bila `ufw status` terlihat benar tapi port tetap tidak bisa diakses
  dari luar.
- Jangan menutup sesi SSH/konsol yang sedang dipakai untuk perbaikan sampai sesi baru
  terbukti berhasil (§5 S0/S4/S7 plan 01) — pola yang sama berlaku untuk pemulihan darurat.
- Setelah insiden selesai, perbarui laporan §1.3 CLAUDE.md ke Lead: apa yang terjadi,
  perintah yang dijalankan, bukti pemulihan, dan tindak lanjut supaya tidak terulang.
- **Panel admin (Keycloak/Grafana/Uptime Kuma) saat SSH tidak tersedia (H5, 2026-09-23):** panel admin hanya di
  entrypoint Traefik `admin` yang di-publish `127.0.0.1:8443` di VPS — tidak bisa dibuka dari internet maupun lewat :443.
  Normalnya: `ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221` (`docs/03-operations/traefik.md` §Entrypoint
  `admin`). Dari konsol Hostinger (root di VPS) yang bisa dilakukan hanya Admin REST via curl, mis.
  `curl --resolve auth.bimacreative.tech:8443:127.0.0.1 https://auth.bimacreative.tech:8443/admin/…` (token akun
  `automation`, `docs/03-operations/keycloak.md`). Pulihkan SSH dulu untuk akses browser.
