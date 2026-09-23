#!/usr/bin/env bash
# QA T17a — acceptance plan 01 §7 yang bisa diuji dari host (read-only). Jalankan sebagai root.
# Pemakaian: sudo qa/host-checks.sh
set -u
echo "## sshd";      sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|allowusers) '
echo "## listen";    ss -tlnp
echo "## ufw";       ufw status verbose
echo "## fail2ban";  fail2ban-client status sshd
echo "## services";  systemctl is-active auditd chrony fail2ban docker containerd crowdsec-firewall-bouncer
echo "## auditd";    auditctl -l
echo "## swap";      swapon --show
sysctl vm.swappiness net.ipv4.ip_forward net.core.somaxconn fs.inotify.max_user_watches
timedatectl | grep 'Time zone'; localectl status | grep LANG
docker version --format '{{.Server.Version}}'; docker compose version
docker info --format '{{.LoggingDriver}} {{.LiveRestoreEnabled}}'
python3 -m json.tool /etc/docker/daemon.json
id deploy; sudo -l -U deploy; grep -r ssh_pwauth /etc/cloud/cloud.cfg.d/
echo "## secret file modes (harus 600/700)"
for f in /etc/restic/* /opt/infra/*/.env /opt/infra/*/*/.env /opt/infra/*/*/*/.env \
         /opt/infra/traefik/acme/*.json /opt/infra/traefik/secrets/* \
         /opt/infra/*/*/secrets/master-password /opt/infra/*/*/secrets/tenants/* \
         /opt/infra/identity/keycloak/.admin-credentials /opt/src/*/.env; do
  [ -e "$f" ] && stat -c '%a %U:%G %n' "$f"
done
echo "## ansible (check mode, tanpa perubahan)"
( cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook -i inventories/local/hosts.yml site.yml --check 2>&1 | tail -3 )
