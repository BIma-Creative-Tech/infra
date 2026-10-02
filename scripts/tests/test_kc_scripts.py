#!/usr/bin/env python3
# Uji skrip job SaaS Fase 1 (kc-org.sh, kc-user.sh, kc-realm-sync.sh, tenant-state.sh, odoo-user.sh,
# odoo-tenant-config.sh, render-client-route.sh --suspended, lib/keycloak-admin.sh) TANPA Keycloak/Docker sungguhan:
#   - Admin REST → mock in-memory scripts/tests/kc_mock.py di 127.0.0.1:<port acak> (INFRA_TEST_MODE=1 +
#     KC_TEST_BASE_URL, lihat header lib/keycloak-admin.sh);
#   - `docker` / `dig` → shim di PATH (psql/odoo shell/HUP diemulasikan, argv dicatat).
# WAJIB dijalankan di container sekali pakai TANPA socket Docker dan tanpa jaringan (scripts/tests/test-kc-scripts.sh):
# setUpClass menolak berjalan bila /var/run/docker.sock ada (shim salah → perintah docker sungguhan ke prod).
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import kc_mock  # noqa: E402

T_ACME = '11111111-1111-4111-8111-111111111111'
T_BETA = '22222222-2222-4222-8222-222222222222'
T_PLATFORM = '33333333-3333-4333-8333-333333333333'

DOCKER_SHIM = r'''#!/usr/bin/env bash
# shim docker untuk uji (TIDAK PERNAH memanggil docker sungguhan)
set -u
printf '%s\n' "$*" >> "$MOCK_STATE/docker-argv.log"
case "$1" in
  inspect) echo true; exit 0 ;;
  logs) exit 0 ;;
  exec) shift ;;
  *) echo "shim docker: perintah tidak didukung: $1" >&2; exit 99 ;;
esac
while [[ "${1:-}" == -* ]]; do
  case "$1" in -e) shift 2 ;; *) shift ;; esac
done
target="$1"; shift
if [[ "$target" == traefik ]]; then echo HUP >> "$MOCK_STATE/hup.log"; exit 0; fi
if [[ "$target" == postgres ]]; then
  sql="${*: -1}"
  case "$sql" in
    *"SELECT 1 FROM pg_database"*) [[ -n "${MOCK_NO_DB:-}" ]] || echo 1 ;;
    *pg_get_userbyid*) if [[ "$sql" == *_staging\'* ]]; then echo odoo_staging; else echo odoo_pool_a; fi ;;
    *"name = 'base'"*) echo installed ;;
    *sh_auth_oidc*) echo "${MOCK_OIDC_VERSION:-19.0.1.3.0}" ;;
    *) echo "shim psql: SQL tidak dikenal" >&2; exit 98 ;;
  esac
  exit 0
fi
# odoo shell
script="$(cat)"
if [[ "$script" == *ODOO_USER_TEST_HELPER* ]]; then
  env | grep '^ODOO_USER_' | sort > "$MOCK_STATE/helper-env.txt"
  rc="${MOCK_HELPER_RC:-0}"
  if [[ "$rc" != 0 ]]; then echo "ERROR: ditolak (mock)"; exit "$rc"; fi
  echo "PLAN: res.users dibuat (mock)"
  echo "RESULT db=${MOCK_HELPER_DB:-acme_staging} odoo_user=7 kc_user=${ODOO_USER_KC_ID} created=1 changed=2"
  exit 0
fi
if [[ "$script" == *sh_auth_oidc.tenant_check* ]]; then
  printf '%s' "$script" | python3 "$MOCK_STATE/icp.py"
  exit $?
fi
echo "shim odoo: skrip tidak dikenal" >&2; exit 97
'''

ICP_SHIM = r'''import json, os, re, sys
src = sys.stdin.read()
want = dict(re.findall(r"'(sh_auth_oidc\.[a-z_]+)': '([^']*)'", src))
dry = re.search(r'dry = (\d) == 1', src).group(1) == '1'
path = os.path.join(os.environ['MOCK_STATE'], 'icp.json')
cur = json.load(open(path)) if os.path.exists(path) else {}
n = 0
for k, v in want.items():
    if cur.get(k, '') != v:
        n += 1
        print('CFG_CHANGE %s: %s -> %s' % (k, cur.get(k) or '-', v))
        if not dry:
            cur[k] = v
if not dry:
    json.dump(cur, open(path, 'w'))
print('CFG_RESULT changed=%d' % n)
'''

DIG_SHIM = '''#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == AAAA ]] && exit 0; done
echo 31.97.50.221
'''

HELPER_STUB = '# ODOO_USER_TEST_HELPER — stub uji; helper asli: branch feat/infra-saas-p1-odoo-user\n'


RESULT_KEYS = set('db realm client provider hosts changed kc_user odoo_user action invite mode blockers route host '
                  'created pool org roles enabled state tenant'.split())   # dispatcher + kontrak §1.2
