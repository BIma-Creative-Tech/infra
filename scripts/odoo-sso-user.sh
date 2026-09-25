#!/usr/bin/env bash
# Onboarding/offboarding user SSO satu tenant-env (plan 04 §3.3, ADR 0008 #3). IDEMPOTEN.
#
#   scripts/odoo-sso-user.sh <slug> <prod|demo|staging> --email <e> [--login <odoo login>] [--create-kc] [--admin]
#                            [--grant|--revoke|--resend-invite] [--first-name <f>] [--last-name <l>] [--dry-run]
#
#   --email          username Keycloak (= email, huruf kecil). Satu identitas per orang di realm platform.
#   --login          login res.users di DB tenant (default = email). res.users TIDAK pernah dibuat skrip ini —
#                    dibuat admin tenant/ops (hak akses = keputusan bisnis).
#   --create-kc      buat user Keycloak bila belum ada (enabled, emailVerified=false, required actions UPDATE_PASSWORD
#                    [+ CONFIGURE_TOTP bila --admin]) lalu kirim execute-actions-email (undangan).
#   --admin          admin tenant (grant): pastikan CONFIGURE_TOTP (bila user belum punya OTP).
#   --grant          (default) assign client role odoo_access + tautkan res.users (oauth_provider_id, oauth_uid = id Keycloak).
#   --revoke         cabut client role odoo_access untuk tenant ini (role gate menolak login). Tautan res.users
#                    DIBIARKAN (melepas tautan = password lokal user aktif lagi); arsipkan res.users bila perlu.
#                    Nonaktifkan user di SEMUA tenant: disable user Keycloak (console/Admin REST), bukan skrip ini.
#   --resend-invite  aksi TERSENDIRI (BUG-J5-01): HANYA kirim ulang execute-actions-email untuk required actions yang
#                    masih tertunda. Tidak pernah assign role, membuat user Keycloak, atau menautkan res.users.
#                    Syarat (selain itu BLOKIR → dry-run blockers≥1, apply exit≠0): user Keycloak ada, SUDAH punya
#                    client role odoo_access pada client tenant ini (user yang dicabut ditolak — pakai --grant), dan
#                    res.users <login> aktif SUDAH tertaut (provider tenant + oauth_uid = id Keycloak).
#                    --admin diterima (kontrak dispatcher) tetapi tidak mengubah apa pun pada aksi ini.
#                    --grant/--revoke/--resend-invite saling eksklusif.
#   --dry-run        hanya GET Admin REST + SELECT psql; mencetak rencana.
# Syarat: provision-odoo-sso.sh <slug> <env> sudah dijalankan (client Keycloak + role + provider Odoo ada).
# Output baris terakhir: RESULT db=<db> realm=<r> client=<clientId> kc_user=<id> odoo_user=<id> action=<grant|revoke|resend_invite> changed=<n>
# (tanpa email/login — log job tanpa PII). JANGAN jalankan dengan `bash -x`.
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
# shellcheck source=lib/odoo-exec.sh
source "$LIB/odoo-exec.sh"
# shellcheck source=lib/keycloak-admin.sh
source "$LIB/keycloak-admin.sh"

OIDC_ROLE=odoo_access            # sama dengan provision-odoo-sso.sh
EMAIL_RE='^[a-z0-9._%+-]+@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
LOGIN_RE='^[A-Za-z0-9._@+-]{1,254}$'
NAME_RE="^[[:alpha:][:space:].'-]{1,100}$"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

usage() {
  echo "pemakaian: $0 <slug> <prod|demo|staging> --email <e> [--login <l>] [--create-kc] [--admin] [--grant|--revoke|--resend-invite] [--first-name <f>] [--last-name <l>] [--dry-run]" >&2
  exit 2
}
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
EMAIL=""; LOGIN=""; CREATE_KC=0; ADMIN=0; ACTION=grant; NACTION=0; FIRST=""; LAST=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) [[ $# -ge 2 ]] || usage; EMAIL="${2,,}"; shift 2 ;;
    --login) [[ $# -ge 2 ]] || usage; LOGIN="$2"; shift 2 ;;
    --first-name) [[ $# -ge 2 ]] || usage; FIRST="$2"; shift 2 ;;
    --last-name) [[ $# -ge 2 ]] || usage; LAST="$2"; shift 2 ;;
    --create-kc) CREATE_KC=1; shift ;;
    --admin) ADMIN=1; shift ;;
    --grant) ACTION=grant; NACTION=$((NACTION+1)); shift ;;
    --revoke) ACTION=revoke; NACTION=$((NACTION+1)); shift ;;
    --resend-invite) ACTION=resend_invite; NACTION=$((NACTION+1)); shift ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
