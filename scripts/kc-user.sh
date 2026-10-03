#!/usr/bin/env bash
# User Keycloak per tenant (job kc_user_*, kontrak saas-phase-1-contract.md §0/§1/§1.1, ADR 0017). IDEMPOTEN.
#
#   scripts/kc-user.sh ensure  <slug> <env> --email <e> --tenant-id <uuid> [--name <n>] [--no-invite] [--adopt]
#                                           [--dry-run]
#   scripts/kc-user.sh roles   <slug> <env> --email <e> --cp-role <none|superadmin|ops|client_admin|client_user>
#                                           [--odoo <none|user|admin>] [--dry-run]
#   scripts/kc-user.sh enabled <slug> <env> --email <e> --enabled <true|false> [--dry-run]
#   scripts/kc-user.sh email   <slug> <env> --email <e> --action <UPDATE_PASSWORD|VERIFY_EMAIL|CONFIGURE_TOTP> [--dry-run]
#
# Realm dari env (prod|demo → platform, staging → platform-staging). tenant slug → Organization `name=<slug>`;
# tenant_id = alias org (§0.2) — host tidak pernah mempercayai tenant_id dari job tanpa mencocokkannya ke org.
#
# ensure  user by email (eksak, email/username). Tidak ada → dibuat (username = email, emailVerified=false, atribut
#         tenant_id, required action UPDATE_PASSWORD) + execute-actions-email (kecuali --no-invite; tautan kembali
#         ke client control-plane). Ada → tenant_id kosong diisi; beda → exit 3 (lintas tenant). Pastikan member org.
#         Nama (--name) hanya dipakai saat membuat (first word → firstName, sisanya → lastName).
#         ADOPSI (kontrak v1.2 §5, QA F1b): user yang SUDAH ADA dengan tenant_id kosong tetapi punya penanda hak lama —
#         role client EFEKTIF (composite: langsung/grup/role komposit) di `control-plane` atau `odoo-*`, role
#         `realm-management`, atau keanggotaan Organization mana pun — ditolak (exit 3, "user lama tanpa tenant_id —
#         butuh adopt oleh superadmin") kecuali `--adopt`. User lama tanpa penanda (belum pernah diberi akses) tetap
#         diisi tanpa --adopt. User yang dibuat run ini tidak terpengaruh.
#         Staf platform: slug ≠ platform dan role control-plane EFEKTIF memuat superadmin/ops → exit 3, juga dengan
#         --adopt (staf platform hanya diikat lewat slug platform).
# roles   client role `control-plane` PERSIS {cp_role} (kosong untuk none). §0.3: superadmin/ops hanya slug platform,
#         client_admin/client_user hanya slug ≠ platform. --odoo (dilarang untuk slug platform): client
#         `odoo-<slug>-<env>` PERSIS none → {} · user → {odoo_access} · admin → {odoo_access, odoo_admin}; role
#         odoo_admin dibuat bila belum ada (butuh manage-clients — cp-admin tidak punya → jalankan kc-realm-sync).
#         Menolak (exit 3) melepas superadmin dari superadmin aktif terakhir.
# enabled set enabled; false → juga POST /users/{id}/logout (idempoten, tidak dihitung changed). Menolak (exit 3)
#         menonaktifkan user ber-role superadmin kecuali slug platform, dan tidak pernah superadmin aktif terakhir.
#         (Aturan "aktor bukan dirinya sendiri" ditegakkan control plane.)
# email   PUT execute-actions-email [<action>] (client control-plane). User nonaktif → BLOKIR.
# Semua subcommand selain ensure: user harus sudah terikat tenant slug (atribut tenant_id = alias org) → else exit 3.
# Semua subcommand, slug ≠ platform: user dengan role control-plane EFEKTIF superadmin/ops → exit 3 (QA F1c), apa pun
# atribut tenant_id-nya (staf platform tidak pernah diubah/dinonaktifkan/dikirimi email aksi lewat slug tenant).
# Log tidak memuat email mentah: email#<8 hex sha256> (lib/kc-tenant.sh email_ref, QA F5) atau id user Keycloak.
#
# Kredensial: client `cp-admin` (identity/keycloak/secrets/cp-admin-<realm>.secret) — lib/keycloak-admin.sh.
# Output baris terakhir (tanpa email — log job tanpa PII; format kunci = klarifikasi Lead untuk control-plane):
#   ensure : RESULT realm=<r> kc_user=<id|-> tenant=<uuid> created=<0|1> changed=<n> invite=<0|1>
#   roles  : RESULT realm=<r> kc_user=<id|-> roles=<nama role dipisah koma, mis. client_admin,odoo_access,odoo_admin;
#            kosong bila none/none> changed=<n>   (role control-plane lalu role odoo-<slug>-<env> bila --odoo)
#   enabled: RESULT realm=<r> kc_user=<id|-> enabled=<0|1> changed=<n>
#   email  : RESULT realm=<r> kc_user=<id|-> action=<ACTION> invite=<0|1> changed=<n>
#   (+ ` blockers=<n>` pada --dry-run; kc_user=- bila user belum ada). Exit 3 = ditolak kebijakan.
#   JANGAN jalankan dengan `bash -x`.
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
KC_ADMIN_CLIENT=cp-admin
# shellcheck source=lib/keycloak-admin.sh
source "$LIB/keycloak-admin.sh"
# shellcheck source=lib/kc-tenant.sh
source "$LIB/kc-tenant.sh"