RESULT_VAL_RE = re.compile(r'[A-Za-z0-9._,:@/=-]{0,512}', re.ASCII)       # = dispatcher


def result(out):
    lines = [ln for ln in out.splitlines() if ln.startswith('RESULT ')]
    if not lines:
        return None
    kv = dict(t.split('=', 1) for t in lines[-1].split()[1:])
    for k, v in kv.items():   # setiap kunci/nilai harus lolos allowlist dispatcher
        if k not in RESULT_KEYS or not RESULT_VAL_RE.fullmatch(v):
            raise AssertionError(f'RESULT tidak lolos allowlist dispatcher: {k}={v}')
    return kv


class Base(unittest.TestCase):
    SEED_CP_ADMIN = True   # T01RealmSync: False (sync membuat cp-admin)
    @classmethod
    def setUpClass(cls):
        if os.geteuid() != 0:
            raise unittest.SkipTest('butuh root (skrip memeriksa EUID)')
        if os.path.exists('/var/run/docker.sock') or os.path.exists('/run/docker.sock'):
            raise RuntimeError('socket Docker terlihat — jalankan lewat scripts/tests/test-kc-scripts.sh (container)')
        os.makedirs('/run/lock', exist_ok=True)
        cls.tmp = tempfile.mkdtemp(prefix='kc-test-')
        cls.secrets = os.path.join(cls.tmp, 'secrets')
        os.makedirs(cls.secrets, mode=0o700)
        for realm in ('platform', 'platform-staging'):
            for client in ('automation', 'cp-admin', 'kc-realm-sync'):
                with open(os.path.join(cls.secrets, f'{client}-{realm}.secret'), 'w') as f:
                    f.write(f'test-{client}-{realm}')
        # salinan scripts/ (+ stub helper Odoo) dan INFRA_DIR sementara
        cls.scripts = os.path.join(cls.tmp, 'scripts')
        shutil.copytree(os.path.join(REPO, 'scripts'), cls.scripts,
                        ignore=shutil.ignore_patterns('tests', 'infra-job', '__pycache__'))
        helper = os.path.join(cls.scripts, 'lib', 'odoo_user_ensure.py')
        with open(helper, 'w') as f:
            f.write(HELPER_STUB)
        cls.infra = os.path.join(cls.tmp, 'infra')
        shutil.copytree(os.path.join(REPO, 'identity', 'keycloak', 'realm'),
                        os.path.join(cls.infra, 'identity', 'keycloak', 'realm'))
        if cls.SEED_CP_ADMIN:
            # kelas uji user/org = kondisi setelah W2: Organizations aktif lewat override staging (bukan console)
            ov = os.path.join(cls.infra, 'identity', 'keycloak', 'realm', 'platform-staging.overrides.json')
            with open(ov) as f:
                data = json.load(f)
            data['realm'] = {'organizationsEnabled': True}
            with open(ov, 'w') as f:
                json.dump(data, f)
        shutil.copytree(os.path.join(REPO, 'templates'), os.path.join(cls.infra, 'templates'))
        os.makedirs(os.path.join(cls.infra, 'traefik', 'dynamic', 'clients'))
        cls.state = os.path.join(cls.tmp, 'state')
        cls.shims = os.path.join(cls.tmp, 'shims')
        os.makedirs(cls.state)
        os.makedirs(cls.shims)
        for name, body in (('docker', DOCKER_SHIM), ('dig', DIG_SHIM)):
            p = os.path.join(cls.shims, name)
            with open(p, 'w') as f:
                f.write(body)
            os.chmod(p, 0o755)  # noqa: S103 — shim harus bisa dieksekusi
        with open(os.path.join(cls.state, 'icp.py'), 'w') as f:
            f.write(ICP_SHIM)
        cls.srv, cls.store = kc_mock.start(cls.secrets, seed_cp_admin=cls.SEED_CP_ADMIN)
        cls.port = cls.srv.server_address[1]
        cls.outputs = []

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        joined = '\n'.join(cls.outputs)
        shutil.rmtree(cls.tmp, ignore_errors=True)
        if kc_mock.MOCK_SECRET_MARKER in joined or 'mocktoken-' in joined:
            raise AssertionError('secret/token mock muncul di output skrip')

    def run_script(self, *argv, extra_env=None):
        env = {
            'PATH': self.shims + ':' + os.environ.get('PATH', '/usr/bin:/bin'),
            'INFRA_TEST_MODE': '1', 'KC_TEST_BASE_URL': f'http://127.0.0.1:{self.port}',
            'KC_SECRETS_DIR': self.secrets, 'INFRA_DIR': self.infra, 'MOCK_STATE': self.state, 'LANG': 'C.UTF-8',
        }
        env.update(extra_env or {})
        p = subprocess.run([os.path.join(self.scripts, argv[0]), *argv[1:]], capture_output=True, text=True,  # noqa: S603
                           env=env, timeout=120, check=False)
        out = p.stdout + p.stderr
        type(self).outputs.append(out)
        return p.returncode, out, result(p.stdout)

    def ok(self, *argv, **kw):
        rc, out, res = self.run_script(*argv, **kw)
        self.assertEqual(rc, 0, out)
        self.assertIsNotNone(res, out)
        return res, out

    def realm(self, name='platform-staging'):
        return self.store.realms[name]

    def writes(self, name='platform-staging'):
        return list(self.realm(name)['events'])

    def client(self, cid, name='platform-staging'):
        return next(c for c in self.realm(name)['clients'].values() if c['rep']['clientId'] == cid)

    def user_by_email(self, email, name='platform-staging'):
        return next((u for u in self.realm(name)['users'].values() if u.get('email') == email), None)

    def user_roles(self, uid, cid, name='platform-staging'):
        c = self.client(cid, name)
        return sorted(c['roles'][r]['name'] for r in self.realm(name)['role_maps'].get((uid, c['rep']['id']), ()))


