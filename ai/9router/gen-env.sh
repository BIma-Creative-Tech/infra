#!/bin/sh
# Membuat /opt/9router/.env (600) berisi secret acak. Tidak menimpa .env yang sudah ada; tidak mencetak isi.
set -eu
f=/opt/9router/.env
[ -e "$f" ] && { echo ".env sudah ada, dilewati"; exit 0; }
umask 077
{
  echo "INITIAL_PASSWORD=$(openssl rand -hex 12)"
  echo "JWT_SECRET=$(openssl rand -hex 32)"
  echo "API_KEY_SECRET=$(openssl rand -hex 32)"
  echo "MACHINE_ID_SALT=$(openssl rand -hex 16)"
} > "$f"
echo ".env dibuat"
