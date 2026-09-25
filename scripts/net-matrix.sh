#!/usr/bin/env bash
# Matriks jangkauan TCP antar-container (plan 06 §2.3/§8.1/§8.2, ADR 0010, QA B15). READ-ONLY: hanya `docker exec`
# ke container yang sedang berjalan + resolve nama (3 s) lalu connect TCP ke IP (2 s) (tanpa request HTTP, tanpa perubahan
# network/container).
# Efek samping satu-satunya: Postgres mencatat "incomplete startup packet" untuk probe :5432 (sama dengan probe Analyst).
#
#   net-matrix.sh              cetak matriks (OPEN / tidak) per sumber
#   net-matrix.sh --check      cetak + bandingkan dengan target SESUDAH (plan 06 §8.2, setelah S10); exit 1 bila selisih
#   NET_MATRIX_SOURCES="a b"   batasi sumber (mis. hanya container staging untuk gerbang QA N4)
#   NET_MATRIX_TARGETS="ip:port …"  ganti daftar target (mode per-IP, tanpa DNS; QA §1c). Tidak bisa dengan --check.
#   NET_MATRIX_DNS_TIMEOUT / NET_MATRIX_TCP_TIMEOUT  detik (default 3 / 2)
#
# Sel: O = OPEN, - = ter-resolve tetapi TCP tidak (timeout / ditolak), n = nama tidak ter-resolve (DNS:*),
# ? = tidak ada hasil probe (alat gagal) — `?` SELALU dihitung selisih di --check (tidak pernah dianggap "tertutup").
# --check: `-` dan `n` sama-sama memenuhi target "tertutup". Pada masa transisi (sebelum S10) selisih yang tercetak adalah
# jalur yang belum ditutup (mis. prod sebelum S7–S9, control-plane-staging → keycloak via `proxy` sampai S8) — bukan galat.
# `traefik:8082` tidak dinilai (QA-T17B-03:
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
  *) sed -n '7,12p' "$0" >&2; exit 2 ;;
esac
if [[ -n "${NET_MATRIX_TARGETS:-}" ]]; then
  [[ "$CHECK" == yes ]] && { echo "NET_MATRIX_TARGETS tidak bisa dipakai dengan --check (target §8.2 per nama)" >&2; exit 2; }
  read -r -a TARGETS <<<"$NET_MATRIX_TARGETS"
fi

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
# Semua mencetak "host:port=<hasil>" per target, dipisah spasi. <hasil>: OPEN | timeout | <kode errno TCP>
# | DNS:<kode> (nama tidak ter-resolve: DNS:timeout, DNS:EAI_AGAIN, DNS:ENOTFOUND, DNS:fail).
# BUG-N4-01: DNS dan TCP dipisah. Semua nama di-resolve PARALEL lebih dulu, masing-masing dengan batas waktu sendiri
# ($DNS_T s) — di network `internal` lookup nama yang tidak ada menggantung ±10 s, dan dengan threadpool libuv default (4)
# lookup nama yang valid ikut mengantre → dulu semua target `timeout` (false negative). Timeout TCP ($TCP_T s) baru dimulai
# setelah alamat diketahui, connect ke IP (semua IPv4 hasil resolve; OPEN bila salah satu OPEN). Target berupa IP literal
# tidak melewati DNS (mode per-IP, NET_MATRIX_TARGETS).
DNS_T="${NET_MATRIX_DNS_TIMEOUT:-3}"; TCP_T="${NET_MATRIX_TCP_TIMEOUT:-2}"
NODE_PROBE='const net=require("net"),dns=require("dns").promises;const[DT,TT]=process.argv.slice(1,3).map(x=>x*1000);
const ts=process.argv.slice(3),hs=[...new Set(ts.map(t=>t.slice(0,t.lastIndexOf(":"))))];
const res=h=>Promise.race([dns.lookup(h,{all:true,family:4}).then(a=>({ips:[...new Set(a.map(x=>x.address))]}),e=>({err:e.code||"fail"})),
 new Promise(r=>setTimeout(()=>r({err:"timeout"}),DT))]);
const tcp=(ip,p)=>new Promise(r=>{const s=net.connect({host:ip,port:p});const k=setTimeout(()=>d("timeout"),TT);
 function d(x){clearTimeout(k);s.destroy();r(x)}s.on("connect",()=>d("OPEN"));s.on("error",e=>d(e.code||"error"))});
Promise.all(hs.map(res)).then(async rs=>{const R={};hs.forEach((h,i)=>R[h]=rs[i]);
 const o=await Promise.all(ts.map(async t=>{const i=t.lastIndexOf(":"),r=R[t.slice(0,i)];if(r.err)return t+"=DNS:"+r.err;
  const v=await Promise.all(r.ips.map(ip=>tcp(ip,+t.slice(i+1))));return t+"="+(v.includes("OPEN")?"OPEN":v[0])}));
 console.log(o.join(" "));process.exit(0)});'
