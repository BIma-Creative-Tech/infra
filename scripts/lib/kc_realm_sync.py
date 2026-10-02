#!/usr/bin/env python3
# Part of infra (SaaS Fase 1, ADR 0017 D7, kontrak saas-phase-1-contract.md §1.1). Realm sebagai kode untuk realm
# `platform` / `platform-staging`: membandingkan desired-state `identity/keycloak/realm/platform.json` (+ override
# `<realm>.overrides.json`) dengan kondisi live (hasil GET Admin REST yang dikumpulkan scripts/kc-realm-sync.sh ke
# direktori state) dan menghasilkan daftar operasi Admin REST. Python stdlib saja; TIDAK melakukan HTTP sendiri
# (token tetap di lib/keycloak-admin.sh). Tidak pernah membaca/mencetak secret: `sanitize` membuang field secret
# sebelum JSON ditulis ke direktori state.
#
#   sanitize                                stdin JSON → stdout JSON tanpa kunci secret (rekursif)
#   need     --desired F [--overrides F] --state DIR
#            → baris "client <uuid> <clientId>" / "sa <uuid> <clientId>" / "rm <uuid>" / "flow <alias>"
#              (sub-resource yang harus di-GET oleh skrip)
#   plan     --desired F [--overrides F] --state DIR
#            → JSON {"ops": [{"m": METHOD|null, "p": path, "b": body|null, "e": [status…], "d": deskripsi}],
#                    "blockers": [pesan…], "notes": [pesan…]}
#              op dengan "m": null = TERTUNDA (bergantung pada objek yang baru dibuat di op sebelumnya) — dihitung
#              pada rencana, dilewati saat apply; putaran berikutnya (GET ulang) menghasilkan op nyata.
#
# Cakupan TERKELOLA (selain ini tidak pernah disentuh — user, secret client, client lain):
#   realm      kunci allowlist MANAGED_REALM_KEYS (PUT /admin/realms/<realm> parsial)
#   browser    eksekusi top-level di flow browser realm yang harus DISABLED (mis. sub-flow `Organization`)
#   profile    atribut user profile (mis. tenant_id; PUT /users/profile — konfigurasi lain dipertahankan)
#   scopes     client scope (mis. `tenant`) + protocol mapper
#   default    default client scope pada client control-plane + semua odoo-<slug>-<env> (hanya menambah)
#   roles      client role yang harus ada (hanya membuat, tidak pernah menghapus)
#   sa         client service account (cp-admin): representasi terkelola + role realm-management PERSIS allowlist
import argparse
import json
import os
import re
import sys
import urllib.parse

MANAGED_REALM_KEYS = frozenset({
    'organizationsEnabled', 'resetPasswordAllowed', 'bruteForceProtected', 'passwordPolicy',
    'registrationAllowed', 'verifyEmail', 'loginWithEmailAllowed', 'duplicateEmailsAllowed', 'sslRequired',
    'editUsernameAllowed', 'rememberMe', 'registrationEmailAsUsername', 'permanentLockout', 'failureFactor',
    'waitIncrementSeconds', 'maxFailureWaitSeconds', 'maxDeltaTimeSeconds',
})
TOP_KEYS = frozenset({'_comment', 'version', 'realm', 'browserFlow', 'userProfile', 'clientScopes',
                      'defaultClientScopes', 'clientRoles', 'serviceAccountClients'})
# Client yang boleh disebut eksplisit (selain pola odoo-*). kc-realm-sync/automation/bawaan KC tidak pernah dikelola.
EXPLICIT_CLIENTS = frozenset({'control-plane'})
SA_CLIENTS = frozenset({'cp-admin'})
NEVER_MANAGED = frozenset({'kc-realm-sync', 'automation', 'realm-management', 'admin-cli', 'security-admin-console',
                           'account', 'account-console', 'broker'})
ODOO_CLIENT_RE = re.compile(r'odoo-[a-z0-9-]{3,30}-(prod|demo|staging)')
SECRET_KEYS = frozenset({'secret', 'password', 'privateKey', 'registrationAccessToken', 'credentials',
                         'client_secret', 'access_token', 'refresh_token'})
