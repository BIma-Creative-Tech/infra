#!/usr/bin/env bash
# Mirror prod → staging Dit. LED: DB `ditled` (shared cluster, read-only pg_dump) + media. Idempotent, can be rerun.
# Staging is overwritten in full. Sanitized: questions (Tanya Dit. LED: name/email/phone), attachments (PDF
# attachments), visitor_logs, users_sessions, payload_locked_documents. CMS users are kept (same passwords as prod).
# Run as root after .env exists (setup-env.sh): bash /opt/infra/web/clients/ditled-stg/mirror-from-prod.sh
set -euo pipefail
D=/opt/infra/web/clients/ditled-stg
DUMP="/root/ditled-stg-mirror-$(date +%Y%m%d-%H%M%S).dump"
cd "$D"

echo "== db up"
docker compose up -d db
for i in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' web-ditled-stg-db)" == healthy ]] && break; sleep 2
done
[[ "$(docker inspect -f '{{.State.Health.Status}}' web-ditled-stg-db)" == healthy ]] || { docker logs --tail 40 web-ditled-stg-db; exit 1; }

echo "== web stop (if running)"
docker compose stop web 2>/dev/null || true

echo "== pg_dump prod → $DUMP"
docker exec postgres pg_dump -U postgres -Fc --no-owner --no-acl ditled > "$DUMP"
chmod 600 "$DUMP"

echo "== restore → staging (schema public reset)"
docker exec -i web-ditled-stg-db psql -q -v ON_ERROR_STOP=1 -U ditled -d ditled \
  -c 'DROP SCHEMA IF EXISTS public CASCADE' -c 'CREATE SCHEMA public'
docker exec -i web-ditled-stg-db pg_restore --no-owner --no-acl --exit-on-error -U ditled -d ditled < "$DUMP"

echo "== sanitize"
docker exec -i web-ditled-stg-db psql -v ON_ERROR_STOP=1 -U ditled -d ditled <<'SQL'
TRUNCATE questions, attachments, visitor_logs, users_sessions, payload_locked_documents CASCADE;
SELECT (SELECT count(*) FROM users) users, (SELECT count(*) FROM questions) questions,
       (SELECT count(*) FROM visitor_logs) visitor_logs, (SELECT count(*) FROM media) media;
SQL

echo "== media (attachments left empty)"
install -d -o 1001 -g 1001 -m 0700 /srv/ditled-stg/data /srv/ditled-stg/data/media /srv/ditled-stg/data/attachments
rsync -a --delete /srv/ditled/data/media/ /srv/ditled-stg/data/media/
find /srv/ditled-stg/data/attachments -mindepth 1 -delete
chown -R 1001:1001 /srv/ditled-stg/data

echo "== web up"
docker compose up -d web
for i in $(seq 1 60); do
  s="$(docker inspect -f '{{.State.Health.Status}}' web-ditled-stg 2>/dev/null || echo absent)"
  [[ "$s" == healthy ]] && break; sleep 2
done
echo "== web-ditled-stg: $s"
[[ "$s" == healthy ]] || { docker logs --tail 60 web-ditled-stg; exit 1; }
echo "OK. Dump kept at $DUMP (delete when no longer needed)."
