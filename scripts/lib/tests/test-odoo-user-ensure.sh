#!/usr/bin/env bash
# Uji scripts/lib/odoo_user_ensure.py di stack SEKALI PAKAI (kontrak SaaS Fase 1 §3): Postgres + odoo:19.0-20260908
# baru, jaringan docker --internal sendiri, tanpa port terpublikasi, tanpa volume/jaringan prod. Semua dibersihkan
# (trap EXIT). Tidak menyentuh container odoo-pool-*/odoo-staging/postgres.
#
#   scripts/lib/tests/test-odoo-user-ensure.sh [<path odoo-addons-shared>]   (default /opt/src/odoo-addons-shared)
#
# Kasus: dry-run create (tidak menulis), create, rerun idempoten, role user→admin→user, nonaktif/aktif, dry-run
# perubahan, user admin/__system__ ditolak, oauth_uid konflik ditolak, user tertaut subject lain ditolak, login
# dipakai user lain ditolak, user portal ditolak, tidak ada + active=false = no-op, parameter tidak valid, provider
# tidak ada, signal_changes (orm_signaling_*) hanya saat apply, pergantian email/login via KC id, user lokal admin
# ditemukan by login dengan role user ditolak (QA F7).
set -euo pipefail

ADDONS="${1:-/opt/src/odoo-addons-shared}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../odoo_user_ensure.py"
ODOO_IMAGE=odoo:19.0-20260908
PG_IMAGE=postgres:16.15-bookworm
TAG="${TEST_TAG_PREFIX:-p1test-c-oue}-$$"   # prefix nama container/jaringan uji (bisa dioverride)
NET="$TAG-net"; DBC="$TAG-db"; DB=t_oue
[[ -f "$ADDONS/sh_auth_oidc/__manifest__.py" ]] || { echo "sh_auth_oidc tidak ada di $ADDONS" >&2; exit 2; }
[[ -f "$SCRIPT" ]] || { echo "$SCRIPT tidak ada" >&2; exit 2; }

