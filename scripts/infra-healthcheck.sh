#!/usr/bin/env bash
# Pemeriksaan kesehatan stack infra + alert email (H7, keputusan user 2026-09-23). IDEMPOTEN, root.
#
#   infra-healthcheck.sh                 cek + kirim alert/RESOLVED (dipanggil infra-healthcheck.timer tiap 5 menit)
#   infra-healthcheck.sh --no-mail       cek saja (journal + stderr), tidak mengirim email, state tidak diubah
#   infra-healthcheck.sh --selftest      cek + satu masalah PALSU `selftest-fake-problem` (uji jalur email; run
#                                        normal berikutnya mengirim RESOLVED untuknya)
#   infra-healthcheck.sh --unit-failed <unit>   dipanggil infra-unit-failure@<unit>.service (OnFailure= unit restic,
#                                        infra-job@<inst>.service, infra-job-<inst>.path)
#
# Yang diperiksa:
#   1. Setiap service long-running (restart ≠ "no") dari compose stack di $HC_STACKS (dibaca `docker compose config`)
#      → container ada, running, dan healthy bila punya healthcheck ("starting" = belum dianggap masalah).
#   2. crowdsec-firewall-bouncer.service active.
#   3. Tidak ada container RUNNING dengan HasBeenManuallyStopped=true di config.v2.json (flag yang membuat
#      `unless-stopped` tidak start saat reboot — insiden 2026-09-23; biasanya akibat `docker kill --signal=…`).
#   4. Unit systemd di $HC_UNITS (default restic-*) tidak berstatus failed, juga unit yang pernah dilaporkan
#      --unit-failed (RESOLVED dikirim setelah unit tidak lagi failed / di-reset-failed).
#   5. (opsional) $HC_EXTRA_CONTAINERS: nama container tambahan yang harus running (mis. nama fiktif untuk uji).
# Hasil ke journal: `journalctl -t infra-healthcheck` (prioritas err bila ada masalah, info bila OK).
# Anti-spam: satu masalah (kunci sama) dikirim sekali per $HC_REPEAT_MINUTES (default 60) menit; state di
# $HC_STATE_DIR (default /var/lib/infra-healthcheck/active/<kunci>). Email gagal → state tidak diubah (dicoba lagi
# run berikutnya). Keterbatasan: bila mailserver sendiri mati, alert hanya ada di journal.
# Exit: 0 OK, 1 ada masalah, 2 kesalahan pemakaian/internal.
set -euo pipefail
umask 077

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${HC_ENV_FILE:-/etc/infra-healthcheck/alert.env}"
TAG=infra-healthcheck

