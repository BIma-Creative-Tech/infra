# Plan 01 — Host bootstrap & hardening (Ansible)

- **Status:** proposed (menunggu GATE 1) · **Tanggal:** 2026-09-23 · **Penulis:** Analyst
- **Keputusan user yang dipakai:** #2 (reboot oleh Lead sebelum FASE 2), #5 (SSH port **2221**),
  #6 (Ansible lokal **dan** dari laptop/CI — satu playbook, dua inventory), #4 (spek tetap)
- **Fakta dari Lead (2026-09-23):** kunci SSH `admin` dan `deploy` = kunci ed25519 yang sama dengan
  yang ada di `/root/.ssh/authorized_keys`. Journal hanya mencatat `Accepted password for root`
  dari `103.108.130.11` → **kunci belum pernah terbukti dipakai**.
- **Terkait:** CLAUDE.md §3.6 Host, §0.5, §0.9; docs/00 §4; discovery §1.5; ADR 0001, 0004, 0006

## 1. Scope

IN: user `admin`/`deploy`, sshd (port 2221, key-only, no root), ufw, fail2ban, auditd, chrony,
sysctl, swap 4 GiB, TZ `Asia/Jakarta`, locale `en_US.UTF-8`, cloud-init ssh_pwauth, Docker CE +
compose plugin + `daemon.json`, unattended-upgrades, struktur `/opt/infra`, prasyarat CrowdSec host
(repo APT; firewall bouncer dipasang setelah container CrowdSec ada — plan 02).
OUT: service platform (plan 02), backup timers (plan 02 / ADR 0006), reboot (Lead, sebelum ini).

## 2. Fakta host yang memengaruhi desain (diverifikasi 2026-09-23, read-only)

| Fakta | Sumber | Implikasi |
|---|---|---|
| sshd memakai **socket activation**: `ssh.socket` enabled+active, `ssh.service` disabled; generator `/usr/lib/systemd/system-generators/sshd-socket-generator` ada | `systemctl is-enabled/is-active`, `ls` | Ubah port **harus** diikuti `systemctl daemon-reload && systemctl restart ssh.socket` (README.Debian openssh-server 1:9.6p1-3ubuntu13.19 §"Socket-based activation") — `systemctl restart ssh` saja tidak memindahkan port |
| `/etc/ssh/sshd_config` baris 12 `Include /etc/ssh/sshd_config.d/*.conf`; baris 130 `PermitRootLogin yes` | `grep -n` | Drop-in kita dibaca lebih dulu → nilai pertama menang |
| `50-cloud-init.conf` = `PasswordAuthentication yes`, `60-cloudimg-settings.conf` = `no` | `grep` | Drop-in kita harus bernama `00-*.conf` (dibaca sebelum `50-`) — atau `50-cloud-init.conf` dinetralkan |
| cloud-init 26.1 punya modul `cc_set_passwords` yang menangani `ssh_pwauth` | `/usr/lib/python3/dist-packages/cloudinit/config/cc_set_passwords.py` | Tambah `/etc/cloud/cloud.cfg.d/99-hardening.cfg` `ssh_pwauth: false` agar tidak dibuat ulang |
| ufw 0.36.2 terpasang tapi inactive; `/etc/default/ufw` `IPV6=yes` | `dpkg-query`, `cat` | Aturan ufw berlaku v4 & v6 |
| chrony `Conflicts: time-daemon` | `apt-cache show chrony` | Pasang chrony menggantikan systemd-timesyncd |
| `python3-venv` tersedia (3.12.3-0ubuntu2.1), `pip3` tidak terpasang | `apt-cache policy` | Ansible dipasang di venv |
| `net.core.somaxconn=4096` | discovery | docs/00 §4.5 menyebut 1024 — **jangan diturunkan**; set ≥ 4096 |
| Konsol Hostinger (browser terminal/VNC) = jalur darurat; login konsol tidak lewat sshd | ASUMSI (akses konsol belum diverifikasi — pertanyaan terbuka) | Password root lokal **dipertahankan** untuk konsol; hanya login SSH root yang dimatikan |

## 3. Struktur Ansible (satu playbook, dua inventory)