PGPW="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"   # hanya untuk stack uji ini
cleanup() {
  docker rm -f "$DBC" >/dev/null 2>&1 || true
  docker ps -aq --filter "name=^${TAG}-odoo" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create --internal "$NET" >/dev/null
docker run -d --name "$DBC" --network "$NET" --network-alias db --memory 384m --security-opt no-new-privileges:true \
  -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD="$PGPW" -e POSTGRES_DB=postgres "$PG_IMAGE" >/dev/null
for _ in $(seq 1 60); do docker exec "$DBC" pg_isready -U odoo -d postgres >/dev/null 2>&1 && break; sleep 1; done

N=0
odoo_run() {  # odoo_run [docker run opsi…] -- <argumen odoo…>
  local opts=()
  while [[ "$1" != -- ]]; do opts+=("$1"); shift; done; shift
  N=$((N+1))
  docker run --rm -i --name "$TAG-odoo-$N" --network "$NET" --memory 1g --cap-drop ALL \
    --security-opt no-new-privileges:true -v "$ADDONS:/mnt/extra-addons:ro" \
    -e HOST=db -e USER=odoo -e PASSWORD="$PGPW" "${opts[@]}" "$ODOO_IMAGE" odoo "$@"
}
psql_q() { docker exec "$DBC" psql -X -q -tA -U odoo -d "$DB" -c "$1"; }

echo "== install auth_oauth + sh_auth_oidc ke DB baru $DB"
odoo_run -- -d "$DB" -i sh_auth_oidc --stop-after-init --without-demo --no-http --log-level=warn

echo "== fixture: provider OIDC aktif + user pembanding"
odoo_run -- shell -d "$DB" --no-http --log-level=warn <<'PY'
from odoo import Command
P = env['auth.oauth.provider']
base = {'enabled': True, 'auth_endpoint': 'https://idp.test/realms/platform/protocol/openid-connect/auth',
        'validation_endpoint': 'https://idp.test/realms/platform/protocol/openid-connect/userinfo',
        'scope': 'openid profile email', 'body': 'Login SSO', 'sh_oidc_enabled': True, 'sh_oidc_issuer': 'https://idp.test/realms/platform',
        'sh_oidc_token_endpoint': 'https://idp.test/realms/platform/protocol/openid-connect/token',
        'sh_oidc_jwks_uri': 'https://idp.test/realms/platform/protocol/openid-connect/certs'}
# provider bawaan auth_oauth (Google dst.) tidak sh_oidc → tidak dihitung
prov = P.create(dict(base, name='Keycloak', client_id='odoo-acme-staging'))
other = P.create(dict(base, name='Old', client_id='odoo-old-staging', enabled=False))
U = env['res.users'].with_context(no_reset_password=True)
g_user = env.ref('base.group_user')
U.create({'name': 'Bob', 'login': 'bob@example.com', 'email': 'bob@example.com', 'oauth_provider_id': prov.id,
          'oauth_uid': '22222222-2222-4222-8222-222222222222', 'group_ids': [Command.set(g_user.ids)]})
U.create({'name': 'Carol', 'login': 'carol@example.com', 'email': 'carol@example.com',
          'oauth_provider_id': other.id, 'oauth_uid': '33333333-3333-4333-8333-333333333333',
          'group_ids': [Command.set(g_user.ids)]})
U.create({'name': 'Dave', 'login': 'dave@example.com', 'email': 'dave@example.com',
          'group_ids': [Command.set(g_user.ids)]})
U.create({'name': 'Pat', 'login': 'pat@example.com', 'email': 'pat@example.com',
          'group_ids': [Command.set(env.ref('base.group_portal').ids)]})
# user LOKAL admin (tanpa tautan OIDC) — kasus 12 (QA F7)
U.create({'name': 'Gina', 'login': 'gina@example.com', 'email': 'gina@example.com',
          'group_ids': [Command.set((g_user | env.ref('base.group_system')).ids)]})
env.cr.commit()
print('FIXTURE_OK provider=%d' % prov.id)
PY

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ok   $*"; }
ko() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1 (dapat '$2', harap '$3')"; fi; }
# out_has <regex> <label> / out_lacks <regex> <label> — pemeriksaan stdout kasus terakhir
out_has() { if grep -q -- "$1" <<<"$OUT"; then ok "$2"; else ko "$2 (stdout: $OUT)"; fi; }
out_lacks() { if grep -q -- "$1" <<<"$OUT"; then ko "$2 (stdout: $OUT)"; else ok "$2"; fi; }

OUT=""; RC=0
# ensure <email> <role> <active> <kc_id> <dry_run> [VAR=nilai…] — env diteruskan dengan -e VAR (pola wrapper)
ensure() {
  local -a extra=()
  local kv
  for kv in "${@:6}"; do extra+=(-e "${kv%%=*}"); export "${kv?}"; done
  export ODOO_USER_EMAIL="$1" ODOO_USER_ROLE="$2" ODOO_USER_ACTIVE="$3" ODOO_USER_KC_ID="$4" ODOO_USER_DRY_RUN="$5"
  set +e
  OUT="$(odoo_run -e ODOO_USER_EMAIL -e ODOO_USER_LOGIN -e ODOO_USER_NAME -e ODOO_USER_ROLE -e ODOO_USER_ACTIVE \
        -e ODOO_USER_KC_ID -e ODOO_USER_DRY_RUN -e ODOO_USER_OIDC_CLIENT_ID "${extra[@]}" -- \
        shell -d "$DB" --no-http --log-level=warn < "$SCRIPT" 2>"$ERRF")"
  RC=$?
  set -e
  unset ODOO_USER_LOGIN ODOO_USER_NAME ODOO_USER_OIDC_CLIENT_ID
  for kv in "${@:6}"; do unset "${kv%%=*}"; done
}
ERRF="$(mktemp)"; trap 'cleanup; rm -f "$ERRF"' EXIT
result() { tail -n1 <<<"$OUT"; }
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$(result)"; }

KC=11111111-1111-4111-8111-111111111111
uid_of() { psql_q "SELECT id FROM res_users WHERE oauth_uid = '$1'"; }
has_group() {  # has_group <user id> <xmlid name di modul base> → t|f (termasuk grup implisit)
  psql_q "WITH RECURSIVE g(id) AS (SELECT gid FROM res_groups_users_rel WHERE uid = $1
            UNION SELECT r.hid FROM res_groups_implied_rel r JOIN g ON r.gid = g.id)
          SELECT EXISTS (SELECT 1 FROM g JOIN ir_model_data d ON d.res_id = g.id AND d.model = 'res.groups'
                         AND d.module = 'base' AND d.name = '$2')"
}
sig() { psql_q "SELECT (SELECT coalesce(max(id),0) FROM orm_signaling_default) + (SELECT coalesce(max(id),0) FROM orm_signaling_registry)"; }