class T01RealmSync(Base):
    SEED_CP_ADMIN = False

    def test_1_plan_apply_idempotent(self):
        before = len(self.writes())
        res, out = self.ok('kc-realm-sync.sh', 'platform', 'staging', '--dry-run')
        self.assertEqual(res['mode'], 'plan')
        self.assertEqual(res['blockers'], '0', out)
        planned = int(res['changed'])
        self.assertGreater(planned, 5, out)
        self.assertEqual(len(self.writes()), before, 'plan tidak boleh menulis')
        self.assertIn('tertunda', out)  # role SA cp-admin bergantung pada client baru

        res, out = self.ok('kc-realm-sync.sh', 'platform', 'staging')
        self.assertEqual(res['mode'], 'apply')
        self.assertGreaterEqual(int(res['changed']), planned - 1, out)
        R = self.realm()
        self.assertIs(R['rep']['organizationsEnabled'], False)
        self.assertTrue(any(a['name'] == 'tenant_id' and a['permissions'] == {'view': ['admin'], 'edit': ['admin']}
                            for a in R['profile']['attributes']))
        self.assertNotIn('${', json.dumps(R['profile']), 'label placeholder diganti literal (WAF CRS 932130)')
        self.assertEqual(R['profile']['attributes'][0]['displayName'], 'Username')
        scope = next(s for s in R['scopes'].values() if s['name'] == 'tenant')
        self.assertEqual(scope['protocolMappers'][0]['config']['claim.name'], 'tenant_id')
        org_scope = next(sid for sid, s in R['scopes'].items() if s['name'] == 'organization')
        for cid in ('control-plane', 'odoo-demo-staging', 'odoo-acme-staging'):
            c = self.client(cid)
            self.assertIn(scope['id'], c['default'], cid)
            self.assertNotIn(org_scope, c['default'], f'{cid}: organization TIDAK boleh default (keputusan Lead S1)')
            self.assertNotIn(scope['id'], self.client('automation')['default'])
        self.assertIn(org_scope, self.client('control-plane')['optional'], 'organization tetap optional')
        for cid in ('odoo-demo-staging', 'odoo-acme-staging'):
            self.assertIn('odoo_admin', {r['name'] for r in self.client(cid)['roles'].values()})
        cp = self.client('cp-admin')
        self.assertTrue(cp['rep']['serviceAccountsEnabled'])
        self.assertEqual(self.user_roles(cp['sa_user'], 'realm-management'),
                         sorted(['manage-organizations', 'manage-users', 'query-users', 'view-users', 'query-groups',
                                 'view-clients']))
        org_exec = next(e for e in R['flows']['browser'] if e['displayName'] == 'Organization')
        self.assertEqual(org_exec['requirement'], 'DISABLED')
        # tidak pernah menulis user biasa / kc-realm-sync / automation
        for who, _method, path in self.writes():
            self.assertEqual(who, 'kc-realm-sync')
            m = re.match(r'/users/([0-9a-f-]{36})', path)
            if m:
                self.assertTrue(R['users'][m.group(1)].get('serviceAccountClientId'), path)
            for other in ('kc-realm-sync', 'automation'):
                self.assertNotIn(self.client(other)['rep']['id'], path)

        res, out = self.ok('kc-realm-sync.sh', 'platform', 'staging')
        self.assertEqual(res['changed'], '0', out)
        res, out = self.ok('kc-realm-sync.sh', 'platform', 'staging', '--dry-run')
        self.assertEqual((res['changed'], res['blockers']), ('0', '0'), out)

    def test_2_drift_sa_roles_exact(self):
        self.ok('kc-realm-sync.sh', 'platform', 'staging')
        R = self.realm()
        cp = self.client('cp-admin')
        rm = self.client('realm-management')
        bad = next(r for r in rm['roles'].values() if r['name'] == 'manage-realm')
        R['role_maps'][(cp['sa_user'], rm['rep']['id'])].add(bad['id'])
        R['flows']['browser'][2]['requirement'] = 'ALTERNATIVE'
        res, out = self.ok('kc-realm-sync.sh', 'platform', 'staging')
        self.assertEqual(res['changed'], '2', out)
        self.assertNotIn('manage-realm', self.user_roles(cp['sa_user'], 'realm-management'))

    def test_4_unknown_placeholder_blocks(self):
        R = self.realm('platform')
        R['profile']['attributes'][0]['displayName'] = '$' + '{customLabel}'
        res, out = self.ok('kc-realm-sync.sh', 'platform', 'prod', '--dry-run')
        self.assertEqual(res['blockers'], '1', out)
        rc, out, _ = self.run_script('kc-realm-sync.sh', 'platform', 'prod', '--approve')
        self.assertEqual(rc, 1, out)
        R['profile']['attributes'][0]['displayName'] = '$' + '{username}'

    def test_3_prod_needs_approve_and_platform_slug(self):
        rc, out, _ = self.run_script('kc-realm-sync.sh', 'platform', 'prod')
        self.assertEqual(rc, 3, out)
        res, out = self.ok('kc-realm-sync.sh', 'platform', 'prod', '--dry-run')
        self.assertEqual(res['realm'], 'platform')
        res, out = self.ok('kc-realm-sync.sh', 'platform', 'demo', '--approve')
        self.assertEqual(res['realm'], 'platform')
        rc, out, _ = self.run_script('kc-realm-sync.sh', 'acme', 'staging', '--dry-run')
        self.assertEqual(rc, 3, out)


