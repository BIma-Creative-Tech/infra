#!/usr/bin/env bash
# QA T17a — hardening semua container berjalan (CLAUDE.md §3.5). Read-only.
set -u
for c in $(docker ps --format '{{.Names}}'); do
  docker inspect "$c" --format '{{.Name}} priv={{.HostConfig.Privileged}} capdrop={{.HostConfig.CapDrop}} capadd={{.HostConfig.CapAdd}} secopt={{.HostConfig.SecurityOpt}} ro={{.HostConfig.ReadonlyRootfs}} mem={{.HostConfig.Memory}} cpus={{.HostConfig.NanoCpus}} user={{.Config.User}} restart={{.HostConfig.RestartPolicy.Name}} log={{.HostConfig.LogConfig.Config}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}NONE{{end}} ports={{.HostConfig.PortBindings}}'
  docker inspect "$c" --format '   mounts: {{range .Mounts}}{{.Source}}->{{.Destination}}(rw={{.RW}}) {{end}}' | grep -q docker.sock && echo "   !! $c memount docker.sock"
done
echo "## network"
# plan 06 (ADR 0010): network per konsumen; `docker network inspect` untuk network yang belum/tidak ada lagi (db setelah S10)
# mencetak error ke stderr lalu lanjut (tanpa set -e).
for n in proxy db odoo-edge odoo-edge-stg kc-edge crowdsec db-keycloak db-odoo-pool-a db-odoo-staging db-cp db-cp-stg db-drms-stg; do
  docker network inspect "$n" --format '{{.Name}} internal={{.Internal}} members={{range .Containers}}{{.Name}} {{end}}'
done