UUIDISH = r'[0-9a-f-]{36}'
# Path op yang boleh dihasilkan (pertahanan berlapis: planner tidak pernah menyentuh user biasa / secret).
ALLOWED_OPS = [
    ('PUT', re.compile(r'')),
    ('PUT', re.compile(r'/users/profile')),
    ('PUT', re.compile(r'/authentication/flows/[A-Za-z0-9%._-]+/executions')),
    ('POST', re.compile(r'/client-scopes')),
    ('PUT', re.compile(rf'/client-scopes/{UUIDISH}')),
    ('POST', re.compile(rf'/client-scopes/{UUIDISH}/protocol-mappers/models')),
    ('PUT', re.compile(rf'/client-scopes/{UUIDISH}/protocol-mappers/models/{UUIDISH}')),
    ('POST', re.compile(r'/clients')),
    ('PUT', re.compile(rf'/clients/{UUIDISH}')),
    ('POST', re.compile(rf'/clients/{UUIDISH}/roles')),
    ('PUT', re.compile(rf'/clients/{UUIDISH}/default-client-scopes/{UUIDISH}')),
    ('DELETE', re.compile(rf'/clients/{UUIDISH}/optional-client-scopes/{UUIDISH}')),
    ('POST', re.compile(rf'/users/{UUIDISH}/role-mappings/clients/{UUIDISH}')),
    ('DELETE', re.compile(rf'/users/{UUIDISH}/role-mappings/clients/{UUIDISH}')),
]


class PlanError(Exception):
    pass


# ------------------------------------------------------------------------------------------------ util
def sanitize(obj):
    if isinstance(obj, dict):
        return {k: sanitize(v) for k, v in obj.items() if k not in SECRET_KEYS}
    if isinstance(obj, list):
        return [sanitize(v) for v in obj]
    return obj


def deep_merge(base, over):
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load_desired(path, overrides=None):
    with open(path, encoding='utf-8') as f:
        desired = json.load(f)
    if overrides and os.path.exists(overrides):
        with open(overrides, encoding='utf-8') as f:
            ov = json.load(f)
        unknown = set(ov) - TOP_KEYS
        if unknown:
            raise PlanError(f'override: kunci tidak dikenal {sorted(unknown)}')
        desired = deep_merge(desired, ov)
    validate_desired(desired)
    return desired


def validate_desired(d):
    unknown = set(d) - TOP_KEYS
    if unknown:
        raise PlanError(f'desired: kunci top-level tidak dikenal {sorted(unknown)}')
    bad = set(d.get('realm', {})) - MANAGED_REALM_KEYS
    if bad:
        raise PlanError(f'desired.realm: kunci di luar allowlist {sorted(bad)}')
    for sect in ('defaultClientScopes', 'clientRoles'):
        for rule in d.get(sect, []):
            names = set(rule.get('clients', []))
            if names - EXPLICIT_CLIENTS:
                raise PlanError(f'desired.{sect}: client eksplisit tidak diizinkan {sorted(names - EXPLICIT_CLIENTS)}')
            pat = rule.get('clientPattern')
            if pat is not None and pat != ODOO_CLIENT_RE.pattern:
                raise PlanError(f'desired.{sect}: clientPattern harus {ODOO_CLIENT_RE.pattern!r}')
    for sa in d.get('serviceAccountClients', []):
        cid = sa.get('client', {}).get('clientId')
        if cid not in SA_CLIENTS:
            raise PlanError(f'desired.serviceAccountClients: client {cid!r} tidak diizinkan')
        if sa['client'].get('serviceAccountsEnabled') is not True:
            raise PlanError(f'desired.serviceAccountClients: {cid} harus serviceAccountsEnabled=true')
        if any(k in SECRET_KEYS for k in sa['client']):
            raise PlanError(f'desired.serviceAccountClients: {cid} memuat field secret')
    if json.dumps(d).find('${') >= 0:
        # CRS 932130 memblok body Admin REST berisi '${' (keycloak.md §T16b)
        raise PlanError("desired memuat '${' — diblok WAF; tulis nilai literal")


def read_state(state, name, default=None):
    path = os.path.join(state, name)
    if not os.path.exists(path):
        if default is not None:
            return default
        raise PlanError(f'state tidak ada: {name}')
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def matches(rule, client_id):
    if client_id in NEVER_MANAGED:
        return False
    if client_id in rule.get('clients', []):
        return True
    pat = rule.get('clientPattern')
    return bool(pat and re.fullmatch(pat, client_id))


def managed_clients(desired, clients):
    """{clientId: uuid} untuk client yang sub-resource-nya perlu dibaca (scopes/roles)."""
    out = {}
    for c in clients:
        cid = c.get('clientId', '')
        for sect in ('defaultClientScopes', 'clientRoles'):
            if any(matches(r, cid) for r in desired.get(sect, [])):
                out[cid] = c['id']
    return out