class T02Org(Base):
    def test_0_org_feature_disabled(self):
        R = self.realm('platform')
        R['rep']['organizationsEnabled'] = False
        rc, out, _ = self.run_script('kc-org.sh', 'acme', 'prod', '--tenant-id', T_ACME, '--dry-run')
        self.assertEqual(rc, 1, out)
        self.assertIn('Organizations belum aktif', out)
        R['rep']['organizationsEnabled'] = True

    def test_org_create_idempotent_and_conflicts(self):
        before = len(self.writes())
        res, out = self.ok('kc-org.sh', 'acme', 'staging', '--tenant-id', T_ACME, '--dry-run')
        self.assertEqual((res['changed'], res['created'], res['blockers']), ('1', '0', '0'), out)
        self.assertEqual(len(self.writes()), before)
        res, out = self.ok('kc-org.sh', 'acme', 'staging', '--tenant-id', T_ACME)
        self.assertEqual((res['changed'], res['created']), ('1', '1'), out)
        org = next(o for o in self.realm()['orgs'].values() if o['name'] == 'acme')
        self.assertEqual((org['alias'], org['attributes']), (T_ACME, {'slug': ['acme']}))
        res, out = self.ok('kc-org.sh', 'acme', 'staging', '--tenant-id', T_ACME)
        self.assertEqual((res['changed'], res['created']), ('0', '0'), out)
        # alias beda → exit 3
        rc, out, _ = self.run_script('kc-org.sh', 'acme', 'staging', '--tenant-id', T_BETA)
        self.assertEqual(rc, 3, out)
        self.assertIn('terikat tenant lain', out)
        # tenant_id sudah alias org lain → exit 3
        rc, out, _ = self.run_script('kc-org.sh', 'beta', 'staging', '--tenant-id', T_ACME, '--dry-run')
        self.assertEqual(rc, 3, out)
        # atribut di-drift → diselaraskan
        org['attributes'] = {}
        res, out = self.ok('kc-org.sh', 'acme', 'staging', '--tenant-id', T_ACME)
        self.assertEqual(res['changed'], '1', out)


