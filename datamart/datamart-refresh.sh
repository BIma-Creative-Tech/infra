#!/usr/bin/env bash
# Refresh data mart (ADR 0016 #4): ingest semua tenant (DATAMART_TENANTS) → dbt build (model + test) di container
# python resmi dengan pylib ro, user nobody, network db-datamart saja. Dipanggil datamart-refresh.timer (tiap 2 menit).
# Plan 16 — berbasis perubahan: sidik jari = jumlah insert/update/delete (pg_stat_user_tables) tabel alur CRM →
# penawaran/SPK → project/timesheet → SCM → invoice/payment (+ isu link dokumen, plan 18; BAST, plan 19) per tenant. Sama dengan
# run sukses terakhir dan belum DATAMART_FORCE_EVERY detik (default 1800) → skip. `--force` = selalu jalan.
# Baris terakhir: RESULT status=ok|skip|fail …  (journald: `journalctl -u datamart-refresh -n 20`)
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
tables="'crm_lead','sale_order','sale_order_line','project_task','account_analytic_line','account_move',\
'account_payment','account_partial_reconcile','purchase_order','stock_picking','mrp_production','res_partner',\
'res_users','res_groups_users_rel','hr_employee','purchase_order_line','stock_move','custom_doc_trace_issue',\
'custom_bast_document','product_template'"
fp=""
for t in $DATAMART_TENANTS; do
  n=$(docker exec postgres psql -U postgres -d "${t%%:*}_${t##*:}" -XtAc \
    "SELECT coalesce(sum(n_tup_ins + n_tup_upd + n_tup_del), 0) FROM pg_stat_user_tables WHERE relname IN ($tables)" \
    2>/dev/null) || n=none
  fp+="$t=$n;"
done
state_dir=${STATE_DIRECTORY:-/var/lib/datamart-refresh}
mkdir -p "$state_dir"
last_fp=$(cat "$state_dir/fingerprint" 2>/dev/null || true)
last_at=$(stat -c %Y "$state_dir/fingerprint" 2>/dev/null || echo 0)
if [[ "${1:-}" != --force && "$fp" == "$last_fp" && $(( start - last_at )) -lt ${DATAMART_FORCE_EVERY:-1800} ]]; then
  echo "RESULT status=skip reason=unchanged"
  exit 0
fi
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
printf '%s' "$fp" > "$state_dir/fingerprint"  # sidik jari SEBELUM ingest: perubahan selama run terbawa ke run berikut
echo "RESULT status=ok tenants=\"$DATAMART_TENANTS\" duration=$(( $(date +%s) - start ))s"
