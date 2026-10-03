#!/usr/bin/env bash
# Aktivasi SSO Keycloak (sh_auth_oidc) untuk satu tenant-env (plan 04 §3.4, ADR 0008). IDEMPOTEN.
#
#   scripts/provision-odoo-sso.sh <slug> <prod|demo|staging> [--host <fqdn>]… [--rotate-secret] [--disable]
#                                 [--dry-run] [--skip-smoke]
#
#   --host          semua hostname tenant-env (redirect URI eksak per host). Tanpa --host: prod/staging memakai
#                   host default (lib/odoo-pools.sh); demo WAJIB --host. Domain client baru → jalankan ulang dengan
#                   daftar host LENGKAP (redirectUris di-PUT sesuai daftar ini).
#   --rotate-secret regenerasi secret client di Keycloak lalu tulis file (efektif tanpa restart pool).
#   --disable       provider Odoo Allowed OFF + client Keycloak enabled=false. Tidak menghapus apa pun.
#   --dry-run       hanya GET Admin REST + SELECT psql + docker exec baca; mencetak rencana. Tidak menulis apa pun.
#   --skip-smoke    lewati uji /web/login + /sh_auth_oidc/authorize (mis. router Traefik tenant belum dibuat).
#
# Langkah (masing-masing dicek dulu; hanya diubah bila berbeda):
#  1. validasi slug/env/host (lib/odoo-pools.sh); realm prod|demo → platform, staging → platform-staging; flock per DB;
#     DB harus sudah ada (provision-odoo-db.sh).
#  2. Keycloak (client `automation`, Admin REST :8443, lib/keycloak-admin.sh): client `odoo-<slug>-<env>`
#     (representasi lib/odoo_sso_kc.py = plan 04 F12, redirect eksak), default scopes, client role `odoo_access`,
#     mapper role klaim literal `resource_access.<clientId>.roles`.
#  3. Secret client → <pool>/secrets/oidc/<db> (printf '%s', tanpa newline, 0440 root:<gid odoo>, dir 0750) hanya bila
#     berbeda; nilai tidak pernah dicetak. Dicek terbaca di container lewat mount /run/sh-oidc.
#  4. Odoo: install auth_oauth,sh_auth_oidc bila belum (one-off, pola provision-odoo-db.sh); ICP
#     auth_signup.invitation_scope=b2b, auth_oauth.authorization_header=True; provider lain dinonaktifkan; provider
#     platform dibuat/diperbarui (sumber secret file, role gate); ICP legacy sh_auth_oidc.client_secret.<id> dihapus.
#  5. Smoke: /web/login memuat link provider; /sh_auth_oidc/authorize → 303 ke realm dengan client_id + redirect_uri benar.
# Output baris terakhir:
#   RESULT db=<db> realm=<r> client=<clientId> provider=<id> hosts=<h,…> changed=<n> secret_file=<path> [mode=dry-run|disable]
# Exit ≠ 0 bila gagal. JANGAN jalankan dengan `bash -x` (token Admin REST ada di variabel).
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
# shellcheck source=lib/odoo-exec.sh
source "$LIB/odoo-exec.sh"
# shellcheck source=lib/keycloak-admin.sh
source "$LIB/keycloak-admin.sh"

# ---- Kontrak dengan modul sh_auth_oidc 19.0.1.2.0 (S1) — SATU-SATUNYA tempat nama field/nilai; sesuaikan di sini ----
OIDC_MODULE=sh_auth_oidc
OIDC_MODULE_MIN_VERSION=19.0.1.2.0
OIDC_F_SECRET_SOURCE=sh_oidc_secret_source      # Selection; nilai 'file' = SH_OIDC_SECRET_DIR/<db>
OIDC_V_SECRET_SOURCE="file"
OIDC_F_SECRET_ENV=sh_oidc_client_secret_env      # sumber lama (env) — dikosongkan
OIDC_F_REQUIRED_ROLE=sh_oidc_required_client_role
OIDC_LEGACY_SECRET_ICP_PREFIX=sh_auth_oidc.client_secret.
OIDC_ROLE=odoo_access
OIDC_SECRET_DIR_IN_CONTAINER=/run/sh-oidc         # compose: env SH_OIDC_SECRET_DIR + mount ro <pool>/secrets/oidc
OIDC_CALLBACK_PATH=/sh_auth_oidc/callback         # controllers/main.py CALLBACK_PATH
OIDC_AUTHORIZE_PATH=/sh_auth_oidc/authorize       # controllers/main.py AUTHORIZE_PATH
OIDC_BUTTON_LABEL="Masuk dengan SSO"

