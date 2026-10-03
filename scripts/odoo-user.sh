#!/usr/bin/env bash
# res.users Odoo untuk satu user Keycloak di DB tenant-env (job `odoo_user_ensure`, kontrak
# saas-phase-1-contract.md §1/§1.1). Wrapper tipis: validasi + resolusi (pool, DB, id user Keycloak, cek tenant) lalu
# menjalankan helper scripts/lib/odoo_user_ensure.py (odoo-developer) di `odoo shell` pool. IDEMPOTEN (helper).
#
#   scripts/odoo-user.sh <slug> <prod|demo|staging> --email <e> [--login <l>] [--name <n>] --role <user|admin>
#                        --active <true|false> [--dry-run]
#
#   - slug `platform` ditolak (exit 3); DB <slug>_<env> harus ada (dry-run: BLOKIR);
#   - user Keycloak dicari by email (client cp-admin, GET saja) — harus ada (job kc_user_ensure dulu) dan atribut
#     tenant_id-nya = alias Organization slug (lintas tenant → exit 3);
#   - --login default = email; --name default = firstName + lastName Keycloak (atau email).
#
# ---- ANTARMUKA HELPER (scripts/lib/odoo_user_ensure.py, odoo-developer, branch feat/infra-saas-p1-odoo-user 445ac51) --
# Header helper = sumber kebenaran. Dijalankan:
#   docker exec -i -e ODOO_USER_EMAIL -e ODOO_USER_LOGIN -e ODOO_USER_NAME -e ODOO_USER_ROLE -e ODOO_USER_ACTIVE
#     -e ODOO_USER_KC_ID -e ODOO_USER_DRY_RUN -e ODOO_USER_OIDC_CLIENT_ID <pool> odoo shell -c /etc/odoo/odoo.conf
#     -d <db> --no-http --workers=0 --max-cron-threads=0 --log-level=warn < scripts/lib/odoo_user_ensure.py
# `-e NAMA` TANPA nilai: nilai diambil dari env proses wrapper (di-export di sini) → email/login/nama tidak muncul di
# argv/`ps`. Parameter (sudah lolos regex di wrapper; helper memvalidasi ulang):
#   ODOO_USER_EMAIL    email (huruf kecil)                ODOO_USER_LOGIN    login res.users (default = email)
#   ODOO_USER_NAME     nama tampilan                       ODOO_USER_ROLE     user | admin
#   ODOO_USER_ACTIVE   true | false                        ODOO_USER_KC_ID    id user Keycloak (UUID) = oauth_uid
#   ODOO_USER_DRY_RUN  true | false (true = tulis dalam transaksi lalu rollback)
#   ODOO_USER_OIDC_CLIENT_ID  SELALU odoo-<slug>-<env> (keputusan Lead) — provider sh_auth_oidc yang dipakai
# Helper: exit 0 + baris terakhir `RESULT db=<db> odoo_user=<id|-> kc_user=<uuid> created=<0|1> changed=<n>`;
# exit 2 parameter/prasyarat, 3 ditolak (user terlindungi/portal/konflik tautan), 1 tak terduga — tanpa RESULT, baris
# `ERROR: …` di stdout. Wrapper meneruskan kode keluar helper apa adanya dan mencetak ulang RESULT helper (tervalidasi:
# db = DB tenant, kc_user = id yang dikirim) sebagai baris terakhirnya (+ ` blockers=<n>` pada dry-run).
# -------------------------------------------------------------------------------------------------------------------
# Output baris terakhir: RESULT db=<db> odoo_user=<id|-> kc_user=<id|-> created=<0|1> changed=<n>
#                        [blockers=<n> pada --dry-run]
# Log tidak memuat email/login mentah: email#<8 hex sha256> (lib/kc-tenant.sh email_ref, QA F5); helper juga tanpa PII.
# JANGAN jalankan dengan `bash -x`.
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
KC_ADMIN_CLIENT=cp-admin
# shellcheck source=lib/keycloak-admin.sh
source "$LIB/keycloak-admin.sh"
# shellcheck source=lib/odoo-exec.sh
source "$LIB/odoo-exec.sh"
# shellcheck source=lib/kc-tenant.sh
source "$LIB/kc-tenant.sh"   # setelah odoo-exec.sh: log/change/block versi kc-tenant (prefix LOG_PREFIX)
HELPER="$LIB/odoo_user_ensure.py"

