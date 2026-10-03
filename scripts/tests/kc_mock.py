#!/usr/bin/env python3
# Mock Keycloak 26 Admin REST + token endpoint (in-memory) untuk uji scripts/kc-*.sh, odoo-user.sh,
# odoo-tenant-config.sh
# TANPA Keycloak sungguhan (change freeze; kontrak saas-phase-1-contract.md §3 "mode --dry-run terhadap mock").
# Hanya endpoint yang dipakai skrip. Bentuk respons mengikuti Admin REST KC 26 sebatas yang dibaca skrip;
# perilaku yang diemulasikan secara sengaja:
#   - user profile: atribut user yang TIDAK dideklarasikan di /users/profile dibuang diam-diam
#     (unmanaged attribute policy default);
#   - GET /clients mengembalikan field `secret` (seperti KC) → uji bahwa skrip tidak pernah mencetaknya;
#   - izin kasar per client service account (cp-admin tanpa manage-clients/manage-realm, kc-realm-sync tanpa akses
#     user biasa/organization) → 403;
#   - execute-actions-email ke user nonaktif → 400;
#   - role EFEKTIF (/role-mappings/clients/{c}/composite): mapping client langsung + realm role (`realm_role_maps`)
#     diekspansi transitif lewat `composites` (set id role) — model "role komposit/grup" untuk uji adopsi (QA F1);
#   - GET /clients?clientId=..&search=true = pencarian infix (case-insensitive) seperti KC;
#   - GET /organizations/members/{user}/organizations (KC 26.7.4 OrganizationsResource).
# Jalankan: python3 kc_mock.py --port 0 --secrets DIR  (mencetak "PORT <n>"); atau impor `start(secrets_dir)`.
import argparse
import copy
import json
import os
import re
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MOCK_SECRET_MARKER = 'MOCK-CLIENT-SECRET-must-never-be-printed'  # noqa: S105 — penanda uji, bukan secret
UUID = r'[0-9a-f-]{36}'


def _id():
    return str(uuid.uuid4())