usage() {
  echo "pemakaian: $0 <slug> <prod|demo|staging> [--host <fqdn>]… [--rotate-secret] [--disable] [--dry-run] [--skip-smoke]" >&2
  exit 2
}
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
HOSTS=(); ROTATE=0; DISABLE=0; DRY=0; SMOKE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage; validate_host "$2"
            [[ " ${HOSTS[*]} " == *" $2 "* ]] || HOSTS+=("$2"); shift 2 ;;
    --rotate-secret) ROTATE=1; shift ;;
    --disable) DISABLE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --skip-smoke) SMOKE=0; shift ;;
    *) usage ;;
  esac
done
[[ $ROTATE -eq 0 || $DISABLE -eq 0 ]] || die "--rotate-secret dan --disable tidak bisa digabung"
[[ ${#HOSTS[@]} -gt 0 ]] || HOSTS=("$(default_host)")

REALM="$(kc_realm_for_env "$TENANT_ENV")"
ISSUER="$(kc_issuer "$REALM")"
CLIENT_ID="odoo-${SLUG}-${TENANT_ENV}"
SECRET_DIR="$(oidc_secret_dir)"   # 0750 root:$ODOO_GID (ODOO_GID di lib/odoo-pools.sh)
SECRET_FILE="$SECRET_DIR/$DB_NAME"
HOSTS_CSV="$(IFS=,; echo "${HOSTS[*]}")"
CHANGED=0
MODE=apply; [[ $DRY -eq 1 ]] && MODE=dry-run; [[ $DISABLE -eq 1 ]] && MODE="${MODE/apply/disable}" && [[ $DRY -eq 1 ]] && MODE=dry-run,disable


container_running "$PG_CONTAINER" || die "container $PG_CONTAINER tidak berjalan"
container_running "$POOL_CONTAINER" || die "container $POOL_CONTAINER tidak berjalan"
if [[ $DRY -eq 0 ]]; then
  exec 9>"/run/lock/odoo-provision-${DB_NAME}.lock"
  flock -n 9 || die "provisioning ${DB_NAME} sedang berjalan (lock)"
fi
DB_EXISTS=1
if [[ $DRY -eq 1 && -z "$(pgq "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" ]]; then
  DB_EXISTS=0; block "DB ${DB_NAME} belum ada — jalankan dulu scripts/provision-odoo-db.sh ${SLUG} ${TENANT_ENV}"
else
  require_tenant_db
fi
log "realm=${REALM} client=${CLIENT_ID} hosts=${HOSTS_CSV} mode=${MODE}"

TMP_FILES=()
cleanup() { local f; for f in "${TMP_FILES[@]}"; do rm -f "$f"; done; }
trap cleanup EXIT

# ============================================================== Keycloak
kc_init "$REALM"
kc_client_list() { kc_get "/clients?clientId=$(kc_urlencode "$CLIENT_ID")"; }
CLIENTS_JSON="$(kc_client_list)"
CLIENT_UUID="$(kc_json '(d[0]["id"] if d else "")' "$CLIENTS_JSON")"

if [[ $DISABLE -eq 1 ]]; then
  if [[ -z "$CLIENT_UUID" ]]; then
    log "client Keycloak ${CLIENT_ID} tidak ada — tidak ada yang dinonaktifkan"
  elif [[ "$(kc_json 'str(d[0].get("enabled")).lower()' "$CLIENTS_JSON")" == true ]]; then
    if change "client Keycloak ${CLIENT_ID}: enabled=false"; then
      body="$(kc_json '{k: (False if k == "enabled" else v) for k, v in d[0].items() if k not in ("secret", "access")}' "$CLIENTS_JSON")"
      kc_send PUT "/clients/${CLIENT_UUID}" "$body" 204
    fi
  else
    log "client Keycloak ${CLIENT_ID}: sudah disabled"
  fi
else
  hostargs=(); for h in "${HOSTS[@]}"; do hostargs+=(--host "$h"); done
  plan="$(printf '%s' "$CLIENTS_JSON" | python3 "$LIB/odoo_sso_kc.py" client --client-id "$CLIENT_ID" \
          --name "Odoo ${SLUG} (${TENANT_ENV})" --enabled 1 "${hostargs[@]}")"
  action="$(kc_json 'd["action"]' "$plan")"
  case "$action" in
    create)
      if change "client Keycloak ${CLIENT_ID}: dibuat (redirect ${HOSTS_CSV})"; then
        kc_send POST /clients "$(kc_json 'd["body"]' "$plan")" 201
        CLIENT_UUID="$(kc_json '(d[0]["id"] if d else "")' "$(kc_client_list)")"
        [[ -n "$CLIENT_UUID" ]] || die "client ${CLIENT_ID} tidak ditemukan setelah POST"
      fi ;;
    update)
      if change "client Keycloak ${CLIENT_ID}: $(kc_json '", ".join(d["changes"])' "$plan")"; then
        kc_send PUT "/clients/${CLIENT_UUID}" "$(kc_json 'd["body"]' "$plan")" 204
      fi ;;
    none) log "client Keycloak ${CLIENT_ID}: sesuai (uuid ${CLIENT_UUID})" ;;
    *) die "rencana client tidak dikenal: ${action}" ;;
  esac

  if [[ -z "$CLIENT_UUID" ]]; then
    # hanya dry-run untuk client baru: sisa objek Keycloak pasti dibuat
    change "client ${CLIENT_ID}: default scopes basic,profile,email,acr (optional kosong)" || true
    change "client ${CLIENT_ID}: role ${OIDC_ROLE}" || true
    change "client ${CLIENT_ID}: mapper 'client roles' → resource_access.${CLIENT_ID}.roles (ID/access/userinfo)" || true
  else
    # default/optional client scopes
    scopes_in="$(printf '{"default": %s, "optional": %s, "all": %s}' \
      "$(kc_get "/clients/${CLIENT_UUID}/default-client-scopes")" \
      "$(kc_get "/clients/${CLIENT_UUID}/optional-client-scopes")" \
      "$(kc_get "/client-scopes")")"
    splan="$(printf '%s' "$scopes_in" | python3 "$LIB/odoo_sso_kc.py" scopes)"
    missing="$(kc_json '",".join(d["missing"])' "$splan")"
    [[ -z "$missing" ]] || die "client scope realm tidak ada: ${missing}"
    while IFS=' ' read -r op sid sname; do
      [[ -n "$op" ]] || continue
      case "$op" in
        add-default) change "scope default ${sname}: ditambah" && kc_send PUT "/clients/${CLIENT_UUID}/default-client-scopes/${sid}" "" 204 ;;
        remove-default) change "scope default ${sname}: dilepas" && kc_send DELETE "/clients/${CLIENT_UUID}/default-client-scopes/${sid}" "" 204 ;;
        remove-optional) change "scope optional ${sname}: dilepas" && kc_send DELETE "/clients/${CLIENT_UUID}/optional-client-scopes/${sid}" "" 204 ;;
      esac || true
    done < <(kc_json '"\n".join(" ".join(o) for o in d["ops"])' "$splan"; echo)

    # client role odoo_access
    kc_request GET "/clients/${CLIENT_UUID}/roles/${OIDC_ROLE}"
    case "$KC_STATUS" in
      200) log "role ${OIDC_ROLE}: ada" ;;
      404) if change "role ${OIDC_ROLE}: dibuat"; then
             kc_send POST "/clients/${CLIENT_UUID}/roles" \
               "{\"name\": \"${OIDC_ROLE}\", \"description\": \"Login Odoo ${DB_NAME} (sh_auth_oidc role gate)\"}" 201
           fi ;;
      *) die "GET role ${OIDC_ROLE}: HTTP ${KC_STATUS}" ;;
    esac

    # client role odoo_admin (dikelola kc-realm-sync, platform.json clientRoles) — HANYA dibuat bila hilang dan realm
    # sudah di-sync (scope tenant ada): tanpa ini langkah onboarding kc_user_set_roles(odoo=admin) gagal 403 karena
    # cp-admin sengaja tanpa manage-clients (2026-10-03, tenant ujiq). Deskripsi = platform.json (sync tidak membandingkan).
    if [[ "$(kc_json 'str(d.get("realm_sync", False)).lower()' "$splan")" == true ]]; then
      kc_request GET "/clients/${CLIENT_UUID}/roles/odoo_admin"
      case "$KC_STATUS" in
        200) log "role odoo_admin: ada" ;;
        404) if change "role odoo_admin: dibuat"; then
               kc_send POST "/clients/${CLIENT_UUID}/roles" \
                 '{"name": "odoo_admin", "description": "Admin Odoo tenant (group Settings, job odoo_user_ensure)"}' 201
             fi ;;
        *) die "GET role odoo_admin: HTTP ${KC_STATUS}" ;;
      esac
    else
      log "realm belum di-sync kc-realm-sync (scope tenant tidak ada): scope tenant & role odoo_admin dilewati"
    fi

    # mapper klaim role (nama klaim literal)
    mplan="$(kc_get "/clients/${CLIENT_UUID}/protocol-mappers/models" | python3 "$LIB/odoo_sso_kc.py" mapper --client-id "$CLIENT_ID")"
    case "$(kc_json 'd["action"]' "$mplan")" in
      create) if change "mapper 'client roles': dibuat (resource_access.${CLIENT_ID}.roles)"; then
                kc_send POST "/clients/${CLIENT_UUID}/protocol-mappers/models" "$(kc_json 'd["body"]' "$mplan")" 201
              fi ;;
      update) if change "mapper 'client roles': $(kc_json '", ".join(d["changes"])' "$mplan")"; then
                kc_send PUT "/clients/${CLIENT_UUID}/protocol-mappers/models/$(kc_json 'd["id"]' "$mplan")" \
                  "$(kc_json 'd["body"]' "$mplan")" 204
              fi ;;
      none) log "mapper 'client roles': sesuai" ;;
    esac
  fi
