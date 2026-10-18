#!/usr/bin/env bash
# SSO dashboard 9router → Keycloak realm `platform` (2026-10-19). Idempoten: aman dijalankan ulang.
#
#  1. Flow `9router browser` (salinan perilaku flow `browser`: cookie | username+password [+ OTP bila user punya]) +
#     sub-flow CONDITIONAL "Condition - user role" (negate) → "Deny access": user TANPA client role `9router.access`
#     ditolak — juga saat masuk lewat cookie SSO sesi aplikasi lain. 9router 0.5.104 TIDAK memfilter email/sub.
#  2. Client `9router` (confidential, standard flow saja, PKCE S256, redirect HANYA callback 9router, flow override
#     browser = flow di atas, fullScopeAllowed=false).
#  3. Client role `access` → HANYA user dengan email $ALLOWED_EMAIL.
#  4. Konfigurasi 9router (PATCH /api/settings, sesi login password lokal di dalam container): authMode, issuer,
#     clientId, clientSecret. Secret client tidak pernah dicetak (Admin REST → pipe → stdin node di container).
#
# Token Admin REST: client service account `kc-realm-sync` (satu-satunya yang punya manage-realm untuk flow).
# Pemakaian: provision-9router-sso.sh [both|oidc]   (default both = password + SSO; oidc = SSO saja)
set -euo pipefail
MODE="${1:-both}"
[[ "$MODE" == both || "$MODE" == oidc ]] || { echo "mode: both|oidc" >&2; exit 2; }
INFRA_DIR=/opt/infra
# shellcheck source=/dev/null
. "$INFRA_DIR/scripts/lib/odoo-pools.sh"
KC_ADMIN_CLIENT=kc-realm-sync
# shellcheck source=/dev/null
. "$INFRA_DIR/scripts/lib/keycloak-admin.sh"

REALM=platform
CLIENT_ID=9router
ROLE=access
ALLOWED_EMAIL=am.ademaryadi@gmail.com
HOST=9router.bimacreative.tech
REDIRECT="https://${HOST}/api/auth/oidc/callback"
FLOW="9router browser"
q() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
FLOW_Q="$(q "$FLOW")"

kc_init "$REALM" >/dev/null

