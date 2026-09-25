# shellcheck shell=bash
# shellcheck disable=SC2034  # library: KC_* (KC_LOCATION, KC_STATUS, …) dibaca skrip pemanggil
# Keycloak Admin REST client untuk skrip ops (plan 04 S2, ADR 0008 #5). Di-source SETELAH lib/odoo-pools.sh
# (butuh: die, INFRA_DIR). Tidak ada secret di file ini.
#
# - Token: client `automation` (service account, realm yang sama) — secret dari
#   identity/keycloak/secrets/automation-<realm>.secret (600 root, tanpa newline), dikirim dengan
#   `--data-urlencode client_secret@<file>` (tidak pernah muncul di argv/log).
# - Admin REST HANYA via entrypoint Traefik `admin` :8443 (H5): `--resolve auth.bimacreative.tech:8443:127.0.0.1`.
# - Header Authorization dikirim lewat `-H @<(printf …)` (builtin printf → tidak ada token di argv / `ps`).
# - Body JSON dikirim dari stdin (`--data-binary @-`). Body yang memuat `${` ditolak sebelum dikirim:
#   CrowdSec AppSec CRS 932130 memblok (403) — tulis nama klaim literal (keycloak.md §T16b).
# - Jangan pernah `set -x` di skrip pemanggil. Fungsi di sini tidak mencetak token/secret; body respons error
#   dicetak terpotong (≤ 300 char) — endpoint yang mengembalikan secret (client-secret) tidak dicetak.
#
# API:
#   kc_init <realm>                    set KC_REALM, ambil token (die bila gagal)
#   kc_request <METHOD> <path> [json]  set KC_STATUS, KC_BODY, KC_LOCATION (path relatif /admin/realms/<realm>)
#   kc_get <path>                      stdout = body; die bila status ≠ 200
#   kc_get_quiet <path>                seperti kc_get tetapi body error TIDAK dicetak (untuk endpoint secret)
#   kc_send <METHOD> <path> <json> <expected-status…>   die bila status tidak termasuk expected
#   kc_json <python-expr> [json]       evaluasi ekspresi Python pada JSON (variabel `d`); tanpa arg → stdin

KC_HOST="${KC_HOST:-auth.bimacreative.tech}"
KC_ADMIN_PORT="${KC_ADMIN_PORT:-8443}"
KC_BASE="https://${KC_HOST}:${KC_ADMIN_PORT}"
KC_RESOLVE=(--resolve "${KC_HOST}:${KC_ADMIN_PORT}:127.0.0.1")
KC_SECRETS_DIR="${KC_SECRETS_DIR:-$INFRA_DIR/identity/keycloak/secrets}"
KC_AUTOMATION_CLIENT="automation"
# Issuer publik (KC_HOSTNAME) — dipakai Odoo; BUKAN URL admin :8443.
KC_PUBLIC_BASE="https://${KC_HOST}"
KC_CURL_OPTS=(-sS --proto '=https' --max-time 30 --retry 0)

KC_REALM=""
KC_TOKEN=""
KC_TOKEN_EXP=0
KC_STATUS=""
KC_BODY=""
KC_LOCATION=""

# kc_realm_for_env <prod|demo|staging> → echo nama realm (ADR 0008 #1)
kc_realm_for_env() {
  case "$1" in
    prod|demo) echo platform ;;
    staging) echo platform-staging ;;
    *) die "env tidak dikenal: $1" ;;
  esac
}

kc_issuer() { echo "${KC_PUBLIC_BASE}/realms/${1:-$KC_REALM}"; }

