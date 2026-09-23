#!/usr/bin/env bash
# QA T17a — hardening semua container berjalan (CLAUDE.md §3.5). Read-only.
set -u
for c in $(docker ps --format '{{.Names}}'); do
  docker inspect "$c" --format '{{.Name}} priv={{.HostConfig.Privileged}} capdrop={{.HostConfig.CapDrop}} capadd={{.HostConfig.CapAdd}} secopt={{.HostConfig.SecurityOpt}} ro={{.HostConfig.ReadonlyRootfs}} mem={{.HostConfig.Memory}} cpus={{.HostConfig.NanoCpus}} user={{.Config.User}} restart={{.HostConfig.RestartPolicy.Name}} log={{.HostConfig.LogConfig.Config}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}NONE{{end}} ports={{.HostConfig.PortBindings}}'
  docker inspect "$c" --format '   mounts: {{range .Mounts}}{{.Source}}->{{.Destination}}(rw={{.RW}}) {{end}}' | grep -q docker.sock && echo "   !! $c memount docker.sock"
done
echo "## network"
for n in proxy db odoo-edge crowdsec; do
  docker network inspect "$n" --format '{{.Name}} internal={{.Internal}} members={{range .Containers}}{{.Name}} {{end}}'
done