```
ansible/
  ansible.cfg
  requirements.yml            # community.general 13.4.0, ansible.posix 2.2.2, community.docker 5.3.0 (pin)
  site.yml                    # hosts: vps; roles berurutan; tag per fase
  inventories/
    local/hosts.yml           # vps: ansible_connection: local  (dijalankan di VPS oleh root/admin+sudo)
    remote/hosts.yml          # vps: ansible_host 31.97.50.221, ansible_port 2221, ansible_user admin, become: true
  group_vars/all.yml          # port, user, key (public key saja), versi paket
  roles/ base, users, ssh, firewall, fail2ban, auditd, sysctl_swap, docker, unattended, layout, crowdsec_repo
```
- Instalasi runner di VPS: `apt install python3-venv` → venv `/opt/ansible-venv` (di luar repo) →
  `pip install ansible-core==2.21.4` (butuh Python ≥ 3.12; host 3.12.3) → `ansible-galaxy collection install -r requirements.yml`.
- Laptop/CI: venv yang sama dengan pin yang sama; inventory `remote` (hanya bisa dipakai **setelah** fase SSH C).
- Modul yang dipakai (ada di versi yang di-pin — dicek file `plugins/modules/*.py` di GitHub tag):
  `community.general.ufw`, `community.general.timezone`, `community.general.locale_gen`,
  `community.general.sudoers`, `ansible.posix.sysctl`, `ansible.posix.authorized_key`, plus `ansible.builtin.*`.
- Template sshd memakai `validate: /usr/sbin/sshd -t -f %s` (nama opsi `validate` builtin template — verifikasi saat implementasi).
- Idempoten: run kedua harus `changed=0`.

## 4. Target konfigurasi (ringkas; pseudo-config, nilai final di-review QA)

| Area | Target |
|---|---|
| Users | `admin` (grup `sudo`, shell bash, password lokal kuat untuk sudo & konsol — disimpan user di password manager); `deploy` (tanpa grup sudo/docker; sudo **hanya** ke skrip wrapper root-owned `/usr/local/sbin/infra-deploy <stack>` yang memvalidasi argumen). authorized_keys keduanya = kunci ed25519 user (keputusan Lead). |
| sshd drop-in `00-hardening.conf` | `Port 2221`, `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`, `AllowUsers admin deploy`, `MaxAuthTries 3`, `LoginGraceTime 30`, `X11Forwarding no`, `AllowAgentForwarding no` (nama direktif diverifikasi `sshd -T` saat implementasi) |
| ufw | default deny incoming / allow outgoing; allow `2221/tcp`, `80/tcp`, `443/tcp`; mail `25,465,587,993/tcp` dibuka saat mail stack (plan 02), bukan sekarang; `22/tcp` hanya selama transisi |
| fail2ban | jail `sshd` port `2221` (+`22` selama transisi), backend systemd (verifikasi opsi di jail.conf fail2ban 1.0.2), bantime bertingkat |
| auditd | watch `/etc/ssh/`, `/etc/sudoers*`, `/etc/docker/`, `/etc/restic/`, `/opt/infra/**/.env`, eksekusi `docker` & `sudo` |
| chrony | ganti systemd-timesyncd |
| sysctl | `net.ipv4.ip_forward=1`, `vm.swappiness=10`, `fs.inotify.max_user_watches=524288`, `net.core.somaxconn=4096` (tidak diturunkan) |
| swap | `/swapfile` 4 GiB, 600, fstab |
| TZ/locale | `Asia/Jakarta`; `en_US.UTF-8` |
| Docker | repo resmi download.docker.com; `docker-ce=5:29.8.1-1~ubuntu.24.04~noble`, `docker-compose-plugin=5.5.1-1~ubuntu.24.04~noble`, `apt-mark hold` |
| `/etc/docker/daemon.json` | `log-driver: json-file`, `log-opts: {max-size: 10m, max-file: "3"}`, `live-restore: true`, `userland-proxy: false`, `no-new-privileges: true`, `icc: false` (kunci diverifikasi di `docker/cli` docs `reference/dockerd.md`; `icc` hanya berlaku untuk default bridge). **Tanpa** `ipv6`/`ip6tables` (ADR 0002/0005). |
| unattended-upgrades | tetap aktif (sudah enabled); `Automatic-Reboot "false"`; paket Docker di-hold |
| `/opt/infra` | owner `root:admin` 750 (repo), `*/data` 700 owner service; **deploy tidak boleh bisa menulis skrip yang dijalankan root** |
| cloud-init | `/etc/cloud/cloud.cfg.d/99-hardening.cfg`: `ssh_pwauth: false` |

