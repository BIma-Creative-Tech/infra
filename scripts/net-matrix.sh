#!/usr/bin/env bash
# Matriks jangkauan TCP antar-container (plan 06 §2.3/§8.1/§8.2, ADR 0010, QA B15). READ-ONLY: hanya `docker exec`
# ke container yang sedang berjalan + connect TCP 2 s (tanpa request HTTP, tanpa perubahan network/container).
# Efek samping satu-satunya: Postgres mencatat "incomplete startup packet" untuk probe :5432 (sama dengan probe Analyst).
#
#   net-matrix.sh              cetak matriks (OPEN / tidak) per sumber
#   net-matrix.sh --check      cetak + bandingkan dengan target SESUDAH (plan 06 §8.2, setelah S10); exit 1 bila selisih
#   NET_MATRIX_SOURCES="a b"   batasi sumber (mis. hanya container staging untuk gerbang QA N4)
#
# Sel: O = OPEN, - = tidak (timeout / ditolak / nama tidak ter-resolve). `traefik:8082` tidak dinilai (QA-T17B-03:
# entrypoint metrics terbuka TCP di semua network Traefik, dibatasi ipAllowList → 403) → ditandai `~` di mode --check.
# Container sumber yang tidak berjalan dilewati (dicetak SKIP). Exit: 0 OK, 1 ada selisih (--check), 2 pemakaian.
set -uo pipefail

TARGETS=(odoo-pool-a:8069 odoo-pool-a:8072 odoo-staging:8069 odoo-staging:8072 keycloak:8080 keycloak:9000
         postgres:5432 control-plane:3000 control-plane-staging:3000 drms-pk-stg:3000 grafana:3000 uptime-kuma:3001
         traefik:8082)
DEFAULT_SOURCES="drms-pk-stg drms-pk-stg-worker control-plane control-plane-worker control-plane-staging
  control-plane-staging-worker uptime-kuma grafana odoo-pool-a odoo-staging keycloak traefik prometheus"
SOURCES="${NET_MATRIX_SOURCES:-$DEFAULT_SOURCES}"
IGNORED="traefik:8082"

CHECK=no
case "${1:-}" in
  "") ;;
  --check) CHECK=yes ;;
  *) sed -n '5,8p' "$0" >&2; exit 2 ;;
esac

# Target SESUDAH (plan 06 §8.2): target yang BOLEH/HARUS OPEN per sumber; selain itu harus tertutup.
# Koreksi terhadap tabel §8.2: worker dan web aplikasi yang SAMA berbagi `db-<konsumen>` (satu trust boundary, §3.2)
# → control-plane(-staging)-worker → control-plane(-staging):3000 dan drms-pk-stg-worker → drms-pk-stg:3000 = OPEN;
# prometheus → grafana:3000 = OPEN (network `observability`).
# R1 = residual `proxy` (plan 07), R2 = residual `metrics` (plan 06 §4.1 d).
declare -A EXPECT=(
  [drms-pk-stg]="postgres:5432 drms-pk-stg:3000"
  [drms-pk-stg-worker]="postgres:5432 drms-pk-stg:3000"
  [control-plane]="postgres:5432 control-plane:3000 control-plane-staging:3000 grafana:3000 uptime-kuma:3001"
  [control-plane-staging]="postgres:5432 control-plane:3000 control-plane-staging:3000 grafana:3000 uptime-kuma:3001"
  [control-plane-worker]="postgres:5432 control-plane:3000"
  [control-plane-staging-worker]="postgres:5432 control-plane-staging:3000"
  [uptime-kuma]="control-plane:3000 control-plane-staging:3000 grafana:3000 uptime-kuma:3001"
  [grafana]="control-plane:3000 control-plane-staging:3000 grafana:3000 uptime-kuma:3001"
  [odoo-pool-a]="odoo-pool-a:8069 odoo-pool-a:8072 postgres:5432"
  [odoo-staging]="odoo-staging:8069 odoo-staging:8072 postgres:5432"
  [keycloak]="keycloak:8080 keycloak:9000 postgres:5432"
  [traefik]="odoo-pool-a:8069 odoo-pool-a:8072 odoo-staging:8069 odoo-staging:8072 keycloak:8080 keycloak:9000
             control-plane:3000 control-plane-staging:3000 drms-pk-stg:3000 grafana:3000 uptime-kuma:3001"
  # prometheus ↔ grafana berbagi `observability` (di luar scope plan 06, tidak berubah; tabel §8.2 menulis "–").
  [prometheus]="keycloak:8080 keycloak:9000 grafana:3000"
)

