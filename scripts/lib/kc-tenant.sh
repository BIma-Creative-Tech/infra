# shellcheck shell=bash
# shellcheck disable=SC2034  # library: variabel (ORG_*, KC_UID, …) dibaca skrip pemanggil
# Fungsi bersama skrip job SaaS Fase 1 (kontrak docs/plans/saas-phase-1-contract.md §0/§1.1): kc-org.sh,
# kc-user.sh, odoo-user.sh, odoo-tenant-config.sh. Di-source SETELAH lib/odoo-pools.sh + lib/keycloak-admin.sh
# (butuh: die, kc_get, kc_json, kc_urlencode). Tidak ada secret di file ini; tidak pernah mencetak token.
#
# Kode keluar: 0 sukses · 1 gagal/precondition (die) · 2 pemakaian · 3 DITOLAK kebijakan (§0.2/§0.3: lintas
# tenant, org slug terikat tenant lain, role terlarang, superadmin, user lama tanpa adopt — kontrak §5 v1.2) —
# dispatcher memperlakukan ≠0 sebagai gagal.
#
# Rencana/penerapan (global DRY=0|1, CHANGED, BLOCKERS — pola lib/odoo-exec.sh, prefix log berbeda):
#   change <desk>  → 0 bila perubahan DITERAPKAN; dry-run: cetak PLAN, return 1. Selalu menambah CHANGED.
#   block <pesan>  → apply: die; dry-run: BLOKIR (dihitung di RESULT blockers=) dan lanjut.
#   refuse <pesan> → exit 3 (dry-run maupun apply).

PLATFORM_SLUG="platform"   # tenant internal (kontrak §0.1)
EMAIL_RE='^[a-z0-9_%+][a-z0-9._%+-]{0,63}@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'   # = dispatcher
LOGIN_RE='^[A-Za-z0-9._@+][A-Za-z0-9._@+-]{0,253}$'                                               # = dispatcher
NAME_RE="^[A-Za-z0-9.,'][A-Za-z0-9 .,'-]{0,99}$"   # kontrak §1 NAME_RE versi ASCII (tidak diawali spasi/'-')
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

DRY="${DRY:-0}"; CHANGED=0; BLOCKERS=0
LOG_PREFIX="${LOG_PREFIX:-kc}"
log() { echo "[${LOG_PREFIX}] $*"; }
change() {
  CHANGED=$((CHANGED+1))
  if [[ $DRY -eq 1 ]]; then log "PLAN: $*"; return 1; fi
  log "UBAH: $*"
}
block() {
  [[ $DRY -eq 1 ]] || die "$*"
  BLOCKERS=$((BLOCKERS+1)); log "BLOKIR: $*"
}
refuse() { echo "ERROR: DITOLAK: $*" >&2; exit 3; }

# email_ref <email> → "email#<8 hex>" = 8 hex pertama sha256(email huruf kecil). Log/tail skrip job TIDAK PERNAH
# memuat email mentah (QA F5, log job tanpa PII); hash pendek cukup untuk mencocokkan baris log dengan user tertentu
# (hitung ulang: printf '%s' "<email huruf kecil>" | sha256sum | cut -c1-8).
email_ref() { printf 'email#%s' "$(printf '%s' "${1,,}" | sha256sum | cut -c1-8)"; }

# result_tail → " blockers=N" pada dry-run, "" pada apply (pre dry-run dispatcher wajib membaca blockers=; kunci `mode`
# sengaja TIDAK dipakai di sini — maknanya khusus kc_realm_sync plan|apply / odoo_tenant_config off|compat|strict)
result_tail() { [[ $DRY -eq 1 ]] && printf ' blockers=%s' "$BLOCKERS"; return 0; }

# take_lock <nama> — flock non-blocking 60 s (hanya apply; dry-run hanya membaca)
take_lock() {
  [[ $DRY -eq 1 ]] && return 0
  exec 9>"/run/lock/${1}.lock"
  flock -w 60 9 || die "${1} sedang berjalan (lock)"
}