fi

# ============================================================== Secret file
# secret_matches → 0 bila file = secret di KC_SECRET (tanpa mencetak nilai)
KC_SECRET=""
fetch_secret() {
  local method=GET
  [[ "${1:-}" == rotate ]] && method=POST
  kc_request "$method" "/clients/${CLIENT_UUID}/client-secret"
  [[ "$KC_STATUS" == 200 ]] || { KC_BODY=""; die "${method} client-secret: HTTP ${KC_STATUS}"; }
  KC_SECRET="$(printf '%s' "$KC_BODY" | python3 -c '
import json, sys
v = json.load(sys.stdin).get("value") or ""
if not v or len(v) > 1024 or any(ord(c) < 0x21 or ord(c) == 0x7f for c in v):
    sys.exit("secret client kosong/tidak valid")
sys.stdout.write(v)')" || die "secret client dari Keycloak tidak valid"
  KC_BODY=""
}
file_meta() { stat -c '%a %u:%g' "$1" 2>/dev/null || true; }

if [[ $DISABLE -eq 0 ]]; then
  if [[ -z "$CLIENT_UUID" ]]; then
    change "secret file ${SECRET_FILE}: ditulis dari secret client baru (0440 root:${ODOO_GID})" || true
  else
    if [[ $ROTATE -eq 1 ]]; then
      if change "secret client ${CLIENT_ID}: DIROTASI di Keycloak"; then fetch_secret rotate; fi
    else
      fetch_secret
    fi
    if [[ -n "$KC_SECRET" ]]; then
      [[ -d "$POOL_DIR/secrets" ]] || die "$POOL_DIR/secrets tidak ada — jalankan odoo-pool-bootstrap.sh"
      if [[ "$(file_meta "$SECRET_DIR")" != "750 0:${ODOO_GID}" ]]; then
        change "dir ${SECRET_DIR}: 0750 root:${ODOO_GID} (sekarang: $(file_meta "$SECRET_DIR" | grep . || echo 'tidak ada'))" \
          && install -d -m 0750 -o root -g "$ODOO_GID" "$SECRET_DIR"
      fi
      if [[ -f "$SECRET_FILE" && ! -L "$SECRET_FILE" ]] && cmp -s <(printf '%s' "$KC_SECRET") "$SECRET_FILE"; then
        log "secret file: isi sesuai"
        if [[ "$(file_meta "$SECRET_FILE")" != "440 0:${ODOO_GID}" ]]; then
          change "secret file: mode/owner → 0440 root:${ODOO_GID}" \
            && { chown "root:${ODOO_GID}" "$SECRET_FILE"; chmod 0440 "$SECRET_FILE"; }
        fi
      elif change "secret file ${SECRET_FILE}: ditulis (isi berbeda/baru, tanpa newline)"; then
        tmp="$(mktemp "${SECRET_DIR}/.${DB_NAME}.XXXXXX")"; TMP_FILES+=("$tmp")
        printf '%s' "$KC_SECRET" > "$tmp"
        chown "root:${ODOO_GID}" "$tmp"; chmod 0440 "$tmp"
        mv -f "$tmp" "$SECRET_FILE"   # rename atomik di direktori yang di-mount (bukan mount per file)
      fi
    elif [[ $DRY -eq 1 ]]; then
      log "PLAN: secret file ${SECRET_FILE}: ditulis setelah rotasi"
    fi
  fi
