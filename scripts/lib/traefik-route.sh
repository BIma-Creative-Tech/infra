# shellcheck shell=bash
# Fungsi bersama untuk skrip yang menulis router Traefik di traefik/dynamic/clients/
# (render-client-route.sh — tenant Odoo; provision-web-client.sh — website Next.js).
# Di-source SETELAH lib/odoo-pools.sh (butuh: die, TRAEFIK_CONTAINER). Tidak ada secret di file ini.

# IP publik VPS (ADR 0002). Satu-satunya target A record yang diterima pre-check.
VPS_IP="31.97.50.221"

# dns_precheck <fqdn>
# ADR 0002 #5 / CLAUDE.md §3.5.1: A <fqdn> = VPS_IP di 1.1.1.1 dan 8.8.8.8 (minimal satu menjawab, tidak
# ada jawaban lain), tanpa AAAA — mencegah kegagalan ACME berulang (rate limit LE). CNAME diikuti oleh
# resolver; hanya baris IPv4 yang dibandingkan. Gagal → die.
dns_precheck() {
  local host="$1" r a aaaa ok=0
  for r in 1.1.1.1 8.8.8.8; do
    a="$(dig +short +time=3 +tries=2 A "$host" "@$r" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ' || true)"
    aaaa="$(dig +short +time=3 +tries=2 AAAA "$host" "@$r" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)"   # hanya baris IPv6; abaikan ';; communications error ...' dari dig
    [[ -z "$aaaa" ]] || die "DNS: ${host} punya AAAA di @$r (${aaaa}) — IPv4-only (ADR 0002 #4)"
    if [[ -z "$a" ]]; then echo "DNS: @$r tidak menjawab/kosong untuk ${host}" >&2; continue; fi
    [[ "$a" == "${VPS_IP} " ]] || die "DNS: A ${host} @$r = '${a% }' ≠ ${VPS_IP}"
    ok=$((ok+1))
  done
  [[ $ok -ge 1 ]] || die "DNS pre-check gagal: tidak ada resolver yang mengembalikan A ${host} = ${VPS_IP}"
}

# traefik_hup <nama-router-untuk-grep-log>
# File di subdirektori dynamic/ tidak di-watch → reload dengan SIGHUP ke PID 1 DI DALAM container.
# H7: JANGAN `docker kill --signal=HUP` — men-set HasBeenManuallyStopped=true + membatalkan restart
# manager (moby daemon/kill.go) → container tidak start setelah reboot (docs/03-operations/traefik.md).
# Traefik tidak punya API aktif (dashboard off) → cek log error konfigurasi sejak HUP.
traefik_hup() {
  local route="$1" since
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker exec "$TRAEFIK_CONTAINER" kill -HUP 1
  sleep 3
  if docker logs --since "$since" "$TRAEFIK_CONTAINER" 2>&1 | grep -E '"level":"(error|fatal)"' | grep -F -e "$route" -e "clients/"; then
    die "Traefik melaporkan error untuk ${route} (log di atas)"
  fi
}
