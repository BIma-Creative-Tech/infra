#!/usr/bin/env bash
# Provision DB tenant Odoo di pool shared (T10). IDEMPOTEN — aman dijalankan berulang.
#
#   scripts/provision-odoo-db.sh <slug> <prod|demo|staging> [--host <fqdn>]
#
#   slug  ^[a-z0-9-]{3,30}$  → DB `<slug dengan '-'→'_'>_<env>` (mis. acme-co prod → acme_co_prod)
#   env   prod|demo → pool-a (odoo-pool-a) · staging → pool staging (odoo-staging)
#   host  default prod `<slug>.erp.bimacreative.tech`, staging `<slug>.staging.bimacreative.tech`;
#         demo WAJIB --host. Dipakai untuk web.base.url (+ freeze).
#
# Langkah (masing-masing dicek dulu, hanya diubah bila perlu):
#  1. DB belum ada → `odoo -d <db> -i base,sh_dbfilter_header --stop-after-init` di container pool
#     (demo: --with-demo; prod/staging: --without-demo). DB ada → pastikan owner = role pool.
#  2. modul sh_dbfilter_header ter-install (server-wide tetap dari odoo.conf; install = tercatat di DB).
#  3. REVOKE ALL ON DATABASE <db> FROM PUBLIC (role pool lain tidak bisa CONNECT).
#  4. ir.config_parameter web.base.url=https://<host>, web.base.url.freeze=True.
#  5. admin tenant (base.user_admin, login `admin`) diberi password acak 40 char, disimpan di
#     <pool>/secrets/tenants/<db>.admin-password (600 root, di luar git); bila file sudah ada dan
#     cocok dengan hash di DB → tidak diubah. User lain yang password == login (data demo:
#     demo/demo, portal/portal) → password acak (tidak disimpan).
# Output baris terakhir (untuk control plane):  RESULT db=<db> pool=<pool> host=<host> created=<yes|no> changed=<n> secret=<path>
# Exit ≠ 0 bila gagal. Tidak pernah DROP DATABASE.
set -euo pipefail
# shellcheck source=lib/odoo-pools.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/odoo-pools.sh"

usage() { echo "pemakaian: $0 <slug> <prod|demo|staging> [--host <fqdn>]" >&2; exit 2; }
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage; HOST="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$HOST" ]] || HOST="$(default_host)"
validate_host "$HOST"

container_running "$PG_CONTAINER" || die "container $PG_CONTAINER tidak berjalan"
container_running "$POOL_CONTAINER" || die "container $POOL_CONTAINER tidak berjalan"

exec 9>"/run/lock/odoo-provision-${DB_NAME}.lock"
flock -n 9 || die "provisioning ${DB_NAME} sedang berjalan (lock)"

CHANGED=0; CREATED=no
log() { echo "[$DB_NAME] $*"; }
# psql superuser via socket (peer). Semua identifier sudah divalidasi regex ^[a-z0-9_]+$.
pgq() { docker exec -i "$PG_CONTAINER" psql -X -q -tA -v ON_ERROR_STOP=1 -U postgres -d "${2:-postgres}" -c "$1"; }
odoo_cli() { # [shell] <opsi…> → proses odoo satu-kali di container pool (tanpa HTTP/cron/worker).
  # Subcommand Odoo harus argumen pertama (odoo/cli/command.py main).
  local sub=(); [[ "${1:-}" == shell ]] && { sub=(shell); shift; }
  docker exec -i "$POOL_CONTAINER" odoo "${sub[@]}" -c "$ODOO_CONF_IN_CONTAINER" -d "$DB_NAME" \
    --no-http --workers=0 --max-cron-threads=0 "$@"
}

# 1. DB
owner="$(pgq "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DB_NAME}'")"
if [[ -z "$owner" ]]; then
  demo_flag="--without-demo"; [[ "$TENANT_ENV" == demo ]] && demo_flag="--with-demo"
  log "membuat DB (${demo_flag}) di ${POOL_CONTAINER} …"
  odoo_cli -i base,sh_dbfilter_header "$demo_flag" --stop-after-init --log-level=warn
  owner="$(pgq "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DB_NAME}'")"
  [[ -n "$owner" ]] || die "DB tidak terbentuk — lihat output odoo di atas"
  CREATED=yes; CHANGED=$((CHANGED+1))
