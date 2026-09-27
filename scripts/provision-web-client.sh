#!/usr/bin/env bash
# Provision website Next.js client (plan 03 W2) — satu perintah: stack compose + router Traefik. IDEMPOTEN.
#
#   scripts/provision-web-client.sh <slug> <prod|staging> --host <fqdn> --image <ref> [--www]
#       [--contact --smtp-host <fqdn> --smtp-user <email> --smtp-from <email> [--smtp-port <port>]
#        [--turnstile-site-key <key>]]
#       [--umami-script-url <https-url> --umami-website-id <uuid>]
#   scripts/provision-web-client.sh <slug> <prod|staging> --remove
#
# Urutan provision:
#   1. validasi argumen (slug lib/odoo-pools.sh, FQDN, image WAJIB tag pin/digest — tolak `latest`/tanpa tag);
#   2. DNS pre-check host (+ www.<host> bila --www): A = IP VPS, tanpa AAAA (lib/traefik-route.sh, ADR 0002 #5);
#   3. hostname belum dipakai router lain di traefik/dynamic/**;
#   4. render stack dari templates/web-client/ ke web/clients/<slug>/ (prod) | staging/web-clients/<slug>/
#      (staging): docker-compose*.yml + .gitignore disalin apa adanya, .env (600, tanpa secret) dibuat;
#   5. `docker compose up -d` (hanya bila stack berubah atau container tidak running/healthy), tunggu healthy;
#   6. render route templates/traefik-web-client.yml → traefik/dynamic/clients/web-<slug>-<env>.yml
#      SETELAH container healthy; isi identik → tidak ditulis, tidak HUP; berubah → `docker exec traefik kill -HUP 1`
#      (H7: JANGAN `docker kill --signal`, docs/03-operations/traefik.md);
#   7. smoke test lewat Traefik: curl --resolve <host>:443:127.0.0.1 https://<host>/api/health → 200 (TLS diverifikasi).
# --remove: hapus route + HUP, `docker compose down` (TANPA -v), direktori render dipertahankan + penanda `.removed`.
# Form kontak (--contact): password SMTP TIDAK lewat argumen — taruh dulu di <dir>/secrets/smtp_password.secret
# (runbook docs/runbooks/web-client-onboarding.md §Form kontak); skrip men-set owner 1001:1001 mode 0400.
# Turnstile (--turnstile-site-key, hanya bersama --contact): secret key di <dir>/secrets/turnstile_secret.secret
# (sama perlakuannya); site key publik → .env. Tanpa flag → override turnstile tidak dimuat (OFF).
# Analytics Umami (plan 11 §3.7, ADR 0013; default OFF): --umami-script-url + --umami-website-id BERPASANGAN → .env
# UMAMI_SCRIPT_URL/UMAMI_WEBSITE_ID (bukan secret) + override docker-compose.umami.yml di COMPOSE_FILE. Tanpa flag → .env &
# COMPOSE_FILE identik dengan sebelumnya (website tidak di-recreate).
# Output baris terakhir: RESULT host=<fqdn|-> container=<nama> route=<file> changed=<yes|no|removed>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/odoo-pools.sh
source "$SCRIPT_DIR/lib/odoo-pools.sh"      # INFRA_DIR, TRAEFIK_*, SLUG_RE, FQDN_RE, die, validate_host
# shellcheck source=lib/traefik-route.sh
source "$SCRIPT_DIR/lib/traefik-route.sh"   # VPS_IP, dns_precheck, traefik_hup

# Template dibaca dari repo tempat skrip berada; output selalu ke $INFRA_DIR (yang di-mount Traefik).
TEMPLATE_DIR="$SCRIPT_DIR/../templates"
COMPOSE_TEMPLATE_DIR="$TEMPLATE_DIR/web-client"
ROUTE_TEMPLATE="$TEMPLATE_DIR/traefik-web-client.yml"
MARKER="# DIRENDER OTOMATIS oleh scripts/provision-web-client.sh"
HEALTH_TIMEOUT=120   # detik menunggu container healthy
SMOKE_TIMEOUT=120    # detik menunggu 200 lewat Traefik (termasuk penerbitan sertifikat HTTP-01 pertama)