# ------------------------------------------------------------------------------------------------ need
def cmd_need(desired, state):
    clients = read_state(state, 'clients.json')
    realm = read_state(state, 'realm.json')
    lines = []
    for cid, uuid in sorted(managed_clients(desired, clients).items()):
        lines.append(f'client {uuid} {cid}')
    by_id = {c.get('clientId'): c for c in clients}
    for sa in desired.get('serviceAccountClients', []):
        cid = sa['client']['clientId']
        if cid in by_id:
            lines.append(f'sa {by_id[cid]["id"]} {cid}')
    if 'realm-management' in by_id:
        lines.append(f'rm {by_id["realm-management"]["id"]}')
    if desired.get('browserFlow'):
        alias = realm.get('browserFlow') or 'browser'
        if not re.fullmatch(r'[A-Za-z0-9 ._-]{1,64}', alias):
            raise PlanError('alias browserFlow realm tidak dikenali')
        lines.append(f'flow {urllib.parse.quote(alias, safe="")}')
    return '\n'.join(lines)


# ------------------------------------------------------------------------------------------------ plan
class Plan:
    def __init__(self):
        self.ops, self.blockers, self.notes = [], [], []

    def op(self, method, path, body, expect, desc):
        if method is not None:
            if not any(m == method and rx.fullmatch(path) for m, rx in ALLOWED_OPS):
                raise PlanError(f'op tidak diizinkan: {method} {path}')
            if body is not None and '${' in json.dumps(body):
                raise PlanError(f"body op memuat '${{': {desc}")
        self.ops.append({'m': method, 'p': path, 'b': body, 'e': list(expect), 'd': desc})

    def pending(self, desc):
        self.ops.append({'m': None, 'p': '', 'b': None, 'e': [], 'd': desc + ' (tertunda: setelah objek dibuat)'})


def plan_realm(p, desired, realm):
    want = desired.get('realm', {})
    diff = {k: v for k, v in sorted(want.items()) if realm.get(k) != v}
    if diff:
        desc = ', '.join(f'{k}: {json.dumps(realm.get(k))} → {json.dumps(v)}' for k, v in diff.items())
        p.op('PUT', '', diff, [204], f'realm: {desc}')


def plan_browser_flow(p, desired, realm, state):
    spec = desired.get('browserFlow') or {}
    names = spec.get('disableExecutions', [])
    if not names:
        return
    alias = realm.get('browserFlow') or 'browser'
    execs = read_state(state, 'flow-executions.json')
    for name in names:
        # Eksekusi top-level (level 0) sub-flow bernama `name` (KC 26.6.1 migrasi menambah sub-flow `Organization`).
        found = [e for e in execs if e.get('displayName') == name and e.get('level') == 0]
        if not found:
            p.notes.append(f'flow {alias}: eksekusi {name!r} tidak ada (tidak ada yang dinonaktifkan)')
            continue
        if len(found) > 1:
            p.blockers.append(f'flow {alias}: lebih dari satu eksekusi top-level {name!r}')
            continue
        e = found[0]
        if e.get('requirement') == 'DISABLED':
            continue
        choices = e.get('requirementChoices')
        if choices is not None and 'DISABLED' not in choices:
            p.blockers.append(f'flow {alias}: eksekusi {name!r} tidak bisa DISABLED (pilihan {choices})')
            continue
        body = {**e, 'requirement': 'DISABLED'}
        # PUT /authentication/flows/{alias}/executions body = AuthenticationExecutionInfoRepresentation
        # UNVERIFIED (KC 26.7 docs): status 202 (Accepted) atau 204.
        p.op('PUT', f'/authentication/flows/{urllib.parse.quote(alias, safe="")}/executions', body, [202, 204],
             f'flow {alias}: eksekusi {name!r} {e.get("requirement")} → DISABLED')


def _subset_differs(cur, want):
    return [k for k, v in want.items() if cur.get(k) != v]