[[ ${#EMAIL} -le 254 && "$EMAIL" =~ $EMAIL_RE ]] || die "email tidak valid"
[[ -n "$LOGIN" ]] || LOGIN="$EMAIL"
[[ "$LOGIN" =~ $LOGIN_RE ]] || die "login tidak valid"
[[ -z "$FIRST" || "$FIRST" =~ $NAME_RE ]] || die "first-name tidak valid"
[[ -z "$LAST" || "$LAST" =~ $NAME_RE ]] || die "last-name tidak valid"
[[ $NACTION -le 1 ]] || die "--grant/--revoke/--resend-invite saling eksklusif (pilih satu)"
[[ "$ACTION" != revoke || ( $CREATE_KC -eq 0 && $ADMIN -eq 0 ) ]] \
  || die "--revoke tidak bisa digabung dengan --create-kc/--admin"
[[ "$ACTION" != resend_invite || $CREATE_KC -eq 0 ]] \
  || die "--resend-invite tidak bisa digabung dengan --create-kc (user baru = --grant --create-kc)"

REALM="$(kc_realm_for_env "$TENANT_ENV")"
CLIENT_ID="odoo-${SLUG}-${TENANT_ENV}"
MODE=apply; [[ $DRY -eq 1 ]] && MODE=dry-run

container_running "$PG_CONTAINER" || die "container $PG_CONTAINER tidak berjalan"
container_running "$POOL_CONTAINER" || die "container $POOL_CONTAINER tidak berjalan"
if [[ $DRY -eq 0 ]]; then
  exec 9>"/run/lock/odoo-provision-${DB_NAME}.lock"
  flock -w 60 9 || die "provisioning ${DB_NAME} sedang berjalan (lock)"
fi
DB_EXISTS=1
if [[ $DRY -eq 1 && -z "$(pgq "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" ]]; then
  DB_EXISTS=0; block "DB ${DB_NAME} belum ada"
else
  require_tenant_db
fi
log "realm=${REALM} client=${CLIENT_ID} email=${EMAIL} login=${LOGIN} action=${ACTION} mode=${MODE}"

# ---- provider Odoo (dibuat provision-odoo-sso.sh)
PROVIDER_ID=""
if [[ $DB_EXISTS -eq 1 && "$(pgq "SELECT state FROM ir_module_module WHERE name = 'sh_auth_oidc'" "$DB_NAME")" == installed ]]; then
  PROVIDER_ID="$(pgq "SELECT id FROM auth_oauth_provider WHERE client_id = '${CLIENT_ID}' AND sh_oidc_enabled ORDER BY id LIMIT 1" "$DB_NAME")"
fi
[[ -n "$PROVIDER_ID" || "$ACTION" == revoke ]] || block "provider Odoo ${CLIENT_ID} tidak ada di ${DB_NAME} — jalankan provision-odoo-sso.sh dulu"

# ---- Keycloak: client + role
kc_init "$REALM"
CLIENT_UUID="$(kc_json '(d[0]["id"] if d else "")' "$(kc_get "/clients?clientId=$(kc_urlencode "$CLIENT_ID")")")"
ROLE_JSON=""
if [[ -z "$CLIENT_UUID" ]]; then
  block "client Keycloak ${CLIENT_ID} tidak ada — jalankan provision-odoo-sso.sh dulu"
else
  kc_request GET "/clients/${CLIENT_UUID}/roles/${OIDC_ROLE}"
  if [[ "$KC_STATUS" == 200 ]]; then
    ROLE_JSON="$(kc_json '{"id": d["id"], "name": d["name"]}' "$KC_BODY")"
  else
    block "role ${OIDC_ROLE} pada ${CLIENT_ID}: HTTP ${KC_STATUS} — jalankan provision-odoo-sso.sh dulu"
  fi
fi

# ---- Keycloak: user
KC_UID=""; NEW_USER=0
users="$(kc_get "/users?username=$(kc_urlencode "$EMAIL")&exact=true&briefRepresentation=false")"
KC_UID="$(printf '%s' "$users" | python3 -c '
import json, sys
m = [u["id"] for u in json.load(sys.stdin) if u.get("username") == sys.argv[1]]
print(m[0] if len(m) == 1 else "")' "$EMAIL")"
REQ_ACTIONS=(UPDATE_PASSWORD); [[ $ADMIN -eq 1 ]] && REQ_ACTIONS+=(CONFIGURE_TOTP)

if [[ -z "$KC_UID" && "$ACTION" == resend_invite ]]; then
  block "user Keycloak ${EMAIL} tidak ada — resend_invite ditolak (user baru: --grant --create-kc)"
elif [[ -z "$KC_UID" ]]; then
  [[ "$ACTION" == grant ]] || die "user Keycloak ${EMAIL} tidak ada — tidak ada yang dicabut"
  [[ $CREATE_KC -eq 1 ]] || die "user Keycloak ${EMAIL} tidak ada — tambahkan --create-kc untuk membuat + mengundang"
  if change "user Keycloak ${EMAIL}: dibuat (required actions ${REQ_ACTIONS[*]}) + undangan email"; then
    body="$(python3 - "$EMAIL" "$FIRST" "$LAST" "${REQ_ACTIONS[@]}" <<'PY'
import json, sys
email, first, last, *actions = sys.argv[1:]
rep = {'username': email, 'email': email, 'enabled': True, 'emailVerified': False, 'requiredActions': actions}
if first:
    rep['firstName'] = first
if last:
    rep['lastName'] = last
print(json.dumps(rep))
PY
)"
    kc_send POST /users "$body" 201
    KC_UID="${KC_LOCATION##*/}"
    [[ "$KC_UID" =~ $UUID_RE ]] || die "id user baru tidak dikenali dari Location"
    NEW_USER=1
  fi
else
  urep="$(kc_get "/users/${KC_UID}")"
  log "user Keycloak ada (id ${KC_UID}, enabled=$(kc_json 'str(d.get("enabled")).lower()' "$urep"), required actions: $(kc_json '",".join(d.get("requiredActions") or []) or "-"' "$urep"))"
  if [[ $ADMIN -eq 1 && "$ACTION" == resend_invite ]]; then
    log "--admin diabaikan pada resend_invite (tidak mengubah required actions; pakai --grant --admin)"
  elif [[ $ADMIN -eq 1 ]]; then
    has_otp="$(kc_json 'str(any(c.get("type") == "otp" for c in d)).lower()' "$(kc_get "/users/${KC_UID}/credentials")")"
    pending="$(kc_json '" ".join(d.get("requiredActions") or [])' "$urep")"
    if [[ "$has_otp" == false && " $pending " != *" CONFIGURE_TOTP "* ]]; then
      if change "user ${EMAIL}: required action CONFIGURE_TOTP (admin tenant, belum punya OTP)"; then
        body="$(kc_json '{**{k: v for k, v in d.items() if k not in ("access", "credentials")}, "requiredActions": (d.get("requiredActions") or []) + ["CONFIGURE_TOTP"]}' "$urep")"
        kc_send PUT "/users/${KC_UID}" "$body" 204
      fi
    else
      log "user ${EMAIL}: OTP sudah ada / CONFIGURE_TOTP sudah tertunda"
    fi
  fi
fi

# send_invite → execute-actions-email untuk required actions yang masih tertunda (tidak mengubah user/role/tautan).
send_invite() {
  local actions
  actions="$(kc_json 'd.get("requiredActions") or []' "$(kc_get "/users/${KC_UID}")")"
  if [[ "$actions" == "[]" ]]; then
    log "tidak ada required action tertunda — undangan tidak dikirim"
  elif change "execute-actions-email ${actions} → ${EMAIL} (tautan kembali ke client ${CLIENT_ID})"; then
    kc_send PUT "/users/${KC_UID}/execute-actions-email?client_id=$(kc_urlencode "$CLIENT_ID")" "$actions" 204
  fi
}

ODOO_UID="-"
if [[ "$ACTION" == resend_invite ]]; then
  # ---- resend_invite: HANYA pemeriksaan read-only (GET Admin REST + SELECT psql) lalu kirim email. Tidak ada
  # assign role / pembuatan user / penautan res.users (BUG-J5-01: resend tidak boleh memulihkan akses yang dicabut).
  if [[ -n "$KC_UID" ]]; then
    [[ "$KC_UID" =~ $UUID_RE ]] || die "id user Keycloak tidak valid"
    if [[ -n "$ROLE_JSON" ]]; then
      has_role="$(kc_json 'str(any(r.get("name") == "'"$OIDC_ROLE"'" for r in d)).lower()' \
        "$(kc_get "/users/${KC_UID}/role-mappings/clients/${CLIENT_UUID}")")"
      if [[ "$has_role" == true ]]; then
        log "role ${OIDC_ROLE} (${CLIENT_ID}): dimiliki user ${EMAIL} (tidak diubah)"
      else
        block "user ${EMAIL} tidak punya role ${OIDC_ROLE} pada ${CLIENT_ID} (dicabut/belum di-grant) — resend_invite ditolak; pulihkan akses hanya lewat --grant"
      fi
    fi
    if [[ $DB_EXISTS -eq 1 && -n "$PROVIDER_ID" ]]; then
      row="$(pgq "SELECT u.id || '|' || u.active || '|' || coalesce(u.oauth_provider_id::text, '') || '|' || coalesce(u.oauth_uid, '') FROM res_users u WHERE u.login = '${LOGIN}'" "$DB_NAME")"
      IFS='|' read -r ruid active pid ouid <<<"${row:-|||}"
      if [[ -z "$row" ]]; then block "res.users login=${LOGIN} tidak ada di ${DB_NAME} — resend_invite ditolak"
      elif [[ "$active" != true && "$active" != t ]]; then block "res.users ${ruid} diarsipkan — resend_invite ditolak"
      elif [[ "$pid" != "$PROVIDER_ID" || "$ouid" != "$KC_UID" ]]; then
        block "res.users ${ruid} belum tertaut ke user Keycloak ini (provider ${pid:--}) — resend_invite ditolak; tautkan lewat --grant"
      else
        ODOO_UID="$ruid"; log "res.users ${ODOO_UID}: tertaut (tidak diubah)"
      fi
    fi
    if [[ $BLOCKERS -eq 0 ]]; then
      send_invite
    else
      log "execute-actions-email TIDAK direncanakan (ada blocker)"
    fi
  fi
else
# ---- undangan (execute-actions-email) untuk user baru (grant --create-kc)
if [[ -n "$KC_UID" && $NEW_USER -eq 1 ]]; then
  send_invite
elif [[ -z "$KC_UID" && $DRY -eq 1 ]]; then
  log "PLAN: execute-actions-email [${REQ_ACTIONS[*]}] → ${EMAIL}"
fi

# ---- client role odoo_access
if [[ -n "$ROLE_JSON" ]]; then
  has_role=false
  if [[ -n "$KC_UID" ]]; then
    has_role="$(kc_json 'str(any(r.get("name") == "'"$OIDC_ROLE"'" for r in d)).lower()' \
      "$(kc_get "/users/${KC_UID}/role-mappings/clients/${CLIENT_UUID}")")"
  fi
  if [[ "$ACTION" == grant && "$has_role" == false ]]; then
    change "role ${OIDC_ROLE} (${CLIENT_ID}) → user ${EMAIL}" \
      && kc_send POST "/users/${KC_UID}/role-mappings/clients/${CLIENT_UUID}" "[${ROLE_JSON}]" 204
  elif [[ "$ACTION" == revoke && "$has_role" == true ]]; then
    change "role ${OIDC_ROLE} (${CLIENT_ID}) dicabut dari user ${EMAIL}" \
      && kc_send DELETE "/users/${KC_UID}/role-mappings/clients/${CLIENT_UUID}" "[${ROLE_JSON}]" 204
  else
    log "role ${OIDC_ROLE}: sudah sesuai (${ACTION})"
  fi
elif [[ $DRY -eq 1 ]]; then
  log "PLAN: role ${OIDC_ROLE} (${CLIENT_ID}) ${ACTION} → user ${EMAIL} (setelah role ada)"
fi

# ---- tautan res.users (grant saja; tidak pernah membuat res.users)
if [[ "$ACTION" == grant && $DB_EXISTS -eq 1 && -n "$PROVIDER_ID" ]]; then
  if [[ $DRY -eq 1 ]]; then
    row="$(pgq "SELECT u.id || '|' || u.active || '|' || coalesce(u.oauth_provider_id::text, '') || '|' || coalesce(u.oauth_uid, '') || '|' || (u.id = coalesce((SELECT res_id FROM ir_model_data WHERE module = 'base' AND name = 'user_admin'), 0)) FROM res_users u WHERE u.login = '${LOGIN}'" "$DB_NAME")"
    IFS='|' read -r ODOO_UID active pid ouid is_admin <<<"${row:-||||}"
    if [[ -z "$row" ]]; then block "res.users login=${LOGIN} tidak ada di ${DB_NAME} — dibuat admin tenant/ops dulu (skrip tidak membuat user)"; ODOO_UID="-"
    elif [[ "$is_admin" == true || "$is_admin" == t ]]; then block "login=${LOGIN} = base.user_admin (break-glass) — tidak ditautkan"
    elif [[ "$active" != true && "$active" != t ]]; then block "res.users ${ODOO_UID} diarsipkan"
    elif [[ -n "$KC_UID" && "$pid" == "$PROVIDER_ID" && "$ouid" == "$KC_UID" ]]; then log "res.users ${ODOO_UID}: sudah tertaut"
    elif [[ -n "$ouid" && ( "$pid" != "$PROVIDER_ID" || "$ouid" != "${KC_UID:-<baru>}" ) ]]; then block "res.users ${ODOO_UID} sudah tertaut ke subject/provider lain (${pid}/${ouid})"
    else change "res.users ${ODOO_UID} (${LOGIN}) → oauth_provider_id=${PROVIDER_ID}, oauth_uid=${KC_UID:-<id user baru>}" || true
    fi
  else
    [[ "$KC_UID" =~ $UUID_RE ]] || die "id user Keycloak tidak valid"
    out="$(odoo_cli shell --log-level=warn <<PY 2>&1
U = env['res.users'].sudo().with_context(active_test=False)
u = U.search([('login', '=', '${LOGIN}')])
admin = env.ref('base.user_admin', raise_if_not_found=False)
if not u:
    raise SystemExit('LINK_ERROR res.users login tidak ada (skrip tidak membuat user)')
if admin and u == admin:
    raise SystemExit('LINK_ERROR base.user_admin = break-glass, tidak ditautkan')
if not u.active:
    raise SystemExit('LINK_ERROR res.users %d diarsipkan' % u.id)
if u.oauth_provider_id.id == ${PROVIDER_ID} and u.oauth_uid == '${KC_UID}':
    print('LINK=same')
else:
    if u.oauth_uid:
        raise SystemExit('LINK_ERROR res.users %d sudah tertaut ke provider %s / subject lain' % (u.id, u.oauth_provider_id.id))
    other = U.search([('oauth_provider_id', '=', ${PROVIDER_ID}), ('oauth_uid', '=', '${KC_UID}'), ('id', '!=', u.id)])
    if other:
        raise SystemExit('LINK_ERROR subject sudah tertaut ke res.users %d' % other.id)
    u.write({'oauth_provider_id': ${PROVIDER_ID}, 'oauth_uid': '${KC_UID}'})
    env.cr.commit()
    print('LINK=changed')
if u.share:
    print('WARN_SHARE=1')
print('ODOO_UID=%d' % u.id)
PY
)" || { echo "$out" >&2; die "odoo shell gagal"; }
    if grep -q '^LINK_ERROR' <<<"$out"; then die "$(grep -m1 '^LINK_ERROR' <<<"$out" | sed 's/^LINK_ERROR //')"; fi
    ODOO_UID="$(sed -n 's/^ODOO_UID=//p' <<<"$out" | tail -n1)"
    [[ "$ODOO_UID" =~ ^[0-9]+$ ]] || { echo "$out" >&2; die "output odoo shell tidak dikenali"; }
    if grep -q '^LINK=changed' <<<"$out"; then CHANGED=$((CHANGED+1)); log "UBAH: res.users ${ODOO_UID} ditautkan (provider ${PROVIDER_ID}, oauth_uid ${KC_UID})"
    else log "res.users ${ODOO_UID}: sudah tertaut"; fi
    grep -q '^WARN_SHARE=1' <<<"$out" && log "PERINGATAN: res.users ${ODOO_UID} adalah user portal/share"
  fi
elif [[ "$ACTION" == revoke ]]; then
  log "tautan res.users dibiarkan (password lokal tetap ditolak); arsipkan res.users bila user keluar dari tenant"
fi
fi  # grant|revoke

extra=""; [[ $DRY -eq 1 ]] && extra=" mode=dry-run blockers=${BLOCKERS}"
echo "RESULT db=${DB_NAME} realm=${REALM} client=${CLIENT_ID} kc_user=${KC_UID:--} odoo_user=${ODOO_UID:--} action=${ACTION} changed=${CHANGED}${extra}"
