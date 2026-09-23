#!/usr/bin/env bash
# QA T17a — gitleaks / trivy / semgrep / hadolint via container sementara (tag ter-pin, --rm).
# Pemakaian: sudo qa/pipeline-scans.sh <out_dir>
# Catatan: trivy memount docker.sock READ-ONLY ke container sementara agar bisa membaca image lokal;
# container dihapus setelah scan. Alternatif tanpa socket: `docker save <img> | trivy image --input -`.
set -u
OUT=${1:?out_dir}; mkdir -p "$OUT/trivy-cache"
GITLEAKS=zricethezav/gitleaks:v8.30.1; TRIVY=aquasec/trivy:0.74.0
SEMGREP=semgrep/semgrep:1.177.0;      HADOLINT=hadolint/hadolint:v2.15.1
for r in /opt/infra /opt/src/odoo-addons-shared /opt/src/control-plane; do
  docker run --rm -u 0 -v "$r:/repo:ro" -v "$OUT:/out" $GITLEAKS git /repo --no-banner --redact \
    -f json -r "/out/gitleaks-$(basename "$r").json"
done
for img in $(docker ps --format '{{.Image}}' | sort -u); do
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro -v "$OUT/trivy-cache:/root/.cache" \
    -v "$OUT:/out" $TRIVY image --quiet --scanners vuln --severity HIGH,CRITICAL --format json \
    -o "/out/trivy-$(echo "$img" | tr '/:' '__').json" "$img"
done
docker run --rm -v /opt/src/odoo-addons-shared:/src:ro -v "$OUT:/out" $SEMGREP semgrep scan \
  --config p/owasp-top-ten --config p/python --metrics=off --json -o /out/semgrep-addons.json /src
docker run --rm -v /opt/src/control-plane:/src:ro -v "$OUT:/out" $SEMGREP semgrep scan \
  --config p/owasp-top-ten --config p/typescript --metrics=off --exclude node_modules --exclude .next \
  --exclude dist --json -o /out/semgrep-cp.json /src
for f in /opt/src/control-plane/Dockerfile /opt/infra/identity/keycloak/Containerfile; do
  echo "== hadolint $f"; docker run --rm -i $HADOLINT hadolint - < "$f"
done