CP_CLIENT=control-plane
# Masa berlaku tautan email aksi (undangan/reset): 72 jam (keputusan Lead 2026-10-03; default KC 12 jam terlalu
# pendek untuk undangan user client). Parameter query `lifespan` (detik) endpoint execute-actions-email.
ACTION_LIFESPAN_S=259200
ODOO_ACCESS=odoo_access
ODOO_ADMIN=odoo_admin

usage() {
  cat >&2 <<EOF
pemakaian: $0 ensure  <slug> <env> --email <e> --tenant-id <uuid> [--name <n>] [--no-invite] [--adopt] [--dry-run]
           $0 roles   <slug> <env> --email <e> --cp-role <none|superadmin|ops|client_admin|client_user> [--odoo <none|user|admin>] [--dry-run]
           $0 enabled <slug> <env> --email <e> --enabled <true|false> [--dry-run]
           $0 email   <slug> <env> --email <e> --action <UPDATE_PASSWORD|VERIFY_EMAIL|CONFIGURE_TOTP> [--dry-run]
EOF
  exit 2
}
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 3 ]] || usage
CMD="$1"; shift
case "$CMD" in ensure|roles|enabled|email) ;; *) usage ;; esac
validate_slug_env "$1" "$2"; shift 2

EMAIL=""; TENANT_ID=""; NAME=""; INVITE=1; ADOPT=0; CP_ROLE=""; ODOO=""; ENABLED=""; ACTION=""
opt_ok() { [[ " $1 " == *" $CMD "* ]] || usage; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) [[ $# -ge 2 ]] || usage; EMAIL="${2,,}"; shift 2 ;;
    --tenant-id) opt_ok ensure; [[ $# -ge 2 ]] || usage; TENANT_ID="$2"; shift 2 ;;
    --name) opt_ok ensure; [[ $# -ge 2 ]] || usage; NAME="$2"; shift 2 ;;
    --no-invite) opt_ok ensure; INVITE=0; shift ;;
    --adopt) opt_ok ensure; ADOPT=1; shift ;;
    --cp-role) opt_ok roles; [[ $# -ge 2 ]] || usage; CP_ROLE="$2"; shift 2 ;;
    --odoo) opt_ok roles; [[ $# -ge 2 ]] || usage; ODOO="$2"; shift 2 ;;
    --enabled) opt_ok enabled; [[ $# -ge 2 ]] || usage; ENABLED="$2"; shift 2 ;;
    --action) opt_ok email; [[ $# -ge 2 ]] || usage; ACTION="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
[[ ${#EMAIL} -le 254 && "$EMAIL" =~ $EMAIL_RE ]] || die "email tidak valid"
EREF="$(email_ref "$EMAIL")"   # pengganti email di log (QA F5)
case "$CMD" in
  ensure)
    [[ "$TENANT_ID" =~ $UUID_RE ]] || die "--tenant-id harus UUID huruf kecil"
    [[ -z "$NAME" || "$NAME" =~ $NAME_RE ]] || die "--name tidak valid (ASCII, ≤ 100, tidak diawali spasi/'-')" ;;
  roles)
    case "$CP_ROLE" in none|superadmin|ops|client_admin|client_user) ;; *) die "--cp-role tidak valid" ;; esac
    case "$ODOO" in ""|none|user|admin) ;; *) die "--odoo tidak valid" ;; esac
    # §0.3 — tidak pernah memberi hak lebih (BUG-J5-01)
    if [[ "$SLUG" == "$PLATFORM_SLUG" ]]; then
      [[ "$CP_ROLE" != client_admin && "$CP_ROLE" != client_user ]] \
        || refuse "role ${CP_ROLE} hanya untuk tenant ≠ ${PLATFORM_SLUG}"
      [[ -z "$ODOO" ]] || refuse "--odoo dilarang untuk slug ${PLATFORM_SLUG}"
    else
      [[ "$CP_ROLE" != superadmin && "$CP_ROLE" != ops ]] || refuse "role ${CP_ROLE} hanya untuk slug ${PLATFORM_SLUG}"
    fi ;;
  enabled) [[ "$ENABLED" == true || "$ENABLED" == false ]] || die "--enabled harus true|false" ;;
  email)
    case "$ACTION" in UPDATE_PASSWORD|VERIFY_EMAIL|CONFIGURE_TOTP) ;; *) die "--action tidak valid" ;; esac ;;