fi

# Mount + env di container (compose plan 04). Tanpa ini provider sumber 'file' gagal saat token exchange.
MOUNT_OK=0
in_dir="$(container_env "$POOL_CONTAINER" SH_OIDC_SECRET_DIR)"
trusted="$(container_env "$POOL_CONTAINER" SH_OIDC_TRUSTED_ISSUERS)"
if [[ "$in_dir" != "$OIDC_SECRET_DIR_IN_CONTAINER" ]]; then
  log "PERINGATAN: ${POOL_CONTAINER} tanpa SH_OIDC_SECRET_DIR=${OIDC_SECRET_DIR_IN_CONTAINER} (pool belum di-recreate dengan compose plan 04)"
elif [[ ",${trusted// /}," != *",${ISSUER},"* ]]; then
  log "PERINGATAN: ${ISSUER} tidak ada di SH_OIDC_TRUSTED_ISSUERS container"
elif [[ -n "$KC_SECRET" ]]; then
  if [[ $DRY -eq 1 && ! -f "$SECRET_FILE" ]]; then
    log "PLAN: file akan terlihat di container sebagai ${OIDC_SECRET_DIR_IN_CONTAINER}/${DB_NAME}"; MOUNT_OK=1
  elif [[ "$(docker exec "$POOL_CONTAINER" sha256sum "${OIDC_SECRET_DIR_IN_CONTAINER}/${DB_NAME}" 2>/dev/null | cut -d' ' -f1)" \
          == "$(printf '%s' "$KC_SECRET" | sha256sum | cut -d' ' -f1)" ]]; then
    log "container: ${OIDC_SECRET_DIR_IN_CONTAINER}/${DB_NAME} terbaca user Odoo, isi = secret client"; MOUNT_OK=1
  elif [[ $DRY -eq 1 ]]; then
    log "PLAN: isi file di container akan sama setelah ditulis"; MOUNT_OK=1
  else
    log "PERINGATAN: ${OIDC_SECRET_DIR_IN_CONTAINER}/${DB_NAME} tidak terbaca/berbeda di ${POOL_CONTAINER}"
  fi
