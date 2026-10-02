#!/usr/bin/env bash
# =============================================================================
# bash-policy.sh — PreToolUse hook untuk Claude Code di VPS Athera
#
# Dipanggil Claude Code sebelum setiap tool call Bash. Membaca JSON dari stdin,
# melihat teks perintah PENUH + cwd sesi, lalu memutuskan (urutan evaluasi):
#   1. deny  -> perintah dibatalkan, alasan dikirim ke Claude (berlaku di SEMUA mode)
#   2. allow -> HANYA perintah tunggal yang terbukti aman (tanpa ; && || $( ` > dsb.)
#   3. ask   -> mutasi PROD: selalu prompt, walau ada allow rule lebar di settings
#   (kosong, exit 0) -> tidak ada keputusan; alur normal (permissions/classifier)
#
# Pasang:  lihat README di .claude/README-permission-policy.md
# Uji:     .claude/hooks/test-bash-policy.sh  (wajib hijau sebelum commit)
# Log:     /var/log/claude-bash-policy.log (deny/ask/allow; mode 600, logrotate)
# =============================================================================
set -u
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$PWD
LOG=${CLAUDE_BASH_POLICY_LOG:-/var/log/claude-bash-policy.log}

decide() { # decide <deny|ask|allow> <alasan>
  printf '%s | %-5s | %s | cwd=%s | %s\n' "$(date -Is)" "$1" "$2" "$CWD" "$CMD" >> "$LOG" 2>/dev/null
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}
deny()  { decide deny  "$1"; }
ask()   { decide ask   "$1"; }
allow() { decide allow "$1"; }
has()   { printf '%s' "$C" | grep -Eq -- "$1"; }
hasi()  { printf '%s' "$C" | grep -Eqi -- "$1"; }