class T03User(Base):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()

    def setUp(self):
        if not any(o['name'] == 'acme' for o in self.realm()['orgs'].values()):
            self.ok('kc-org.sh', 'acme', 'staging', '--tenant-id', T_ACME)
            self.ok('kc-org.sh', 'beta', 'staging', '--tenant-id', T_BETA)
            self.ok('kc-org.sh', 'platform', 'staging', '--tenant-id', T_PLATFORM)

    def test_1_ensure_needs_profile_then_creates(self):
        # tanpa sync: user profile belum memuat tenant_id → dry-run BLOKIR, apply gagal sebelum menulis
        res, out = self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'a@acme.test', '--tenant-id', T_ACME,
                           '--dry-run')
        self.assertEqual(res['blockers'], '1', out)
        rc, out, _ = self.run_script('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'a@acme.test',
                                     '--tenant-id', T_ACME)
        self.assertEqual(rc, 1, out)
        self.assertIsNone(self.user_by_email('a@acme.test'))
        self.ok('kc-realm-sync.sh', 'platform', 'staging')
        res, out = self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'A@Acme.test', '--tenant-id', T_ACME,
                           '--name', "Ann O'Neil")
        self.assertEqual((res['created'], res['invite'], res['tenant']), ('1', '1', T_ACME), out)
        self.assertEqual(res['changed'], '3', out)   # buat + anggota org + undangan
        self.assertNotIn('acme.test', out.split('RESULT', 1)[1])  # RESULT tanpa PII
        u = self.user_by_email('a@acme.test')
        self.assertEqual((u['username'], u['attributes'], u['requiredActions'], u['emailVerified']),
                         ('a@acme.test', {'tenant_id': [T_ACME]}, ['UPDATE_PASSWORD'], False))
        self.assertEqual((u['firstName'], u['lastName']), ('Ann', "O'Neil"))
        org = next(o for o in self.realm()['orgs'].values() if o['name'] == 'acme')
        self.assertIn(u['id'], self.realm()['members'][org['id']])
        self.assertIn(('cp-admin', 'PUT', f'/users/{u["id"]}/execute-actions-email'), self.writes())
        res, out = self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'a@acme.test', '--tenant-id', T_ACME)
        self.assertEqual((res['changed'], res['created'], res['invite']), ('0', '0', '0'), out)

    def test_2_cross_tenant_and_alias(self):
        self.ok('kc-realm-sync.sh', 'platform', 'staging')
        self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'x@acme.test', '--tenant-id', T_ACME,
                '--no-invite')
        before = len(self.writes())
        rc, out, _ = self.run_script('kc-user.sh', 'ensure', 'beta', 'staging', '--email', 'x@acme.test',
                                     '--tenant-id', T_BETA)
        self.assertEqual(rc, 3, out)
        self.assertIn('lintas tenant', out)
        rc, out, _ = self.run_script('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'x@acme.test',
                                     '--tenant-id', T_BETA, '--dry-run')
        self.assertEqual(rc, 3, out)   # alias org acme ≠ tenant-id
        for args in (('roles', 'beta', 'staging', '--email', 'x@acme.test', '--cp-role', 'client_user'),
                     ('enabled', 'beta', 'staging', '--email', 'x@acme.test', '--enabled', 'false'),
                     ('email', 'beta', 'staging', '--email', 'x@acme.test', '--action', 'UPDATE_PASSWORD')):
            rc, out, _ = self.run_script('kc-user.sh', *args)
            self.assertEqual(rc, 3, f'{args}: {out}')
        self.assertEqual(len(self.writes()), before, 'penolakan tidak boleh menulis')

    def test_3_fill_empty_tenant_id(self):
        self.ok('kc-realm-sync.sh', 'platform', 'staging')
        R = self.realm()
        uid = 'aaaaaaaa-0000-4000-8000-000000000001'
        R['users'][uid] = {'id': uid, 'username': 'legacy@acme.test', 'email': 'legacy@acme.test', 'enabled': True,
                           'attributes': {}, 'requiredActions': []}
        rc, out, _ = self.run_script('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'legacy@acme.test',
                                     '--cp-role', 'client_user')
        self.assertEqual(rc, 3, out)   # belum terikat tenant
        res, out = self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'legacy@acme.test',
                           '--tenant-id', T_ACME)
        self.assertEqual((res['created'], res['changed'], res['invite']), ('0', '2', '0'), out)
        self.assertEqual(R['users'][uid]['attributes'], {'tenant_id': [T_ACME]})

    def test_4_roles_exact_and_policy(self):
        self.ok('kc-realm-sync.sh', 'platform', 'staging')
        self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'r@acme.test', '--tenant-id', T_ACME)
        uid = self.user_by_email('r@acme.test')['id']
        res, out = self.ok('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'r@acme.test', '--cp-role',
                           'client_admin', '--odoo', 'admin')
        self.assertEqual((res['roles'], res['changed'], res['kc_user']),
                         ('client_admin,odoo_access,odoo_admin', '2', uid), out)
        self.assertEqual(self.user_roles(uid, 'control-plane'), ['client_admin'])
        self.assertEqual(self.user_roles(uid, 'odoo-acme-staging'), ['odoo_access', 'odoo_admin'])
        res, out = self.ok('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'r@acme.test', '--cp-role',
                           'client_admin', '--odoo', 'admin')
        self.assertEqual(res['changed'], '0', out)
        # role tambahan manual di control-plane → dibuang (persis)
        cp = self.client('control-plane')
        ops = next(r for r in cp['roles'].values() if r['name'] == 'ops')
        self.realm()['role_maps'][(uid, cp['rep']['id'])].add(ops['id'])
        res, out = self.ok('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'r@acme.test', '--cp-role',
                           'client_user', '--odoo', 'user')
        self.assertEqual(self.user_roles(uid, 'control-plane'), ['client_user'])
        self.assertEqual(self.user_roles(uid, 'odoo-acme-staging'), ['odoo_access'])
        res, out = self.ok('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'r@acme.test', '--cp-role', 'none',
                           '--odoo', 'none')
        self.assertEqual(res['roles'], '', out)
        self.assertEqual((self.user_roles(uid, 'control-plane'), self.user_roles(uid, 'odoo-acme-staging')), ([], []))
        # §0.3
        for args, why in (((('acme', 'superadmin'),), 'superadmin non-platform'), ((('acme', 'ops'),), 'ops'),
                          ((('platform', 'client_admin'),), 'client_admin platform')):
            slug, role = args[0]
            rc, out, _ = self.run_script('kc-user.sh', 'roles', slug, 'staging', '--email', 'r@acme.test',
                                         '--cp-role', role, '--dry-run')
            self.assertEqual(rc, 3, f'{why}: {out}')
        rc, out, _ = self.run_script('kc-user.sh', 'roles', 'platform', 'staging', '--email', 'r@acme.test',
                                     '--cp-role', 'ops', '--odoo', 'user', '--dry-run')
        self.assertEqual(rc, 3, out)

    def test_5_odoo_admin_role_created_only_with_rights(self):
        self.ok('kc-realm-sync.sh', 'platform', 'staging')
        self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'o@acme.test', '--tenant-id', T_ACME)
        c = self.client('odoo-acme-staging')
        c['roles'] = {k: v for k, v in c['roles'].items() if v['name'] != 'odoo_admin'}
        _res, out = self.ok('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'o@acme.test', '--cp-role',
                            'client_user', '--odoo', 'admin', '--dry-run')
        self.assertIn('odoo_admin dibuat', out)
        rc, out, _ = self.run_script('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'o@acme.test', '--cp-role',
                                     'client_user', '--odoo', 'admin')
        self.assertEqual(rc, 1, out)
        self.assertIn('manage-clients', out)
        self.ok('kc-realm-sync.sh', 'platform', 'staging')   # sync membuat ulang odoo_admin

    def test_6_disable_logout_and_superadmin(self):
        self.ok('kc-realm-sync.sh', 'platform', 'staging')
        self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'd@acme.test', '--tenant-id', T_ACME)
        uid = self.user_by_email('d@acme.test')['id']
        res, out = self.ok('kc-user.sh', 'enabled', 'acme', 'staging', '--email', 'd@acme.test', '--enabled', 'false')
        self.assertEqual((res['enabled'], res['changed']), ('0', '1'), out)
        self.assertFalse(self.realm()['users'][uid]['enabled'])
        self.assertEqual(self.realm()['users'][uid]['attributes'], {'tenant_id': [T_ACME]}, 'PUT penuh: atribut utuh')
        self.assertIn(('cp-admin', 'POST', f'/users/{uid}/logout'), self.writes())
        res, out = self.ok('kc-user.sh', 'enabled', 'acme', 'staging', '--email', 'd@acme.test', '--enabled', 'false')
        self.assertEqual(res['changed'], '0', out)
        # user nonaktif → email aksi BLOKIR
        res, out = self.ok('kc-user.sh', 'email', 'acme', 'staging', '--email', 'd@acme.test', '--action',
                           'UPDATE_PASSWORD', '--dry-run')
        self.assertEqual(res['blockers'], '1', out)
        res, out = self.ok('kc-user.sh', 'enabled', 'acme', 'staging', '--email', 'd@acme.test', '--enabled', 'true')
        self.assertEqual(res['changed'], '1', out)
        res, out = self.ok('kc-user.sh', 'email', 'acme', 'staging', '--email', 'd@acme.test', '--action',
                           'VERIFY_EMAIL')
        self.assertEqual((res['action'], res['invite']), ('VERIFY_EMAIL', '1'), out)
        # superadmin (platform): yang terakhir tidak bisa dinonaktifkan / dilepas
        self.ok('kc-user.sh', 'ensure', 'platform', 'staging', '--email', 's1@plat.test', '--tenant-id', T_PLATFORM)
        self.ok('kc-user.sh', 'roles', 'platform', 'staging', '--email', 's1@plat.test', '--cp-role', 'superadmin')
        rc, out, _ = self.run_script('kc-user.sh', 'enabled', 'platform', 'staging', '--email', 's1@plat.test',
                                     '--enabled', 'false')
        self.assertEqual(rc, 3, out)
        rc, out, _ = self.run_script('kc-user.sh', 'roles', 'platform', 'staging', '--email', 's1@plat.test',
                                     '--cp-role', 'ops')
        self.assertEqual(rc, 3, out)
        self.ok('kc-user.sh', 'ensure', 'platform', 'staging', '--email', 's2@plat.test', '--tenant-id', T_PLATFORM)
        self.ok('kc-user.sh', 'roles', 'platform', 'staging', '--email', 's2@plat.test', '--cp-role', 'superadmin')
        res, out = self.ok('kc-user.sh', 'enabled', 'platform', 'staging', '--email', 's1@plat.test',
                           '--enabled', 'false')
        self.assertEqual(res['changed'], '1', out)
        # superadmin lewat slug tenant → ditolak (lintas tenant lebih dulu)
        rc, out, _ = self.run_script('kc-user.sh', 'enabled', 'acme', 'staging', '--email', 's2@plat.test',
                                     '--enabled', 'false')
        self.assertEqual(rc, 3, out)

    def test_7_usage_and_options(self):
        rc, out, _ = self.run_script('kc-user.sh', 'roles', 'acme', 'staging', '--email', 'a@acme.test',
                                     '--tenant-id', T_ACME)
        self.assertEqual(rc, 2, out)
        rc, out, _ = self.run_script('kc-user.sh', 'email', 'acme', 'staging', '--email', 'a@acme.test',
                                     '--action', 'EXECUTE_ANYTHING')
        self.assertEqual(rc, 1, out)
        rc, out, _ = self.run_script('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'a@acme.test',
                                     '--tenant-id', T_ACME, '--name', '-x')
        self.assertEqual(rc, 1, out)