fi
KC_SECRET=""
if [[ $DISABLE -eq 0 && $DRY -eq 0 && $MOUNT_OK -eq 0 ]]; then
  die "provider Odoo TIDAK diubah: secret file belum terbaca di container (compose plan 04: env + mount, lalu recreate pool)"
fi

# ============================================================== Odoo
# Nilai provider yang diinginkan (JSON) — dipakai odoo shell (apply) dan perbandingan SELECT (dry-run).
PROVIDER_VALS="$(python3 - "$REALM" "$ISSUER" "$CLIENT_ID" "$OIDC_BUTTON_LABEL" "$OIDC_F_SECRET_SOURCE" \
  "$OIDC_V_SECRET_SOURCE" "$OIDC_F_SECRET_ENV" "$OIDC_F_REQUIRED_ROLE" "$OIDC_ROLE" <<'PY'
import json, sys
realm, iss, client_id, label, f_src, v_src, f_env, f_role, role = sys.argv[1:]
oidc = iss + '/protocol/openid-connect'
print(json.dumps({
    'name': f'Keycloak ({realm})', 'client_id': client_id, 'enabled': True,
    'auth_endpoint': oidc + '/auth', 'validation_endpoint': oidc + '/userinfo',
    'scope': 'openid profile email', 'body': label,
    'sh_oidc_enabled': True, 'sh_oidc_issuer': iss,
    'sh_oidc_token_endpoint': oidc + '/token', 'sh_oidc_jwks_uri': oidc + '/certs',
    'sh_oidc_allow_signup': False, f_src: v_src, f_env: False, f_role: role,
}, sort_keys=True))
PY
)"
ICP_VALS='{"auth_signup.invitation_scope": "b2b", "auth_oauth.authorization_header": "True"}'