Catatan penting: docs/00 §4.8 mengusulkan `/opt/infra` owner `deploy:docker`. Ditolak: user di grup
`docker` = setara root, dan bila `deploy` bisa menulis skrip yang dieksekusi via sudo/cron root →
eskalasi hak. Diusulkan pola wrapper root-owned (lihat threat model).

## 5. Prosedur anti-lockout (WAJIB urut; satu langkah → satu verifikasi)

Prasyarat (semua harus ✔ sebelum mulai):
- P1. Lead sudah reboot host (kernel 6.8.0-142) dan host kembali normal.
- P2. **User memverifikasi akses konsol Hostinger** (browser terminal/VNC) dengan login `root` + password
  — dan menyimpan password root di password manager.
- P3. **Snapshot Hostinger** dibuat (L3, ADR 0006; kedaluwarsa 1 hari → buat tepat sebelum mulai).
- P4. Sesi SSH root saat ini tetap terbuka sepanjang prosedur (jangan ditutup) + user siap membuka sesi kedua.

| Langkah | Aksi | Verifikasi (harus lolos sebelum lanjut) |
|---|---|---|
| **S0 — bukti kunci** | User dari laptop: `ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no root@31.97.50.221 true` | Lead: `journalctl -u ssh --since "-10min" \| grep "Accepted publickey for root"` muncul, dan fingerprint cocok dengan `ssh-keygen -lf /root/.ssh/authorized_keys`. **Gagal → STOP**; user memperbaiki kunci dulu. Password auth TIDAK boleh dimatikan sebelum S0 lolos. |
| S1 — user | Ansible (inventory `local`, tag `users`): buat `admin`, `deploy`, authorized_keys, sudo | `id admin`, `sudo -l -U admin`, `stat -c '%a %U' /home/admin/.ssh/authorized_keys` → `600 admin` |
| S2 — firewall dulu | Tag `firewall`: `ufw allow 22/tcp`, `ufw allow 2221/tcp`, 80, 443, default deny incoming, **lalu** `ufw enable` | `ufw status verbose` memuat 22 **dan** 2221; sesi SSH saat ini masih hidup; user membuka sesi baru di port 22 → sukses |
| S3 — port ganda | Tag `ssh_phase_a`: drop-in `00-hardening.conf` berisi **`Port 22` dan `Port 2221`** saja (belum ada pembatasan lain) → `sshd -t` → `systemctl daemon-reload && systemctl restart ssh.socket` | `ss -tlnp \| grep -E ':(22\|2221)\b'` → dua port; `systemctl cat ssh.socket` memuat drop-in generator dengan dua `ListenStream` |
| S4 — bukti admin | User (sesi baru): `ssh -p 2221 -o PreferredAuthentications=publickey admin@31.97.50.221 'sudo -v && echo OK'` | Lead: `journalctl -u ssh --since "-10min" \| grep "Accepted publickey for admin"` **dan** `OK` tampil. Gagal → perbaiki, jangan lanjut |
| S5 — dead-man switch | Lead memasang timer revert otomatis: `systemd-run --on-active=15min --unit=ssh-revert <skrip revert>` (skrip mengembalikan drop-in ke versi S3 + `daemon-reload` + `restart ssh.socket`). Nama/opsi `systemd-run` diverifikasi `man systemd-run` saat implementasi | `systemctl list-timers \| grep ssh-revert` |
| S6 — kunci pintu | Tag `ssh_phase_b`: drop-in penuh (Port 22 & 2221 masih ada) + `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AllowUsers admin deploy`, `MaxAuthTries 3`; cloud-init `ssh_pwauth: false` → `sshd -t` → restart socket | `sshd -T \| grep -E '^(permitrootlogin\|passwordauthentication\|kbdinteractiveauthentication\|allowusers\|maxauthtries) '` sesuai target |
| S7 — uji negatif & positif (sesi BARU) | User: (a) `ssh -p 2221 admin@… 'sudo -v && echo OK'` → OK; (b) `ssh -p 2221 -o PubkeyAuthentication=no admin@…` → `Permission denied (publickey)`; (c) `ssh -p 2221 root@…` → ditolak; (d) `ssh -p 2221 deploy@… true` → OK | Semua sesuai. **Lalu** batalkan dead-man: `systemctl stop ssh-revert.timer` |
| S8 — tutup 22 | Tag `ssh_phase_c`: hapus `Port 22` dari drop-in → restart socket; `ufw delete allow 22/tcp`; fail2ban jail hanya 2221 | `ss -tlnp` hanya `2221` untuk sshd; dari laptop `nc -zv -w5 31.97.50.221 22` gagal; `ssh -p 2221 admin@…` sukses |
| S9 — sisa role | Tag `fail2ban,auditd,sysctl_swap,base,docker,unattended,layout` | Acceptance criteria §7 |