# Normalisasi: newline/spasi ganda -> satu spasi
C=$(printf '%s' "$CMD" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

# ----------------------------------------------------------------------------
# Peta lingkungan (sumber: vps-audit 2026-10-02, docker compose ls)
# ----------------------------------------------------------------------------
PROD_CONTAINERS='traefik|postgres|keycloak|mailserver|webmail|odoo-pool-a|control-plane|control-plane-worker|web-expomedia-prod|web-bct-prod|drms-pk-web|drms-pk-worker|crowdsec|grafana|prometheus|loki|alloy|uptime-kuma|umami|node-exporter'
STAGING_CONTAINERS='odoo-staging|control-plane-staging|control-plane-staging-worker|drms-pk-stg|drms-pk-stg-worker|web-[a-z0-9-]+-staging'
PROD_DBS='expomedia_prod|control_plane|keycloak|pk_drms|datamart|umami'
STAGING_DBS='[a-z0-9_]+_staging|[a-z0-9_]+_demo|demo_[a-z0-9_]+|ssotest_[a-z0-9_]+|pk_drms_stg'
# Direktori compose PROD = semua di /opt/infra kecuali staging/
PROD_DIR_RE='^/opt/infra/(traefik|postgres|identity|mail|webmail|odoo/pool-a|web|security|observability|analytics|datamart)(/|$)'
STAGING_DIR_RE='^/opt/infra/staging/'
# Lokasi kritis untuk rm -r / find -delete
CRIT_RE='(/opt/infra|/opt/src|/var/lib/docker|/var/lib/infra-jobs|/var/mail|/var/log/mailserver|/etc)(/|[ ;&|]|$)'
# Path secret (isi tidak boleh dicetak / ditimpa)
SECRET_RE='(/run/secrets/|/secrets/|\.secret([ ;&|"'"'"']|$)|(^|[ /"'"'"'])\.env([ ;&|"'"'"']|$)|acme(-staging)?\.json|dkim/[^ ]*\.private|/run/sh-oidc/|des_key|pwhelper_token|crowdsec-bouncer\.key)'
# Tanda perintah majemuk / substitusi / redirect tulis (setelah redirect aman dibuang)
SAFE_C=$(printf '%s' "$C" | sed -E 's#[0-9]?>&[0-9]##g; s#[0-9]?>> ?/dev/null##g; s#[0-9]?> ?/dev/null##g')
COMPOUND=0; printf '%s' "$SAFE_C" | grep -Eq '(;|&&|\|\||`|\$\(|<\(|>|&$| & )' && COMPOUND=1
# Pipe hanya ke filter read-only
PIPE_OK=1
if printf '%s' "$SAFE_C" | grep -q '|'; then
  printf '%s' "$SAFE_C" | tr '|' '\n' | tail -n +2 | sed 's/^ *//' \
    | grep -Evq '^(grep|egrep|head|tail|sort|uniq|wc|cut|tr|column|jq|nl|cat)( |$)' && PIPE_OK=0
fi
SIMPLE=0; [ "$COMPOUND" = 0 ] && [ "$PIPE_OK" = 1 ] && SIMPLE=1

# Target compose: -f/--file/--project-directory, `cd X &&`, atau cwd sesi
compose_dirs() {
  local d
  d=$(printf '%s' "$C" | grep -oE '(-f|--file|--project-directory)[ =]+[^ ;&|]+' | sed -E 's/^(-f|--file|--project-directory)[ =]+//; s#/[^/]*\.ya?ml$##')
  [ -z "$d" ] && d=$(printf '%s' "$C" | grep -oE '(^|[;&|] *)cd [^ ;&|]+' | tail -n1 | sed -E 's/.*cd //')
  [ -z "$d" ] && d=$CWD
  printf '%s\n' "$d" | sed -E 's#/+$##; s#^\.$#'"$CWD"'#'
}
IS_COMPOSE=0; has '(^|[;&|] *|env [^;&|]*|[A-Z_]+=[^ ]* )docker[ -]compose ' && IS_COMPOSE=1
COMPOSE_PROD=0; COMPOSE_STG_ONLY=0
if [ "$IS_COMPOSE" = 1 ]; then
  DIRS=$(compose_dirs)
  printf '%s\n' "$DIRS" | grep -Eq "$PROD_DIR_RE" && COMPOSE_PROD=1
  printf '%s\n' "$DIRS" | grep -Evq "$STAGING_DIR_RE" || COMPOSE_STG_ONLY=1
fi
COMPOSE_VERB=$(printf '%s' "$C" | grep -oE 'docker[ -]compose( +(-f|--file|-p|--project-name|--project-directory|--env-file|--profile)[ =]+[^ ]+| +--[a-z-]+)* +[a-z]+' | head -n1 | awk '{print $NF}')

# ----------------------------------------------------------------------------
# 1. HARD DENY — guardrail brief §0.1. Tanpa pengecualian, apa pun modenya.
# ----------------------------------------------------------------------------
# rm rekursif di lokasi kritis (absolut), atau relatif saat cwd di /opt/infra
has "(^|[;&| ])(sudo )?rm (-[a-zA-Z]*[rR][a-zA-Z]* |-[a-zA-Z]+ -[a-zA-Z]*[rR][a-zA-Z]* |.*--recursive ).*${CRIT_RE}" \
  && deny "rm rekursif di direktori infra/data dilarang (brief §0.1)"
if printf '%s' "$CWD" | grep -Eq '^/opt/infra(/|$)' \
   && has '(^|[;&| ])(sudo )?rm (-[a-zA-Z]*[rR][a-zA-Z]* |.*--recursive )' \
   && ! has '(^|[;&| ])(sudo )?rm (-[a-zA-Z]+ )+/tmp/'; then
  deny "rm rekursif relatif dari cwd /opt/infra dilarang (brief §0.1); pakai path absolut di luar infra/data"
fi
has "(^|[;&| ])find .*${CRIT_RE}.* -(delete|exec rm|execdir rm)" \
  && deny "find -delete / -exec rm di direktori infra/data dilarang (brief §0.1)"
# docker volume / system prune & rm
has '(^|[;&| ])docker (volume (rm|prune)|system prune)' \
  && deny "docker volume rm/prune dan system prune dilarang; image/builder prune boleh setelah daftar dilaporkan"
# compose down/rm/stop/kill pada project PROD (-f, cd, atau cwd)
if [ "$COMPOSE_PROD" = 1 ] && printf '%s' "$COMPOSE_VERB" | grep -Eq '^(down|rm|stop|kill|pause)$'; then
  deny "docker compose $COMPOSE_VERB pada project PROD dilarang tanpa persetujuan eksplisit di chat (brief §0.1)"
fi
# restart/stop/kill/rm container PROD langsung (nama persis, bukan prefix -staging)
has "(^|[;&| ])docker (container )?(restart|stop|kill|rm|pause)( -[a-zA-Z-]+)* ([^;&|]* )?(${PROD_CONTAINERS})( |$|[;&|])" \
  && deny "docker restart/stop/kill/rm pada container PROD dilarang; ubah compose lalu minta persetujuan"
# dropdb / DROP DATABASE pada DB prod
hasi "(dropdb( [^;&|]*)? (${PROD_DBS})( |$|[;&|\"'])|drop database (if exists )?[\"']?(${PROD_DBS})([ ;\"']|$))" \
  && deny "DROP DATABASE pada DB produksi dilarang"
# firewall & routing (ufw/iptables/nft/ip)
has '(^|[;&| ])(sudo )?(ufw (allow|deny|reject|limit|delete|insert|disable|reset|default|route)|iptables(-legacy|-nft)? .*-[ADIRFXPNZE]( |$)|iptables-restore|nft (add|delete|destroy|flush|insert|replace|create|-f)|ip (-[a-z0-9]+ )*(l|link|a|addr|address|r|route|rule|n|neigh) (set|del|delete|add|flush|change|replace|append))' \
  && deny "perubahan firewall/routing harus lewat repo infra + persetujuan"
# mencetak / menyalin / menimpa secret
hasi "(^|[;&| ]|docker exec [^ ]+ )(cat|tac|less|more|head|tail|strings|base64|xxd|od|hexdump|jq|yq|awk|sed|cut|sort|diff|cp|scp|rsync|tee|dd|vi|vim|nano|grep|rg)( [^|]*)?${SECRET_RE}" \
  && deny "mencetak/menyalin isi secret dilarang (brief §0.1); nama file/variabel boleh"
has ">>? ?[^ ]*${SECRET_RE}" \
  && deny "menimpa file secret lewat redirect dilarang; ubah secret manual di luar sesi"
if has 'docker (compose [^;&|]*)?(exec|inspect|run) .*(printenv|( |^)env( |$|;|\|)|\.Config\.Env)' && ! has '\| *cut -d ?=? ?-f ?1'; then
  deny "mencetak env container dilarang (berisi secret); nama variabel saja boleh: ... | cut -d= -f1"
fi
# docker compose config tanpa --quiet mencetak nilai .env/env_file yang sudah di-interpolasi
if [ "$IS_COMPOSE" = 1 ] && [ "$COMPOSE_VERB" = config ] && ! has ' (-q|--quiet|--services|--images|--volumes|--networks|--profiles|--hash)( |$)'; then
  deny "docker compose config mencetak secret hasil interpolasi .env; pakai 'config --quiet' (validasi) atau '--services'"
fi
# curl | bash
has '(curl|wget) [^|]*\| *(sudo )?(ba|z|da)?sh' \
  && deny "curl|bash dilarang; unduh dulu, periksa, baru jalankan"
# git destruktif ke remote
has 'git (-C [^ ]+ )?push .*(--force|-f( |$)| \+[a-zA-Z0-9_/.-]+(:| |$)|--delete| -d( |$)|--mirror)' \
  && deny "git push --force/--delete/--mirror dilarang"
# Keycloak admin destruktif pada realm prod
hasi 'kcadm(\.sh)? .*(delete realms|delete users|(update|delete) realms/(platform|drms|master)( |/|$))' \
  && deny "perubahan realm prod Keycloak harus lewat realm export + job realm.sync"

# ----------------------------------------------------------------------------
# 2. ALLOW — hanya perintah TUNGGAL yang aman (SIMPLE=1), supaya tidak prompt
# ----------------------------------------------------------------------------
if [ "$SIMPLE" = 1 ]; then
  # read-only docker / systemd / jaringan / file
  has '^(sudo )?(docker (ps|inspect|logs|stats|images|image (ls|inspect|history)|volume (ls|inspect)|network (ls|inspect)|system df|version|info|compose (ls|version))|systemctl (status|cat|list-units|list-timers|list-unit-files|list-dependencies|is-active|is-enabled|is-failed|show)|ss|dig|host|nslookup|df|du|free|uptime|nproc|lsblk|ls|cat|head|tail|wc|grep|egrep|rg|jq|yq|tree|stat|file|which|readlink|realpath|id|date|hostname)( |$)' \
    && allow "read-only"
  [ "$IS_COMPOSE" = 1 ] && printf '%s' "$COMPOSE_VERB" | grep -Eq '^(ps|logs|images|top|ls|version)$' && allow "compose read-only"
  [ "$IS_COMPOSE" = 1 ] && [ "$COMPOSE_VERB" = config ] && allow "compose config --quiet/--services"
  has '^journalctl( |$)' && ! has ' --(vacuum-[a-z]+|rotate|flush|relinquish-var|sync|setup-keys)' && allow "journalctl read-only"
  has '^ip (-[a-z0-9]+ )*(a|addr|address|r|route|l|link|n|neigh|rule|-br)( (show|list)( |$)|$| [^ ]+$)' && allow "ip read-only"
  has '^find ' && ! has ' -(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)( |$)' && allow "find read-only"
  has '^printenv [A-Z_]+$' && allow "printenv nama var"
  # psql SELECT / meta-command read-only (prod maupun staging)
  hasi '^docker exec (-i )?postgres psql .*(-c|-[a-zA-Z]*c) ?["'"'"'] *(select|with|\\l|\\dt|\\dn|\\du|\\d |\\d\+|show|explain [^a]|table )' \
    && ! hasi '(pg_terminate|pg_cancel|pg_reload|set_config|lo_unlink|lo_import|lo_export|dblink|nextval|setval| into |\\c |\\connect|\\copy|\\!)' \
    && allow "psql read-only"
  # mailserver read-only
  has '^docker exec mailserver setup (email list|alias list|quota list|config dkim help|help)( |$)' && allow "mailserver read-only"
  # staging: compose apa pun (selain config tanpa --quiet, sudah di-deny di atas)
  [ "$IS_COMPOSE" = 1 ] && [ "$COMPOSE_STG_ONLY" = 1 ] && [ "$COMPOSE_PROD" = 0 ] && allow "compose staging"
  # staging: exec / restart / logs container staging
  has "^docker (exec( -[a-zA-Z]+)*|restart|stop|start|kill) (${STAGING_CONTAINERS})( |$)" && allow "container staging"
  # psql DDL/DML pada DB staging/demo (lewat container postgres)
  hasi "^docker exec (-i )?postgres (psql .*-d ?[\"']?(${STAGING_DBS})([\"' ]|$)|(createdb|dropdb) ([^ ]+ )*(${STAGING_DBS})$)" \
    && ! hasi '(\\c |\\connect)' && allow "db staging/demo"
  # git lokal non-destruktif (tanpa push)
  has '^git (-C [^ ]+ )?(status|log|diff|show|branch|add|commit|stash|fetch|worktree|checkout -b|switch|rev-parse|ls-files|tag|blame|describe|remote -v|config --get)( |$)' \
    && ! has ' (-D|--delete|-d|drop|clear|remove|prune|--force|-f|--discard-changes|--amend)( |$)' && allow "git lokal"
  # lint / test / dry-run
  has '^(bash -n|sh -n|shellcheck|hadolint|ansible-lint|ansible-playbook .*--check|npm (test|run (lint|typecheck|build|test)[a-z:-]*)|pnpm (lint|test|build|typecheck)|npx (tsc|eslint|prettier|vitest|playwright) )' \
    && allow "lint/test/dry-run"
fi

# ----------------------------------------------------------------------------
# 3. ASK — mutasi PROD: selalu minta persetujuan (mengalahkan allow rule lebar)
# ----------------------------------------------------------------------------
if [ "$COMPOSE_PROD" = 1 ] && ! printf '%s' "$COMPOSE_VERB" | grep -Eq '^(ps|logs|images|top|ls|version|config)$'; then
  ask "docker compose ${COMPOSE_VERB:-?} pada project PROD — perlu persetujuan"
fi
has "(^|[;&| ])docker (exec|cp|update|container update)( -[a-zA-Z]+)* (${PROD_CONTAINERS})( |$|:)" \
  && ask "docker exec/cp ke container PROD — perlu persetujuan"
has '(^|[;&| ])(sudo )?systemctl (restart|stop|start|reload|try-restart|enable|disable|mask|unmask|daemon-reload|kill)( |$)' \
  && ask "systemctl mutasi service host — perlu persetujuan"
has '(^|[;&| ])git (-C [^ ]+ )?push( |$)' && ask "git push — perlu persetujuan"
has '(^|[;&| ])docker (image prune|builder prune|rmi|image rm)( |$)' \
  && ask "hapus image/build cache — laporkan daftar dulu, lalu setujui"
has '(^|[;&| ])(sudo )?/usr/local/sbin/infra-deploy ' && ask "infra-deploy ke PROD — perlu persetujuan"

# ----------------------------------------------------------------------------
# 4. Tanpa keputusan -> alur normal (permissions.ask/allow, classifier auto mode)
# ----------------------------------------------------------------------------
exit 0