# Probe di dalam container dengan alat yang tersedia di image: node → bash /dev/tcp → busybox nc.
# Semua mencetak "host:port=OPEN|<alasan>" per target, dipisah spasi.
NODE_PROBE='const net=require("net");const ts=process.argv.slice(1);let o=[],n=ts.length;ts.forEach((t,i)=>{const[h,p]=t.split(":");
const s=net.connect({host:h,port:+p,timeout:2000});const d=r=>{o[i]=t+"="+r;s.destroy();if(--n==0)console.log(o.join(" "))};
s.on("connect",()=>d("OPEN"));s.on("timeout",()=>d("timeout"));s.on("error",e=>d(e.code))});'
# shellcheck disable=SC2016  # dievaluasi di dalam container
BASH_PROBE='for t in "$@"; do h=${t%:*}; p=${t#*:}; if timeout 2 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then r=OPEN; else r=closed; fi; printf "%s=%s " "$t" "$r"; done; echo'
# shellcheck disable=SC2016
# Busybox di image prometheus tidak bisa me-resolve nama lewat libc (nc/wget: "bad address"), nslookup ke 127.0.0.11
# bisa → resolve dulu dengan nslookup (alamat jawaban terakhir), lalu nc ke IP.
NC_PROBE='for t in "$@"; do h=${t%:*}; p=${t#*:}; a=$(nslookup "$h" 2>/dev/null | awk "/^Name:/{n=1} n&&/^Address/{a=\$2} END{print a}");
if [ -z "$a" ]; then r=ENOTFOUND; elif nc -z -w 2 "$a" "$p" 2>/dev/null; then r=OPEN; else r=closed; fi; printf "%s=%s " "$t" "$r"; done; echo'

has() { docker exec "$1" sh -c "command -v $2" >/dev/null 2>&1; }

probe() { # probe <container> → baris hasil
  local c="$1"
  # stderr dibuang: bash mencetak "Terminated" untuk probe yang di-kill `timeout`.
  if has "$c" node; then docker exec "$c" node -e "$NODE_PROBE" "${TARGETS[@]}" 2>/dev/null
  elif has "$c" bash; then docker exec "$c" bash -c "$BASH_PROBE" probe "${TARGETS[@]}" 2>/dev/null
  elif has "$c" nc; then docker exec "$c" sh -c "$NC_PROBE" probe "${TARGETS[@]}" 2>/dev/null
  else echo "NO-PROBE-TOOL"; fi
}

rc=0
printf '# net-matrix %s (docker exec, TCP connect 2 s)\n' "$(date -Is)"
printf '# kolom: %s\n' "${TARGETS[*]}"
for c in $SOURCES; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]]; then echo "[$c] SKIP (tidak berjalan)"; continue; fi
  line="$(probe "$c")"
  row=""; diff=""
  for t in "${TARGETS[@]}"; do
    v="$(tr ' ' '\n' <<<"$line" | sed -n "s/^${t}=//p" | head -n1)"
    if [[ "$v" == OPEN ]]; then cell=O; else cell=-; fi
    if [[ "$CHECK" == yes ]]; then
      if [[ " $IGNORED " == *" $t "* ]]; then cell="~"
      else
        want=-   # EXPECT bisa memuat newline (traefik) → normalisasi spasi
        [[ " $(tr -s ' \n' '  ' <<<"${EXPECT[$c]:-}") " == *" $t "* ]] && want=O
        if [[ "$cell" != "$want" ]]; then diff+=" ${t}(want=${want},got=${cell}${v:+/$v})"; rc=1; fi
      fi
    fi
    row+="$cell "
  done
  printf '[%s] %s\n' "$c" "$row"
  [[ "$CHECK" == yes && -z "${EXPECT[$c]+x}" ]] && echo "   (tidak ada target di §8.2 untuk $c)"
  [[ -n "$diff" ]] && echo "   SELISIH:$diff"
  [[ "$CHECK" == no ]] && printf '   %s\n' "$line"
done
if [[ "$CHECK" == yes ]]; then
  if [[ $rc -eq 0 ]]; then echo "RESULT: OK (sesuai plan 06 §8.2)"; else echo "RESULT: SELISIH terhadap plan 06 §8.2"; fi
fi
exit "$rc"
