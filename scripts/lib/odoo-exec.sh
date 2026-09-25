# shellcheck shell=bash
# Helper eksekusi Odoo/Postgres untuk skrip SSO (plan 04 S2) — pola yang sama dengan provision-odoo-db.sh
# (fungsi di sana sengaja tidak dipindah agar perilaku skrip itu tidak berubah). Di-source SETELAH
# lib/odoo-pools.sh + validate_slug_env (butuh: die, DB_NAME, POOL_CONTAINER, POOL_PGUSER, PG_CONTAINER,
# ODOO_CONF_IN_CONTAINER). Tidak ada secret di file ini.

# pgq <sql> [db] — psql superuser via socket (peer). Identifier sudah divalidasi regex ^[a-z0-9_]+$.
pgq() { docker exec -i "$PG_CONTAINER" psql -X -q -tA -v ON_ERROR_STOP=1 -U postgres -d "${2:-postgres}" -c "$1"; }

# odoo_cli [shell] <opsi…> → proses odoo satu-kali di container pool (tanpa HTTP/cron/worker).
# Subcommand Odoo harus argumen pertama (odoo/cli/command.py main).
odoo_cli() {
  local sub=(); [[ "${1:-}" == shell ]] && { sub=(shell); shift; }
  docker exec -i "$POOL_CONTAINER" odoo "${sub[@]}" -c "$ODOO_CONF_IN_CONTAINER" -d "$DB_NAME" \
    --no-http --workers=0 --max-cron-threads=0 "$@"
}

# require_tenant_db — DB ada, owner = role pool, base installed (hasil provision-odoo-db.sh). Tidak membuat DB.
require_tenant_db() {
  local owner base_state
  owner="$(pgq "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DB_NAME}'")"
  [[ -n "$owner" ]] || die "DB ${DB_NAME} belum ada — jalankan dulu scripts/provision-odoo-db.sh"
  [[ "$owner" == "$POOL_PGUSER" ]] || die "DB ${DB_NAME} dimiliki '${owner}', bukan ${POOL_PGUSER}"
  base_state="$(pgq "SELECT state FROM ir_module_module WHERE name = 'base'" "$DB_NAME" 2>/dev/null || true)"
  [[ "$base_state" == installed ]] || die "DB ${DB_NAME}: modul base tidak ter-install (state='${base_state}')"
}


# version_ge <a> <b> → 0 bila a >= b (sort -V)
version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

# container_env <container> <VAR> → nilai env di container (hanya untuk variabel NON-secret)
container_env() { docker exec "$1" printenv "$2" 2>/dev/null || true; }

# ---- rencana/penerapan (dipakai skrip dengan --dry-run; global DRY=0|1, CHANGED, BLOCKERS) ----
DRY="${DRY:-0}"; CHANGED=0; BLOCKERS=0
log() { echo "[$DB_NAME] $*"; }
# change <deskripsi> → 0 bila perubahan harus DITERAPKAN; dry-run: cetak PLAN dan return 1. Selalu menghitung CHANGED.
change() {
  CHANGED=$((CHANGED+1))
  if [[ $DRY -eq 1 ]]; then log "PLAN: $*"; return 1; fi
  log "UBAH: $*"
}
# block <pesan> → apply: die; dry-run: catat BLOKIR (rencana tetap dicetak) dan lanjut.
block() {
  [[ $DRY -eq 1 ]] || die "$*"
  BLOCKERS=$((BLOCKERS+1)); log "BLOKIR: $*"
}
