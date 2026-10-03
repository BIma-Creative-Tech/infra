#!/usr/bin/env python3
# Part of infra (plan 04 S2, ADR 0008 #2). Representasi yang DIINGINKAN untuk client Keycloak
# `odoo-<slug>-<env>` + perbandingan dengan representasi saat ini (idempoten). Dipanggil oleh
# scripts/provision-odoo-sso.sh — input JSON dari stdin (hasil GET Admin REST), output JSON di stdout.
# Tidak pernah membaca/mencetak secret: field `secret` dari GET dibuang sebelum dibandingkan/di-PUT.
#
#   client  --client-id C --name N --host H [--host H…] --enabled 0|1   stdin: GET /clients?clientId=C
#           → {"action": "create|update|none", "changes": [...], "body": {...}}
#   mapper  --client-id C                                               stdin: GET /clients/<uuid>/protocol-mappers/models
#           → {"action": ..., "changes": [...], "id": <id|null>, "body": {...}}
#   scopes  --                                                          stdin: {"default": [...], "optional": [...], "all": [...]}
#           → {"ops": [["add-default"|"remove-default"|"remove-optional", scope_id, scope_name], ...], "missing": [...]}
import argparse
import json
import sys

# Representasi F12 (plan 04, export `odoo-demo-staging`): confidential, standard flow saja, PKCE S256.
CLIENT_FIXED = {
    'protocol': 'openid-connect',
    'publicClient': False,
    'bearerOnly': False,
    'clientAuthenticatorType': 'client-secret',
    'consentRequired': False,
    'standardFlowEnabled': True,
    'implicitFlowEnabled': False,
    'directAccessGrantsEnabled': False,
    'serviceAccountsEnabled': False,
    'frontchannelLogout': False,
    'fullScopeAllowed': False,
    'webOrigins': [],
    'surrogateAuthRequired': False,
}
ATTRIBUTES_FIXED = {
    'pkce.code.challenge.method': 'S256',
    'id.token.signed.response.alg': 'RS256',
    'oauth2.device.authorization.grant.enabled': 'false',
    'oidc.ciba.grant.enabled': 'false',
    'standard.token.exchange.enabled': 'false',
}
DEFAULT_SCOPES = ['acr', 'basic', 'email', 'profile']
# Scope default yang DIKELOLA kc-realm-sync (identity/keycloak/realm/platform.json, ADR 0017 D3): TIDAK PERNAH dilepas
# di sini (tanpa itu provision-odoo-sso.sh dan kc-realm-sync saling membatalkan / flapping), tetapi DITAMBAH bila scope
# sudah ada di realm (2026-10-03: client odoo-* baru dari onboarding tidak punya scope tenant sampai sync berikutnya →
# token tanpa tenant_id). Scope belum ada di realm (realm belum di-sync, mis. prod sebelum migrasi) → dilewati, bukan
# `missing`; keluaran `realm_sync` = false.
REALM_SYNC_DEFAULT_SCOPES = ('tenant',)
CALLBACK_PATH = '/sh_auth_oidc/callback'   # sh_auth_oidc controllers/main.py CALLBACK_PATH
LOGOUT_PATH = '/web/login'
MAPPER_NAME = 'client roles'
UNORDERED = ('redirectUris', 'webOrigins')
# Field yang dibuang dari hasil GET sebelum PUT (read-only / secret).
DROP_ON_PUT = ('secret', 'access')


def desired_client(client_id, name, hosts, enabled):
    rep = dict(CLIENT_FIXED)
    rep.update({
        'clientId': client_id,
        'name': name,
        'enabled': enabled,
        'redirectUris': [f'https://{h}{CALLBACK_PATH}' for h in hosts],
        'rootUrl': f'https://{hosts[0]}',
        'baseUrl': f'https://{hosts[0]}',
    })
    attrs = dict(ATTRIBUTES_FIXED)
    attrs['post.logout.redirect.uris'] = '##'.join(f'https://{h}{LOGOUT_PATH}' for h in hosts)
    rep['attributes'] = attrs
    return rep


def _norm(key, value):
    if key in UNORDERED and isinstance(value, list):
        return sorted(value)
    return value