class T04Odoo(Base):
    def setUp(self):
        if not any(o['name'] == 'acme' for o in self.realm()['orgs'].values()):
            self.ok('kc-realm-sync.sh', 'platform', 'staging')
            self.ok('kc-org.sh', 'acme', 'staging', '--tenant-id', T_ACME)
            self.ok('kc-org.sh', 'beta', 'staging', '--tenant-id', T_BETA)
            self.ok('kc-user.sh', 'ensure', 'acme', 'staging', '--email', 'u@acme.test', '--tenant-id', T_ACME,
                    '--name', 'Udin Acme')

    def test_1_odoo_user_wrapper(self):
        uid = self.user_by_email('u@acme.test')['id']
        log = os.path.join(self.state, 'docker-argv.log')
        if os.path.exists(log):
            os.remove(log)
        res, out = self.ok('odoo-user.sh', 'acme', 'staging', '--email', 'u@acme.test', '--role', 'admin',
                           '--active', 'true', '--dry-run')
        self.assertEqual((res['db'], res['odoo_user'], res['kc_user'], res['created'], res['blockers']),
                         ('acme_staging', '7', uid, '1', '0'), out)
        with open(os.path.join(self.state, 'helper-env.txt')) as f:
            env = dict(ln.strip().split('=', 1) for ln in f)
        self.assertEqual(env, {'ODOO_USER_EMAIL': 'u@acme.test', 'ODOO_USER_LOGIN': 'u@acme.test',
                               'ODOO_USER_NAME': 'Udin Acme', 'ODOO_USER_ROLE': 'admin', 'ODOO_USER_ACTIVE': 'true',
                               'ODOO_USER_KC_ID': uid, 'ODOO_USER_DRY_RUN': 'true',
                               'ODOO_USER_OIDC_CLIENT_ID': 'odoo-acme-staging'})
        with open(log) as f:
            argv = f.read()
        self.assertNotIn('u@acme.test', argv, 'email tidak boleh di argv docker')
        self.assertIn('-e ODOO_USER_EMAIL -e ODOO_USER_LOGIN', argv)
        res, out = self.ok('odoo-user.sh', 'acme', 'staging', '--email', 'u@acme.test', '--role', 'user',
                           '--active', 'false')
        self.assertNotIn('blockers', res)
        rc, out, _ = self.run_script('odoo-user.sh', 'acme', 'staging', '--email', 'u@acme.test', '--role', 'user',
                                     '--active', 'true', extra_env={'MOCK_HELPER_RC': '3'})
        self.assertEqual(rc, 3, out)
        rc, out, _ = self.run_script('odoo-user.sh', 'acme', 'staging', '--email', 'u@acme.test', '--role', 'user',
                                     '--active', 'true', extra_env={'MOCK_HELPER_DB': 'other_staging'})
        self.assertEqual(rc, 1, out)   # RESULT helper untuk DB lain ditolak
        rc, out, _ = self.run_script('odoo-user.sh', 'beta', 'staging', '--email', 'u@acme.test', '--role', 'user',
                                     '--active', 'true', '--dry-run')
        self.assertEqual(rc, 3, out)   # user tenant acme ke DB beta
        rc, out, _ = self.run_script('odoo-user.sh', 'platform', 'staging', '--email', 'u@acme.test', '--role',
                                     'user', '--active', 'true', '--dry-run')
        self.assertEqual(rc, 3, out)
        res, out = self.ok('odoo-user.sh', 'acme', 'staging', '--email', 'nobody@acme.test', '--role', 'user',
                           '--active', 'true', '--dry-run')
        self.assertEqual(res['blockers'], '1', out)
        res, out = self.ok('odoo-user.sh', 'acme', 'staging', '--email', 'u@acme.test', '--role', 'user',
                           '--active', 'true', '--dry-run', extra_env={'MOCK_NO_DB': '1'})
        self.assertEqual(res['blockers'], '1', out)

    def test_2_tenant_config(self):
        res, out = self.ok('odoo-tenant-config.sh', 'acme', 'staging', '--tenant-check', 'strict', '--dry-run')
        self.assertEqual((res['mode'], res['tenant'], res['changed'], res['blockers']),
                         ('strict', T_ACME, '2', '0'), out)
        res, out = self.ok('odoo-tenant-config.sh', 'acme', 'staging', '--tenant-check', 'strict')
        self.assertEqual(res['changed'], '2', out)
        res, out = self.ok('odoo-tenant-config.sh', 'acme', 'staging', '--tenant-check', 'strict')
        self.assertEqual(res['changed'], '0', out)
        res, out = self.ok('odoo-tenant-config.sh', 'acme', 'staging', '--tenant-check', 'compat')
        self.assertEqual(res['changed'], '1', out)
        res, out = self.ok('odoo-tenant-config.sh', 'acme', 'staging', '--tenant-check', 'strict', '--dry-run',
                           extra_env={'MOCK_OIDC_VERSION': '19.0.1.2.0'})
        self.assertEqual(res['blockers'], '1', out)
        rc, out, _ = self.run_script('odoo-tenant-config.sh', 'platform', 'staging', '--tenant-check', 'off')
        self.assertEqual(rc, 3, out)