# --- konfigurasi: file env (KEY=VALUE, tanpa eksekusi shell) lalu default ---------------------------------------
if [[ -r "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^(ALERT_TO|ALERT_FROM|ALERT_SMTP_HOST|ALERT_SMTP_PORT|ALERT_PASSWORD_FILE|HC_STACKS|HC_UNITS|HC_REPEAT_MINUTES|HC_STATE_DIR|HC_EXTRA_CONTAINERS|HC_DISK_PCT|HC_SWAP_MIB|HC_SWAPIN_PPS|HC_SWAP_CRIT_MIB|HC_CI_TEXTFILE_DIR|HC_CI_DISK_PCT|HC_CI_HEARTBEAT_SEC|HC_CI_REG_FAILS|HC_CI_RUNNER_MAX_AGE_DAYS|HC_CI_MEM_PCT)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; v="${v#\"}"; v="${v%\"}"
    [[ -n "${!k+x}" ]] || export "$k=$v"   # env proses (mis. dari unit/pemanggil) menang atas file
  done < "$ENV_FILE"
fi
export ALERT_TO="${ALERT_TO:-postmaster@bimacreative.tech}"
export ALERT_FROM="${ALERT_FROM:-alerts@bimacreative.tech}"
export ALERT_SMTP_HOST="${ALERT_SMTP_HOST:-mail.bimacreative.tech}"
export ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-587}"
export ALERT_PASSWORD_FILE="${ALERT_PASSWORD_FILE:-$INFRA_DIR/mail/secrets/${ALERT_FROM}.password}"
HC_STACKS="${HC_STACKS:-traefik security/crowdsec postgres identity/keycloak odoo/pool-a staging/odoo web/control-plane staging/control-plane mail observability staging/drms-proyekkas}"
HC_UNITS="${HC_UNITS:-restic-backup.service restic-prune.service restic-restore-test.service}"
HC_REPEAT_MINUTES="${HC_REPEAT_MINUTES:-60}"
HC_STATE_DIR="${HC_STATE_DIR:-/var/lib/infra-healthcheck}"
HC_EXTRA_CONTAINERS="${HC_EXTRA_CONTAINERS:-}"
[[ "$HC_REPEAT_MINUTES" =~ ^[0-9]+$ ]] || { echo "HC_REPEAT_MINUTES tidak valid" >&2; exit 2; }

log() { # log <info|warning|err> <pesan>
  logger -t "$TAG" -p "user.$1" -- "$2"
  if [[ -t 2 ]]; then echo "[$1] $2" >&2; fi
}

usage() { sed -n '2,9p' "$0" >&2; exit 2; }
MODE=check; MAIL=yes; FAILED_UNIT=""
case "${1:-}" in
  "") ;;
  --no-mail) MAIL=no ;;
  --selftest) MODE=selftest ;;
  --unit-failed) [[ $# -eq 2 ]] || usage; MODE=unit; FAILED_UNIT="$2"
                 [[ "$FAILED_UNIT" =~ ^[A-Za-z0-9@._:-]+\.(service|timer|path)$ ]] || { echo "nama unit tidak valid" >&2; exit 2; } ;;
  *) usage ;;
esac
[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 2; }

ACTIVE_DIR="$HC_STATE_DIR/active"
install -d -m 0700 "$HC_STATE_DIR" "$ACTIVE_DIR"
exec 9>"/run/lock/infra-healthcheck.lock"
flock -w 120 9 || { log err "lock /run/lock/infra-healthcheck.lock tidak didapat (run lain macet?)"; exit 2; }

HOST="$(hostname -s)"
NOW="$(date +%s)"
NOWH="$(date '+%Y-%m-%d %H:%M:%S %Z')"

send_mail() { # send_mail <subject>  (body dari stdin); return ≠ 0 bila gagal
  local err
  if ! err="$(python3 "$INFRA_DIR/scripts/lib/infra_alert_mail.py" "$1" 2>&1)"; then
    log err "email alert GAGAL dikirim ke ${ALERT_TO}: ${err}"
    return 1
  fi
  log info "email terkirim ke ${ALERT_TO}: $1"
}

key_file() { printf '%s/%s' "$ACTIVE_DIR" "$1"; }

# --- mode --unit-failed: kirim segera (anti-spam per unit), state dipakai run berkala untuk RESOLVED --------------
if [[ "$MODE" == unit ]]; then
  key="unit-${FAILED_UNIT}"
  kf="$(key_file "$key")"
  log err "unit ${FAILED_UNIT} FAILED (OnFailure)"
  if [[ -f "$kf" ]] && (( NOW - $(head -n1 "$kf") < HC_REPEAT_MINUTES * 60 )); then
    log info "alert ${key} sudah dikirim < ${HC_REPEAT_MINUTES} menit lalu — tidak dikirim ulang"
    exit 0
  fi
  # shellcheck disable=SC2016  # backtick di teks email, bukan ekspansi
  body="$(printf 'Host: %s\nWaktu: %s\n\nUnit systemd %s GAGAL.\n\n' "$HOST" "$NOWH" "$FAILED_UNIT"
          systemctl status --no-pager --lines=0 "$FAILED_UNIT" 2>&1 | head -n 15 || true
          printf '\n--- journal (30 baris terakhir) ---\n'
          journalctl -u "$FAILED_UNIT" -n 30 --no-pager -o short-iso 2>&1 || true
          printf '\nTindak lanjut: journalctl -u %s ; setelah diperbaiki unit berikutnya yang sukses (atau\n`systemctl reset-failed %s`) memicu email RESOLVED dari infra-healthcheck.\n' "$FAILED_UNIT" "$FAILED_UNIT")"
  if printf '%s\n' "$body" | send_mail "[ALERT][${HOST}] unit ${FAILED_UNIT} gagal"; then
    printf '%s\n%s\n' "$NOW" "unit ${FAILED_UNIT} failed" > "$kf"
  fi
  exit 0
