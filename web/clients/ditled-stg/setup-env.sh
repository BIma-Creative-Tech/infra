#!/usr/bin/env bash
# Creates the staging .env (600 root) ONCE: fresh random secrets, EPENYIARAN_* copied from prod .env.
# Will not overwrite an existing .env. Run as root: bash /opt/infra/web/clients/ditled-stg/setup-env.sh <tag-stg>
set -euo pipefail
D=/opt/infra/web/clients/ditled-stg
PROD_ENV=/opt/infra/web/clients/ditled/.env
TAG="${1:?usage: setup-env.sh <image tag, e.g. 0.8.0-202611161746-stg>}"
[[ -e "$D/.env" ]] && { echo "$D/.env already exists — not overwritten"; exit 1; }
docker image inspect "web-ditled:$TAG" >/dev/null

PW="$(openssl rand -hex 24)"
umask 077
{
  echo "DITLED_TAG=$TAG"
  echo "PAYLOAD_SECRET=$(openssl rand -hex 32)"
  echo "POSTGRES_PASSWORD=$PW"
  echo "DATABASE_URI=postgres://ditled:$PW@db:5432/ditled"
  grep -E '^EPENYIARAN_(API_URL|API_KEY)=' "$PROD_ENV" || true
} > "$D/.env"
chown root:root "$D/.env"; chmod 600 "$D/.env"
echo "== $D/.env created; keys:"; sed 's/=.*/=…/' "$D/.env"
grep -q '^EPENYIARAN_API_KEY=.' "$D/.env" || echo "NOTE: EPENYIARAN_API_KEY is empty → Penyiaran card shows 'Menunggu integrasi'"