fi
[[ "$owner" == "$POOL_PGUSER" ]] || die "DB ${DB_NAME} dimiliki '${owner}', bukan ${POOL_PGUSER} — periksa manual"
base_state="$(pgq "SELECT state FROM ir_module_module WHERE name = 'base'" "$DB_NAME" 2>/dev/null || true)"
[[ "$base_state" == installed ]] || die "DB ${DB_NAME} ada tetapi modul base tidak ter-install (state='${base_state}') — DB rusak/setengah jadi, periksa manual (skrip tidak menghapus DB)"
log "DB ok (owner ${owner}, created=${CREATED})"

# 2. sh_dbfilter_header
st="$(pgq "SELECT state FROM ir_module_module WHERE name = 'sh_dbfilter_header'" "$DB_NAME")"
if [[ "$st" != installed ]]; then
  log "install sh_dbfilter_header (state='${st}') …"
  odoo_cli -i sh_dbfilter_header --stop-after-init --log-level=warn
  st="$(pgq "SELECT state FROM ir_module_module WHERE name = 'sh_dbfilter_header'" "$DB_NAME")"
  [[ "$st" == installed ]] || die "sh_dbfilter_header gagal di-install (state='${st}')"
  CHANGED=$((CHANGED+1))
fi
log "sh_dbfilter_header: installed"

# 3. CONNECT hanya owner
acl="$(pgq "SELECT coalesce(array_to_string(datacl, ','), '') FROM pg_database WHERE datname = '${DB_NAME}'")"
if [[ -z "$acl" || ",${acl}," == *",=T"* || ",${acl}," == *",=c"* || ",${acl}," == *",=Tc"* ]]; then
  pgq "REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC" >/dev/null
  CHANGED=$((CHANGED+1)); log "REVOKE ALL FROM PUBLIC: diterapkan"
else
  log "ACL ok (${acl})"
fi

# 4 + 5. parameter sistem & password admin — lewat `odoo shell` (script dari stdin, bukan argv).
SECRET="$(tenant_secret_file)"
umask 077
install -d -o root -g root -m 0700 "$(dirname "$SECRET")"
if [[ ! -s "$SECRET" ]]; then
  pw="$(openssl rand -base64 60 | tr -dc 'A-Za-z0-9' | head -c 40)"
  [[ ${#pw} -eq 40 ]] || die "gagal membangkitkan password"
  printf '%s' "$pw" > "$SECRET"; unset pw
  log "password admin baru dibangkitkan → ${SECRET}"
fi
chmod 600 "$SECRET"; chown root:root "$SECRET"
ADMIN_PW="$(cat "$SECRET")"
[[ "$ADMIN_PW" =~ ^[A-Za-z0-9]{32,}$ ]] || die "isi ${SECRET} tidak valid"

shell_out="$(odoo_cli shell --log-level=warn <<PY 2>&1
changed = 0
ICP = env['ir.config_parameter'].sudo()
for key, val in (('web.base.url', 'https://${HOST}'), ('web.base.url.freeze', 'True')):
    if ICP.get_param(key) != val:
        ICP.set_param(key, val)
        changed += 1
        print('PARAM %s: diubah' % key)
Users = env['res.users'].sudo().with_context(active_test=False)
ctx = Users._crypt_context()
def pw_hash(user):
    env.cr.execute('SELECT COALESCE(password, \'\') FROM res_users WHERE id = %s', (user.id,))
    return env.cr.fetchone()[0]
admin = env.ref('base.user_admin')
h = pw_hash(admin)
if not (h and ctx.verify('${ADMIN_PW}', h)):
    admin.write({'password': '${ADMIN_PW}'})
    changed += 1
    print('ADMIN password: disetel')
import secrets
for u in Users.search([('id', '!=', admin.id)]):
    h = pw_hash(u)
    if h and u.login and ctx.verify(u.login, h):
        u.write({'password': secrets.token_urlsafe(32)})
        changed += 1
        print('USER %s: password default (= login) diganti acak' % u.login)
env.cr.commit()
print('SHELL_CHANGED=%d' % changed)
PY
)" || { echo "$shell_out" >&2; die "odoo shell gagal"; }
unset ADMIN_PW
echo "$shell_out" | grep -E '^(PARAM|ADMIN|USER) ' | sed "s/^/[$DB_NAME] /" || true
sc="$(echo "$shell_out" | sed -n 's/^SHELL_CHANGED=//p' | tail -n1)"
[[ "$sc" =~ ^[0-9]+$ ]] || { echo "$shell_out" >&2; die "output odoo shell tidak dikenali"; }
CHANGED=$((CHANGED+sc))
log "web.base.url=https://${HOST} (freeze) · admin login=admin"

echo "RESULT db=${DB_NAME} pool=${POOL} host=${HOST} created=${CREATED} changed=${CHANGED} secret=${SECRET}"
