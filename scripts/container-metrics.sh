#!/usr/bin/env bash
# container-metrics.sh — riwayat memori/CPU per container TANPA docker.sock di container mana pun
# (T19 follow-up, ADR 0004 § "Pengukuran ulang T19" R3/§8.2; docs/03-operations/observability.md §Metrik per container).
#
# Dijalankan di HOST sebagai root oleh container-metrics.timer (tiap 60 s, role ansible `container_metrics`).
# `docker ps` di host → id + nama + label compose project; nilai dibaca langsung dari cgroup v2
# (driver systemd: /sys/fs/cgroup/system.slice/docker-<id>.scope/). Hasil → file textfile Prometheus
# yang dibaca node-exporter (`--collector.textfile.directory`, bind mount read-only).
#
# Label HANYA `name` dan `compose_project` (tanpa env, image, command, atau label lain → tidak ada secret).
# Penulisan atomik: file sementara di direktori yang sama (nama diawali titik, tanpa akhiran .prom → diabaikan
# node-exporter) lalu `mv -f` (rename(2) di filesystem yang sama).
#
# Pemakaian:  container-metrics.sh [DIR_OUTPUT]      (default /var/lib/node-exporter-textfile)
# Env opsional: CGROUP_ROOT (default /sys/fs/cgroup), OUT_NAME (default containers.prom)
# Exit: 0 = file ditulis; 1 = docker ps gagal / direktori output tidak ada (file lama dibiarkan → umur file
#       terlihat dari node_textfile_mtime_seconds dan infra_container_metrics_last_success_timestamp_seconds).
set -euo pipefail
umask 022

OUT_DIR="${1:-/var/lib/node-exporter-textfile}"
OUT_NAME="${OUT_NAME:-containers.prom}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
SCOPE_DIR="${CGROUP_ROOT}/system.slice"

log() { printf 'container-metrics: %s\n' "$*" >&2; }

if [[ ! -d "$OUT_DIR" ]]; then
  log "direktori output tidak ada: $OUT_DIR"
  exit 1
fi

start_ns=$(date +%s%N)

# Escape nilai label sesuai format eksposisi teks Prometheus: \ → \\, " → \", newline → \n.
esc() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//$'\n'/\\n}
  printf '%s' "$v"
}

# Baca satu nilai dari file cgroup; "max" → +Inf; file tidak ada → kosong (metrik dilewati).
read_cg() {
  local f=$1 v
  [[ -r "$f" ]] || return 0
  read -r v < "$f" || true
  [[ "$v" == "max" ]] && v="+Inf"
  printf '%s' "$v"
}

# Nilai kunci tertentu dari file "kunci nilai" (cpu.stat, memory.stat, memory.events).
# Builtin bash saja (tanpa fork awk per container).
read_kv() {
  local f=$1 key=$2 k v
  [[ -r "$f" ]] || return 0
  while read -r k v; do
    if [[ "$k" == "$key" ]]; then
      printf '%s' "$v"
      return 0
    fi
  done < "$f"
}

if ! ps_out=$(docker ps --no-trunc --format '{{.ID}}	{{.Names}}	{{.Label "com.docker.compose.project"}}'); then
  log "docker ps gagal — file lama dibiarkan"
  exit 1
fi

