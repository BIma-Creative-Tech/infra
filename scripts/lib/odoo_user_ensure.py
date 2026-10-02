# Part of infra (SaaS Fase 1, kontrak docs/plans/saas-phase-1-contract.md §1 `odoo_user_ensure` + §1.1).
# Helper Odoo yang DIJALANKAN OLEH `odoo shell` (bukan skrip mandiri): memastikan satu res.users internal untuk satu
# user Keycloak di satu DB tenant. Pemilik: odoo-developer. Pemanggil: scripts/odoo-user.sh (infra-engineer).
#
# Cara pemanggilan (wrapper). `docker exec` TIDAK meneruskan env host secara otomatis: setiap variabel harus diteruskan
# eksplisit dengan `-e VAR` (tanpa `=nilai`, agar nilai diambil dari env proses wrapper dan tidak muncul di argv/ps):
#
#   ODOO_USER_EMAIL=... ODOO_USER_ROLE=user ... \
#   docker exec -i \
#     -e ODOO_USER_EMAIL -e ODOO_USER_LOGIN -e ODOO_USER_NAME -e ODOO_USER_ROLE -e ODOO_USER_ACTIVE \
#     -e ODOO_USER_KC_ID -e ODOO_USER_DRY_RUN [-e ODOO_USER_OIDC_CLIENT_ID] \
#     <pool> odoo shell -c <conf> -d <db> --no-http --workers=0 --max-cron-threads=0 --log-level=warn \
#     < scripts/lib/odoo_user_ensure.py
#
# (`odoo shell` membaca stdin bila stdin bukan TTY dan menjalankannya dengan `env` = Environment superuser DB `-d`.)
#
# Parameter (env, semua divalidasi ulang di sini — pertahanan berlapis di belakang validator dispatcher):
#   ODOO_USER_EMAIL           wajib; email huruf kecil (= EMAIL_RE dispatcher), maks. 254.
#   ODOO_USER_LOGIN           opsional; default = email (= LOGIN_RE dispatcher).
#   ODOO_USER_NAME            opsional; nama tampilan (NAME_RE kontrak §1, ASCII). Default saat membuat = email.
#                             Saat user sudah ada, nama hanya diubah bila parameter ini diisi.
#   ODOO_USER_ROLE            wajib; `user` | `admin`.
#   ODOO_USER_ACTIVE          wajib; `true` | `false`.
#   ODOO_USER_KC_ID           wajib; id user Keycloak (= klaim `sub` OIDC), UUID huruf kecil.
#   ODOO_USER_DRY_RUN         wajib; `true` | `false`. `true` = rencana saja (perubahan dijalankan di transaksi lalu
#                             di-rollback: constraint Odoo ikut teruji, tidak ada yang di-commit).
#   ODOO_USER_OIDC_CLIENT_ID  opsional; Client ID provider (`odoo-<slug>-<env>`). Kosong = harus tepat satu provider
#                             sh_auth_oidc aktif (enabled + OIDC code flow) di DB ini.
#
# Perilaku (kontrak §1.1):
#   1. Provider = provider sh_auth_oidc aktif (tepat satu). Cari res.users (termasuk yang diarsipkan) by
#      (oauth_provider_id = provider, oauth_uid = KC id), lalu by login.
#   2. Tidak ada + active=true → buat user INTERNAL (share=False) tanpa password lokal, tanpa email undangan
#      (context no_reset_password). Tidak ada + active=false → no-op (tidak membuat user yang langsung diarsipkan).
#   3. Ada → samakan login, email, nama (bila diisi), tautan (oauth_provider_id, oauth_uid), grup, active.
#   4. Grup (hanya grup EKSPLISIT `group_ids`; grup lain, mis. aplikasi/paket, tidak disentuh):
#        user  → pastikan base.group_user; CABUT setiap grup eksplisit yang (transitif) mengimplikasikan
#                base.group_erp_manager (Access Rights) — termasuk base.group_system — agar tidak tersisa hak admin.
#        admin → pastikan base.group_user + base.group_system (Settings/Administration).
#      Pasca-kondisi diperiksa ulang (all_group_ids); gagal → rollback + ERROR.
#   5. Menolak (exit 3, baris `ERROR:`) bila target = base.user_root/__system__, base.user_admin, base.public_user,
#      template user (base.default_user, base.template_portal_user_id); target user portal/public (share=True,
#      konversi ke internal harus manual); oauth_uid sudah tertaut ke res.users LAIN (provider mana pun); user yang
#      ditemukan by login sudah tertaut ke subject Keycloak lain; login baru sudah dipakai res.users lain.
#   6. Apply: env.cr.commit() eksplisit (odoo shell me-rollback di akhir), lalu env.registry.signal_changes() —
#      write group_ids/active membersihkan ormcache (has_group, session token) HANYA di proses shell ini; tanpa sinyal
#      worker pool tetap memakai cache lama (pelajaran: ubah grup via odoo shell wajib signal_changes()).
#      Dry-run: env.cr.rollback() + env.registry.reset_changes().
#
# Output stdout: baris `PLAN: ...` (dry-run) / `UBAH: ...` (apply) tanpa nilai email/login/nama (PII hanya sebagai nama
# field), lalu baris terakhir:
#   RESULT db=<db> odoo_user=<id|-> kc_user=<kc_id> created=<0|1> changed=<n>
# `changed` = jumlah perubahan (pembuatan user = 1; tiap field/kelompok yang berubah = 1). Run kedua = changed=0.
# Dry-run yang akan membuat user mencetak odoo_user=- (id belum ada).
# Exit code: 0 sukses; 2 parameter/prasyarat tidak valid (mis. provider tidak ada); 3 ditolak (user terlindungi /
# konflik tautan); 1 kegagalan tak terduga (traceback Odoo di stderr). Pada exit ≠ 0 tidak ada baris RESULT dan
# transaksi di-rollback. Tidak ada secret yang dibaca atau dicetak.
import os
import re
import sys