def default_realm(name, seed_cp_admin=False):
    rm_roles = ['manage-users', 'view-users', 'query-users', 'query-groups', 'manage-organizations',
                'view-organizations', 'query-organizations', 'manage-realm', 'view-realm', 'manage-clients',
                'view-clients', 'query-clients', 'realm-admin', 'impersonation']
    r = {
        'rep': {
            'realm': name, 'enabled': True, 'organizationsEnabled': False, 'resetPasswordAllowed': False,
            'bruteForceProtected': True, 'permanentLockout': False, 'failureFactor': 5, 'waitIncrementSeconds': 60,
            'maxFailureWaitSeconds': 900, 'maxDeltaTimeSeconds': 43200,
            'passwordPolicy': 'length(12) and maxLength(128) and upperCase(1) and lowerCase(1) and digits(1) and '
                              'specialChars(1) and notUsername and notEmail and passwordHistory(5)',
            'registrationAllowed': False, 'registrationEmailAsUsername': False, 'verifyEmail': False,
            'loginWithEmailAllowed': True, 'duplicateEmailsAllowed': False, 'editUsernameAllowed': False,
            'rememberMe': False, 'sslRequired': 'external', 'browserFlow': 'browser',
            'smtpServer': {'host': 'mail.example', 'password': MOCK_SECRET_MARKER},
        },
        'profile': {'attributes': [
            # label placeholder pesan seperti konfigurasi default KC 26.7.4 (diverifikasi container sekali pakai)
            {'name': n, 'displayName': '$' + '{' + n + '}',
             'permissions': {'view': ['admin', 'user'], 'edit': ['admin', 'user']}}
            for n in ('username', 'email', 'firstName', 'lastName')
        ], 'groups': [{'name': 'user-metadata', 'displayHeader': 'User metadata'}]},
        'flows': {'browser': [
            {'id': _id(), 'displayName': 'Cookie', 'requirement': 'ALTERNATIVE', 'level': 0, 'index': 0,
             'authenticationFlow': False, 'requirementChoices': ['REQUIRED', 'ALTERNATIVE', 'DISABLED']},
            {'id': _id(), 'displayName': 'Identity Provider Redirector', 'requirement': 'ALTERNATIVE', 'level': 0,
             'index': 1, 'authenticationFlow': False, 'requirementChoices': ['REQUIRED', 'ALTERNATIVE', 'DISABLED']},
            {'id': _id(), 'displayName': 'Organization', 'requirement': 'ALTERNATIVE', 'level': 0, 'index': 2,
             'authenticationFlow': True, 'flowId': _id(),
             'requirementChoices': ['REQUIRED', 'ALTERNATIVE', 'DISABLED', 'CONDITIONAL']},
            {'id': _id(), 'displayName': 'Browser - Conditional Organization', 'requirement': 'CONDITIONAL', 'level': 1,
             'index': 0, 'authenticationFlow': True},
            {'id': _id(), 'displayName': 'forms', 'requirement': 'ALTERNATIVE', 'level': 0, 'index': 3,
             'authenticationFlow': True},
        ]},
        'scopes': {}, 'clients': {}, 'users': {}, 'orgs': {}, 'members': {},
        'role_maps': {},          # (uid, client_uuid) -> set(role_id)
        'realm_roles': {},        # role_id -> {'id', 'name', 'composites': set(role_id klien/realm)}
        'realm_role_maps': {},    # uid -> set(realm role_id)
        'events': [],             # (client_id, method, path) penulisan + email/logout
    }
    for s in ('acr', 'basic', 'email', 'profile', 'roles', 'web-origins', 'organization', 'offline_access'):
        sid = _id()
        r['scopes'][sid] = {'id': sid, 'name': s, 'protocol': 'openid-connect', 'attributes': {}, 'protocolMappers': []}

    def add_client(cid, roles=(), sa=False, default=('acr', 'basic', 'email', 'profile'), optional=()):
        u = _id()
        c = {'id': u, 'clientId': cid, 'enabled': True, 'protocol': 'openid-connect', 'publicClient': False,
             'serviceAccountsEnabled': sa, 'secret': MOCK_SECRET_MARKER, 'attributes': {'realm_client': 'false'},
             'redirectUris': [], 'webOrigins': [], 'fullScopeAllowed': True}
        r['clients'][u] = {'rep': c, 'roles': {}, 'default': set(), 'optional': set(), 'sa_user': None}
        for rn in roles:
            rid = _id()
            r['clients'][u]['roles'][rid] = {'id': rid, 'name': rn, 'clientRole': True, 'containerId': u}
        by_name = {s['name']: sid for sid, s in r['scopes'].items()}
        r['clients'][u]['default'] = {by_name[n] for n in default}
        r['clients'][u]['optional'] = {by_name[n] for n in optional}
        if sa:
            _make_sa(r, u)
        return u

    add_client('realm-management', rm_roles)
    add_client('control-plane', ['superadmin', 'ops', 'client_admin', 'client_user'],
               default=('acr', 'basic', 'email', 'profile', 'roles', 'web-origins'),
               optional=('organization', 'offline_access'))
    add_client('automation', sa=True)
    add_client('kc-realm-sync', sa=True)
    env = 'staging' if name.endswith('-staging') else 'prod'
    add_client(f'odoo-demo-{env}', ['odoo_access'])
    add_client(f'odoo-acme-{env}', ['odoo_access'])
    if seed_cp_admin:   # seperti setelah kc-realm-sync pertama (kelas uji selain realm sync)
        cu = add_client('cp-admin', sa=True)
        rm = next(c for c in r['clients'].values() if c['rep']['clientId'] == 'realm-management')
        allow = {'manage-users', 'view-users', 'query-users', 'query-groups', 'manage-organizations', 'view-clients'}
        r['rep']['organizationsEnabled'] = True   # kelas uji user/org: kondisi setelah W2
        r['role_maps'][(r['clients'][cu]['sa_user'], rm['rep']['id'])] = {
            rid for rid, role in rm['roles'].items() if role['name'] in allow}
    return r


def _make_sa(realm, cuuid):
    c = realm['clients'][cuuid]
    if c['sa_user']:
        return
    uid = _id()
    realm['users'][uid] = {'id': uid, 'username': 'service-account-' + c['rep']['clientId'], 'enabled': True,
                           'attributes': {}, 'serviceAccountClientId': c['rep']['clientId'], 'requiredActions': []}
    c['sa_user'] = uid