# DB belum ada (hanya mungkin di dry-run) → modul dianggap belum ter-install
module_state() { if [[ $DB_EXISTS -eq 1 ]]; then pgq "SELECT state FROM ir_module_module WHERE name = '$1'" "$DB_NAME"; fi; }
module_db_version() {
  if [[ $DB_EXISTS -eq 1 ]]; then pgq "SELECT coalesce(latest_version, '') FROM ir_module_module WHERE name = '$1' AND state = 'installed'" "$DB_NAME"; fi
}
code_version="$(docker exec "$POOL_CONTAINER" python3 -c 'import ast, sys; print(ast.literal_eval(open(sys.argv[1]).read())["version"])' \
  "/mnt/extra-addons/shared/${OIDC_MODULE}/__manifest__.py" 2>/dev/null || true)"
st_oauth="$(module_state auth_oauth)"; st_oidc="$(module_state "$OIDC_MODULE")"
db_version="$(module_db_version "$OIDC_MODULE")"
log "modul: auth_oauth='${st_oauth:-absent}' ${OIDC_MODULE}='${st_oidc:-absent}' (DB ${db_version:--}, kode pool ${code_version:--})"

PROVIDER_ID=""
if [[ $DISABLE -eq 1 ]]; then
  if [[ "$st_oidc" != installed ]]; then
    log "${OIDC_MODULE} tidak ter-install — tidak ada provider untuk dinonaktifkan"
  else
    row="$(pgq "SELECT id || ' ' || coalesce(enabled, false) FROM auth_oauth_provider WHERE client_id = '${CLIENT_ID}' ORDER BY id LIMIT 1" "$DB_NAME")"
    PROVIDER_ID="${row%% *}"
    if [[ -z "$row" ]]; then log "provider ${CLIENT_ID} tidak ada"
    elif [[ "${row##* }" == t || "${row##* }" == true ]]; then
      if change "provider ${PROVIDER_ID} (${CLIENT_ID}): Allowed OFF"; then
        out="$(odoo_cli shell --log-level=warn <<PY 2>&1
p = env['auth.oauth.provider'].sudo().browse(${PROVIDER_ID})
p.write({'enabled': False})
env.cr.commit()
print('DISABLED=%d' % p.id)
PY
)" || { echo "$out" >&2; die "odoo shell gagal"; }
        grep -q "^DISABLED=${PROVIDER_ID}$" <<<"$out" || { echo "$out" >&2; die "provider tidak dinonaktifkan"; }
      fi
    else
      log "provider ${PROVIDER_ID}: sudah Allowed OFF"
    fi
  fi