fi

# --- kumpulkan masalah: baris "<kunci>\t<pesan>" -------------------------------------------------------------------
PROBLEMS="$(mktemp)"; trap 'rm -f "$PROBLEMS"' EXIT
problem() { printf '%s\t%s\n' "$1" "$2" >> "$PROBLEMS"; }

# 1. container yang diharapkan dari compose stack
EXPECTED=""
for s in $HC_STACKS; do
  f="$INFRA_DIR/$s/docker-compose.yml"
  if [[ ! -f "$f" ]]; then problem "compose-${s//\//_}" "compose file tidak ada: $f"; continue; fi
  # stderr compose dibuang (bisa memuat nilai env); stdout JSON hanya diparse di memori.
  if ! out="$(docker compose -f "$f" config --format json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for name, svc in sorted(d.get("services", {}).items()):
    if str(svc.get("restart", "no")) == "no":
        continue  # one-shot (migrate) / tidak dimaksudkan hidup terus
    print(svc.get("container_name") or "-".join([d["name"], name, "1"]))
')"; then
    problem "compose-${s//\//_}" "gagal membaca compose stack ${s} (docker compose config)"; continue
  fi
  EXPECTED+="$out"$'\n'
done
for c in $HC_EXTRA_CONTAINERS; do EXPECTED+="$c"$'\n'; done
if [[ "$MODE" == selftest ]]; then
  problem "selftest-fake-problem" "SELFTEST: masalah PALSU untuk uji jalur alert (bukan gangguan nyata)"
fi

while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  if ! st="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null)"; then
    problem "container-$c" "container ${c} TIDAK ADA"; continue
  fi
  status="${st%%|*}"; health="${st#*|}"
  if [[ "$status" != running ]]; then
    problem "container-$c" "container ${c} tidak running (status=${status})"
  elif [[ -n "$health" && "$health" != healthy && "$health" != starting ]]; then
    problem "container-$c" "container ${c} running tetapi health=${health}"
  elif [[ "$health" == starting ]]; then
    log warning "container ${c} health=starting (belum dianggap masalah)"
  fi
done < <(printf '%s' "$EXPECTED" | sort -u)

# 2. firewall bouncer host
fwb="$(systemctl is-active crowdsec-firewall-bouncer.service 2>/dev/null || true)"
[[ "$fwb" == active ]] || problem "unit-crowdsec-firewall-bouncer.service" "crowdsec-firewall-bouncer.service tidak active (${fwb:-unknown})"

# 3. flag manual-stop pada container yang berjalan
droot="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
while IFS=$'\t' read -r name flag; do
  if [[ "$flag" == True ]]; then problem "manualstop-$name" "container ${name} berjalan dengan HasBeenManuallyStopped=true (unless-stopped TIDAK akan start setelah reboot; crash tidak di-restart). Perbaiki di jendela pemeliharaan: docker restart ${name}"; fi
  if [[ "$flag" == ERR ]]; then problem "manualstop-$name" "config.v2.json container ${name} tidak terbaca"; fi