from odoo import Command

env = globals().get('env')  # disuntikkan `odoo shell`

EMAIL_RE = re.compile(r'[a-z0-9_%+][a-z0-9._%+-]{0,63}@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}', re.ASCII)
LOGIN_RE = re.compile(r'[A-Za-z0-9._@+][A-Za-z0-9._@+-]{0,253}', re.ASCII)
NAME_RE = re.compile(r"[A-Za-z0-9.,'][A-Za-z0-9 .,'-]{0,99}", re.ASCII)
UUID_RE = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.ASCII)
CLIENT_ID_RE = re.compile(r'[a-z0-9][a-z0-9-]{0,99}', re.ASCII)
ROLES = ('user', 'admin')
PROTECTED_XMLIDS = ('base.user_root', 'base.user_admin', 'base.public_user', 'base.default_user',
                    'base.template_portal_user_id')
EXIT_INVALID = 2
EXIT_REFUSED = 3


class EnsureError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def _out(line):
    print(line, flush=True)


def _param(name, regex=None, required=True, max_len=254):
    value = os.environ.get(name, '')
    if not value:
        if required:
            raise EnsureError(f'{name} wajib diisi', EXIT_INVALID)
        return ''
    if len(value) > max_len or (regex is not None and not regex.fullmatch(value)):
        raise EnsureError(f'{name} tidak valid', EXIT_INVALID)
    return value


def _bool_param(name):
    value = os.environ.get(name, '')
    if value not in ('true', 'false'):
        raise EnsureError(f'{name} wajib `true` atau `false`', EXIT_INVALID)
    return value == 'true'