def plan_user_profile(p, desired, profile):
    want_attrs = (desired.get('userProfile') or {}).get('attributes', [])
    if not want_attrs:
        return
    attrs = list(profile.get('attributes') or [])
    changed = []
    for want in want_attrs:
        idx = next((i for i, a in enumerate(attrs) if a.get('name') == want['name']), None)
        if idx is None:
            attrs.append(want)
            changed.append(f'atribut {want["name"]} ditambah')
        else:
            diff = _subset_differs(attrs[idx], want)
            if diff:
                attrs[idx] = {**attrs[idx], **want}
                changed.append(f'atribut {want["name"]}: {", ".join(sorted(diff))}')
    if changed:
        # PUT /users/profile body = UPConfig lengkap (atribut lain, groups, unmanagedAttributePolicy dipertahankan)
        # → 200 + konfigurasi baru (UNVERIFIED (KC 26.7 docs): status 200).
        p.op('PUT', '/users/profile', {**profile, 'attributes': attrs}, [200], 'user profile: ' + '; '.join(changed))


def plan_client_scopes(p, desired, scopes):
    by_name = {s['name']: s for s in scopes}
    for want in desired.get('clientScopes', []):
        cur = by_name.get(want['name'])
        if cur is None:
            p.op('POST', '/client-scopes', want, [201],
                 f'client scope {want["name"]} dibuat (+ {len(want.get("protocolMappers", []))} mapper)')
            continue
        if cur.get('protocol') != want.get('protocol'):
            p.blockers.append(f'client scope {want["name"]}: protocol {cur.get("protocol")} ≠ {want.get("protocol")}')
            continue
        attrs = dict(cur.get('attributes') or {})
        diff = _subset_differs(attrs, want.get('attributes') or {})
        if diff or cur.get('description') != want.get('description'):
            body = {k: v for k, v in cur.items() if k != 'protocolMappers'}
            body.update({'description': want.get('description'),
                         'attributes': {**attrs, **(want.get('attributes') or {})}})
            p.op('PUT', f'/client-scopes/{cur["id"]}', body, [204],
                 f'client scope {want["name"]}: {", ".join(sorted(diff) or ["description"])}')
        mappers = {m['name']: m for m in cur.get('protocolMappers') or []}
        for wm in want.get('protocolMappers', []):
            cm = mappers.get(wm['name'])
            if cm is None:
                p.op('POST', f'/client-scopes/{cur["id"]}/protocol-mappers/models', wm, [201],
                     f'client scope {want["name"]}: mapper {wm["name"]} dibuat')
                continue
            if cm.get('protocolMapper') != wm['protocolMapper'] or cm.get('protocol') != wm['protocol']:
                p.blockers.append(f'mapper {want["name"]}/{wm["name"]}: tipe berbeda ({cm.get("protocolMapper")}) — '
                                  'perbaiki manual')
                continue
            cdiff = _subset_differs(cm.get('config') or {}, wm.get('config') or {})
            if cdiff:
                body = {**cm, 'config': {**(cm.get('config') or {}), **wm['config']}}
                p.op('PUT', f'/client-scopes/{cur["id"]}/protocol-mappers/models/{cm["id"]}', body, [204],
                     f'client scope {want["name"]}: mapper {wm["name"]} config {", ".join(sorted(cdiff))}')


def plan_default_scopes(p, desired, clients, scopes, state):
    scope_ids = {s['name']: s['id'] for s in scopes}
    present = {c['clientId']: c for c in clients}
    for rule in desired.get('defaultClientScopes', []):
        for name in rule.get('clients', []):
            if name not in present:
                p.blockers.append(f'client {name} tidak ada di realm (default scope tidak bisa diterapkan)')
        for cid in sorted(c for c in present if matches(rule, c)):
            uuid = present[cid]['id']
            default = {s['name'] for s in read_state(state, f'clients/{uuid}/default.json')}
            optional = {s['name']: s['id'] for s in read_state(state, f'clients/{uuid}/optional.json')}
            for sname in rule.get('scopes', []):
                if sname in default:
                    continue
                sid = scope_ids.get(sname)
                if sid is None:
                    p.pending(f'client {cid}: scope default {sname}')
                    continue
                if sname in optional:
                    p.op('DELETE', f'/clients/{uuid}/optional-client-scopes/{optional[sname]}', None, [204],
                         f'client {cid}: scope {sname} dilepas dari optional')
                p.op('PUT', f'/clients/{uuid}/default-client-scopes/{sid}', None, [204],
                     f'client {cid}: scope default {sname} ditambah')


def plan_client_roles(p, desired, clients, state):
    present = {c['clientId']: c for c in clients}
    for rule in desired.get('clientRoles', []):
        for name in rule.get('clients', []):
            if name not in present:
                p.blockers.append(f'client {name} tidak ada di realm (role tidak bisa dibuat)')
        for cid in sorted(c for c in present if matches(rule, c)):
            uuid = present[cid]['id']
            have = {r['name'] for r in read_state(state, f'clients/{uuid}/roles.json')}
            for role in rule.get('roles', []):
                if role['name'] not in have:
                    p.op('POST', f'/clients/{uuid}/roles', role, [201], f'client {cid}: role {role["name"]} dibuat')