class Store:
    def __init__(self, secrets_dir, seed_cp_admin=False):
        self.lock = threading.RLock()
        self.secrets_dir = secrets_dir
        self.realms = {n: default_realm(n, seed_cp_admin) for n in ('platform', 'platform-staging')}
        self.tokens = {}   # token -> (realm, clientId)


# ------------------------------------------------------------------------------------------------ izin kasar
def allowed(client_id, realm, method, path):
    if client_id == 'automation':
        return True
    if client_id == 'cp-admin':
        if path.startswith(('/users', '/organizations')):
            return not (path == '/users/profile' and method != 'GET')
        if method == 'GET' and path.startswith(('/clients', '/client-scopes')):
            return True
        return False
    if client_id == 'kc-realm-sync':
        if path.startswith('/organizations'):
            return False
        if path.startswith('/users') and path != '/users/profile':
            m = re.fullmatch(rf'/users/({UUID})/role-mappings/clients/{UUID}', path)
            return bool(m and realm['users'].get(m.group(1), {}).get('serviceAccountClientId'))
        return True
    return False


def effective_role_ids(realm, uid):
    """Id role efektif user: mapping client langsung + realm role, diekspansi transitif lewat `composites`."""
    by_id = dict(realm['realm_roles'])
    for c in realm['clients'].values():
        by_id.update(c['roles'])
    todo = set(realm['realm_role_maps'].get(uid, set()))
    for (u, _cu), rids in realm['role_maps'].items():
        if u == uid:
            todo |= rids
    seen = set()
    while todo:
        rid = todo.pop()
        if rid in seen:
            continue
        seen.add(rid)
        todo |= set(by_id.get(rid, {}).get('composites', ()))
    return seen


def user_view(realm, u):
    return copy.deepcopy(u)


def filter_attrs(realm, attrs):
    declared = {a['name'] for a in realm['profile']['attributes']}
    return {k: v for k, v in (attrs or {}).items() if k in declared}


