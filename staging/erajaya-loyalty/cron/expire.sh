#!/usr/bin/env bash
# erajaya-loyalty STAGING — daily point-lot / voucher expiry (app route GET /api/cron/expire, `Authorization: Bearer
# <CRON_SECRET>`; same contract as the app's vercel.json cron "0 17 * * *" UTC = 00:00 WIB).
# Run by systemd erajaya-staging-expire.service (ansible role erajaya_staging_cron) as root.
#
# Path: host → 127.0.0.1:443 (Traefik websecure, --resolve: no DNS, the VPS resolvers are flaky) → arrives at Traefik as
# 10.100.0.1 (hairpin/host, docs/03-operations/traefik.md) → router erajaya-stg-cron (ClientIP 10.100.0.1/32 only; every
# other source gets 403 from erajaya-stg-cron-deny) → crowdsec → erajaya-staging-web:3000.
# The secret is read from the stack's secret file and given to curl on STDIN (`-H @-`), never in argv/env/logs.
# Exit != 0 → OnFailure=infra-unit-failure@ (email alert). Output (JSON counts from the app) goes to the journal.
set -euo pipefail

HOST="erajaya-loyalty.staging.bimacreative.tech"
SECRET_FILE="/opt/infra/staging/erajaya-loyalty/secrets/cron_secret.secret"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -s "$SECRET_FILE" ]] || { echo "missing/empty $SECRET_FILE" >&2; exit 1; }

secret="$(<"$SECRET_FILE")"
# -f: HTTP >= 400 → exit 22 (alert). --max-time: expiry runs inside one request (app: Payload local API).
# NO --retry on purpose: runExpiry (src/lib/loyalty.ts) reads the expiring lots BEFORE taking the per-member lock, so a
# retry that overlaps a still-running first request (client timeout, server continues) could expire the same lots twice
# (only capped by the balance). A failed run alerts; re-run by hand after checking the app log
# (`systemctl start erajaya-staging-expire.service`). Max 5000 lots per run (app limit) → a daily run is enough.
printf 'Authorization: Bearer %s\n' "$secret" \
  | curl -sS -f --max-time 600 \
      --resolve "${HOST}:443:127.0.0.1" -H @- "https://${HOST}/api/cron/expire"
echo