def cmd_client(args):
    current = json.load(sys.stdin)
    if not isinstance(current, list):
        sys.exit('client: expected a JSON list')
    matches = [c for c in current if c.get('clientId') == args.client_id]
    if len(matches) > 1:
        sys.exit('client: more than one client with this clientId')
    want = desired_client(args.client_id, args.name, args.host, args.enabled == '1')
    if not matches:
        body = dict(want)
        body['defaultClientScopes'] = list(DEFAULT_SCOPES)
        body['optionalClientScopes'] = []
        return {'action': 'create', 'changes': ['client (new)'], 'body': body}
    cur = matches[0]
    changes = []
    body = {k: v for k, v in cur.items() if k not in DROP_ON_PUT}
    for key, value in want.items():
        if key == 'attributes':
            attrs = dict(cur.get('attributes') or {})
            for akey, aval in value.items():
                if attrs.get(akey) != aval:
                    changes.append(f'attributes.{akey}')
                    attrs[akey] = aval
            body['attributes'] = attrs
        elif _norm(key, cur.get(key)) != _norm(key, value):
            changes.append(key)
            body[key] = value
    return {'action': 'update' if changes else 'none', 'changes': changes, 'body': body, 'id': cur['id']}


def desired_mapper(client_id):
    # Nama klaim LITERAL (tanpa ${client_id}: CRS 932130 memblok body Admin REST, keycloak.md §T16b).
    return {
        'name': MAPPER_NAME,
        'protocol': 'openid-connect',
        'protocolMapper': 'oidc-usermodel-client-role-mapper',
        'consentRequired': False,
        'config': {
            'usermodel.clientRoleMapping.clientId': client_id,
            'claim.name': f'resource_access.{client_id}.roles',
            'jsonType.label': 'String',
            'multivalued': 'true',
            'id.token.claim': 'true',
            'access.token.claim': 'true',
            'userinfo.token.claim': 'true',
            'introspection.token.claim': 'true',
        },
    }


def cmd_mapper(args):
    current = json.load(sys.stdin)
    want = desired_mapper(args.client_id)
    matches = [m for m in current if m.get('name') == MAPPER_NAME]
    if not matches:
        return {'action': 'create', 'changes': ['mapper (new)'], 'id': None, 'body': want}
    cur = matches[0]
    changes = [k for k in ('protocol', 'protocolMapper') if cur.get(k) != want[k]]
    if changes:
        # tipe mapper tidak bisa diubah lewat PUT → minta operator menghapus manual
        sys.exit(f'mapper {MAPPER_NAME!r} exists with a different type ({", ".join(changes)}) — fix manually')
    config = dict(cur.get('config') or {})
    for key, value in want['config'].items():
        if config.get(key) != value:
            changes.append(f'config.{key}')
            config[key] = value
    body = dict(cur)
    body['config'] = config
    return {'action': 'update' if changes else 'none', 'changes': changes, 'id': cur['id'], 'body': body}


def cmd_scopes(_args):
    data = json.load(sys.stdin)
    by_name = {s['name']: s['id'] for s in data['all']}
    default = {s['name']: s['id'] for s in data['default']}
    optional = {s['name']: s['id'] for s in data['optional']}
    ops, missing = [], []
    for name in DEFAULT_SCOPES:
        if name not in default:
            if name not in by_name:
                missing.append(name)
            else:
                ops.append(['add-default', by_name[name], name])
    realm_sync = all(name in by_name for name in REALM_SYNC_DEFAULT_SCOPES)
    if realm_sync:
        for name in REALM_SYNC_DEFAULT_SCOPES:
            if name not in default:
                ops.append(['add-default', by_name[name], name])
    for name, sid in sorted(default.items()):
        if name not in DEFAULT_SCOPES and name not in REALM_SYNC_DEFAULT_SCOPES:
            ops.append(['remove-default', sid, name])
    for name, sid in sorted(optional.items()):
        if name not in REALM_SYNC_DEFAULT_SCOPES:
            ops.append(['remove-optional', sid, name])
    return {'ops': ops, 'missing': missing, 'realm_sync': realm_sync}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('client')
    p.add_argument('--client-id', required=True)
    p.add_argument('--name', required=True)
    p.add_argument('--host', action='append', required=True)
    p.add_argument('--enabled', choices=('0', '1'), required=True)
    p = sub.add_parser('mapper')
    p.add_argument('--client-id', required=True)
    sub.add_parser('scopes')
    args = parser.parse_args()
    result = {'client': cmd_client, 'mapper': cmd_mapper, 'scopes': cmd_scopes}[args.cmd](args)
    json.dump(result, sys.stdout, sort_keys=True)


if __name__ == '__main__':
    main()
