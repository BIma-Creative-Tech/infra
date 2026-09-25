#!/bin/bash
# user-patches.sh — mekanisme resmi DMS v16.0.1 (docs config/advanced/override-defaults/user-patches.md; source
# setup-stack.sh `_setup_run_user_patches`): /tmp/docker-mailserver/user-patches.sh dijalankan `bash` saat SETUP container
# BARU (bukan restart — restart melewati _setup, tetapi file supervisor di bawah tetap ada di lapisan container).
# Sumber kebenaran = git mail/config/user-patches.sh → disalin bootstrap.sh ke data/config/.
#
# ADR 0012 (plan 08): pasang program supervisord `pwhelper` (ganti password self-service webmail). Helper listen HANYA
# di IP mailserver pada network internal `webmail-mail` (10.100.16.2, ipv4_address tetap di docker-compose.yml).
# Kill switch: `touch data/config/pwhelper/disabled` (503 seketika) atau `docker exec mailserver supervisorctl stop pwhelper`.
# Kegagalan helper TIDAK memengaruhi dms-healthcheck (program ini bukan bagian daftar layanan DMS).
set -euo pipefail

PWH_DIR=/tmp/docker-mailserver/pwhelper
if [[ -f "$PWH_DIR/pwhelper.py" ]]; then
  cat > /etc/supervisor/conf.d/pwhelper.conf <<'EOF'
[program:pwhelper]
command=/usr/bin/python3 -I -S /tmp/docker-mailserver/pwhelper/pwhelper.py --bind 10.100.16.2 --port 8080
directory=/
user=root
autostart=true
autorestart=true
startsecs=3
startretries=10
stopwaitsecs=10
stdout_logfile=/var/log/supervisor/%(program_name)s.log
stderr_logfile=/var/log/supervisor/%(program_name)s.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=2
EOF
  chmod 0644 /etc/supervisor/conf.d/pwhelper.conf
  # supervisord (PID 1) sudah berjalan saat _setup → daftarkan & start program baru.
  supervisorctl reread >/dev/null 2>&1 || true
  supervisorctl update >/dev/null 2>&1 || true
  echo "[user-patches] pwhelper terpasang"
else
  rm -f /etc/supervisor/conf.d/pwhelper.conf
  echo "[user-patches] pwhelper.py tidak ada — helper tidak dipasang"
fi