Catatan operasional:
- Setelah S6, **login SSH sebagai root tidak mungkin lagi**. Claude Code yang kini berjalan sebagai
  root via SSH: sesi berjalan tetap hidup, tetapi sesi berikutnya harus `ssh -p 2221 admin@…` lalu
  `sudo -i` (atau menjalankan Claude Code sebagai `admin`). Lead harus memberi tahu user sebelum S6.
- Firewall panel Hostinger (bila ada fitur firewall di hPanel): UNVERIFIED — user memastikan tidak ada
  aturan panel yang memblokir 2221 sebelum S3.
- Ubuntu 24.04 socket activation: restart `ssh.socket` **diharapkan** tidak memutus sesi yang sudah ada
  (sesi = proses sshd terpisah) — **UNVERIFIED**, karena itu konsol (P2) dan dead-man switch (S5) wajib.

### Rollback via konsol Hostinger (bila terkunci)

1. Buka konsol Hostinger → login `root` + password.
2. `rm /etc/ssh/sshd_config.d/00-hardening.conf` (kembali ke konfigurasi awal: port 22).
3. `systemctl daemon-reload && systemctl restart ssh.socket`
4. `ufw allow 22/tcp` (atau `ufw disable` bila ufw penyebabnya — catat sebagai insiden).
5. Verifikasi dari laptop: `ssh root@31.97.50.221` (kondisi pra-bootstrap). Ulangi prosedur dari S0.
6. Jika host tidak bisa diperbaiki: restore snapshot P3 (menimpa seluruh VPS — hanya valid ≤ 1 hari).

## 6. Threat model ringkas (STRIDE) — host bootstrap

Aset: akses root host, kunci SSH, `.env`/secret, Docker daemon, data client, jalur konsol.
Entry point: sshd (2221), konsol Hostinger, paket APT/Docker repo, cloud-init, akun `deploy` (CI).

| STRIDE | Ancaman | Mitigasi (implementasi) | Verifikasi (QA) |
|---|---|---|---|
| S — Spoofing | Brute force password SSH (kondisi sekarang: password root aktif, port 22, tanpa firewall) | key-only, `PermitRootLogin no`, `AllowUsers`, `MaxAuthTries 3`, fail2ban + CrowdSec sshd, port 2221 | `sshd -T`; uji login password → ditolak; `fail2ban-client status sshd` |
| S | Kunci tunggal dipakai `admin` & `deploy` (keputusan Lead) — kebocoran satu kunci = dua akun | Diterima sementara; rekomendasi kunci `deploy` terpisah khusus CI saat GitHub remote siap; `deploy` tanpa shell interaktif penuh (opsi `command=`/`restrict` di authorized_keys — UNVERIFIED sintaks, cek `man sshd` AUTHORIZED_KEYS) | review `authorized_keys` |
| T — Tampering | Skrip deploy dimodifikasi `deploy` lalu dijalankan root | wrapper root-owned 755 di `/usr/local/sbin`, `/opt/infra` tidak writable oleh `deploy`, sudoers tanpa wildcard | `sudo -l -U deploy`; `find /opt/infra /usr/local/sbin -writable -user deploy` kosong (dijalankan sebagai deploy) |
| T | cloud-init/re-run mengaktifkan kembali password SSH | `ssh_pwauth: false`; drop-in `00-` menang | `sshd -T` setelah reboot |
| R — Repudiation | Perubahan config tanpa jejak | auditd rules + journald persisten; semua perubahan lewat git+Ansible | `auditctl -l`; `ausearch -k sshd_config` |
| I — Info disclosure | Port container ter-expose (Docker bypass ufw) | hanya Traefik & mail publish port; `ss -tlnp` + scan eksternal | `nmap -Pn -p- 31.97.50.221` dari luar |
| I | Secret di swap/log | swap tidak terenkripsi (diterima §3.6); log tanpa secret | review |
| D — DoS | Lockout diri sendiri saat hardening | prosedur §5 (S0–S8), konsol, snapshot, dead-man switch | dry-run prosedur di checklist |
| D | OOM host | swap 4 GiB + `mem_limit` (ADR 0004) | `swapon --show` |
| E — Elevation | `deploy` di grup `docker` = root | `deploy` **tidak** di grup docker; sudo hanya ke wrapper | `id deploy` |
| E | Paket tidak terpercaya | repo resmi + GPG key Docker; pin versi; unattended-upgrades security | `apt-cache policy docker-ce` |