# Resolusi paralel untuk bash/busybox: satu baris "host ip1 ip2" atau "host DNS:<kode>" per nama (subshell di background,
# `timeout` → DNS:timeout). Busybox di image prometheus tidak bisa me-resolve nama lewat libc (nc/wget: "bad address"),
# nslookup ke 127.0.0.11 bisa → pakai nslookup bila getent tidak ada.
# Hanya builtin sh + getent/nslookup/timeout/nc/bash: image keycloak tidak punya awk/sed/grep.
# shellcheck disable=SC2016  # dievaluasi di dalam container
RESOLVE_SH='DT=$1; shift; seen=" "; for t in "$@"; do h=${t%:*}; case "$seen" in *" $h "*) continue ;; esac; seen="$seen$h "; (
case "$h" in *[!0-9.]*) ;; *) echo "$h $h"; exit 0 ;; esac   # IP literal: tanpa DNS
if command -v getent >/dev/null 2>&1; then o=$(timeout "$DT" getent ahostsv4 "$h" 2>/dev/null); rc=$?; m=getent
else o=$(timeout "$DT" nslookup "$h" 2>/dev/null); rc=$?; m=nslookup; fi
a=""; n=0; while read -r x y z; do
  if [ $m = getent ]; then [ "$y" = STREAM ] || continue; ip=$x
  else case "$x" in Name:) n=1; continue ;; Address*) [ $n = 1 ] || continue; ip=$y; case "$y" in *:) ip=${z%% *} ;; esac ;; *) continue ;; esac; fi
  case "$ip" in *[!0-9.]*|"") continue ;; esac; case " $a " in *" $ip "*) ;; *) a="$a $ip" ;; esac
done <<EOF
$o
EOF
if [ -n "$a" ]; then echo "$h$a"; elif [ $rc -eq 124 ] || [ $rc -eq 143 ]; then echo "$h DNS:timeout"; else echo "$h DNS:fail"; fi ) & done; wait'
# shellcheck disable=SC2016
TCP_SH='TT=$1; R=$2; shift 2; for t in "$@"; do h=${t%:*}; p=${t##*:}; a=""
while read -r hh rest; do [ "$hh" = "$h" ] && a=$rest; done <<EOF
$R
EOF
case "$a" in DNS:*) r=$a ;; "") r=DNS:fail ;; *) r=closed; for ip in $a; do
  if [ "$TOOL" = bash ]; then timeout "$TT" bash -c "exec 3<>/dev/tcp/$ip/$p" 2>/dev/null && r=OPEN
  else nc -z -w "$TT" "$ip" "$p" 2>/dev/null && r=OPEN; fi; done ;; esac; printf "%s=%s " "$t" "$r"; done; echo'

has() { docker exec "$1" sh -c "command -v $2" >/dev/null 2>&1; }

probe() { # probe <container> → baris hasil
  local c="$1" tool r
  if has "$c" node; then
    # UV_THREADPOOL_SIZE: cadangan bila dns.lookup tetap lewat threadpool (satu thread per nama unik).
    docker exec -e UV_THREADPOOL_SIZE=64 "$c" node -e "$NODE_PROBE" "$DNS_T" "$TCP_T" "${TARGETS[@]}" 2>/dev/null; return
  elif has "$c" bash; then tool=bash
  elif has "$c" nc; then tool=nc
  else echo "NO-PROBE-TOOL"; return; fi
  # stderr dibuang: bash/busybox mencetak "Terminated" untuk proses yang di-kill `timeout`.
  r="$(docker exec "$c" sh -c "$RESOLVE_SH" resolve "$DNS_T" "${TARGETS[@]}" 2>/dev/null)"
  docker exec -e TOOL="$tool" "$c" sh -c "$TCP_SH" probe "$TCP_T" "$r" "${TARGETS[@]}" 2>/dev/null
}

rc=0
printf '# net-matrix %s (docker exec, DNS %s s lalu TCP connect ke IP %s s)\n' "$(date -Is)" "$DNS_T" "$TCP_T"
printf '# kolom: %s\n' "${TARGETS[*]}"
for c in $SOURCES; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]]; then echo "[$c] SKIP (tidak berjalan)"; continue; fi
  line="$(probe "$c")"
  row=""; diff=""
  for t in "${TARGETS[@]}"; do
    v="$(tr ' ' '\n' <<<"$line" | sed -n "s/^${t}=//p" | head -n1)"
    case "$v" in OPEN) cell=O ;; DNS:*) cell=n ;; "") cell="?" ;; *) cell=- ;; esac
    if [[ "$CHECK" == yes ]]; then
      if [[ " $IGNORED " == *" $t "* ]]; then cell="~"
      else
        want=-   # EXPECT bisa memuat newline (traefik) → normalisasi spasi
        [[ " $(tr -s ' \n' '  ' <<<"${EXPECT[$c]:-}") " == *" $t "* ]] && want=O
        got=$cell; [[ "$got" == n ]] && got=-   # tidak ter-resolve = tertutup; `?` tidak pernah cocok
        if [[ "$got" != "$want" ]]; then diff+=" ${t}(want=${want},got=${cell}${v:+/$v})"; rc=1; fi
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