def _read_params():
    email = _param('ODOO_USER_EMAIL', EMAIL_RE)
    role = os.environ.get('ODOO_USER_ROLE', '')
    if role not in ROLES:
        raise EnsureError('ODOO_USER_ROLE wajib `user` atau `admin`', EXIT_INVALID)
    return {
        'email': email,
        'login': _param('ODOO_USER_LOGIN', LOGIN_RE, required=False) or email,
        'name': _param('ODOO_USER_NAME', NAME_RE, required=False, max_len=100),
        'role': role,
        'active': _bool_param('ODOO_USER_ACTIVE'),
        'kc_id': _param('ODOO_USER_KC_ID', UUID_RE, max_len=36),
        'dry_run': _bool_param('ODOO_USER_DRY_RUN'),
        'client_id': _param('ODOO_USER_OIDC_CLIENT_ID', CLIENT_ID_RE, required=False, max_len=100),
    }


def _provider(client_id):
    if 'auth.oauth.provider' not in env.registry or 'sh_oidc_enabled' not in env['auth.oauth.provider']._fields:
        raise EnsureError('modul sh_auth_oidc tidak ter-install di DB ini', EXIT_INVALID)
    domain = [('enabled', '=', True), ('sh_oidc_enabled', '=', True)]
    if client_id:
        domain.append(('client_id', '=', client_id))
    providers = env['auth.oauth.provider'].search(domain)
    if len(providers) != 1:
        scope = f' untuk client {client_id}' if client_id else ''
        raise EnsureError(f'harus tepat satu provider sh_auth_oidc aktif{scope} (ditemukan {len(providers)}) — '
                          f'jalankan provision-odoo-sso.sh / isi ODOO_USER_OIDC_CLIENT_ID', EXIT_INVALID)
    return providers


def _protected_users():
    users = env['res.users'].browse()
    for xmlid in PROTECTED_XMLIDS:
        record = env.ref(xmlid, raise_if_not_found=False)
        if record is not None and record._name == 'res.users':
            users |= record
    users |= env['res.users'].with_context(active_test=False).search([('login', '=', '__system__')])
    return users | env['res.users'].browse(1)  # SUPERUSER_ID


def _refuse_if_protected(user, protected):
    if user & protected:
        raise EnsureError(f'res.users {user.id} adalah user sistem/admin terlindungi — tidak diubah', EXIT_REFUSED)


def _find_target(params, provider, protected):
    users = env['res.users'].with_context(active_test=False)
    kc_id, login = params['kc_id'], params['login']
    linked_any = users.search([('oauth_uid', '=', kc_id)])
    by_uid = linked_any.filtered(lambda u: u.oauth_provider_id == provider)
    by_login = users.search([('login', '=', login)])
    for user in linked_any | by_login:
        _refuse_if_protected(user, protected)
    target = by_uid or by_login
    others = linked_any - target
    if others:
        raise EnsureError(f'oauth_uid (KC id) sudah tertaut ke res.users lain ({", ".join(map(str, others.ids))})',
                          EXIT_REFUSED)
    if by_uid and by_login and by_login != by_uid:
        raise EnsureError(f'login sudah dipakai res.users {by_login.id}, sedangkan KC id tertaut ke res.users '
                          f'{by_uid.id}', EXIT_REFUSED)
    if target and target.oauth_uid and target.oauth_uid != kc_id:
        raise EnsureError(f'res.users {target.id} sudah tertaut ke subject Keycloak lain', EXIT_REFUSED)
    if target and target.share:
        raise EnsureError(f'res.users {target.id} adalah user portal/public (share) — konversi ke user internal '
                          f'harus manual', EXIT_REFUSED)
    return target


def _group_commands(user, role):
    """Command group_ids + deskripsi; hanya grup eksplisit yang disentuh."""
    group_user = env.ref('base.group_user')
    group_system = env.ref('base.group_system')
    erp_manager = env.ref('base.group_erp_manager')
    current = user.group_ids if user else env['res.groups']
    wanted = group_user | (group_system if role == 'admin' else env['res.groups'])
    add = wanted - current
    remove = env['res.groups']
    if role == 'user':
        remove = current.filtered(lambda g: erp_manager in g.all_implied_ids)
    commands = [Command.link(g.id) for g in add] + [Command.unlink(g.id) for g in remove]
    labels = [f'+{g.get_external_id().get(g.id) or g.id}' for g in add]
    labels += [f'-{g.get_external_id().get(g.id) or g.id}' for g in remove]
    return commands, labels