echo "== 1. dry-run create: rencana, tidak menulis, tanpa sinyal cache"
S0="$(sig)"
ensure alice@example.com user true "$KC" true ODOO_USER_NAME="Alice A"
check "exit 0" "$RC" 0
check "RESULT dry-run create" "$(result)" "RESULT db=$DB odoo_user=- kc_user=$KC created=1 changed=1"
out_has '^PLAN: buat res.users internal' "baris PLAN"
check "tidak ada user dibuat" "$(uid_of "$KC")" ""
check "tidak ada sinyal cache" "$(sig)" "$S0"

echo "== 2. create (role user)"
ensure alice@example.com user true "$KC" false ODOO_USER_NAME="Alice A"
check "exit 0" "$RC" 0
ID="$(uid_of "$KC")"
check "RESULT create" "$(result)" "RESULT db=$DB odoo_user=$ID kc_user=$KC created=1 changed=1"
check "internal (share=f), aktif, login=email" \
  "$(psql_q "SELECT share, active, login, oauth_provider_id IS NOT NULL FROM res_users WHERE id = $ID")" "f|t|alice@example.com|t"
check "tanpa password lokal" "$(psql_q "SELECT password IS NULL FROM res_users WHERE id = $ID")" t
check "nama" "$(psql_q "SELECT p.name FROM res_users u JOIN res_partner p ON p.id = u.partner_id WHERE u.id = $ID")" "Alice A"
check "group_user" "$(has_group "$ID" group_user)" t
check "bukan group_system" "$(has_group "$ID" group_system)" f
if [[ "$(sig)" -gt "$S0" ]]; then ok "signal_changes() menulis orm_signaling_*"; else ko "tidak ada sinyal cache setelah apply"; fi
if grep -qF -e alice@example.com -e "Alice A" <<<"$OUT"; then ko "stdout memuat email/nama"; else ok "stdout tanpa email/nama (PII)"; fi

echo "== 3. rerun idempoten"
ensure alice@example.com user true "$KC" false ODOO_USER_NAME="Alice A"
check "RESULT rerun" "$(result)" "RESULT db=$DB odoo_user=$ID kc_user=$KC created=0 changed=0"
ensure alice@example.com user true "$KC" false
check "rerun tanpa nama (nama tidak diubah)" "$(field changed)" 0

echo "== 4. role user → admin (dry-run lalu apply) → user"
ensure alice@example.com admin true "$KC" true
check "dry-run admin changed=1" "$(field changed)" 1
check "dry-run tidak mengubah grup" "$(has_group "$ID" group_system)" f
ensure alice@example.com admin true "$KC" false
check "RESULT admin" "$(result)" "RESULT db=$DB odoo_user=$ID kc_user=$KC created=0 changed=1"
check "group_system" "$(has_group "$ID" group_system)" t
ensure alice@example.com admin true "$KC" false
check "admin rerun changed=0" "$(field changed)" 0
ensure alice@example.com user true "$KC" false
check "kembali user changed=1" "$(field changed)" 1
check "group_system dicabut" "$(has_group "$ID" group_system)" f
check "group_erp_manager tidak tersisa" "$(has_group "$ID" group_erp_manager)" f
check "group_user tetap" "$(has_group "$ID" group_user)" t