# kc_json <expr> [json] — ekspresi Python dengan `d` = JSON ter-parse; hasil str dicetak apa adanya,
# lainnya sebagai JSON. Hanya untuk data non-secret.
kc_json() {
  local expr="$1"
  if [[ $# -ge 2 ]]; then
    printf '%s' "$2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = eval(sys.argv[1])
sys.stdout.write(r if isinstance(r, str) else json.dumps(r, sort_keys=True))' "$expr"
  else
    python3 -c '
import json, sys
d = json.load(sys.stdin)
r = eval(sys.argv[1])
sys.stdout.write(r if isinstance(r, str) else json.dumps(r, sort_keys=True))' "$expr"
  fi
}

kc_login() {
  local realm="$1" secret_file resp code tok exp
  secret_file="$KC_SECRETS_DIR/${KC_AUTOMATION_CLIENT}-${realm}.secret"
  [[ -r "$secret_file" && -s "$secret_file" ]] || die "secret automation tidak ada: $secret_file"
  # respons token berisi access_token → tidak pernah dicetak; hanya status.
  resp="$(curl "${KC_CURL_OPTS[@]}" "${KC_RESOLVE[@]}" -w '\n%{http_code}' \
      -d grant_type=client_credentials -d "client_id=${KC_AUTOMATION_CLIENT}" \
      --data-urlencode "client_secret@${secret_file}" \
      "${KC_BASE}/realms/${realm}/protocol/openid-connect/token")" \
    || die "Keycloak token: curl gagal (Traefik entrypoint admin :${KC_ADMIN_PORT} berjalan?)"
  code="${resp##*$'\n'}"
  [[ "$code" == 200 ]] || die "Keycloak token realm ${realm}: HTTP ${code} (secret automation salah / WAF?)"
  { read -r tok; read -r exp; } < <(printf '%s' "${resp%$'\n'*}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["access_token"]); print(int(d.get("expires_in", 60)))')
  [[ -n "$tok" && "$exp" =~ ^[0-9]+$ ]] || die "Keycloak token realm ${realm}: respons tidak dikenali"
  KC_TOKEN="$tok"
  KC_TOKEN_EXP=$(( $(date +%s) + exp - 30 ))
}

kc_init() {
  [[ "$1" =~ ^[a-z0-9-]{1,64}$ ]] || die "realm tidak valid"
  KC_REALM="$1"
  kc_login "$KC_REALM"
}

# kc_request <METHOD> <path> [json-body]
kc_request() {
  local method="$1" path="$2" body="${3-}" out hdr code
  [[ -n "$KC_REALM" ]] || die "kc_init belum dipanggil"
  [[ "$method" =~ ^(GET|POST|PUT|DELETE)$ ]] || die "metode tidak didukung: $method"
  [[ "$path" == /* && "$path" != *'..'* ]] || die "path Admin REST tidak valid: $path"
  # shellcheck disable=SC2016  # literal '${' (bukan ekspansi)
  local forbidden='${'
  if [[ -n "$body" && "$body" == *"$forbidden"* ]]; then
    die "body Admin REST memuat '\${' — diblok CRS 932130; tulis nilai literal"
  fi
  (( $(date +%s) < KC_TOKEN_EXP )) || kc_login "$KC_REALM"
  out="$(mktemp)"; hdr="$(mktemp)"
  # Authorization lewat process substitution DI BARIS curl (fd harus hidup selama curl berjalan).
  local args=("${KC_CURL_OPTS[@]}" "${KC_RESOLVE[@]}" -X "$method" -o "$out" -D "$hdr" -w '%{http_code}'
              -H 'Accept: application/json')
  if [[ -n "$body" ]]; then
    code="$(printf '%s' "$body" | curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$KC_TOKEN") \
             -H 'Content-Type: application/json' --data-binary @- \
             "${KC_BASE}/admin/realms/${KC_REALM}${path}")" || { rm -f "$out" "$hdr"; die "Admin REST ${method} ${path}: curl gagal"; }
  else
    code="$(curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$KC_TOKEN") \
             "${KC_BASE}/admin/realms/${KC_REALM}${path}")" \
      || { rm -f "$out" "$hdr"; die "Admin REST ${method} ${path}: curl gagal"; }
  fi
  KC_STATUS="$code"
  KC_BODY="$(cat "$out")"
  KC_LOCATION="$(sed -n 's/^[Ll]ocation: *//p' "$hdr" | tr -d '\r' | tail -n1)"
  rm -f "$out" "$hdr"
}

_kc_fail() { # <what> [print-body]
  local detail=""
  [[ "${2:-yes}" == yes ]] && detail=" — ${KC_BODY:0:300}"
  [[ "$KC_STATUS" == 403 && -z "$KC_BODY" ]] && detail=" — 403 kosong = kemungkinan WAF AppSec (cscli alerts list)"
  die "Admin REST $1: HTTP ${KC_STATUS}${detail}"
}

kc_get() {
  kc_request GET "$1"
  [[ "$KC_STATUS" == 200 ]] || _kc_fail "GET $1"
  printf '%s' "$KC_BODY"
}

kc_get_quiet() {
  kc_request GET "$1"
  [[ "$KC_STATUS" == 200 ]] || _kc_fail "GET $1" no
  printf '%s' "$KC_BODY"
}

# kc_send <METHOD> <path> <json|""> <expected…>
kc_send() {
  local method="$1" path="$2" body="$3" c; shift 3
  kc_request "$method" "$path" "$body"
  for c in "$@"; do [[ "$KC_STATUS" == "$c" ]] && return 0; done
  _kc_fail "${method} ${path}"
}

# kc_urlencode <string> → percent-encoding untuk query parameter
kc_urlencode() { python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