class T05TenantState(Base):
    def setUp(self):
        self.route = os.path.join(self.infra, 'traefik', 'dynamic', 'clients', 'expomedia-staging.yml')
        shutil.copy(os.path.join(REPO, 'traefik', 'dynamic', 'clients', 'expomedia-staging.yml'), self.route)
        with open(self.route, 'rb') as f:
            self.original = f.read()
        self.host = re.search(r'Host\(`([a-z0-9.-]+)`\)', self.original.decode()).group(1)

    def test_1_render_unchanged_without_flag(self):
        res, out = self.ok('render-client-route.sh', 'expomedia', 'staging', '--host', self.host)
        self.assertEqual(res['changed'], 'no', 'template baru harus identik byte-per-byte untuk tenant aktif\n' + out)

    def test_2_suspend_resume(self):
        res, out = self.ok('tenant-state.sh', 'expomedia', 'staging', '--suspend', '--dry-run')
        self.assertEqual((res['state'], res['changed'], res['blockers'], res['route']),
                         ('suspended', '1', '0', 'expomedia-staging.yml'), out)
        self.assertNotIn('mode', res)
        with open(self.route, 'rb') as f:
            self.assertEqual(f.read(), self.original)
        res, out = self.ok('tenant-state.sh', 'expomedia', 'staging', '--suspend')
        self.assertEqual((res['state'], res['changed'], res['host']), ('suspended', '1', self.host), out)
        with open(self.route) as f:
            text = f.read()
        self.assertEqual(text.count('[crowdsec, tenant-suspended@file, odoo-security-headers'), 4)
        self.assertNotIn('ipallowlist-admin, tenant-suspended', text)   # dbmanager :8443 tidak berubah
        res, out = self.ok('tenant-state.sh', 'expomedia', 'staging', '--suspend')
        self.assertEqual(res['changed'], '0', out)
        res, out = self.ok('tenant-state.sh', 'expomedia', 'staging', '--resume')
        self.assertEqual((res['state'], res['changed']), ('active', '1'), out)
        with open(self.route, 'rb') as f:
            self.assertEqual(f.read(), self.original)
        rc, out, _ = self.run_script('tenant-state.sh', 'platform', 'staging', '--suspend')
        self.assertEqual(rc, 3, out)
        rc, out, _ = self.run_script('render-client-route.sh', 'expomedia', 'staging', '--remove', '--suspended')
        self.assertEqual(rc, 1, out)