else
  version_ge "${code_version:-0}" "$OIDC_MODULE_MIN_VERSION" \
    || block "kode ${OIDC_MODULE} di ${POOL_CONTAINER} = '${code_version:-?}' < ${OIDC_MODULE_MIN_VERSION} — naikkan submodule addons + recreate pool dulu"
  # 4a. modul
  for m in auth_oauth "$OIDC_MODULE"; do
    st="$(module_state "$m")"
    [[ -z "$st" || "$st" == uninstalled || "$st" == installed ]] || block "modul ${m} state='${st}' — periksa manual"
  done
  if [[ "$st_oauth" != installed || "$st_oidc" != installed ]]; then
    if change "install auth_oauth,${OIDC_MODULE} (one-off --stop-after-init)"; then
      odoo_cli -i "auth_oauth,${OIDC_MODULE}" --stop-after-init --log-level=warn
      [[ "$(module_state "$OIDC_MODULE")" == installed ]] || die "${OIDC_MODULE} gagal di-install"
      db_version="$(module_db_version "$OIDC_MODULE")"
    fi
  elif ! version_ge "$db_version" "$OIDC_MODULE_MIN_VERSION"; then
    block "${OIDC_MODULE} ter-install versi ${db_version} < ${OIDC_MODULE_MIN_VERSION}: backup DB lalu -u ${OIDC_MODULE} (docs/03-operations/odoo.md §Upgrade) — skrip tidak meng-upgrade otomatis"
  fi

  if [[ $DRY -eq 1 ]]; then
    # 4b (dry-run): bandingkan dengan SELECT saja
    if [[ "$st_oidc" != installed ]]; then
      change "ICP auth_signup.invitation_scope=b2b, auth_oauth.authorization_header=True (setelah install; auth_signup install men-set b2c)" || true
      change "provider non-platform bawaan (Odoo.com — enabled=True dari data auth_oauth) dinonaktifkan" || true
      change "provider 'Keycloak (${REALM})' ${CLIENT_ID} dibuat (${OIDC_F_SECRET_SOURCE}=${OIDC_V_SECRET_SOURCE}, ${OIDC_F_REQUIRED_ROLE}=${OIDC_ROLE})" || true
      PROVIDER_ID=new
    else
      has_cols="$(pgq "SELECT count(*) FROM information_schema.columns WHERE table_name = 'auth_oauth_provider' AND column_name IN ('${OIDC_F_SECRET_SOURCE}', '${OIDC_F_REQUIRED_ROLE}')" "$DB_NAME")"
      [[ "$has_cols" == 2 ]] || log "PERINGATAN: kolom ${OIDC_F_SECRET_SOURCE}/${OIDC_F_REQUIRED_ROLE} belum ada di DB (modul lama)"
      icp_now="$(pgq "SELECT coalesce(json_object_agg(key, value), '{}') FROM ir_config_parameter WHERE key IN ('auth_signup.invitation_scope', 'auth_oauth.authorization_header')" "$DB_NAME")"
      prov_now="$(pgq "SELECT coalesce(json_agg(row_to_json(p) ORDER BY p.id), '[]') FROM auth_oauth_provider p" "$DB_NAME")"
      legacy="$(pgq "SELECT count(*) FROM ir_config_parameter WHERE key LIKE '${OIDC_LEGACY_SECRET_ICP_PREFIX//_/\\_}%'" "$DB_NAME")"
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" == PROVIDER_ID=* ]]; then PROVIDER_ID="${line#PROVIDER_ID=}"; else change "$line" || true; fi
      done < <(python3 - "$PROVIDER_VALS" "$ICP_VALS" "$icp_now" "$prov_now" "$legacy" <<'PY'
import json, sys
want, icp_want, icp_now, provs, legacy = (json.loads(a) for a in sys.argv[1:6])
for k, v in icp_want.items():
    if icp_now.get(k) != v:
        print(f'ICP {k}: {icp_now.get(k)!r} -> {v!r}')
mine = [p for p in provs if p.get('client_id') == want['client_id']]
for p in provs:
    if p['id'] not in [m['id'] for m in mine[:1]] and p.get('enabled'):
        print(f"provider {p['id']} ({p.get('name')}): Allowed OFF")
if not mine:
    print(f"provider {want['name']} {want['client_id']}: dibuat")
    print('PROVIDER_ID=new')
else:
    p = mine[0]
    diff = []
    for k, v in want.items():
        cur = p.get(k, '<kolom tidak ada>')
        if isinstance(cur, dict):
            cur = cur.get('en_US')
        if (cur or False) != (v or False):
            diff.append(f'{k}: {cur!r} -> {v!r}')
    if diff:
        print(f"provider {p['id']}: " + '; '.join(diff))
    print(f"PROVIDER_ID={p['id']}")
if legacy:
    print(f'ICP legacy client_secret.*: {legacy} baris dihapus')
PY
)
    fi
  else
    # 4b. odoo shell: ICP + provider (nilai sudah divalidasi; JSON dari python json.dumps, tanpa ''' )
    [[ "$PROVIDER_VALS$ICP_VALS" != *"'''"* ]] || die "nilai provider tidak valid"
    shell_out="$(odoo_cli shell --log-level=warn <<PY 2>&1
import json
changed = 0
want = json.loads(r'''${PROVIDER_VALS}''')
icp_want = json.loads(r'''${ICP_VALS}''')
ICP = env['ir.config_parameter'].sudo()
for key, val in icp_want.items():
    if ICP.get_param(key) != val:
        ICP.set_param(key, val)
        changed += 1
        print('CHANGE ICP %s=%s' % (key, val))
P = env['auth.oauth.provider'].sudo().with_context(active_test=False, lang='en_US')
missing = [f for f in want if f not in P._fields]
if missing:
    raise SystemExit('FIELD_MISSING %s' % ','.join(missing))
mine = P.search([('client_id', '=', want['client_id'])], order='id')
if len(mine) > 1:
    raise SystemExit('DUPLICATE provider client_id %s: %s' % (want['client_id'], mine.ids))
if not mine:
    mine = P.create(want)
    changed += 1
    print('CHANGE provider %d dibuat' % mine.id)
else:
    diff = {k: v for k, v in want.items() if (mine[k] or False) != (v or False)}
    if diff:
        mine.write(diff)
        changed += 1
        print('CHANGE provider %d: %s' % (mine.id, ', '.join(sorted(diff))))
for other in P.search([('id', '!=', mine.id), ('enabled', '=', True)]):
    other.write({'enabled': False})
    changed += 1
    print('CHANGE provider %d (%s): Allowed OFF' % (other.id, other.name))
legacy = ICP.search([('key', '=like', '${OIDC_LEGACY_SECRET_ICP_PREFIX}%')])
if legacy:
    n = len(legacy)
    legacy.unlink()
    changed += 1
    print('CHANGE ICP legacy client_secret: %d dihapus' % n)
env.cr.commit()
print('PROVIDER_ID=%d' % mine.id)
print('SHELL_CHANGED=%d' % changed)
PY
)" || { echo "$shell_out" >&2; die "odoo shell gagal"; }
    grep -E '^CHANGE ' <<<"$shell_out" | sed "s/^CHANGE /[$DB_NAME] UBAH: /" || true
    sc="$(sed -n 's/^SHELL_CHANGED=//p' <<<"$shell_out" | tail -n1)"
    PROVIDER_ID="$(sed -n 's/^PROVIDER_ID=//p' <<<"$shell_out" | tail -n1)"
    [[ "$sc" =~ ^[0-9]+$ && "$PROVIDER_ID" =~ ^[0-9]+$ ]] || { echo "$shell_out" >&2; die "output odoo shell tidak dikenali"; }
    CHANGED=$((CHANGED+sc))
  fi
