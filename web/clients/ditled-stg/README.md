# web/clients/ditled-stg: Staging website Dit. LED

`https://ditled.staging.bimacreative.tech` (wildcard DNS `*.staging`). Created 2026-11-17. Same app as
prod (`web/clients/ditled`), used to try a release before the prod swap.

| What | Where |
|---|---|
| Compose | `docker-compose.yml` (project `web-ditled-stg`: `web-ditled-stg` + `web-ditled-stg-db`) |
| Secrets | `.env` (600 root), created by `setup-env.sh`: `DITLED_TAG`, `PAYLOAD_SECRET`, `POSTGRES_PASSWORD`, `DATABASE_URI`, `EPENYIARAN_*` (copied from prod) |
| DB | dedicated Postgres 16 (internal network `web-ditled-stg-db`), data at `/srv/ditled-stg/pg` (999:999) |
| Uploads | `/srv/ditled-stg/data` (1001:1001, 0700) |
| Traefik route | `/opt/infra/traefik/dynamic/clients/web-ditled-stg.yml` (source: `web-ditled-stg.yml.pending`) |

**Why a dedicated DB, not the shared cluster:** pg_hba in the cluster is a read-only bind mount whose inode
is stale (new lines need a restart → all prod DBs go down), and role `ditled` has connlimit 10 that the prod
container already uses up. Dedicated container: 256m / 0.5 CPU.

**Separate image (-stg tag):** `NEXT_PUBLIC_SERVER_URL` is inlined at build time (metadataBase, CMS links), so the
staging image is built with the staging URL from the same commit as prod:

```bash
cd /home/admin/src/led-website   # git checkout of the same commit as prod
docker build --build-arg NEXT_PUBLIC_SERVER_URL=https://ditled.staging.bimacreative.tech -t web-ditled:<tag>-stg .
sed -i 's/^DITLED_TAG=.*/DITLED_TAG=<tag>-stg/' /opt/infra/web/clients/ditled-stg/.env
cd /opt/infra/web/clients/ditled-stg && docker compose up -d
```

**Data:** `mirror-from-prod.sh` = prod pg_dump (read-only) → restore to staging + media rsync, sanitized
(questions/Tanya Dit. LED, attachments, visitor_logs, sessions). CMS users are kept (same passwords as prod). The prod dump in /root is deleted automatically after restore (or on failure).
Umami is off on staging. Email has no adapter (console), same as prod.

Remove staging: `docker compose down`, delete the route file, `rm -rf /srv/ditled-stg`.