# kc_org_by_slug <slug> → ORG_ID, ORG_ALIAS, ORG_JSON (kosong bila tidak ada).
# Organization: name = slug, alias = tenant_id (ADR 0017 D2). Daftar penuh dibaca sekali (Fase 1: < 1000 tenant)
# agar konflik alias (tenant_id sudah dipakai org lain) juga terdeteksi → ORG_ALIAS_OWNER (nama org pemilik alias
# yang diminta, bila diberikan sebagai arg 2).
# Admin REST KC 26: GET /organizations?briefRepresentation=false&first=&max= → [OrganizationRepresentation]
# (id, name, alias, enabled, description, attributes{k:[v]}, domains[]). Butuh realm-management
# view-organizations/manage-organizations (KC 26.7, kontrak update Lead S1).
ORG_ID=""; ORG_ALIAS=""; ORG_JSON=""; ORG_ALIAS_OWNER=""
kc_org_by_slug() {
  local slug="$1" want_alias="${2:-}" all out
  kc_request GET "/organizations?briefRepresentation=false&first=0&max=1000"
  if [[ "$KC_STATUS" == 404 && "$KC_BODY" == *"not enabled"* ]]; then
    # KC 26.7.4 (diverifikasi): {"errorMessage":"Organizations not enabled for this realm."}
    die "Organizations belum aktif di realm ${KC_REALM} (organizationsEnabled=false; W2 setelah S1 — platform.json)"
  fi
  [[ "$KC_STATUS" == 200 ]] || die "GET /organizations: HTTP ${KC_STATUS} — ${KC_BODY:0:200}"
  all="$KC_BODY"
  out="$(printf '%s' "$all" | python3 -c '
import json, sys
slug, want = sys.argv[1], sys.argv[2]
orgs = json.load(sys.stdin)
if not isinstance(orgs, list):
    sys.exit("respons /organizations bukan list")
if len(orgs) >= 1000:
    sys.exit("lebih dari 999 organization — paging belum diimplementasikan")
m = [o for o in orgs if o.get("name") == slug]
if len(m) > 1:
    sys.exit("lebih dari satu organization bernama slug ini")
owner = [o.get("name", "?") for o in orgs if want and o.get("alias") == want and o.get("name") != slug]
o = m[0] if m else {}
# satu baris, pemisah "|" (id/alias/nama org tidak memuat "|"; JSON di kolom terakhir boleh)
print("|".join((o.get("id", ""), o.get("alias") or "", owner[0] if owner else "",
                json.dumps(o, sort_keys=True) if o else "")))
' "$slug" "$want_alias")" || die "membaca organization gagal"
  IFS='|' read -r ORG_ID ORG_ALIAS ORG_ALIAS_OWNER ORG_JSON <<<"$out"
  [[ -z "$ORG_ID" || "$ORG_ID" =~ $UUID_RE ]] || die "id organization tidak dikenali"
  return 0
}

# kc_user_by_email <email> → KC_UID, KC_USER_JSON (representasi penuh; kosong bila tidak ada).
# Cocok eksak pada email ATAU username (username = email untuk user platform). > 1 kecocokan → die.
KC_UID=""; KC_USER_JSON=""
kc_user_by_email() {
  local email="$1" enc a b out
  enc="$(kc_urlencode "$email")"
  a="$(kc_get "/users?email=${enc}&exact=true&briefRepresentation=false")"
  b="$(kc_get "/users?username=${enc}&exact=true&briefRepresentation=false")"
  out="$(python3 -c '
import json, sys
email = sys.argv[1]
seen = {}
for blob in sys.argv[2:]:
    for u in json.loads(blob):
        if (u.get("email") or "").lower() == email or (u.get("username") or "").lower() == email:
            seen[u["id"]] = u
if len(seen) > 1:
    sys.exit("lebih dari satu user Keycloak cocok dengan email ini")
u = next(iter(seen.values()), None)
print((u["id"] + "|" + json.dumps(u, sort_keys=True)) if u else "|")
' "$email" "$a" "$b")" || die "pencarian user Keycloak gagal"
  IFS='|' read -r KC_UID KC_USER_JSON <<<"$out"
  [[ -z "$KC_UID" || "$KC_UID" =~ $UUID_RE ]] || die "id user Keycloak tidak dikenali"
  return 0
}

# user_tenant_id <user-json> → nilai atribut tenant_id (kosong bila tidak ada; > 1 nilai → die)
user_tenant_id() {
  kc_json '(lambda v: v[0] if len(v) == 1 else ("" if not v else "<MULTI>"))((d.get("attributes") or {}).get("tenant_id") or [])' "$1"
}

# require_same_tenant <user-json> <alias> — §0.3: user milik tenant lain / belum terikat tenant → exit 3
require_same_tenant() {
  local tid
  tid="$(user_tenant_id "$1")"
  [[ -n "$tid" ]] || refuse "user belum terikat tenant (atribut tenant_id kosong) — jalankan dulu kc-user.sh ensure dengan --tenant-id"
  [[ "$tid" == "$2" ]] || refuse "user milik tenant lain (tenant_id user ≠ alias org slug ${SLUG}) — lintas tenant"
}

# kc_client_uuid <clientId> → uuid (kosong bila tidak ada)
kc_client_uuid() {
  kc_get "/clients?clientId=$(kc_urlencode "$1")" | python3 -c '
import json, sys
m = [c for c in json.load(sys.stdin) if c.get("clientId") == sys.argv[1]]
sys.stdout.write(m[0]["id"] if len(m) == 1 else "")' "$1"
}

# user_put_body <user-json> <python-expr-on-d> → body PUT /users/{id} = representasi penuh (field read-only dibuang)
# dengan modifikasi. PUT parsial bisa menghapus atribut user-profile di KC 24+ → selalu kirim representasi penuh.
user_put_body() {
  kc_json '(lambda d: '"$2"')({k: v for k, v in d.items() if k not in ("access", "credentials", "userProfileMetadata", "federationLink", "createdTimestamp", "totp", "disableableCredentialTypes", "notBefore")})' "$1"
}