usage() {
  echo "pemakaian: $0 <slug> <prod|demo|staging> --email <e> [--login <l>] [--name <n>] --role <user|admin> --active <true|false> [--dry-run]" >&2
  exit 2
}
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
[[ "$SLUG" != "$PLATFORM_SLUG" ]] || refuse "slug ${PLATFORM_SLUG} tidak punya DB Odoo"
EMAIL=""; LOGIN=""; NAME=""; ROLE=""; ACTIVE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) [[ $# -ge 2 ]] || usage; EMAIL="${2,,}"; shift 2 ;;
    --login) [[ $# -ge 2 ]] || usage; LOGIN="$2"; shift 2 ;;
    --name) [[ $# -ge 2 ]] || usage; NAME="$2"; shift 2 ;;
    --role) [[ $# -ge 2 ]] || usage; ROLE="$2"; shift 2 ;;
    --active) [[ $# -ge 2 ]] || usage; ACTIVE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
[[ ${#EMAIL} -le 254 && "$EMAIL" =~ $EMAIL_RE ]] || die "email tidak valid"
[[ -n "$LOGIN" ]] || LOGIN="$EMAIL"
[[ "$LOGIN" =~ $LOGIN_RE ]] || die "login tidak valid"
[[ -z "$NAME" || "$NAME" =~ $NAME_RE ]] || die "--name tidak valid"
[[ "$ROLE" == user || "$ROLE" == admin ]] || die "--role harus user|admin"
[[ "$ACTIVE" == true || "$ACTIVE" == false ]] || die "--active harus true|false"
REALM="$(kc_realm_for_env "$TENANT_ENV")"
LOG_PREFIX="odoo-user ${DB_NAME}"
EREF="$(email_ref "$EMAIL")"   # log tanpa email/login mentah (QA F5)
LREF=email; [[ "$LOGIN" == "$EMAIL" ]] || LREF="lain#$(email_ref "$LOGIN" | cut -d'#' -f2)"
log "user=${EREF} login=${LREF} role=${ROLE} active=${ACTIVE} mode=$([[ $DRY -eq 1 ]] && echo dry-run || echo apply)"

[[ -r "$HELPER" ]] || die "helper ${HELPER} belum ada (odoo-developer, branch feat/infra-saas-p1-odoo-user)"
container_running "$PG_CONTAINER" || die "container $PG_CONTAINER tidak berjalan"
container_running "$POOL_CONTAINER" || die "container $POOL_CONTAINER tidak berjalan"
if [[ $DRY -eq 0 ]]; then
  exec 8>"/run/lock/odoo-provision-${DB_NAME}.lock"   # sama dengan provision-odoo-*.sh / odoo-sso-user.sh
  flock -w 60 8 || die "provisioning ${DB_NAME} sedang berjalan (lock)"
fi
if [[ $DRY -eq 1 && -z "$(pgq "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" ]]; then
  block "DB ${DB_NAME} belum ada"
else
  require_tenant_db
fi

# ---- Keycloak (GET saja): tenant + user
kc_init "$REALM"
kc_org_by_slug "$SLUG"
[[ -n "$ORG_ID" ]] || block "organization ${SLUG} belum ada (job kc_org_ensure)"
kc_user_by_email "$EMAIL"
if [[ -z "$KC_UID" ]]; then
  block "user Keycloak ${EREF} tidak ada (job kc_user_ensure dulu)"
else
  [[ -n "$ORG_ID" ]] && require_same_tenant "$KC_USER_JSON" "$ORG_ALIAS"
  if [[ -z "$NAME" ]]; then
    NAME="$(kc_json '" ".join(x for x in (d.get("firstName") or "", d.get("lastName") or "") if x) or d.get("email") or ""' "$KC_USER_JSON")"
    [[ "$NAME" =~ $NAME_RE ]] || NAME="$EMAIL"   # nama KC di luar NAME_RE (mis. non-ASCII) → email
  fi
fi

ODOO_UID="-"; CREATED=0
if [[ $BLOCKERS -gt 0 ]]; then
  log "helper Odoo TIDAK dijalankan (ada blocker)"
else
  export ODOO_USER_EMAIL="$EMAIL" ODOO_USER_LOGIN="$LOGIN" ODOO_USER_NAME="$NAME" ODOO_USER_ROLE="$ROLE" \
         ODOO_USER_ACTIVE="$ACTIVE" ODOO_USER_KC_ID="$KC_UID" ODOO_USER_OIDC_CLIENT_ID="odoo-${SLUG}-${TENANT_ENV}"
  ODOO_USER_DRY_RUN=false; [[ $DRY -eq 1 ]] && ODOO_USER_DRY_RUN=true
  export ODOO_USER_DRY_RUN
  pass_env=()
  for v in ODOO_USER_EMAIL ODOO_USER_LOGIN ODOO_USER_NAME ODOO_USER_ROLE ODOO_USER_ACTIVE ODOO_USER_KC_ID \
           ODOO_USER_DRY_RUN ODOO_USER_OIDC_CLIENT_ID; do
    pass_env+=(-e "$v")   # nama saja → nilai dari env wrapper (tidak di argv)
  done
  rc=0
  out="$(docker exec -i "${pass_env[@]}" "$POOL_CONTAINER" odoo shell -c "$ODOO_CONF_IN_CONTAINER" -d "$DB_NAME" \
           --no-http --workers=0 --max-cron-threads=0 --log-level=warn < "$HELPER" 2>&1)" || rc=$?
  grep -v '^RESULT ' <<<"$out" | tail -n 40 || true
  if [[ $rc -ne 0 ]]; then
    echo "ERROR: helper odoo_user_ensure.py exit ${rc}" >&2
    exit "$rc"   # 2 prasyarat · 3 ditolak · 1 tak terduga (diteruskan apa adanya)
  fi
  hres="$(grep '^RESULT ' <<<"$out" | tail -n1 || true)"
  [[ -n "$hres" ]] || die "helper tidak mencetak baris RESULT"
  parsed="$(python3 -c '
import re, sys
kv = dict(t.split("=", 1) for t in sys.argv[1].split()[1:] if "=" in t)
ok = (kv.get("db") == sys.argv[2] and kv.get("kc_user") == sys.argv[3]
      and re.fullmatch(r"[0-9]+|-", kv.get("odoo_user", "")) and kv.get("created") in ("0", "1")
      and re.fullmatch(r"[0-9]{1,4}", kv.get("changed", "")))
if not ok:
    sys.exit("RESULT helper tidak valid")
print(kv["odoo_user"], kv["created"], kv["changed"])' "$hres" "$DB_NAME" "$KC_UID")" || die "RESULT helper tidak valid"
  read -r ODOO_UID CREATED hchanged <<<"$parsed"
  CHANGED=$((CHANGED + hchanged))
fi

echo "RESULT db=${DB_NAME} odoo_user=${ODOO_UID} kc_user=${KC_UID:--} created=${CREATED} changed=${CHANGED}$(result_tail)"