echo "== 5. grup Access Rights eksplisit dicabut pada role user"
docker exec "$DBC" psql -X -q -U odoo -d "$DB" -c "INSERT INTO res_groups_users_rel (gid, uid) SELECT res_id, $ID FROM ir_model_data WHERE module='base' AND name='group_erp_manager'" >/dev/null
ensure alice@example.com user true "$KC" false
check "erp_manager dicabut changed=1" "$(field changed)" 1
check "group_erp_manager tidak tersisa" "$(has_group "$ID" group_erp_manager)" f

echo "== 6. nonaktif / aktif"
ensure alice@example.com user false "$KC" false
check "nonaktif changed=1" "$(field changed)" 1
check "active=f" "$(psql_q "SELECT active FROM res_users WHERE id = $ID")" f
ensure alice@example.com user false "$KC" false
check "nonaktif rerun changed=0" "$(field changed)" 0
ensure alice@example.com admin true "$KC" false
check "aktif + admin changed=2" "$(field changed)" 2
check "active=t" "$(psql_q "SELECT active FROM res_users WHERE id = $ID")" t

echo "== 7. email/login berubah di Keycloak (dicari via KC id)"
ensure alice.new@example.com admin true "$KC" false
check "login+email changed=2" "$(field changed)" 2
check "login baru" "$(psql_q "SELECT login FROM res_users WHERE id = $ID")" alice.new@example.com
check "user sama" "$(field odoo_user)" "$ID"

echo "== 8. penolakan (exit 3, tanpa RESULT, tanpa perubahan)"
before="$(psql_q "SELECT md5(string_agg(id||login||active::text||coalesce(oauth_uid,''), ',' ORDER BY id)) FROM res_users")"
ensure admin@example.com admin true 44444444-4444-4444-8444-444444444444 false ODOO_USER_LOGIN=admin
check "base.user_admin ditolak (exit)" "$RC" 3
out_has '^ERROR: .*terlindungi' "ERROR user terlindungi"
ensure sys@example.com user true 44444444-4444-4444-8444-444444444444 false ODOO_USER_LOGIN=__system__
check "__system__ ditolak" "$RC" 3
ensure dave@example.com user true 22222222-2222-4222-8222-222222222222 false
check "KC id tertaut ke Bob, login milik Dave (res.users lain) → ditolak" "$RC" 3
out_has '^ERROR: login sudah dipakai res.users' "ERROR konflik KC id vs login"
ensure eve@example.com user true "$KC" false
check "KC id milik Alice + login lain = ubah login (bukan konflik)" "$RC" 0
ensure alice.new@example.com admin true "$KC" false
ensure bob@example.com user true 55555555-5555-4555-8555-555555555555 false
check "login Bob tertaut subject lain → ditolak" "$RC" 3
out_has '^ERROR: .*subject Keycloak lain' "ERROR subject lain"
ensure frank@example.com user true 33333333-3333-4333-8333-333333333333 false
check "oauth_uid tertaut di provider lain (Carol) → ditolak" "$RC" 3
out_has '^ERROR: oauth_uid (KC id) sudah tertaut ke res.users lain' "ERROR oauth_uid konflik"
ensure alice.new@example.com admin true "$KC" false ODOO_USER_LOGIN=bob@example.com
check "login dipakai res.users lain → ditolak" "$RC" 3
ensure pat@example.com user true 66666666-6666-4666-8666-666666666666 false
check "user portal → ditolak" "$RC" 3
out_has '^ERROR: .*portal' "ERROR portal"
out_lacks '^RESULT' "tanpa RESULT pada penolakan"
check "res.users tidak berubah oleh penolakan" \
  "$(psql_q "SELECT md5(string_agg(id||login||active::text||coalesce(oauth_uid,''), ',' ORDER BY id)) FROM res_users")" "$before"