def _check_postconditions(user, role):
    user.invalidate_recordset()
    groups = user.all_group_ids
    if env.ref('base.group_user') not in groups or user.share:
        raise EnsureError(f'pasca-kondisi gagal: res.users {user.id} bukan user internal', 1)
    is_admin = env.ref('base.group_system') in groups
    is_erp_manager = env.ref('base.group_erp_manager') in groups
    if role == 'admin' and not is_admin:
        raise EnsureError(f'pasca-kondisi gagal: res.users {user.id} tidak punya base.group_system', 1)
    if role == 'user' and (is_admin or is_erp_manager):
        raise EnsureError(f'pasca-kondisi gagal: res.users {user.id} masih punya hak administrasi', 1)


def ensure(params):
    prefix = 'PLAN' if params['dry_run'] else 'UBAH'
    provider = _provider(params['client_id'])
    protected = _protected_users()
    target = _find_target(params, provider, protected)
    changes = []

    if not target:
        if not params['active']:
            _out('INFO: res.users tidak ada dan active=false — tidak ada yang dibuat/dinonaktifkan')
            return None, 0, 0
        commands, labels = _group_commands(None, params['role'])
        vals = {
            'name': params['name'] or params['email'],
            'login': params['login'],
            'email': params['email'],
            'oauth_provider_id': provider.id,
            'oauth_uid': params['kc_id'],
            'active': True,
            'group_ids': commands,
        }
        _out(f'{prefix}: buat res.users internal (role={params["role"]}, grup {" ".join(labels)}, '
             f'provider={provider.id}, tanpa password lokal)')
        user = env['res.users'].with_context(no_reset_password=True).create(vals)
        env.flush_all()
        _check_postconditions(user, params['role'])
        return (None if params['dry_run'] else user), 1, 1

    vals = {}
    if target.login != params['login']:
        vals['login'] = params['login']
        changes.append('login')
    if (target.email or '') != params['email']:
        vals['email'] = params['email']
        changes.append('email')
    if params['name'] and target.name != params['name']:
        vals['name'] = params['name']
        changes.append('name')
    if target.oauth_provider_id != provider or target.oauth_uid != params['kc_id']:
        vals['oauth_provider_id'] = provider.id
        vals['oauth_uid'] = params['kc_id']
        changes.append(f'tautan provider={provider.id} oauth_uid')
    commands, labels = _group_commands(target, params['role'])
    if commands:
        vals['group_ids'] = commands
        changes.append(f'grup {" ".join(labels)} (role={params["role"]})')
    if target.active != params['active']:
        vals['active'] = params['active']
        changes.append(f'active={str(params["active"]).lower()}')
    for change in changes:
        _out(f'{prefix}: res.users {target.id}: {change}')
    if vals:
        target.write(vals)
        env.flush_all()
    _check_postconditions(target, params['role'])
    return target, 0, len(changes)


def main():
    if env is None:
        _out('ERROR: jalankan lewat `odoo shell -d <db>` (variabel env tidak ada)')
        sys.exit(EXIT_INVALID)
    dbname = env.cr.dbname
    try:
        params = _read_params()
        user, created, changed = ensure(params)
    except EnsureError as e:
        env.cr.rollback()
        env.registry.reset_changes()
        _out(f'ERROR: {e}')
        sys.exit(e.code)
    except Exception:
        env.cr.rollback()
        env.registry.reset_changes()
        _out('ERROR: kegagalan tak terduga (lihat traceback di stderr)')
        raise
    if params['dry_run']:
        env.cr.rollback()
        env.registry.reset_changes()
    else:
        env.cr.commit()
        # Beri tahu worker pool lain: ormcache grup/session token di proses ini sudah dibersihkan oleh write().
        env.registry.signal_changes()
    _out(f'RESULT db={dbname} odoo_user={user.id if user else "-"} kc_user={params["kc_id"]} '
         f'created={created} changed={changed}')


main()