class T06Lib(Base):
    def _source(self, env):
        cmd = (f'source {self.scripts}/lib/odoo-pools.sh; source {self.scripts}/lib/keycloak-admin.sh; '
               'echo "BASE=$KC_BASE CLIENT=$KC_ADMIN_CLIENT"')
        full = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'INFRA_DIR': self.infra, **env}
        return subprocess.run(['/bin/bash', '-c', cmd], capture_output=True, text=True, env=full,  # noqa: S603
                              check=False)

    def test_test_mode_guard(self):
        p = self._source({'KC_TEST_BASE_URL': 'http://127.0.0.1:1'})
        self.assertIn('BASE=https://auth.bimacreative.tech:8443 CLIENT=automation', p.stdout)
        self.assertIn('diabaikan', p.stderr)
        p = self._source({'INFRA_TEST_MODE': '1', 'KC_TEST_BASE_URL': 'http://10.0.0.5:8080'})
        self.assertNotEqual(p.returncode, 0)
        p = self._source({'INFRA_TEST_MODE': '1', 'KC_TEST_BASE_URL': 'http://127.0.0.1:8080@evil.example'})
        self.assertNotEqual(p.returncode, 0)
        p = self._source({'KC_ADMIN_CLIENT': 'admin-cli'})
        self.assertNotEqual(p.returncode, 0)
        p = self._source({'KC_ADMIN_CLIENT': 'cp-admin'})
        self.assertIn('CLIENT=cp-admin', p.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
