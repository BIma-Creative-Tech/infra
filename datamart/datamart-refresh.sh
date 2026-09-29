#!/usr/bin/env bash
# Refresh data mart (ADR 0016 #4): ingest semua tenant (DATAMART_TENANTS) → dbt build (model + test) di container
# python resmi dengan pylib ro, user nobody, network db-datamart saja. Dipanggil datamart-refresh.timer (30 menit).
# Baris terakhir: RESULT status=ok|fail …  (journald: `journalctl -u datamart-refresh -n 20`)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec 9>/run/datamart-refresh.lock
flock -n 9 || { echo "RESULT status=skip reason=already_running"; exit 0; }
cfg="$here/datamart.env"; [[ -f "$cfg" ]] || cfg="$here/datamart.env.example"
# shellcheck disable=SC1090
source <(grep -E '^(DBT_PYTHON_IMAGE|DATAMART_TENANTS)=' "$cfg")
pw=$(grep -E '^PG_DATAMART_PASSWORD=' /opt/infra/postgres/.env | cut -d= -f2-)
[[ ${#pw} -ge 32 ]] || { echo "RESULT status=fail reason=no_password"; exit 1; }
[[ -d "$here/pylib" ]] || { echo "RESULT status=fail reason=no_pylib (jalankan build-pylib.sh)"; exit 1; }
start=$(date +%s)
for t in $DATAMART_TENANTS; do
  "$here/ingest.sh" "${t%%:*}" "${t##*:}" || { echo "RESULT status=fail reason=ingest tenant=$t"; exit 1; }
done
set +e
out=$(printf '%s' "$pw" | docker run --rm -i --name datamart-dbt --network db-datamart --user 65534:65534 \
  --read-only --tmpfs /tmp:size=128m --memory 384m --cpus 0.5 --cap-drop ALL --security-opt no-new-privileges:true \
  -e PYTHONPATH=/pylib -e HOME=/tmp -e DBT_PROFILES_DIR=/dbt -e DBT_SEND_ANONYMOUS_USAGE_STATS=false \
  -e DBT_TARGET_PATH=/tmp/dbt-target -e DBT_LOG_PATH=/tmp/dbt-logs \
  -v "$here/pylib:/pylib:ro" -v "$here/dbt:/dbt:ro" -w /dbt --entrypoint sh "$DBT_PYTHON_IMAGE" -c \
  'read -r DBT_PASSWORD; export DBT_PASSWORD; python3 -c "import sys; from dbt.cli.main import dbtRunner; r = dbtRunner().invoke([\"build\", \"--no-use-colors\"]); sys.exit(0 if r.success else 1)"' 2>&1)
rc=$?
set -e
echo "$out" | grep -E "^\S+ +[0-9]+ of [0-9]+ (OK|ERROR|FAIL|PASS|WARN)|Done\.|Completed|ERROR|Database Error" | tail -40
if [[ $rc -ne 0 ]]; then echo "RESULT status=fail reason=dbt duration=$(( $(date +%s) - start ))s"; exit 1; fi
echo "RESULT status=ok tenants=\"$DATAMART_TENANTS\" duration=$(( $(date +%s) - start ))s"