echo "== 9. user lama tanpa tautan ditemukan by login → ditautkan"
ensure dave@example.com user true 77777777-7777-4777-8777-777777777777 false
check "Dave ditautkan changed=1" "$(field changed)" 1
check "tautan Dave" "$(psql_q "SELECT oauth_uid FROM res_users WHERE login = 'dave@example.com'")" 77777777-7777-4777-8777-777777777777

echo "== 10. tidak ada + active=false = no-op"
ensure ghost@example.com user false 88888888-8888-4888-8888-888888888888 false
check "RESULT no-op" "$(result)" "RESULT db=$DB odoo_user=- kc_user=88888888-8888-4888-8888-888888888888 created=0 changed=0"
check "tidak dibuat" "$(uid_of 88888888-8888-4888-8888-888888888888)" ""

echo "== 11. parameter/prasyarat tidak valid (exit 2)"
ensure alice.new@example.com owner true "$KC" false
check "role tidak valid" "$RC" 2
ensure alice.new@example.com user true NOT-A-UUID false
check "KC id tidak valid" "$RC" 2
ensure Alice@Example.com user true "$KC" false
check "email huruf besar" "$RC" 2
ensure alice.new@example.com user yes "$KC" false
check "active bukan true|false" "$RC" 2
ensure alice.new@example.com user true "$KC" ""
check "dry_run kosong" "$RC" 2
ensure alice.new@example.com user true "$KC" false ODOO_USER_NAME="-x"
check "nama diawali '-'" "$RC" 2
ensure alice.new@example.com user true "$KC" false ODOO_USER_OIDC_CLIENT_ID=odoo-none-staging
check "provider tidak ada" "$RC" 2
ensure alice.new@example.com admin true "$KC" false ODOO_USER_OIDC_CLIENT_ID=odoo-acme-staging
check "provider by client id" "$RC" 0

echo "== 12. user LOKAL admin ditemukan by login (oauth_uid kosong) — QA F7"
KG=99999999-9999-4999-8999-999999999999
GID="$(psql_q "SELECT id FROM res_users WHERE login = 'gina@example.com'")"
before="$(psql_q "SELECT md5(string_agg(id||login||active::text||coalesce(oauth_uid,''), ',' ORDER BY id)) FROM res_users")"
ensure gina@example.com user true "$KG" true
check "dry-run role user → ditolak" "$RC" 3
out_has '^ERROR: .*user lokal admin; tautkan dengan role admin atau tangani manual' "ERROR user lokal admin"
out_lacks '^RESULT' "tanpa RESULT"
ensure gina@example.com user true "$KG" false
check "apply role user → ditolak" "$RC" 3
check "hak admin lokal tetap" "$(has_group "$GID" group_system)" t
check "tidak ditautkan" "$(psql_q "SELECT coalesce(oauth_uid, '') FROM res_users WHERE id = $GID")" ""
check "res.users tidak berubah oleh penolakan" \
  "$(psql_q "SELECT md5(string_agg(id||login||active::text||coalesce(oauth_uid,''), ',' ORDER BY id)) FROM res_users")" "$before"
ensure gina@example.com admin true "$KG" false
check "role admin → ditautkan (exit 0)" "$RC" 0
check "tautan saja changed=1" "$(field changed)" 1
check "user sama" "$(field odoo_user)" "$GID"
check "group_system tetap" "$(has_group "$GID" group_system)" t
ensure gina@example.com user true "$KG" false
check "setelah tertaut: turun ke role user diizinkan (by KC id)" "$RC" 0
check "group_system dicabut eksplisit" "$(has_group "$GID" group_system)" f

echo
echo "HASIL: $PASS ok, $FAIL gagal"
[[ $FAIL -eq 0 ]]