# Referensi image: [registry[:port]/]nama[/nama...][:tag][@sha256:<64hex>] — minimal tag ATAU digest.
IMAGE_RE='^([a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/)?[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(@sha256:[a-f0-9]{64})?$'
EMAIL_RE='^[A-Za-z0-9._%+-]{1,64}@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

usage() {
  cat >&2 <<EOF
pemakaian: $0 <slug> <prod|staging> --host <fqdn> --image <ref> [--www]
             [--contact --smtp-host <fqdn> --smtp-user <email> --smtp-from <email> [--smtp-port <port>]
              [--turnstile-site-key <key>]]
             [--lead-webhook <https-url>]
             [--umami-script-url <https-url> --umami-website-id <uuid>]
           $0 <slug> <prod|staging> --remove
EOF
  exit 2
}

[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
[[ "$1" =~ $SLUG_RE ]] || die "slug tidak valid: harus cocok $SLUG_RE"
[[ "$2" =~ ^(prod|staging)$ ]] || die "env tidak valid: harus prod|staging"
SLUG="$1"; WEB_ENV="$2"; shift 2

HOST=""; IMAGE=""; WWW=no; CONTACT=no; REMOVE=no
SMTP_HOST=""; SMTP_PORT=587; SMTP_USER=""; SMTP_FROM=""
TURNSTILE_SITE_KEY=""   # opsional (bct G-43): Cloudflare Turnstile, butuh --contact + secrets/turnstile_secret.secret
UMAMI_SCRIPT_URL=""; UMAMI_WEBSITE_ID=""   # opsional (plan 11): web analytics Umami, berpasangan
LEAD_WEBHOOK=""   # opsional (bct 2026-09-26): URL webhook lead tambahan; .env 600 root, tidak di git (URL bisa memuat token)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage; HOST="$2"; shift 2 ;;
    --image) [[ $# -ge 2 ]] || usage; IMAGE="$2"; shift 2 ;;
    --www) WWW=yes; shift ;;
    --contact) CONTACT=yes; shift ;;
    --smtp-host) [[ $# -ge 2 ]] || usage; SMTP_HOST="$2"; shift 2 ;;
    --smtp-port) [[ $# -ge 2 ]] || usage; SMTP_PORT="$2"; shift 2 ;;
    --smtp-user) [[ $# -ge 2 ]] || usage; SMTP_USER="$2"; shift 2 ;;
    --smtp-from) [[ $# -ge 2 ]] || usage; SMTP_FROM="$2"; shift 2 ;;
    --lead-webhook) [[ $# -ge 2 ]] || usage; LEAD_WEBHOOK="$2"; shift 2 ;;
    --turnstile-site-key) [[ $# -ge 2 ]] || usage; TURNSTILE_SITE_KEY="$2"; shift 2 ;;
    --umami-script-url) [[ $# -ge 2 ]] || usage; UMAMI_SCRIPT_URL="$2"; shift 2 ;;
    --umami-website-id) [[ $# -ge 2 ]] || usage; UMAMI_WEBSITE_ID="$2"; shift 2 ;;
    --remove) REMOVE=yes; shift ;;
    *) usage ;;
  esac
done

if [[ -n "$LEAD_WEBHOOK" ]]; then
  [[ "$LEAD_WEBHOOK" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+@:-]*)?(\?[A-Za-z0-9._~%&=+/:@-]*)?$ ]] \
    || die "--lead-webhook harus URL https tanpa spasi/karakter khusus"
fi

ROUTE="web-${SLUG}-${WEB_ENV}"          # nama router/service Traefik = container_name = project compose
case "$WEB_ENV" in
  prod) STACK_DIR="$INFRA_DIR/web/clients/$SLUG" ;;
  staging) STACK_DIR="$INFRA_DIR/staging/web-clients/$SLUG" ;;
esac
OUT="$TRAEFIK_CLIENTS_DIR/${ROUTE}.yml"

exec 9>"/run/lock/web-client-${ROUTE}.lock"
flock -n 9 || die "provision ${ROUTE} sedang berjalan (lock)"

# File route bisa bentrok nama dengan render-client-route.sh (slug Odoo `web-…`) → jangan sentuh milik skrip lain.
if [[ -f "$OUT" ]] && ! grep -q "^${MARKER}" "$OUT"; then
  die "$OUT ada tetapi bukan hasil provision-web-client.sh — tidak disentuh"
fi

# COMPOSE_FILE (di .env) di-resolve relatif ke cwd, BUKAN ke --project-directory → jalankan dari direktori stack.
compose() { (cd "$STACK_DIR" && docker compose "$@"); }

container_state() {   # → "<status> <health>" atau "absent"
  local s
  # docker inspect mencetak baris kosong ke stdout bila container tidak ada → pakai exit code, bukan output.
  if s="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ROUTE" 2>/dev/null)"; then
    echo "$s"
  else
    echo absent
  fi
}

# ------------------------------------------------------------------------------------------------ remove
if [[ "$REMOVE" == yes ]]; then
  [[ -z "$HOST$IMAGE$UMAMI_SCRIPT_URL$UMAMI_WEBSITE_ID" && "$WWW$CONTACT" == nono ]] || die "--remove tidak menerima opsi lain"
  changed=no
  if [[ -e "$OUT" ]]; then
    rm -f -- "$OUT"; traefik_hup "$ROUTE"; changed=removed
  fi
  if [[ "$(container_state)" != absent ]]; then
    [[ -f "$STACK_DIR/docker-compose.yml" && -f "$STACK_DIR/.env" ]] \
      || die "container ${ROUTE} ada tetapi stack ${STACK_DIR} tidak lengkap — periksa manual"
    # TANPA -v: volume/data tidak pernah dihapus skrip ini.
    compose down
    changed=removed
  fi
  [[ "$(container_state)" == absent ]] || die "container ${ROUTE} masih ada setelah compose down"
  if [[ -d "$STACK_DIR" && ! -e "$STACK_DIR/.removed" ]]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$STACK_DIR/.removed"
  fi
  echo "RESULT host=- container=${ROUTE} route=${OUT} changed=${changed}"
  exit 0
fi

# ------------------------------------------------------------------------------------------------ validasi
[[ -n "$HOST" && -n "$IMAGE" ]] || usage
validate_host "$HOST"
WWW_HOST="www.${HOST}"
if [[ "$WWW" == yes ]]; then
  [[ "$HOST" != www.* ]] || die "--www: --host harus host kanonik tanpa www (${HOST})"
  validate_host "$WWW_HOST"
fi
[[ ${#IMAGE} -le 255 && "$IMAGE" =~ $IMAGE_RE ]] || die "image tidak valid: ${IMAGE}"
[[ "$IMAGE" =~ (:[A-Za-z0-9_][A-Za-z0-9_.-]*|@sha256:[a-f0-9]{64})$ && ! "${IMAGE##*/}" =~ ^[^:@]+$ ]] \
  || die "image wajib tag pin atau digest (tanpa tag = latest): ${IMAGE}"
tag="${IMAGE##*/}"; tag="${tag%%@*}"
if [[ "$tag" == *:* ]]; then
  tag="${tag#*:}"
  [[ "${tag,,}" != latest ]] || die "image tag 'latest' dilarang (CLAUDE.md §0.12): ${IMAGE}"
fi

SECRET_FILE="$STACK_DIR/secrets/smtp_password.secret"
if [[ "$CONTACT" == yes ]]; then
  [[ -n "$SMTP_HOST" && -n "$SMTP_USER" && -n "$SMTP_FROM" ]] \
    || die "--contact butuh --smtp-host, --smtp-user, --smtp-from"
  validate_host "$SMTP_HOST"
  [[ "$SMTP_PORT" =~ ^(25|465|587)$ ]] || die "--smtp-port harus 25|465|587"
  [[ "$SMTP_USER" =~ $EMAIL_RE ]] || die "--smtp-user bukan alamat email valid"
  [[ "$SMTP_FROM" =~ $EMAIL_RE ]] || die "--smtp-from bukan alamat email valid"
  [[ -s "$SECRET_FILE" ]] || die "--contact: file password SMTP belum ada: ${SECRET_FILE} (lihat runbook)"
elif [[ -n "$SMTP_HOST$SMTP_USER$SMTP_FROM" ]]; then
  die "--smtp-* hanya bersama --contact"
fi
TURNSTILE_SECRET="$STACK_DIR/secrets/turnstile_secret.secret"
if [[ -n "$TURNSTILE_SITE_KEY" ]]; then
  [[ "$CONTACT" == yes ]] || die "--turnstile-site-key hanya bersama --contact"
  [[ "$TURNSTILE_SITE_KEY" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || die "--turnstile-site-key tidak valid"
  # Keduanya atau tidak sama sekali (aplikasi exit 1 bila hanya satu): secret wajib ada bila site key diberikan.
  [[ -s "$TURNSTILE_SECRET" ]] || die "--turnstile-site-key: file secret belum ada: ${TURNSTILE_SECRET} (lihat runbook)"
elif [[ -s "$TURNSTILE_SECRET" ]]; then
  echo "catatan: ${TURNSTILE_SECRET} ada tapi --turnstile-site-key tidak diberikan → Turnstile OFF (secret tidak di-mount)" >&2
fi

# Umami (plan 11 §3.7): keduanya atau tidak sama sekali; regex = kontrak env app (Zod) — URL https ke file .js, UUID huruf kecil.
if [[ -n "$UMAMI_SCRIPT_URL$UMAMI_WEBSITE_ID" ]]; then
  [[ -n "$UMAMI_SCRIPT_URL" && -n "$UMAMI_WEBSITE_ID" ]] \
    || die "--umami-script-url dan --umami-website-id harus diberikan berpasangan"
  [[ ${#UMAMI_SCRIPT_URL} -le 255 && "$UMAMI_SCRIPT_URL" =~ ^https://[a-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._-]+\.js$ ]] \
    || die "--umami-script-url harus https://<host>[:port]/<nama>.js (mis. https://analytics.bimacreative.tech/insight.js)"
  [[ "$UMAMI_WEBSITE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || die "--umami-website-id harus UUID huruf kecil (Website ID dari UI Umami)"
fi

for f in "$COMPOSE_TEMPLATE_DIR/docker-compose.yml" "$COMPOSE_TEMPLATE_DIR/docker-compose.contact.yml" \
         "$COMPOSE_TEMPLATE_DIR/docker-compose.turnstile.yml" "$COMPOSE_TEMPLATE_DIR/docker-compose.umami.yml" \
         "$COMPOSE_TEMPLATE_DIR/.gitignore" "$ROUTE_TEMPLATE"; do
  [[ -f "$f" ]] || die "template tidak ada: $f"
done

# ------------------------------------------------------------------------------------------------ network
# W2b: website HANYA di network `web-edge` (traefik/scripts/bootstrap.sh). Tanpa network atau tanpa traefik di
# dalamnya, container tidak bisa dijangkau (502) → gagal lebih awal, sebelum menulis apa pun.
WEB_NETWORK=web-edge
docker network inspect "$WEB_NETWORK" >/dev/null 2>&1 \
  || die "network ${WEB_NETWORK} tidak ada — jalankan /opt/infra/traefik/scripts/bootstrap.sh (docs/03-operations/traefik.md §Network web-edge)"
traefik_nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$TRAEFIK_CONTAINER" 2>/dev/null)" \
  || die "container ${TRAEFIK_CONTAINER} tidak ada"
[[ " ${traefik_nets}" == *" ${WEB_NETWORK} "* ]] \
  || die "${TRAEFIK_CONTAINER} belum terhubung ke ${WEB_NETWORK} — \`docker network connect ${WEB_NETWORK} ${TRAEFIK_CONTAINER}\` (tanpa recreate; lihat traefik.md)"

# ------------------------------------------------------------------------------------------------ DNS + unik
dns_precheck "$HOST"
[[ "$WWW" == no ]] || dns_precheck "$WWW_HOST"

check_host_unused() {
  local h="$1" hits
  hits="$(grep -rl -F --include='*.yml' "Host(\`${h}\`)" "$INFRA_DIR/traefik/dynamic" 2>/dev/null | grep -v -x -F "$OUT" || true)"
  [[ -z "$hits" ]] || die "hostname ${h} sudah dipakai router di: ${hits//$'\n'/ }"
}
check_host_unused "$HOST"
[[ "$WWW" == no ]] || check_host_unused "$WWW_HOST"

# ------------------------------------------------------------------------------------------------ stack
changed=no
stack_changed=no
install -d -o root -g root -m 0755 "$STACK_DIR"

# install_if_changed <src> <dst> <mode>
install_if_changed() {
  if [[ -f "$2" ]] && cmp -s "$1" "$2"; then
    chmod "$3" "$2"; return 0
  fi
  install -o root -g root -m "$3" "$1" "$2"
  stack_changed=yes
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

compose_files="docker-compose.yml"
[[ "$CONTACT" == no ]] || compose_files="docker-compose.yml:docker-compose.contact.yml"
[[ -z "$TURNSTILE_SITE_KEY" ]] || compose_files="${compose_files}:docker-compose.turnstile.yml"
[[ -z "$UMAMI_WEBSITE_ID" ]] || compose_files="${compose_files}:docker-compose.umami.yml"
{
  echo "${MARKER} — jangan edit manual (render ulang). Tidak ada secret."
  echo "COMPOSE_PROJECT_NAME=${ROUTE}"
  echo "COMPOSE_FILE=${compose_files}"
  echo "WEB_CONTAINER=${ROUTE}"
  echo "WEB_IMAGE=${IMAGE}"
  echo "SITE_URL=https://${HOST}"
  echo "CONTACT_ENABLED=$([[ "$CONTACT" == yes ]] && echo true || echo false)"
  if [[ "$CONTACT" == yes ]]; then
    echo "SMTP_HOST=${SMTP_HOST}"
    echo "SMTP_PORT=${SMTP_PORT}"
    echo "SMTP_USER=${SMTP_USER}"
    echo "SMTP_FROM_ADDRESS=${SMTP_FROM}"
  fi
  [[ -z "$LEAD_WEBHOOK" ]] || echo "LEAD_WEBHOOK_URL=${LEAD_WEBHOOK}"
  [[ -z "$TURNSTILE_SITE_KEY" ]] || echo "TURNSTILE_SITE_KEY=${TURNSTILE_SITE_KEY}"
  if [[ -n "$UMAMI_WEBSITE_ID" ]]; then
    echo "UMAMI_SCRIPT_URL=${UMAMI_SCRIPT_URL}"
    echo "UMAMI_WEBSITE_ID=${UMAMI_WEBSITE_ID}"
  fi
} > "$tmpdir/env"

install_if_changed "$COMPOSE_TEMPLATE_DIR/docker-compose.yml" "$STACK_DIR/docker-compose.yml" 0644
install_if_changed "$COMPOSE_TEMPLATE_DIR/docker-compose.contact.yml" "$STACK_DIR/docker-compose.contact.yml" 0644
install_if_changed "$COMPOSE_TEMPLATE_DIR/docker-compose.turnstile.yml" "$STACK_DIR/docker-compose.turnstile.yml" 0644
install_if_changed "$COMPOSE_TEMPLATE_DIR/docker-compose.umami.yml" "$STACK_DIR/docker-compose.umami.yml" 0644
install_if_changed "$COMPOSE_TEMPLATE_DIR/.gitignore" "$STACK_DIR/.gitignore" 0644
install_if_changed "$tmpdir/env" "$STACK_DIR/.env" 0600
if [[ "$CONTACT" == yes ]]; then
  chmod 0700 "$STACK_DIR/secrets"
  # Compose non-swarm mem-bind file apa adanya → owner harus uid container (1001).
  chown 1001:1001 "$SECRET_FILE"; chmod 0400 "$SECRET_FILE"
  if [[ -n "$TURNSTILE_SITE_KEY" ]]; then chown 1001:1001 "$TURNSTILE_SECRET"; chmod 0400 "$TURNSTILE_SECRET"; fi
fi
if [[ -e "$STACK_DIR/.removed" ]]; then rm -f -- "$STACK_DIR/.removed"; stack_changed=yes; fi

compose config --quiet || die "docker compose config gagal untuk ${STACK_DIR}"

state="$(container_state)"
if [[ "$stack_changed" == yes || "$state" != "running healthy" ]]; then
  echo "stack ${ROUTE}: up -d (berubah=${stack_changed}, state=${state})" >&2
  compose up -d
  changed=yes
fi

deadline=$((SECONDS + HEALTH_TIMEOUT))
while :; do
  state="$(container_state)"
  [[ "$state" == "running healthy" ]] && break
  if [[ $SECONDS -ge $deadline || "$state" == "running unhealthy" || "$state" == exited* ]]; then
    docker logs --tail 50 "$ROUTE" >&2 || true
    die "container ${ROUTE} tidak healthy (${state}) — route TIDAK ditulis; rollback: runbook web-client-onboarding"
  fi
  sleep 2
done

# ------------------------------------------------------------------------------------------------ route
host_re="${HOST//./\\\\.}"   # sed replacement '\\.' → hasil '\.'
{
  echo "${MARKER} dari templates/traefik-web-client.yml — jangan edit manual."
  sed -e '1,/^# Website:/{/^# Website:/!d}' "$ROUTE_TEMPLATE"
} > "$tmpdir/route.in"
if [[ "$WWW" == yes ]]; then
  sed -i -e '/^# >>> www$/d' -e '/^# <<< www$/d' "$tmpdir/route.in"
else
  sed -i -e '/^# >>> www$/,/^# <<< www$/d' "$tmpdir/route.in"
fi
# Semua nilai sudah lolos regex: tidak mengandung '|', '&', '\' atau baris baru.
sed -e "s|__HOST_RE__|${host_re}|g" -e "s|__ROUTE__|${ROUTE}|g" -e "s|__HOST__|${HOST}|g" \
    -e "s|__WWW__|${WWW_HOST}|g" -e "s|__SLUG__|${SLUG}|g" -e "s|__ENV__|${WEB_ENV}|g" \
    -e "s|__GENERATED__|oleh provision-web-client.sh|g" "$tmpdir/route.in" > "$tmpdir/route"
if grep -q '__[A-Z_]*__' "$tmpdir/route"; then die "placeholder tersisa di hasil render"; fi
python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$tmpdir/route" || die "hasil render bukan YAML valid"

if [[ -f "$OUT" ]] && cmp -s "$tmpdir/route" "$OUT"; then
  :
else
  install -d -o root -g root -m 0755 "$TRAEFIK_CLIENTS_DIR"
  install -o root -g root -m 0644 "$tmpdir/route" "$OUT.tmp"
  mv -f -- "$OUT.tmp" "$OUT"
  traefik_hup "$ROUTE"
  changed=yes
fi

# ------------------------------------------------------------------------------------------------ smoke test
# Lewat Traefik di host ini (bukan DNS publik), TLS diverifikasi (tanpa -k) → sertifikat LE harus sudah terbit.
smoke() {   # smoke <host> <path> → "<http_code> <redirect_url>"
  curl -sS -o /dev/null --max-time 10 --resolve "$1:443:127.0.0.1" \
    -w '%{http_code} %{redirect_url}' "https://$1$2" 2>/dev/null || true
}
deadline=$((SECONDS + SMOKE_TIMEOUT))
until [[ "$(smoke "$HOST" /api/health)" == "200 " ]]; do
  if [[ $SECONDS -ge $deadline ]]; then
    insecure="$(curl -sk -o /dev/null --max-time 10 --resolve "$HOST:443:127.0.0.1" -w '%{http_code}' "https://$HOST/api/health" || true)"
    die "smoke test gagal: https://${HOST}/api/health tidak 200 dengan TLS valid dalam ${SMOKE_TIMEOUT}s (tanpa verifikasi TLS: ${insecure}) — cek log ACME: docker logs traefik"
  fi
  sleep 5
done
echo "smoke: https://${HOST}/api/health → 200 (TLS valid)" >&2
if [[ "$WWW" == yes ]]; then
  expect="301 https://${HOST}/api/health"
  deadline=$((SECONDS + SMOKE_TIMEOUT))
  until [[ "$(smoke "$WWW_HOST" /api/health)" == "$expect" ]]; do
    [[ $SECONDS -lt $deadline ]] || die "smoke test gagal: https://${WWW_HOST}/api/health ≠ '${expect}' ($(smoke "$WWW_HOST" /api/health))"
    sleep 5
  done
  echo "smoke: https://${WWW_HOST}/api/health → ${expect}" >&2
fi

echo "RESULT host=${HOST} container=${ROUTE} route=${OUT} changed=${changed}"