esac

REALM="$(kc_realm_for_env "$TENANT_ENV")"
LOG_PREFIX="kc-user ${CMD} ${REALM}/${SLUG}"
take_lock "kc-user-${REALM}"
kc_init "$REALM"
log "user=${EREF} mode=$([[ $DRY -eq 1 ]] && echo dry-run || echo apply)"

# ---- tenant: org slug (alias = tenant_id)
kc_org_by_slug "$SLUG"
if [[ -z "$ORG_ID" ]]; then
  block "organization ${SLUG} belum ada — jalankan dulu kc-org.sh (job kc_org_ensure)"
elif [[ "$CMD" == ensure && "$ORG_ALIAS" != "$TENANT_ID" ]]; then
  refuse "org slug ${SLUG} terikat tenant lain (alias org ≠ --tenant-id)"
fi
TENANT_ALIAS="${ORG_ALIAS:-$TENANT_ID}"

kc_user_by_email "$EMAIL"

# ---- helper role client
# client_roles_json <client-uuid> → [{"id","name"}] semua role client
client_roles_json() { kc_json '[{"id": r["id"], "name": r["name"]} for r in d]' "$(kc_get "/clients/$1/roles")"; }
# user_client_roles <uid> <client-uuid> [composite] → nama role (dipisah spasi, terurut)
user_client_roles() {
  local p="/users/$1/role-mappings/clients/$2"; [[ "${3:-}" == composite ]] && p="${p}/composite"
  kc_json '" ".join(sorted(r["name"] for r in d))' "$(kc_get "$p")"
}
# pick_roles <roles-json> <nama…> → JSON list representasi role bernama (die bila ada yang tidak ditemukan)
pick_roles() {
  local all="$1"; shift
  python3 -c '
import json, sys
by = {r["name"]: r for r in json.loads(sys.argv[1])}
miss = [n for n in sys.argv[2:] if n not in by]
if miss:
    sys.exit("role tidak ada: " + ",".join(miss))
print(json.dumps([by[n] for n in sys.argv[2:]]))' "$all" "$@"
}
# set_exact_client_roles <label> <uid> <client-uuid> <roles-json> <desired…> — mapping client PERSIS = desired
set_exact_client_roles() {
  local label="$1" uid="$2" cuuid="$3" all="$4"; shift 4
  local cur r add=() del=()
  cur=" $(user_client_roles "$uid" "$cuuid") "
  for r in "$@"; do [[ "$cur" == *" $r "* ]] || add+=("$r"); done
  for r in $cur; do [[ " $* " == *" $r "* ]] || del+=("$r"); done
  if [[ ${#del[@]} -gt 0 ]] && change "${label}: role dicabut ${del[*]}"; then
    kc_send DELETE "/users/${uid}/role-mappings/clients/${cuuid}" "$(pick_roles "$all" "${del[@]}")" 204
  fi
  if [[ ${#add[@]} -gt 0 ]] && change "${label}: role diberikan ${add[*]}"; then
    kc_send POST "/users/${uid}/role-mappings/clients/${cuuid}" "$(pick_roles "$all" "${add[@]}")" 204
  fi
  [[ ${#add[@]} -gt 0 || ${#del[@]} -gt 0 ]] || log "${label}: sudah sesuai (${*:-kosong})"
}
# other_enabled_superadmins <uid> <cp-uuid> → jumlah user enabled LAIN dengan role superadmin langsung
other_enabled_superadmins() {
  # GET /clients/{id}/roles/{role}/users → [UserRepresentation] (pengguna dengan mapping langsung)
  kc_json 'str(sum(1 for u in d if u.get("enabled") and u.get("id") != "'"$1"'"))' \
    "$(kc_get "/clients/$2/roles/superadmin/users?first=0&max=1000")"
}
# refuse_platform_staff <uid> — QA F1c: slug ≠ platform dan role control-plane EFEKTIF (endpoint /composite: mapping
# langsung + grup + role komposit) memuat superadmin/ops → exit 3, apa pun atribut tenant_id user.
refuse_platform_staff() {
  [[ "$SLUG" != "$PLATFORM_SLUG" ]] || return 0
  local eff
  eff=" $(user_client_roles "$1" "$CP_UUID" composite) "
  if [[ "$eff" == *" superadmin "* || "$eff" == *" ops "* ]]; then
    refuse "user staf platform (role ${CP_CLIENT} efektif superadmin/ops) hanya bisa diubah lewat slug ${PLATFORM_SLUG}"
  fi
}
# legacy_signals <uid> → LEGACY_SIGNALS = penanda hak lama (dipisah spasi; kosong = tidak ada; tanpa PII):
#   control-plane:<role,…> · odoo-<slug>-<env>:<role,…> · realm-management:<role,…> · organizations:<n>
# Role = EFEKTIF (/composite). Dipakai ensure untuk user lama tanpa tenant_id (QA F1b).
LEGACY_SIGNALS=""
legacy_signals() {
  local uid="$1" sig=() r clients cuuid cid rm_uuid orgs
  r="$(user_client_roles "$uid" "$CP_UUID" composite)"
  [[ -z "$r" ]] || sig+=("${CP_CLIENT}:${r// /,}")
  # semua client odoo-* — GET /clients?search=true = pencarian infix (KC), disaring awalan di sini. Representasi client
  # memuat secret → kc_get_quiet, hanya id + clientId yang dipakai.
  clients="$(kc_get_quiet "/clients?clientId=odoo-&search=true&first=0&max=1000")"
  clients="$(kc_json '"\n".join(c["id"] + " " + c["clientId"] for c in d if c.get("clientId", "").startswith("odoo-"))' \
              "$clients")"
  while read -r cuuid cid; do
    [[ -n "$cuuid" ]] || continue
    r="$(user_client_roles "$uid" "$cuuid" composite)"
    [[ -z "$r" ]] || sig+=("${cid}:${r// /,}")
  done <<<"$clients"
  rm_uuid="$(kc_client_uuid realm-management)"
  if [[ -n "$rm_uuid" ]]; then
    r="$(user_client_roles "$uid" "$rm_uuid" composite)"
    [[ -z "$r" ]] || sig+=("realm-management:${r// /,}")
  fi
  # GET /organizations/members/{id}/organizations → [OrganizationRepresentation] (KC 26.7.4 OrganizationsResource:
  # query/view-organizations + view-users — cp-admin punya manage-organizations + view-users)
  orgs="$(kc_get "/organizations/members/${uid}/organizations?briefRepresentation=true")"
  orgs="$(kc_json 'str(len(d))' "$orgs")"
  [[ "$orgs" == 0 ]] || sig+=("organizations:${orgs}")
  LEGACY_SIGNALS="${sig[*]}"
}

CP_UUID="$(kc_client_uuid "$CP_CLIENT")"
[[ -n "$CP_UUID" ]] || die "client ${CP_CLIENT} tidak ada di realm ${REALM}"

case "$CMD" in
# ======================================================================================== ensure
ensure)
  CREATED=0; INVITE_STATE=0; NEW=0
  # user profile harus mendeklarasikan tenant_id (kc-realm-sync) — tanpa itu KC 26 membuang atribut unmanaged
  kc_request GET /users/profile
  if [[ "$KC_STATUS" == 200 ]]; then
    declared="$(kc_json 'str(any(a.get("name") == "tenant_id" for a in d.get("attributes") or [])).lower()' "$KC_BODY")"
    [[ "$declared" == true ]] || block "user profile realm ${REALM} belum mendeklarasikan atribut tenant_id — jalankan kc-realm-sync"
  else
    log "PERINGATAN: GET /users/profile HTTP ${KC_STATUS} — deklarasi tenant_id diverifikasi setelah tulis"
  fi
  if [[ -z "$KC_UID" ]]; then
    body="$(python3 -c '
import json, sys
email, tid, name = sys.argv[1:]
rep = {"username": email, "email": email, "enabled": True, "emailVerified": False,
       "attributes": {"tenant_id": [tid]}, "requiredActions": ["UPDATE_PASSWORD"]}
parts = name.split(None, 1)
if parts:
    rep["firstName"] = parts[0]
if len(parts) > 1:
    rep["lastName"] = parts[1]
print(json.dumps(rep))' "$EMAIL" "$TENANT_ID" "$NAME")"
    if change "user ${EREF} dibuat (tenant_id=${TENANT_ID}, required action UPDATE_PASSWORD)"; then
      kc_send POST /users "$body" 201
      KC_UID="${KC_LOCATION##*/}"
      [[ "$KC_UID" =~ $UUID_RE ]] || die "id user baru tidak dikenali dari Location"
      CREATED=1; NEW=1
    fi
  else
    tid="$(user_tenant_id "$KC_USER_JSON")"
    # staf platform tidak pernah diikat/diubah lewat slug tenant — juga dengan --adopt (QA F1b/F1c)
    refuse_platform_staff "$KC_UID"
    if [[ -z "$tid" ]]; then
      # user lama (dibuat sebelum Fase 1 / era odoo-sso-user.sh) yang sudah punya akses → hanya lewat --adopt (QA F1b)
      legacy_signals "$KC_UID"
      if [[ -n "$LEGACY_SIGNALS" ]]; then
        log "user ${EREF} (id ${KC_UID}) tanpa tenant_id, penanda hak lama: ${LEGACY_SIGNALS}"
        [[ $ADOPT -eq 1 ]] || refuse "user lama tanpa tenant_id — butuh adopt oleh superadmin (args.adopt=true)"
        log "ADOPSI: user lama diikat ke tenant ${SLUG} (--adopt)"
      elif [[ $ADOPT -eq 1 ]]; then
        log "--adopt: user tanpa penanda hak lama — adopsi tidak diperlukan"
      fi
      if change "user ${EREF} (id ${KC_UID}): atribut tenant_id diisi ${TENANT_ID}"; then
        kc_send PUT "/users/${KC_UID}" "$(user_put_body "$KC_USER_JSON" \
          '{**d, "attributes": {**(d.get("attributes") or {}), "tenant_id": ["'"$TENANT_ID"'"]}}')" 204
      fi
    elif [[ "$tid" != "$TENANT_ID" ]]; then
      refuse "user milik tenant lain (tenant_id user ≠ --tenant-id) — lintas tenant"
    else
      log "user ${EREF} ada (id ${KC_UID}), tenant_id cocok"
    fi
  fi
  # verifikasi tulis: atribut tenimpan (user profile membuang atribut tak terdeklarasi tanpa error)
  if [[ $DRY -eq 0 && -n "$KC_UID" ]]; then
    [[ "$(user_tenant_id "$(kc_get "/users/${KC_UID}")")" == "$TENANT_ID" ]] \
      || die "atribut tenant_id tidak tersimpan pada user ${KC_UID} — user profile realm belum memuat tenant_id (kc-realm-sync)"
  fi
  # keanggotaan org
  if [[ -n "$ORG_ID" && -n "$KC_UID" ]]; then
    # GET /organizations/{org}/members/{user} → 200 anggota / 404 bukan (diverifikasi KC 26.7.4 sekali pakai)
    kc_request GET "/organizations/${ORG_ID}/members/${KC_UID}"
    case "$KC_STATUS" in
      200) log "user sudah anggota organization ${SLUG}" ;;
      404) if change "user ${EREF} → anggota organization ${SLUG}"; then
             # POST /organizations/{org}/members, body = id user sebagai JSON string → 201
             kc_send POST "/organizations/${ORG_ID}/members" "\"${KC_UID}\"" 201
           fi ;;
      *) die "GET anggota organization: HTTP ${KC_STATUS}" ;;
    esac
  elif [[ -n "$ORG_ID" ]]; then
    change "user baru → anggota organization ${SLUG}" || true
  fi
  # undangan (hanya user baru)
  if [[ $INVITE -eq 1 && ( $NEW -eq 1 || ( $DRY -eq 1 && -z "$KC_UID" ) ) ]]; then
    if change "execute-actions-email [UPDATE_PASSWORD] → ${EREF} (client ${CP_CLIENT})"; then
      kc_send PUT "/users/${KC_UID}/execute-actions-email?client_id=${CP_CLIENT}&lifespan=${ACTION_LIFESPAN_S}" '["UPDATE_PASSWORD"]' 204
      INVITE_STATE=1
    fi
  fi
  echo "RESULT realm=${REALM} kc_user=${KC_UID:--} tenant=${TENANT_ALIAS:--} created=${CREATED} changed=${CHANGED} invite=${INVITE_STATE}$(result_tail)"
  ;;
# ======================================================================================== roles
roles)
  if [[ -z "$KC_UID" ]]; then
    block "user ${EREF} tidak ada — jalankan dulu kc-user.sh ensure"
  else
    refuse_platform_staff "$KC_UID"
    [[ -z "$ORG_ID" ]] || require_same_tenant "$KC_USER_JSON" "$ORG_ALIAS"
  fi
  if [[ -n "$KC_UID" ]]; then
    CP_ROLES="$(client_roles_json "$CP_UUID")"
    want=(); [[ "$CP_ROLE" == none ]] || want=("$CP_ROLE")
    cur_cp=" $(user_client_roles "$KC_UID" "$CP_UUID") "
    if [[ "$cur_cp" == *" superadmin "* && "$CP_ROLE" != superadmin ]]; then
      [[ "$(other_enabled_superadmins "$KC_UID" "$CP_UUID")" -ge 1 ]] \
        || refuse "user ini superadmin aktif terakhir — role superadmin tidak dilepas"
    fi
    set_exact_client_roles "${CP_CLIENT}" "$KC_UID" "$CP_UUID" "$CP_ROLES" "${want[@]}"
  fi
  if [[ -n "$ODOO" ]]; then
    OCLIENT="odoo-${SLUG}-${TENANT_ENV}"
    OUUID="$(kc_client_uuid "$OCLIENT")"
    if [[ -z "$OUUID" ]]; then
      block "client ${OCLIENT} tidak ada — jalankan dulu provision-odoo-sso.sh (job odoo_sso_provision)"
    else
      OROLES="$(client_roles_json "$OUUID")"
      has() { kc_json 'str(any(r["name"] == "'"$1"'" for r in d)).lower()' "$OROLES"; }
      [[ "$(has "$ODOO_ACCESS")" == true ]] || block "role ${ODOO_ACCESS} tidak ada di ${OCLIENT} — jalankan provision-odoo-sso.sh"
      if [[ "$(has "$ODOO_ADMIN")" != true ]]; then
        if change "role ${ODOO_ADMIN} dibuat di ${OCLIENT}"; then
          kc_request POST "/clients/${OUUID}/roles" \
            "{\"name\": \"${ODOO_ADMIN}\", \"description\": \"Admin Odoo ${DB_NAME} (group Settings, job odoo_user_ensure)\"}"
          case "$KC_STATUS" in
            201) OROLES="$(client_roles_json "$OUUID")" ;;
            403) die "membuat role ${ODOO_ADMIN}: 403 (cp-admin tanpa manage-clients) — jalankan kc-realm-sync (mengelola ${ODOO_ADMIN} di semua odoo-*)" ;;
            *) die "membuat role ${ODOO_ADMIN}: HTTP ${KC_STATUS}" ;;
          esac
        fi
      fi
      if [[ -n "$KC_UID" && $BLOCKERS -eq 0 ]]; then
        case "$ODOO" in
          none) set_exact_client_roles "$OCLIENT" "$KC_UID" "$OUUID" "$OROLES" ;;
          user) set_exact_client_roles "$OCLIENT" "$KC_UID" "$OUUID" "$OROLES" "$ODOO_ACCESS" ;;
          admin)
            if [[ $DRY -eq 1 && "$(has "$ODOO_ADMIN")" != true ]]; then
              cur_o=" $(user_client_roles "$KC_UID" "$OUUID") "
              [[ "$cur_o" == *" ${ODOO_ACCESS} "* ]] || change "${OCLIENT}: role diberikan ${ODOO_ACCESS}" || true
              change "${OCLIENT}: role diberikan ${ODOO_ADMIN} (setelah role dibuat)" || true
            else
              set_exact_client_roles "$OCLIENT" "$KC_UID" "$OUUID" "$OROLES" "$ODOO_ACCESS" "$ODOO_ADMIN"
            fi ;;
        esac
      fi
    fi
  fi
  ROLES_OUT=(); [[ "$CP_ROLE" == none ]] || ROLES_OUT+=("$CP_ROLE")
  case "$ODOO" in user) ROLES_OUT+=("$ODOO_ACCESS") ;; admin) ROLES_OUT+=("$ODOO_ACCESS" "$ODOO_ADMIN") ;; esac
  roles_csv="$(IFS=,; echo "${ROLES_OUT[*]}")"
  echo "RESULT realm=${REALM} kc_user=${KC_UID:--} roles=${roles_csv} changed=${CHANGED}$(result_tail)"
  ;;
