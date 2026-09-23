#!/usr/bin/env bash
# Dead-man switch S5 (plan 01 §5) — mengembalikan sshd ke konfigurasi fase A (port 22 + 2221,
# tanpa pembatasan) bila Lead/user tidak membatalkannya dalam 15 menit setelah S6.
# TIDAK dipasang oleh Ansible. Dipasang MANUAL oleh Lead tepat sebelum S6.
#
# Opsi systemd-run diverifikasi dari `man systemd-run` (systemd 255): --unit=, --description=,
# --on-active= (shortcut OnActiveSec=, systemd.timer(5)); unit timer + service bernama sama.
#
# Pasang (sebagai root, di VPS, SEBELUM `--tags ssh_phase_b`):
#   install -d -m 700 /root/ssh-revert
#   install -m 600 /etc/ssh/sshd_config.d/00-hardening.conf /root/ssh-revert/00-hardening.conf.phase-a
#   install -m 700 /opt/infra/ansible/roles/ssh/files/ssh-revert.sh /root/ssh-revert/ssh-revert.sh
#   systemd-run --unit=ssh-revert --description="Dead-man switch revert sshd (plan 01 S5)" \
#       --on-active=15min /root/ssh-revert/ssh-revert.sh
#   systemctl list-timers ssh-revert.timer        # verifikasi S5
#
# Batalkan (S7 lolos):   systemctl stop ssh-revert.timer
# Cek setelah terpicu:   journalctl -u ssh-revert.service
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly SRC=/root/ssh-revert/00-hardening.conf.phase-a
readonly DST=/etc/ssh/sshd_config.d/00-hardening.conf

logger -t ssh-revert "dead-man switch terpicu: revert sshd ke fase A"

if [[ -f "$SRC" ]] && sshd -t -f "$SRC"; then
  install -m 644 -o root -g root "$SRC" "$DST"
else
  # Tanpa salinan fase A yang valid: hapus drop-in -> default Ubuntu (port 22).
  logger -t ssh-revert "salinan fase A tidak valid/tidak ada: hapus $DST"
  rm -f -- "$DST"
fi

if ! sshd -t; then
  logger -t ssh-revert "sshd -t gagal setelah revert: hapus $DST"
  rm -f -- "$DST"
fi

# Pastikan port 22 dan 2221 diizinkan firewall (idempoten; tidak mereset aturan lain).
ufw allow 22/tcp || true
ufw allow 2221/tcp || true

systemctl daemon-reload
systemctl restart ssh.socket
logger -t ssh-revert "selesai: $(ss -tlnH 'sport = :22 or sport = :2221' | wc -l) listener sshd"