fi
log "provider id=${PROVIDER_ID:--}"

# ============================================================== Smoke
if [[ $DRY -eq 0 && $SMOKE -eq 1 && -n "$PROVIDER_ID" ]]; then
  for h in "${HOSTS[@]}"; do
    page="$(curl -sS --max-time 20 --resolve "${h}:443:127.0.0.1" "https://${h}/web/login")" || die "smoke ${h}: /web/login gagal"
    if [[ $DISABLE -eq 1 ]]; then
      ! grep -qE "${OIDC_AUTHORIZE_PATH}\?provider=${PROVIDER_ID}(\"|&)" <<<"$page" || die "smoke ${h}: link provider masih tampil"
      log "smoke ${h}: link provider tidak tampil (disabled)"; continue
    fi
    grep -qE "${OIDC_AUTHORIZE_PATH}\?provider=${PROVIDER_ID}(\"|&)" <<<"$page" \
      || die "smoke ${h}: /web/login tanpa link ${OIDC_AUTHORIZE_PATH}?provider=${PROVIDER_ID} (worker belum memuat modul? AC-S4)"
    res="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "${h}:443:127.0.0.1" \
           "https://${h}${OIDC_AUTHORIZE_PATH}?provider=${PROVIDER_ID}")" || die "smoke ${h}: authorize gagal"
    want_cb="redirect_uri=$(kc_urlencode "https://${h}${OIDC_CALLBACK_PATH}")&"
    [[ "$res" == "303 ${ISSUER}/protocol/openid-connect/auth?"* && "$res" == *"client_id=${CLIENT_ID}&"* && "$res" == *"$want_cb"* ]] \
      || die "smoke ${h}: authorize tidak 303 ke ${ISSUER} dengan client_id/redirect_uri benar (dapat: ${res%%\?*})"
    log "smoke ${h}: /web/login memuat link; authorize → 303 ${ISSUER} client_id=${CLIENT_ID}"
  done
fi

extra=""; [[ "$MODE" != apply ]] && extra=" mode=${MODE}"
[[ $DRY -eq 1 ]] && extra+=" blockers=${BLOCKERS}"
echo "RESULT db=${DB_NAME} realm=${REALM} client=${CLIENT_ID} provider=${PROVIDER_ID:--} hosts=${HOSTS_CSV} changed=${CHANGED} secret_file=${SECRET_FILE}${extra}"