# ======================================================================================== enabled
enabled)
  if [[ -z "$KC_UID" ]]; then
    block "user ${EREF} tidak ada"
  else
    refuse_platform_staff "$KC_UID"
    [[ -z "$ORG_ID" ]] || require_same_tenant "$KC_USER_JSON" "$ORG_ALIAS"
    if [[ "$ENABLED" == false ]]; then
      eff=" $(user_client_roles "$KC_UID" "$CP_UUID" composite) "
      if [[ "$eff" == *" superadmin "* ]]; then
        [[ "$SLUG" == "$PLATFORM_SLUG" ]] || refuse "user ber-role superadmin hanya bisa dinonaktifkan lewat slug ${PLATFORM_SLUG}"
        [[ "$(other_enabled_superadmins "$KC_UID" "$CP_UUID")" -ge 1 ]] \
          || refuse "user ini superadmin aktif terakhir — tidak dinonaktifkan"
      fi
    fi
    cur="$(kc_json 'str(d.get("enabled") is True).lower()' "$KC_USER_JSON")"
    if [[ "$cur" != "$ENABLED" ]]; then
      if change "user ${EREF} (id ${KC_UID}): enabled ${cur} → ${ENABLED}"; then
        kc_send PUT "/users/${KC_UID}" "$(user_put_body "$KC_USER_JSON" '{**d, "enabled": '"${ENABLED^}"'}')" 204
      fi
    else
      log "user ${EREF}: enabled sudah ${ENABLED}"
    fi
    if [[ "$ENABLED" == false ]]; then
      if [[ $DRY -eq 1 ]]; then
        log "PLAN: logout semua sesi user (idempoten, tidak dihitung)"
      else
        kc_send POST "/users/${KC_UID}/logout" "" 204
        log "sesi user di-logout"
      fi
    fi
  fi
  echo "RESULT realm=${REALM} kc_user=${KC_UID:--} enabled=$([[ "$ENABLED" == true ]] && echo 1 || echo 0) changed=${CHANGED}$(result_tail)"
  ;;
# ======================================================================================== email
email)
  INVITE_STATE=0
  if [[ -z "$KC_UID" ]]; then
    block "user ${EREF} tidak ada"
  else
    refuse_platform_staff "$KC_UID"
    [[ -z "$ORG_ID" ]] || require_same_tenant "$KC_USER_JSON" "$ORG_ALIAS"
    if [[ "$(kc_json 'str(d.get("enabled") is True).lower()' "$KC_USER_JSON")" != true ]]; then
      block "user ${EREF} nonaktif — email aksi tidak dikirim"
    elif change "execute-actions-email [${ACTION}] → ${EREF} (client ${CP_CLIENT})"; then
      kc_send PUT "/users/${KC_UID}/execute-actions-email?client_id=${CP_CLIENT}&lifespan=${ACTION_LIFESPAN_S}" "[\"${ACTION}\"]" 204
      INVITE_STATE=1
    fi
  fi
  echo "RESULT realm=${REALM} kc_user=${KC_UID:--} action=${ACTION} invite=${INVITE_STATE} changed=${CHANGED}$(result_tail)"
  ;;
esac