## 7. Acceptance criteria (perintah → hasil yang diharapkan)

```
sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|allowusers) '
  → port 2221 · permitrootlogin no · passwordauthentication no · kbdinteractiveauthentication no · maxauthtries 3 · allowusers admin deploy
ss -tlnp | grep sshd                      → hanya :2221 (v4 & v6)
ufw status verbose                        → Status: active; Default: deny (incoming), allow (outgoing); ALLOW 2221/tcp, 80/tcp, 443/tcp (tanpa 22)
fail2ban-client status sshd               → jail aktif
systemctl is-active auditd chrony fail2ban docker containerd   → active ×5
auditctl -l                               → memuat rules watch /etc/ssh, /etc/sudoers, /etc/docker
swapon --show                             → /swapfile 4G
sysctl vm.swappiness net.ipv4.ip_forward net.core.somaxconn fs.inotify.max_user_watches → 10 · 1 · 4096 · 524288
timedatectl | grep 'Time zone'            → Asia/Jakarta
localectl status | grep LANG              → en_US.UTF-8
docker version --format '{{.Server.Version}}'  → 29.8.1
docker compose version                    → v5.5.1
docker info --format '{{.LoggingDriver}} {{.LiveRestoreEnabled}}'  → json-file true
python3 -m json.tool /etc/docker/daemon.json   → valid, memuat kunci §4
id deploy                                 → tanpa grup docker/sudo
sudo -l -U deploy                         → hanya /usr/local/sbin/infra-deploy
grep -r ssh_pwauth /etc/cloud/cloud.cfg.d/      → ssh_pwauth: false
ansible-playbook -i inventories/local/hosts.yml site.yml   (run ke-2) → changed=0 failed=0
ansible-playbook -i inventories/remote/hosts.yml site.yml --check  (dari laptop) → sukses, changed=0
Dari laptop: nc -zv -w5 31.97.50.221 22 → gagal; ssh -p 2221 admin@31.97.50.221 true → sukses
Dari luar: nmap -Pn -p 1-65535 31.97.50.221 → hanya 80, 443, 2221 terbuka (mail belum)
```

## 8. Risiko

| # | Risiko | Mitigasi |
|---|---|---|
| 1 | Lockout SSH | §5 lengkap + konsol + snapshot + dead-man |
| 2 | Kunci user ternyata tidak valid (belum pernah dipakai) | S0 wajib lolos sebelum apa pun |
| 3 | Satu kunci untuk admin+deploy | ganti kunci deploy saat CI dibuat (pertanyaan terbuka) |
| 4 | Ansible lokal mengubah sshd dari sesi yang sedang dipakai Ansible sendiri | Ansible lokal tidak memakai SSH (connection local) → tidak terputus; remote run hanya setelah S8 |
| 5 | Docker mem-bypass ufw | kebijakan publish port (plan 02) + scan QA |

## 9. Rollback per role

- users: `userdel -r` (hanya setelah akses root/konsol dipastikan).
- ssh: §5 rollback konsol.
- ufw: `ufw disable` (konsol) — catat insiden.
- docker: `systemctl stop docker`, `apt-mark unhold`, `apt purge docker-ce docker-compose-plugin` (data `/var/lib/docker` dihapus hanya dengan konfirmasi user §0.5).
- swap: `swapoff /swapfile`, hapus entri fstab.
- sysctl/tz/locale: hapus file drop-in `/etc/sysctl.d/99-infra.conf`, `timedatectl set-timezone Etc/UTC`.