tmp=$(mktemp "${OUT_DIR}/.${OUT_NAME}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# Satu array baris sampel per metrik: '<label-set> <nilai>'.
CUR=() MAX=() SWAP=() INACT=() OOM=() CPU=()
n=0
missing=0
add() { # add <nama array> <label-set> <nilai> — lewati nilai kosong (file cgroup tidak ada)
  [[ -n "$3" ]] || return 0
  case $1 in
    CUR) CUR+=("$2 $3") ;;
    MAX) MAX+=("$2 $3") ;;
    SWAP) SWAP+=("$2 $3") ;;
    INACT) INACT+=("$2 $3") ;;
    OOM) OOM+=("$2 $3") ;;
    CPU) CPU+=("$2 $3") ;;
  esac
}
while IFS=$'\t' read -r id name project; do
  [[ -n "$id" ]] || continue
  # ID docker = 64 hex; tolak selain itu (jangan membentuk path dari input tak terduga).
  if [[ ! "$id" =~ ^[0-9a-f]{64}$ ]]; then
    log "ID container tidak valid dilewati"
    continue
  fi
  cg="${SCOPE_DIR}/docker-${id}.scope"
  if [[ ! -d "$cg" ]]; then
    missing=$((missing + 1))
    continue
  fi
  l="{name=\"$(esc "$name")\",compose_project=\"$(esc "$project")\"}"
  add CUR "$l" "$(read_cg "$cg/memory.current")"
  add MAX "$l" "$(read_cg "$cg/memory.max")"
  add SWAP "$l" "$(read_cg "$cg/memory.swap.current")"
  add INACT "$l" "$(read_kv "$cg/memory.stat" inactive_file)"
  add OOM "$l" "$(read_kv "$cg/memory.events" oom_kill)"
  usec=$(read_kv "$cg/cpu.stat" usage_usec)
  if [[ "$usec" =~ ^[0-9]+$ ]]; then
    add CPU "$l" "$(printf '%d.%06d' $((usec / 1000000)) $((usec % 1000000)))"
  fi
  n=$((n + 1))
done <<< "$ps_out"

emit() { # emit <metrik> <type> <help> [sampel...]
  local metric=$1 type=$2 help=$3 x
  shift 3
  printf '# HELP %s %s\n# TYPE %s %s\n' "$metric" "$help" "$metric" "$type"
  for x in "$@"; do
    printf '%s%s\n' "$metric" "$x"
  done
}

{
  emit infra_container_memory_current_bytes gauge \
    "cgroup v2 memory.current (termasuk page cache) per container." "${CUR[@]}"
  emit infra_container_memory_max_bytes gauge \
    "cgroup v2 memory.max (mem_limit); +Inf bila tanpa limit." "${MAX[@]}"
  emit infra_container_memory_swap_current_bytes gauge \
    "cgroup v2 memory.swap.current per container." "${SWAP[@]}"
  emit infra_container_memory_inactive_file_bytes gauge \
    "cgroup v2 memory.stat inactive_file (current - inactive_file = working set ala docker stats)." "${INACT[@]}"
  emit infra_container_memory_oom_kill_total counter \
    "cgroup v2 memory.events oom_kill (sejak container start)." "${OOM[@]}"
  emit infra_container_cpu_usage_seconds_total counter \
    "cgroup v2 cpu.stat usage_usec / 1e6 (sejak container start)." "${CPU[@]}"
  end_ns=$(date +%s%N)
  printf '# HELP infra_container_metrics_containers Jumlah container yang diekspor pada run terakhir.\n'
  printf '# TYPE infra_container_metrics_containers gauge\n'
  printf 'infra_container_metrics_containers %d\n' "$n"
  printf '# HELP infra_container_metrics_missing_cgroup Container dari docker ps tanpa direktori cgroup (run terakhir).\n'
  printf '# TYPE infra_container_metrics_missing_cgroup gauge\n'
  printf 'infra_container_metrics_missing_cgroup %d\n' "$missing"
  printf '# HELP infra_container_metrics_duration_seconds Durasi run kolektor terakhir.\n'
  printf '# TYPE infra_container_metrics_duration_seconds gauge\n'
  awk -v a="$start_ns" -v b="$end_ns" 'BEGIN { printf "infra_container_metrics_duration_seconds %.3f\n", (b - a) / 1e9 }'
  printf '# HELP infra_container_metrics_last_success_timestamp_seconds Waktu Unix run kolektor sukses terakhir.\n'
  printf '# TYPE infra_container_metrics_last_success_timestamp_seconds gauge\n'
  printf 'infra_container_metrics_last_success_timestamp_seconds %d\n' "$((end_ns / 1000000000))"
} > "$tmp"

chmod 0644 "$tmp"
mv -f "$tmp" "${OUT_DIR}/${OUT_NAME}"
trap - EXIT