done < <(docker ps -q --no-trunc | python3 -c '
import json, sys
root = sys.argv[1]
for cid in sys.stdin.read().split():
    try:
        with open(f"{root}/containers/{cid}/config.v2.json", encoding="utf-8") as fh:
            d = json.load(fh)
        print(str(d.get("Name", cid)).lstrip("/"), d.get("HasBeenManuallyStopped") is True, sep="\t")
    except (OSError, ValueError):
        print(cid[:12], "ERR", sep="\t")
' "$droot")

# 4. unit systemd failed (daftar + unit yang pernah dilaporkan --unit-failed)
units="$HC_UNITS"
for kf in "$ACTIVE_DIR"/unit-*; do
  [[ -e "$kf" ]] || continue
  u="${kf##*/unit-}"; [[ "$u" == crowdsec-firewall-bouncer.service ]] || units+=" $u"
done
# shellcheck disable=SC2086  # word splitting disengaja (daftar dipisah spasi)
for u in $(printf '%s\n' $units | sort -u); do
  if systemctl is-failed --quiet "$u" 2>/dev/null; then
    problem "unit-$u" "unit ${u} berstatus failed (journalctl -u ${u})"
  fi
done

# 5. disk & swap (T19 2026-09-25, ADR 0004): disk root > HC_DISK_PCT % (default 70). Swap (2026-10-03): swap terpakai
#    saja bukan masalah (page dingin proses idle — next-server/odoo/rspamd — terparkir di swap, swap-in ±0) → masalah bila
#    terpakai > HC_SWAP_MIB (1024) DAN laju swap-in sejak run sebelumnya > HC_SWAPIN_PPS (50 page/s ≈ 200 KiB/s = memori
#    benar-benar kurang), atau terpakai > HC_SWAP_CRIT_MIB (3072) berapa pun lajunya. Run pertama (tanpa state) → hanya
#    batas kritis. State $HC_STATE_DIR/swapin.last tidak ditulis pada --no-mail.
disk_pct="$(df --output=pcent / | tail -n1 | tr -dc '0-9')"
if [[ -n "$disk_pct" ]] && (( disk_pct > ${HC_DISK_PCT:-70} )); then
  problem "disk-root" "disk / terpakai ${disk_pct}% (> ${HC_DISK_PCT:-70}%) — cek build cache/image (docker system df), backups, /opt/src"
fi
swap_mib="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)"
swapin_now="$(awk '/^pswpin /{print $2}' /proc/vmstat)"; now_s="$(date +%s)"; swapin_pps=""
if [[ -r "$HC_STATE_DIR/swapin.last" ]] && read -r prev_s prev_in < "$HC_STATE_DIR/swapin.last" \
   && [[ "$prev_s" =~ ^[0-9]+$ && "$prev_in" =~ ^[0-9]+$ && -n "$swapin_now" ]] && (( now_s > prev_s && swapin_now >= prev_in )); then
  swapin_pps=$(( (swapin_now - prev_in) / (now_s - prev_s) ))
fi
[[ "$MAIL" == yes && -n "$swapin_now" ]] && printf '%s %s\n' "$now_s" "$swapin_now" > "$HC_STATE_DIR/swapin.last"
if [[ -n "$swap_mib" ]]; then
  if (( swap_mib > ${HC_SWAP_CRIT_MIB:-3072} )); then
    problem "swap-used" "swap terpakai ${swap_mib} MiB (> ${HC_SWAP_CRIT_MIB:-3072} MiB, kritis) — cek build lokal / container mendekati limit"
  elif [[ -n "$swapin_pps" ]] && (( swap_mib > ${HC_SWAP_MIB:-1024} && swapin_pps > ${HC_SWAPIN_PPS:-50} )); then
    problem "swap-used" "swap terpakai ${swap_mib} MiB dan swap-in ${swapin_pps} page/s (> ${HC_SWAPIN_PPS:-50}) — memori kurang; cek build lokal / container mendekati limit"
  fi
fi

# 6. runner CI self-hosted (plan 12 R7, ADR 0014) — hanya bila role ci_runner terpasang (/etc/ci-runner ada).
#    Sumber: textfile node-exporter yang ditulis ci-runner-supervisor + df /srv/ci + cgroup container ci-runner-job.
if [[ -d /etc/ci-runner ]]; then
  ci_tf="${HC_CI_TEXTFILE_DIR:-/var/lib/node-exporter-textfile}"
  ci_val() { [[ -r "$2" ]] || return 0; awk -v m="$1" '$1 == m {print $2; exit}' "$2"; }
  if findmnt -n --mountpoint /srv/ci >/dev/null 2>&1; then
    ci_pct="$(df --output=pcent /srv/ci | tail -n1 | tr -dc '0-9')"
    if [[ -n "$ci_pct" ]] && (( ci_pct > ${HC_CI_DISK_PCT:-85} )); then
      problem "ci-runner-disk" "/srv/ci (kuota runner CI) terpakai ${ci_pct}% (> ${HC_CI_DISK_PCT:-85}%) — ci-runner-gc / reset cache (docs/03-operations/ci-runner.md)"
    fi
  else
    problem "ci-runner-disk" "/srv/ci tidak ter-mount (srv-ci.mount)"
  fi
  if [[ -f /etc/ci-runner/pat ]] && systemctl is-enabled --quiet ci-runner-supervisor.path 2>/dev/null; then
    hb="$(ci_val ci_runner_supervisor_heartbeat_timestamp_seconds "$ci_tf/ci_runner_heartbeat.prom")"
    if [[ -z "$hb" ]] || (( NOW - ${hb%.*} > ${HC_CI_HEARTBEAT_SEC:-600} )); then
      problem "ci-runner-supervisor" "ci-runner-supervisor tanpa detak > ${HC_CI_HEARTBEAT_SEC:-600} s (journalctl -u ci-runner-supervisor)"
    fi
    fails="$(ci_val ci_runner_registration_consecutive_failures "$ci_tf/ci_runner.prom")"
    if [[ -n "$fails" ]] && (( ${fails%.*} >= ${HC_CI_REG_FAILS:-3} )); then
      problem "ci-runner-registration" "registrasi JIT runner gagal ${fails}x berturut-turut (PAT kedaluwarsa/dicabut? journalctl -u ci-runner-supervisor)"
    fi
  fi
  # R12: watchdog container macet (insiden 2026-09-28 23:48 WIB) + job melewati guard timeout.
  stuck_unres="$(ci_val ci_runner_stuck_unresolved "$ci_tf/ci_runner.prom")"
  stuck_last="$(ci_val ci_runner_last_stuck_timestamp_seconds "$ci_tf/ci_runner.prom")"
  if [[ "$stuck_unres" == 1 ]]; then
    problem "ci-runner-stuck" "container ci-runner-job macet dan watchdog TIDAK bisa membersihkannya — runner tidak menerima job (runbook docs/03-operations/ci-runner.md §Container macet)"
  elif [[ -n "$stuck_last" ]] && (( ${stuck_last%.*} > 0 && NOW - ${stuck_last%.*} < ${HC_CI_STUCK_WINDOW_SEC:-86400} )); then
    problem "ci-runner-stuck" "watchdog membersihkan container ci-runner-job yang macet pada $(date -d "@${stuck_last%.*}" '+%F %T %Z') (journalctl -u ci-runner-supervisor; cek sysbox-fs)"
  fi
  job_sec="$(ci_val ci_runner_job_running_seconds "$ci_tf/ci_runner_heartbeat.prom")"
  if [[ -n "$job_sec" ]] && (( ${job_sec%.*} > ${HC_CI_JOB_MAX_SEC:-12600} )); then
    problem "ci-runner-job-timeout" "job CI berjalan ${job_sec%.*} s (> ${HC_CI_JOB_MAX_SEC:-12600} s) — guard timeout supervisor tidak berhasil? (journalctl -u ci-runner-supervisor)"
  fi
  upd="$(ci_val ci_runner_update_available "$ci_tf/ci_runner.prom")"
  lts="$(ci_val ci_runner_latest_release_timestamp_seconds "$ci_tf/ci_runner.prom")"
  if [[ "$upd" == 1 && -n "$lts" ]] && (( ${lts%.*} > 0 && NOW - ${lts%.*} > ${HC_CI_RUNNER_MAX_AGE_DAYS:-21} * 86400 )); then
    problem "ci-runner-outdated" "image runner CI tertinggal rilis actions/runner > ${HC_CI_RUNNER_MAX_AGE_DAYS:-21} hari (GitHub berhenti meng-queue job setelah 30 hari) — bump ci_runner_version + digest"
  fi
  ci_id="$(docker inspect -f '{{.Id}}' ci-runner-job 2>/dev/null || true)"
  if [[ -n "$ci_id" && -r "/sys/fs/cgroup/system.slice/docker-${ci_id}.scope/memory.max" ]]; then
    ci_max="$(< "/sys/fs/cgroup/system.slice/docker-${ci_id}.scope/memory.max")"
    ci_anon="$(awk '$1 == "anon" {print $2}' "/sys/fs/cgroup/system.slice/docker-${ci_id}.scope/memory.stat")"
    if [[ "$ci_max" =~ ^[0-9]+$ && -n "$ci_anon" ]] && (( ci_anon * 100 > ci_max * ${HC_CI_MEM_PCT:-90} )); then
      problem "ci-runner-memory" "container ci-runner-job memakai $(( ci_anon / 1048576 )) MiB anon (> ${HC_CI_MEM_PCT:-90}% dari limit $(( ci_max / 1048576 )) MiB) — risiko OOM job CI"
    fi
  fi
fi

# --- laporan ke journal ---------------------------------------------------------------------------------------------
n_prob="$(wc -l < "$PROBLEMS")"
n_exp="$(printf '%s' "$EXPECTED" | grep -c . || true)"
if (( n_prob == 0 )); then
  log info "OK: ${n_exp} container stack running/healthy, firewall bouncer active, tanpa flag manual-stop, unit tidak failed"
else
  while IFS=$'\t' read -r k m; do log err "MASALAH [$k] $m"; done < "$PROBLEMS"
fi
[[ "$MAIL" == yes ]] || exit $(( n_prob > 0 ))

# --- alert & RESOLVED (anti-spam) -----------------------------------------------------------------------------------
declare -A CUR=()
alert_body=""; alert_keys=()
while IFS=$'\t' read -r k m; do
  CUR["$k"]=1
  kf="$(key_file "$k")"
  if [[ -f "$kf" ]] && (( NOW - $(head -n1 "$kf") < HC_REPEAT_MINUTES * 60 )); then continue; fi
  alert_body+="- ${m}"$'\n'; alert_keys+=("$k|$m")
done < "$PROBLEMS"
if (( ${#alert_keys[@]} > 0 )); then
  if printf 'Host: %s\nWaktu: %s\n\nMasalah (%d baru/berulang, total aktif %d):\n%s\nDetail: journalctl -t %s --since -15min\nEmail ini diulang paling cepat tiap %s menit per masalah; email RESOLVED dikirim saat pulih.\n' \
       "$HOST" "$NOWH" "${#alert_keys[@]}" "$n_prob" "$alert_body" "$TAG" "$HC_REPEAT_MINUTES" \
     | send_mail "[ALERT][${HOST}] infra-healthcheck: ${#alert_keys[@]} masalah"; then
    for km in "${alert_keys[@]}"; do printf '%s\n%s\n' "$NOW" "${km#*|}" > "$(key_file "${km%%|*}")"; done
  fi
fi

res_body=""; res_keys=()
for kf in "$ACTIVE_DIR"/*; do
  [[ -e "$kf" ]] || continue
  k="${kf##*/}"
  [[ -n "${CUR[$k]:-}" ]] && continue
  res_body+="- ${k}: $(sed -n 2p "$kf")"$'\n'; res_keys+=("$kf")
done
if (( ${#res_keys[@]} > 0 )); then
  if printf 'Host: %s\nWaktu: %s\n\nPulih (%d):\n%s\nMasalah aktif tersisa: %d.\n' "$HOST" "$NOWH" "${#res_keys[@]}" "$res_body" "$n_prob" \
     | send_mail "[RESOLVED][${HOST}] infra-healthcheck: ${#res_keys[@]} masalah pulih"; then
    rm -f -- "${res_keys[@]}"
  fi
fi
exit $(( n_prob > 0 ))