SA_COMPARE_SKIP = frozenset({'clientId'})


def plan_sa_clients(p, desired, clients, state):
    present = {c['clientId']: c for c in clients}
    rm = present.get('realm-management')
    rm_roles = {r['name']: r for r in read_state(state, 'rm-roles.json', [])} if rm else {}
    for sa in desired.get('serviceAccountClients', []):
        want = sa['client']
        cid = want['clientId']
        allow = sorted(sa.get('realmManagementRoles', []))
        missing_roles = [r for r in allow if r not in rm_roles]
        if missing_roles:
            p.blockers.append(f'role realm-management tidak ada: {", ".join(missing_roles)}')
        cur = present.get(cid)
        if cur is None:
            p.op('POST', '/clients', want, [201], f'client service account {cid} dibuat (secret dibuat Keycloak)')
            p.pending(f'{cid}: role realm-management PERSIS {",".join(allow)}')
            continue
        diff = []
        body = {k: v for k, v in cur.items() if k not in ('access', 'protocolMappers')}
        for k, v in want.items():
            if k in SA_COMPARE_SKIP:
                continue
            if k == 'attributes':
                attrs = dict(cur.get('attributes') or {})
                adiff = _subset_differs(attrs, v)
                if adiff:
                    diff += [f'attributes.{a}' for a in adiff]
                    body['attributes'] = {**attrs, **v}
            elif k in ('redirectUris', 'webOrigins'):
                if sorted(cur.get(k) or []) != sorted(v):
                    diff.append(k)
                    body[k] = v
            elif cur.get(k) != v:
                diff.append(k)
                body[k] = v
        if diff:
            p.op('PUT', f'/clients/{cur["id"]}', body, [204], f'client {cid}: {", ".join(sorted(diff))}')
        if not cur.get('serviceAccountsEnabled'):
            p.pending(f'{cid}: role realm-management PERSIS {",".join(allow)}')
            continue
        if rm is None:
            p.blockers.append('client realm-management tidak ada')
            continue
        sa_user = read_state(state, f'sa/{cur["id"]}-user.json')
        have = {r['name'] for r in read_state(state, f'sa/{cur["id"]}-rm.json')}
        add = [r for r in allow if r not in have and r in rm_roles]
        drop = sorted(have - set(allow))
        path = f'/users/{sa_user["id"]}/role-mappings/clients/{rm["id"]}'
        if drop:
            p.op('DELETE', path, [{'id': rm_roles[r]['id'], 'name': r} if r in rm_roles else {'name': r}
                                  for r in drop], [204], f'{cid}: role realm-management dicabut {",".join(drop)}')
        if add:
            p.op('POST', path, [{'id': rm_roles[r]['id'], 'name': r} for r in add], [204],
                 f'{cid}: role realm-management diberikan {",".join(add)}')


def cmd_plan(desired, state):
    realm = read_state(state, 'realm.json')
    profile = read_state(state, 'profile.json')
    scopes = read_state(state, 'client-scopes.json')
    clients = read_state(state, 'clients.json')
    p = Plan()
    plan_realm(p, desired, realm)
    plan_browser_flow(p, desired, realm, state)
    plan_user_profile(p, desired, profile)
    plan_client_scopes(p, desired, scopes)
    plan_client_roles(p, desired, clients, state)
    plan_default_scopes(p, desired, clients, scopes, state)
    plan_sa_clients(p, desired, clients, state)
    return {'ops': p.ops, 'blockers': p.blockers, 'notes': p.notes}


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('sanitize')
    for name in ('need', 'plan'):
        sp = sub.add_parser(name)
        sp.add_argument('--desired', required=True)
        sp.add_argument('--overrides')
        sp.add_argument('--state', required=True)
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'sanitize':
            json.dump(sanitize(json.load(sys.stdin)), sys.stdout, sort_keys=True)
            return 0
        desired = load_desired(args.desired, args.overrides)
        if args.cmd == 'need':
            out = cmd_need(desired, args.state)
            if out:
                print(out)
        else:
            json.dump(cmd_plan(desired, args.state), sys.stdout, sort_keys=True)
    except PlanError as e:
        print(f'ERROR: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