class Handler(BaseHTTPRequestHandler):
    store: Store = None

    def log_message(self, *_a):
        pass

    # -------------------------------------------------------------------------------------------- io
    def _send(self, code, body=None, headers=None):
        data = b'' if body is None else json.dumps(body).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if body is not None:
            self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b''
        return raw

    def do_GET(self):
        self._route('GET')

    def do_POST(self):
        self._route('POST')

    def do_PUT(self):
        self._route('PUT')

    def do_DELETE(self):
        self._route('DELETE')

    # -------------------------------------------------------------------------------------------- routing
    def _route(self, method):
        st = self.store
        url = urllib.parse.urlsplit(self.path)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        raw = self._body()
        m = re.fullmatch(r'/realms/([a-z0-9-]+)/protocol/openid-connect/token', url.path)
        if m and method == 'POST':
            return self._token(m.group(1), raw)
        m = re.fullmatch(r'/admin/realms/([a-z0-9-]+)(/.*)?', url.path)
        if not m or m.group(1) not in st.realms:
            return self._send(404, {'error': 'not found'})
        realm = st.realms[m.group(1)]
        path = urllib.parse.unquote(m.group(2) or '')
        auth = self.headers.get('Authorization', '')
        tok = st.tokens.get(auth[7:]) if auth.startswith('Bearer ') else None
        if not tok or tok[0] != m.group(1):
            return self._send(401, {'error': 'HTTP 401 Unauthorized'})
        if not allowed(tok[1], realm, method, path):
            return self._send(403, {'error': 'HTTP 403 Forbidden'})
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            return self._send(400, {'error': 'bad json'})
        with st.lock:
            if method != 'GET':
                realm['events'].append((tok[1], method, path))
            return self._admin(realm, method, path, q, body)

    def _token(self, realm_name, raw):
        form = {k: v[-1] for k, v in urllib.parse.parse_qs(raw.decode()).items()}
        cid, secret = form.get('client_id', ''), form.get('client_secret', '')
        st = self.store
        realm = st.realms.get(realm_name)
        path = os.path.join(st.secrets_dir, f'{cid}-{realm_name}.secret')
        exists = realm and any(c['rep']['clientId'] == cid and c['rep']['serviceAccountsEnabled']
                               for c in realm['clients'].values())
        try:
            with open(path, encoding='utf-8') as f:
                ok = f.read() == secret
        except OSError:
            ok = False
        if form.get('grant_type') != 'client_credentials' or not exists or not ok:
            return self._send(401, {'error': 'unauthorized_client'})
        t = 'mocktoken-' + uuid.uuid4().hex
        st.tokens[t] = (realm_name, cid)
        return self._send(200, {'access_token': t, 'expires_in': 300, 'token_type': 'Bearer'})

    # -------------------------------------------------------------------------------------------- admin
    def _admin(self, realm, method, path, q, body):
        R = realm
        if path == '':
            if method == 'GET':
                return self._send(200, R['rep'])
            if method == 'PUT':
                for k, v in body.items():
                    R['rep'][k] = v
                return self._send(204)
        if path == '/users/profile':
            if method == 'GET':
                return self._send(200, R['profile'])
            if method == 'PUT':
                R['profile'] = body
                return self._send(200, body)
        m = re.fullmatch(r'/authentication/flows/([^/]+)/executions', path)
        if m:
            execs = R['flows'].get(m.group(1))
            if execs is None:
                return self._send(404, {'error': 'flow not found'})
            if method == 'GET':
                return self._send(200, execs)
            if method == 'PUT':
                for e in execs:
                    if e['id'] == body.get('id'):
                        e['requirement'] = body['requirement']
                        return self._send(202)
                return self._send(404, {'error': 'execution not found'})
        # ---- client scopes
        if path == '/client-scopes':
            if method == 'GET':
                return self._send(200, list(R['scopes'].values()))
            if method == 'POST':
                if any(s['name'] == body['name'] for s in R['scopes'].values()):
                    return self._send(409, {'errorMessage': 'exists'})
                sid = _id()
                s = copy.deepcopy(body)
                s['id'] = sid
                s['protocolMappers'] = [{**pm, 'id': _id()} for pm in body.get('protocolMappers', [])]
                R['scopes'][sid] = s
                return self._send(201, None, {'Location': f'http://mock/admin/realms/x/client-scopes/{sid}'})
        m = re.fullmatch(rf'/client-scopes/({UUID})(/protocol-mappers/models(?:/({UUID}))?)?', path)
        if m:
            s = R['scopes'].get(m.group(1))
            if not s:
                return self._send(404, {'error': 'not found'})
            if not m.group(2):
                if method == 'PUT':
                    pms = s['protocolMappers']
                    s.clear()
                    s.update(body)
                    s['protocolMappers'] = pms
                    return self._send(204)
            elif not m.group(3) and method == 'POST':
                s['protocolMappers'].append({**body, 'id': _id()})
                return self._send(201)
            elif m.group(3) and method == 'PUT':
                for i, pm in enumerate(s['protocolMappers']):
                    if pm['id'] == m.group(3):
                        s['protocolMappers'][i] = {**body, 'id': pm['id']}
                        return self._send(204)
                return self._send(404, {'error': 'not found'})
        # ---- clients
        if path == '/clients':
            if method == 'GET':
                reps = [c['rep'] for c in R['clients'].values()]
                if 'clientId' in q and q.get('search') == 'true':
                    reps = [c for c in reps if q['clientId'].lower() in c['clientId'].lower()]
                elif 'clientId' in q:
                    reps = [c for c in reps if c['clientId'] == q['clientId']]
                return self._send(200, reps)
            if method == 'POST':
                if any(c['rep']['clientId'] == body['clientId'] for c in R['clients'].values()):
                    return self._send(409, {'errorMessage': 'exists'})
                u = _id()
                rep = {**copy.deepcopy(body), 'id': u, 'secret': MOCK_SECRET_MARKER}
                R['clients'][u] = {'rep': rep, 'roles': {}, 'default': set(), 'optional': set(), 'sa_user': None}
                if rep.get('serviceAccountsEnabled'):
                    _make_sa(R, u)
                return self._send(201, None, {'Location': f'http://mock/admin/realms/x/clients/{u}'})
        m = re.fullmatch(rf'/clients/({UUID})(/.*)?', path)
        if m:
            c = R['clients'].get(m.group(1))
            if not c:
                return self._send(404, {'error': 'Could not find client'})
            sub = m.group(2) or ''
            return self._client(R, c, method, sub, q, body)
        # ---- users
        if path == '/users':
            if method == 'GET':
                us = [u for u in R['users'].values() if not u.get('serviceAccountClientId')]
                for key in ('email', 'username'):
                    if key in q:
                        us = [u for u in us if (u.get(key) or '').lower() == q[key].lower()]
                return self._send(200, [user_view(R, u) for u in us])
            if method == 'POST':
                if any(u.get('username') == body['username'] or (body.get('email') and u.get('email') == body['email'])
                       for u in R['users'].values()):
                    return self._send(409, {'errorMessage': 'User exists with same username'})
                uid = _id()
                u = {**copy.deepcopy(body), 'id': uid}
                u['attributes'] = filter_attrs(R, body.get('attributes'))
                R['users'][uid] = u
                return self._send(201, None, {'Location': f'http://mock/admin/realms/x/users/{uid}'})
        m = re.fullmatch(rf'/users/({UUID})(/.*)?', path)
        if m:
            u = R['users'].get(m.group(1))
            if not u:
                return self._send(404, {'error': 'User not found'})
            return self._user(R, u, method, m.group(2) or '', q, body)
        # ---- organizations (KC 26.7.4: realm tanpa Organizations → 404 "Organizations not enabled for this realm.")
        if path.startswith('/organizations') and not R['rep'].get('organizationsEnabled'):
            return self._send(404, {'errorMessage': 'Organizations not enabled for this realm.'})
        if path == '/organizations':
            if method == 'GET':
                return self._send(200, list(copy.deepcopy(o) for o in R['orgs'].values()))
            if method == 'POST':
                if any(o['name'] == body['name'] or o.get('alias') == body.get('alias') for o in R['orgs'].values()):
                    return self._send(409, {'errorMessage': 'exists'})
                oid = _id()
                R['orgs'][oid] = {**copy.deepcopy(body), 'id': oid, 'domains': body.get('domains', [])}
                R['members'][oid] = set()
                return self._send(201, None, {'Location': f'http://mock/admin/realms/x/organizations/{oid}'})
        m = re.fullmatch(rf'/organizations/members/({UUID})/organizations', path)
        if m and method == 'GET':
            if m.group(1) not in R['users']:
                return self._send(404, {'error': 'User not found'})
            return self._send(200, [copy.deepcopy(o) for oid, o in R['orgs'].items()
                                    if m.group(1) in R['members'].get(oid, set())])
        m = re.fullmatch(rf'/organizations/({UUID})(/members(?:/({UUID}))?)?', path)
        if m:
            o = R['orgs'].get(m.group(1))
            if not o:
                return self._send(404, {'error': 'not found'})
            if not m.group(2):
                if method == 'GET':
                    return self._send(200, o)
                if method == 'PUT':
                    if body.get('alias') != o.get('alias'):
                        return self._send(400, {'errorMessage': 'Cannot change the alias'})
                    o.update(body)
                    return self._send(204)
            elif not m.group(3) and method == 'POST':
                if not isinstance(body, str) or body not in R['users']:
                    return self._send(400, {'errorMessage': 'body must be user id string'})
                if body in R['members'][o['id']]:
                    return self._send(409, {'errorMessage': 'already member'})
                R['members'][o['id']].add(body)
                return self._send(201)
            elif m.group(3) and method == 'GET':
                if m.group(3) in R['members'][o['id']]:
                    return self._send(200, {'id': m.group(3), 'membershipType': 'MANAGED'})
                return self._send(404, {'error': 'not a member'})
        return self._send(405 if path else 404, {'error': f'mock: {method} {path} tidak didukung'})

    def _client(self, R, c, method, sub, q, body):
        rep = c['rep']
        if sub == '':
            if method == 'GET':
                return self._send(200, rep)
            if method == 'PUT':
                secret = rep.get('secret')
                rep.clear()
                rep.update(body)
                rep['secret'] = secret
                if rep.get('serviceAccountsEnabled'):
                    _make_sa(R, rep['id'])
                return self._send(204)
        if sub == '/roles':
            if method == 'GET':
                return self._send(200, list(c['roles'].values()))
            if method == 'POST':
                if any(r['name'] == body['name'] for r in c['roles'].values()):
                    return self._send(409, {'errorMessage': 'exists'})
                rid = _id()
                c['roles'][rid] = {'id': rid, 'name': body['name'], 'description': body.get('description'),
                                   'clientRole': True, 'containerId': rep['id']}
                return self._send(201)
        m = re.fullmatch(r'/roles/([A-Za-z0-9_-]+)(/users)?', sub)
        if m and method == 'GET':
            role = next((r for r in c['roles'].values() if r['name'] == m.group(1)), None)
            if not role:
                return self._send(404, {'error': 'Could not find role'})
            if not m.group(2):
                return self._send(200, role)
            us = [R['users'][uid] for (uid, cu), rids in R['role_maps'].items()
                  if cu == rep['id'] and role['id'] in rids and uid in R['users']]
            return self._send(200, us)
        m = re.fullmatch(rf'/(default|optional)-client-scopes(?:/({UUID}))?', sub)
        if m:
            kind = m.group(1)
            if not m.group(2) and method == 'GET':
                return self._send(200, [{'id': s, 'name': R['scopes'][s]['name']} for s in c[kind]])
            if m.group(2):
                if m.group(2) not in R['scopes']:
                    return self._send(404, {'error': 'scope'})
                if method == 'PUT':
                    other = 'optional' if kind == 'default' else 'default'
                    if m.group(2) in c[other]:
                        return self._send(409, {'errorMessage': 'scope already linked'})
                    c[kind].add(m.group(2))
                    return self._send(204)
                if method == 'DELETE':
                    c[kind].discard(m.group(2))
                    return self._send(204)
        if sub == '/service-account-user' and method == 'GET':
            if not c['sa_user']:
                return self._send(400, {'error': 'Service account not enabled'})
            return self._send(200, R['users'][c['sa_user']])
        return self._send(405, {'error': f'mock: {method} client{sub} tidak didukung'})

    def _user(self, R, u, method, sub, q, body):
        if sub == '':
            if method == 'GET':
                return self._send(200, user_view(R, u))
            if method == 'PUT':
                for k, v in body.items():
                    if k == 'attributes':
                        u['attributes'] = filter_attrs(R, v)
                    elif k != 'id':
                        u[k] = v
                return self._send(204)
        if sub == '/logout' and method == 'POST':
            return self._send(204)
        if sub == '/execute-actions-email' and method == 'PUT':
            if not u.get('enabled'):
                return self._send(400, {'errorMessage': 'User is disabled'})
            if not isinstance(body, list) or not body:
                return self._send(400, {'errorMessage': 'actions'})
            return self._send(204)
        m = re.fullmatch(rf'/role-mappings/clients/({UUID})(/composite)?', sub)
        if m:
            c = R['clients'].get(m.group(1))
            if not c:
                return self._send(404, {'error': 'client'})
            key = (u['id'], m.group(1))
            have = R['role_maps'].setdefault(key, set())
            if method == 'GET':
                ids = effective_role_ids(R, u['id']) if m.group(2) else have
                return self._send(200, [c['roles'][r] for r in sorted(ids) if r in c['roles']])
            if m.group(2):
                return self._send(405, {'error': 'composite read-only'})
            ids = []
            for r in body or []:
                rid = r.get('id') or next((x['id'] for x in c['roles'].values() if x['name'] == r.get('name')), None)
                if rid not in c['roles']:
                    return self._send(404, {'error': 'Role not found'})
                ids.append(rid)
            if method == 'POST':
                have.update(ids)
                return self._send(204)
            if method == 'DELETE':
                have.difference_update(ids)
                return self._send(204)
        return self._send(405, {'error': f'mock: {method} user{sub} tidak didukung'})


def start(secrets_dir, port=0, seed_cp_admin=False):
    store = Store(secrets_dir, seed_cp_admin)
    handler = type('H', (Handler,), {'store': store})
    srv = ThreadingHTTPServer(('127.0.0.1', port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, store


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=0)
    ap.add_argument('--secrets', required=True)
    a = ap.parse_args()
    srv, _ = start(a.secrets, a.port)
    print(f'PORT {srv.server_address[1]}', flush=True)
    threading.Event().wait()