# ---------------------------------------------------------------- 1. flow
flow_execs() { kc_get "/authentication/flows/${FLOW_Q}/executions"; }
exec_id() { # <displayName|alias> → id eksekusi (pertama)
  flow_execs | python3 -c 'import sys,json
n=sys.argv[1]
for e in json.load(sys.stdin):
    if e.get("displayName")==n or e.get("alias")==n: print(e["id"]); break' "$1"; }
set_req() { # <displayName|alias> <REQUIREMENT>
  local body
  body="$(flow_execs | python3 -c 'import sys,json
n,r=sys.argv[1],sys.argv[2]
for e in json.load(sys.stdin):
    if e.get("displayName")==n or e.get("alias")==n:
        e["requirement"]=r; print(json.dumps(e)); break' "$1" "$2")"
  [[ -n "$body" ]] || die "eksekusi $1 tidak ditemukan"
  kc_send PUT "/authentication/flows/${FLOW_Q}/executions" "$body" 202 204
}
add_sub() { # <parent alias> <alias sub-flow>
  kc_send POST "/authentication/flows/$(q "$1")/executions/flow" \
    "$(python3 -c 'import json,sys;print(json.dumps({"alias":sys.argv[1],"type":"basic-flow","description":"9router SSO","provider":"registration-page-form"}))' "$2")" 201
}
add_exec() { # <parent alias> <provider>
  kc_send POST "/authentication/flows/$(q "$1")/executions/execution" "{\"provider\":\"$2\"}" 201
}

flow_id() { kc_get "/authentication/flows" | python3 -c 'import sys,json
for f in json.load(sys.stdin):
    if f["alias"]==sys.argv[1]: print(f["id"])' "$FLOW"; }
# GET /authentication/flows/{x} butuh id (bukan alias) → cari lewat daftar.
if [[ -z "$(flow_id)" ]]; then
  kc_send POST "/authentication/flows" "$(python3 -c 'import json,sys;print(json.dumps({"alias":sys.argv[1],"providerId":"basic-flow","topLevel":True,"builtIn":False,"description":"Browser login 9router: hanya user dengan client role 9router.access"}))' "$FLOW")" 201
  add_sub "$FLOW" "9router authn"
  add_exec "9router authn" auth-cookie
  add_sub "9router authn" "9router forms"
  add_exec "9router forms" auth-username-password-form
  add_sub "9router forms" "9router 2FA"
  add_exec "9router 2FA" conditional-user-configured
  add_exec "9router 2FA" auth-otp-form
  add_sub "$FLOW" "9router authz"
  add_exec "9router authz" conditional-user-role
  add_exec "9router authz" deny-access-authenticator
  set_req "9router authn" REQUIRED
  set_req "Cookie" ALTERNATIVE
  set_req "9router forms" ALTERNATIVE
  set_req "Username Password Form" REQUIRED
  set_req "9router 2FA" CONDITIONAL
  set_req "Condition - user configured" REQUIRED
  set_req "OTP Form" REQUIRED
  set_req "9router authz" CONDITIONAL
  set_req "Condition - user role" REQUIRED
  set_req "Deny access" REQUIRED
  kc_send POST "/authentication/executions/$(exec_id "Condition - user role")/config" \
    "{\"alias\":\"9router-require-access\",\"config\":{\"condUserRole\":\"${CLIENT_ID}.${ROLE}\",\"negate\":\"true\"}}" 201
  echo "flow '$FLOW': dibuat"
else
  echo "flow '$FLOW': ada"
fi
FLOW_ID="$(flow_id)"
[[ -n "$FLOW_ID" ]] || die "flow $FLOW tidak ditemukan"

# ---------------------------------------------------------------- 2. client
CLIENT_JSON="$(python3 -c 'import json,sys
cid,redir,fid,host=sys.argv[1:5]
print(json.dumps({"clientId":cid,"name":"9Router dashboard","enabled":True,"protocol":"openid-connect",
 "publicClient":False,"clientAuthenticatorType":"client-secret","standardFlowEnabled":True,
 "implicitFlowEnabled":False,"directAccessGrantsEnabled":False,"serviceAccountsEnabled":False,
 "frontchannelLogout":False,"fullScopeAllowed":False,"redirectUris":[redir],"webOrigins":[],
 "rootUrl":"https://"+host,"baseUrl":"/dashboard",
 "attributes":{"pkce.code.challenge.method":"S256","post.logout.redirect.uris":"https://"+host+"/login"},
 "authenticationFlowBindingOverrides":{"browser":fid}}))' "$CLIENT_ID" "$REDIRECT" "$FLOW_ID" "$HOST")"
CUUID="$(kc_get "/clients?clientId=${CLIENT_ID}" | kc_json 'd[0]["id"] if d else ""')"
if [[ -z "$CUUID" ]]; then
  kc_send POST "/clients" "$CLIENT_JSON" 201
  CUUID="$(kc_get "/clients?clientId=${CLIENT_ID}" | kc_json 'd[0]["id"]')"
  echo "client $CLIENT_ID: dibuat"
else
  kc_send PUT "/clients/${CUUID}" "$CLIENT_JSON" 204
  echo "client $CLIENT_ID: diperbarui"
fi

# ---------------------------------------------------------------- 3. role → satu user
kc_request GET "/clients/${CUUID}/roles/${ROLE}"
[[ "$KC_STATUS" == 200 ]] || kc_send POST "/clients/${CUUID}/roles" "{\"name\":\"${ROLE}\",\"description\":\"Akses dashboard 9router\"}" 201
ROLE_JSON="$(kc_get "/clients/${CUUID}/roles/${ROLE}" | kc_json 'json.dumps([{"id":d["id"],"name":d["name"]}])')"
UID_="$(kc_get "/users?email=$(q "$ALLOWED_EMAIL")&exact=true" | kc_json 'd[0]["id"] if len(d)==1 else ""')"
[[ -n "$UID_" ]] || die "user dengan email $ALLOWED_EMAIL tidak ditemukan tepat satu"
kc_send POST "/users/${UID_}/role-mappings/clients/${CUUID}" "$ROLE_JSON" 204
HOLDERS="$(kc_get "/clients/${CUUID}/roles/${ROLE}/users" | kc_json '",".join(sorted(u.get("email","?") for u in d))')"
echo "role ${CLIENT_ID}.${ROLE}: pemegang = ${HOLDERS}"
[[ "$HOLDERS" == "$ALLOWED_EMAIL" ]] || die "pemegang role bukan hanya $ALLOWED_EMAIL — periksa manual"

# ---------------------------------------------------------------- 4. 9router settings
kc_get_quiet "/clients/${CUUID}/client-secret" | kc_json 'd["value"]' | \
docker exec -i -u node -w /app 9router node -e '
const issuer = process.argv[1], clientId = process.argv[2], mode = process.argv[3];
let secret = ""; process.stdin.on("data", c => secret += c).on("end", async () => {
  secret = secret.trim(); if (!secret) { console.error("secret kosong"); process.exit(1); }
  const base = "http://127.0.0.1:20128";
  const login = await fetch(base + "/api/auth/login", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password: process.env.INITIAL_PASSWORD }) });
  const cookie = (login.headers.getSetCookie() || []).map(c => c.split(";")[0]).join("; ");
  if (login.status === 403) { console.log("9router: login password lokal ditolak (sudah mode SSO) — settings TIDAK diubah. " +
    "Ubah lewat dashboard (Profile) atau pulihkan mode password: hapus kunci authMode di tabel settings lalu restart."); return; }
  if (!login.ok || !cookie) { console.error("login lokal gagal: " + login.status + " " + (await login.text()).slice(0, 200)); process.exit(1); }
  const r = await fetch(base + "/api/settings", { method: "PATCH", headers: { "Content-Type": "application/json", Cookie: cookie },
    body: JSON.stringify({ authMode: mode, ssoType: "oidc", oidcIssuerUrl: issuer, oidcClientId: clientId,
      oidcClientSecret: secret, oidcScopes: "openid profile email", oidcLoginLabel: "Masuk dengan SSO Bima Creative" }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { console.error("PATCH settings gagal: " + r.status + " " + JSON.stringify(j).slice(0, 200)); process.exit(1); }
  console.log("9router: authMode=" + j.authMode + " oidcConfigured=" + j.oidcConfigured + " issuer=" + j.oidcIssuerUrl);
});' "https://auth.bimacreative.tech/realms/${REALM}" "$CLIENT_ID" "$MODE"
echo "RESULT realm=${REALM} client=${CLIENT_ID} flow='${FLOW}' role=${CLIENT_ID}.${ROLE} mode=${MODE}"
