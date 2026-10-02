#!/usr/bin/python3 -I
"""infra-job — dispatcher root: file job control plane → skrip /opt/infra/scripts (ADR 0009, plan 05 §3-§4).

    /usr/local/sbin/infra-job <prod|staging>

Dipanggil HANYA oleh infra-job@<inst>.service (dipicu infra-job-<inst>.path, DirectoryNotEmpty= spool/new).
Sumber di repo: scripts/infra-job/infra_job.py → dipasang role Ansible `infra_jobs` (root 0755). Python 3 stdlib saja.

Batas keamanan (plan 05 §6): apa pun isi control plane (CP), yang sampai ke root hanya
"tipe job allowlist dengan argumen tervalidasi untuk env instance ini, dalam kuota". Per file job di spool/new:
  rename → work/ (root 0700) · lstat: reguler, uid cpjob-<inst>, nlink 1, mode ⊆ 0644, ≤ 8 KiB
  · open O_NOFOLLOW + fstat sama · ASCII · JSON ketat (kunci duplikat/tak dikenal, NaN, float = tolak)
  · allowlist tipe (global + per instance, conf `job_types`) + regex fullmatch (ASCII) · binding instance→env
  (hard-coded) · aturan slug `platform` (kontrak SaaS Fase 1 §0.3) · host tenant dari file route
  root-owned · kuota (ledger) · subprocess argv list tanpa shell,
  env bersih (PATH, LANG), cwd /opt/infra, stdin /dev/null, grup proses sendiri, timeout → SIGTERM grup, 30 s → SIGKILL
  · hasil JSON (RESULT allowlist + tail teredaksi) atomik ke results/ (0640 root:cpjob-<inst>) · log penuh root 0600.
Kill switch: /etc/infra-jobs/<inst>.disabled (semua job → failed error_code=disabled) atau `systemctl disable --now
infra-job-<inst>.path`. Serial per instance: flock /run/lock/infra-job-<inst>.lock.
Exit: 0 = run selesai (termasuk job yang ditolak/gagal — hasilnya di results/), 1 = kesalahan tata letak/internal
(unit gagal → OnFailure=infra-unit-failure@%n → email), 2 = pemakaian salah.
"""

from __future__ import annotations

import datetime as _dt
import errno
import fcntl
import grp
import hashlib
import json
import os
import pwd
import re
import signal
import socket
import stat
import subprocess
import sys
import syslog
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

VERSION = "1.1.0"

# ------------------------------------------------------------------------------------------------ konstanta (kontrak)
# Instance → env yang boleh disentuh + user host penulis job.
# HARD-CODED (plan 05 §4.1, STRIDE S2): tidak pernah dari file.
INSTANCES: dict[str, dict[str, Any]] = {
    "prod": {"envs": ("prod", "demo"), "user": "cpjob-prod"},
    "staging": {"envs": ("staging",), "user": "cpjob-staging"},
}
LEGACY_JOB_TYPES = ("odoo_db_provision", "odoo_route", "odoo_sso_provision", "odoo_sso_disable", "odoo_sso_user")
# SaaS Fase 1 (docs/plans/saas-phase-1-contract.md §1). Aktif hanya bila tercantum di `job_types` conf instance.
PHASE1_JOB_TYPES = (
    "kc_realm_sync",
    "kc_org_ensure",
    "kc_user_ensure",
    "kc_user_set_roles",
    "kc_user_set_enabled",
    "kc_user_action_email",
    "odoo_user_ensure",
    "odoo_tenant_config",
    "tenant_suspend",
    "tenant_resume",
)
JOB_TYPES = LEGACY_JOB_TYPES + PHASE1_JOB_TYPES
# Allowlist per instance bila /etc/infra-jobs/<inst>.conf tidak memuat `job_types` (kontrak §0.5): hanya 5 tipe lama.
DEFAULT_JOB_TYPES = LEGACY_JOB_TYPES
ERROR_CODES = (
    "rejected_validation",
    "rejected_quota",
    "disabled",
    "blocked_dry_run",
    "locked",
    "timeout_state_unknown",
    "script_exit",
    "no_result",  # hanya dipakai CP (watchdog); dispatcher tidak pernah menulisnya
)
SCRIPTS = {
    "odoo_db_provision": "provision-odoo-db.sh",
    "odoo_route": "render-client-route.sh",
    "odoo_sso_provision": "provision-odoo-sso.sh",
    "odoo_sso_disable": "provision-odoo-sso.sh",
    "odoo_sso_user": "odoo-sso-user.sh",
    "kc_realm_sync": "kc-realm-sync.sh",
    "kc_org_ensure": "kc-org.sh",
    "kc_user_ensure": "kc-user.sh",
    "kc_user_set_roles": "kc-user.sh",
    "kc_user_set_enabled": "kc-user.sh",
    "kc_user_action_email": "kc-user.sh",
    "odoo_user_ensure": "odoo-user.sh",
    "odoo_tenant_config": "odoo-tenant-config.sh",
    "tenant_suspend": "tenant-state.sh",
    "tenant_resume": "tenant-state.sh",
}
# Subperintah kc-user.sh — argv: kc-user.sh <sub> <slug> <env> … (kontrak §1; tipe lain: <skrip> <slug> <env> …).
KC_USER_SUBCOMMANDS = {
    "kc_user_ensure": "ensure",
    "kc_user_set_roles": "roles",
    "kc_user_set_enabled": "enabled",
    "kc_user_action_email": "email",
}

A = re.ASCII
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", A)
JOB_FILE_RE = re.compile(UUID_RE.pattern + r"\.json", A)
# Lebih ketat dari skrip (^[a-z0-9-]{3,30}$): tidak diawali/diakhiri '-' (nilai argv tidak pernah seperti opsi).
SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]{1,28}[a-z0-9]", A)
ACTOR_RE = re.compile(r"(user|system):[A-Za-z0-9._@:-]{1,128}", A)
# ISO-8601 UTC tanpa pecahan detik (kontrak CP J2: isoSeconds), mis. 2026-09-25T05:30:00Z.
REQUESTED_AT_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", A)
_LABEL = r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
# Iterasi 1 (Q3): hanya subdomain platform. prod/demo → *.erp.bimacreative.tech, staging → *.staging.bimacreative.tech.
HOST_RE = {
    "prod": re.compile(_LABEL + r"\.erp\.bimacreative\.tech", A),
    "demo": re.compile(_LABEL + r"\.erp\.bimacreative\.tech", A),
    "staging": re.compile(_LABEL + r"\.staging\.bimacreative\.tech", A),
}
DEFAULT_HOST_SUFFIX = {"prod": ".erp.bimacreative.tech", "staging": ".staging.bimacreative.tech"}  # demo: tanpa default
# = EMAIL_RE odoo-sso-user.sh, lebih ketat: local-part ≤ 64 dan tidak diawali '.'/'-'; total ≤ 254; huruf kecil saja.
EMAIL_RE = re.compile(r"[a-z0-9_%+][a-z0-9._%+-]{0,63}@(" + _LABEL + r"\.)+[a-z]{2,63}", A)
# = LOGIN_RE odoo-sso-user.sh, lebih ketat: tidak diawali '-' (sama persis dengan CP LOGIN_REGEX, J2).
LOGIN_RE = re.compile(r"[A-Za-z0-9._@+][A-Za-z0-9._@+-]{0,253}", A)
TOP_KEYS = ("v", "job_id", "type", "slug", "env", "dry_run", "actor", "requested_at", "args")
SSO_USER_ACTIONS = ("grant", "revoke", "resend_invite")
# Kontrak §1: NAME_RE CP = [A-Za-z0-9À-ɏ .,'-]{1,100}; dispatcher ASCII saja, tidak diawali spasi/'-'.
NAME_RE = re.compile(r"[A-Za-z0-9.,'][A-Za-z0-9 .,'-]{0,99}", A)
# Tenant internal (kontrak §0.1). Aturan §0.3: superadmin/ops hanya slug platform; client_* hanya slug ≠ platform.
PLATFORM_SLUG = "platform"
CP_ROLES = ("none", "superadmin", "ops", "client_admin", "client_user")
CP_ROLES_PLATFORM = ("none", "superadmin", "ops")
CP_ROLES_TENANT = ("none", "client_admin", "client_user")
ODOO_ACCESS = ("none", "user", "admin")
ODOO_USER_ROLES = ("user", "admin")
KC_EMAIL_ACTIONS = ("UPDATE_PASSWORD", "VERIFY_EMAIL", "CONFIGURE_TOTP")
TENANT_CHECK_MODES = ("off", "compat", "strict")
APPROVE_ENVS = ("prod", "demo")  # kc_realm_sync apply di env ini wajib args.approve=true
MAX_HOSTS = 5

MAX_JOB_BYTES = 8192
MAX_FILES_PER_RUN = 100
RUN_BUDGET_S = 1800  # tidak memulai job baru setelah ini; sisa file memicu run berikutnya (path unit)
KILL_GRACE_S = 30
LEDGER_KEEP_S = 7 * 86400

RESULT_KEYS = frozenset(
    "db realm client provider hosts changed kc_user odoo_user action invite mode blockers route host created pool "
    "org roles enabled state tenant".split()
)
RESULT_VAL_RE = re.compile(r"[A-Za-z0-9._,:@/=-]{0,512}", A)
TAIL_MAX_LINES = 40
TAIL_MAX_BYTES = 8192
TAIL_LINE_MAX = 400
REDACT_RE = re.compile(r"secret|token|password|passwd|bearer|authorization", re.IGNORECASE)
LOCK_MSG_RE = re.compile(r"^ERROR: .* sedang berjalan \(lock\)$", A)
ROUTE_HEADER = b"# DIRENDER OTOMATIS oleh scripts/render-client-route.sh"
ROUTE_HOST_RE = re.compile(rb"Host\(`([a-z0-9.-]{1,253})`\)", A)
MAX_ROUTE_BYTES = 256 * 1024

DEFAULT_QUOTA = {
    "total_per_hour": 60,
    "odoo_db_provision_per_day": 3,
    "odoo_sso_user_per_hour": 30,
    "rotate_secret_per_day": 5,
    # SaaS Fase 1 (kontrak §1.2)
    "kc_user_per_hour": 60,  # semua kc_user_* (termasuk dry_run)
    "kc_user_disable_per_hour": 20,  # kc_user_set_enabled enabled=false, dry_run=false
    "kc_action_email_per_hour": 20,  # kc_user_action_email (termasuk dry_run)
    "kc_realm_sync_per_day": 10,  # kc_realm_sync (termasuk dry_run)
    "tenant_state_per_day": 20,  # tenant_suspend + tenant_resume (termasuk dry_run)
    "odoo_user_per_hour": 60,  # odoo_user_ensure (termasuk dry_run)
}
DEFAULT_TIMEOUTS = {
    "odoo_db_provision": 900,
    "odoo_route": 60,
    "odoo_sso_provision": 300,
    "odoo_sso_disable": 120,
    "odoo_sso_user": 180,
    "kc_realm_sync": 300,
    "kc_org_ensure": 120,
    "kc_user_ensure": 120,
    "kc_user_set_roles": 120,
    "kc_user_set_enabled": 120,
    "kc_user_action_email": 120,
    "odoo_user_ensure": 300,
    "odoo_tenant_config": 300,
    "tenant_suspend": 60,
    "tenant_resume": 60,
    # dry-run pendahulu (odoo_sso_provision / odoo_sso_disable / odoo_sso_user grant|resend_invite / semua tipe Fase 1)
    # dan job dry_run=true
    "dry_run": 60,
}
# Kuota per tipe: (tipe yang dihitung, jendela detik, kunci kuota, pesan). Kuota dihitung atas job yang DITERIMA.
TYPE_QUOTAS: tuple[tuple[tuple[str, ...], int, str, str], ...] = (
    (("odoo_db_provision",), 86400, "odoo_db_provision_per_day", "kuota odoo_db_provision/24 jam habis"),
    (("odoo_sso_user",), 3600, "odoo_sso_user_per_hour", "kuota odoo_sso_user/jam habis"),
    (tuple(KC_USER_SUBCOMMANDS), 3600, "kc_user_per_hour", "kuota kc_user_*/jam habis"),
    (("kc_user_action_email",), 3600, "kc_action_email_per_hour", "kuota kc_user_action_email/jam habis"),
    (("kc_realm_sync",), 86400, "kc_realm_sync_per_day", "kuota kc_realm_sync/24 jam habis"),
    (("tenant_suspend", "tenant_resume"), 86400, "tenant_state_per_day", "kuota tenant_suspend/resume/24 jam habis"),
    (("odoo_user_ensure",), 3600, "odoo_user_per_hour", "kuota odoo_user_ensure/jam habis"),
)
QUOTA_BOUNDS = (0, 10000)
TIMEOUT_BOUNDS = (5, 7200)
ALERT_MAX_PER_HOUR = 6

CLEAN_ENV = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"}
ALERT_ENV_KEYS = ("ALERT_TO", "ALERT_FROM", "ALERT_SMTP_HOST", "ALERT_SMTP_PORT", "ALERT_PASSWORD_FILE")

# Mode tata letak (plan 05 §3.2, AC-J1). owner "root" = uid 0 (atau Config.root_uid di test), "job" = uid cpjob.
LAYOUT = (
    # (path relatif base/<inst>, owner, group, mode)
    ("spool", "root", "job", 0o730),
    ("spool/new", "root", "job", 0o730),
    ("work", "root", "root", 0o700),
    ("rejected", "root", "root", 0o700),
    ("results", "root", "job", 0o750),
)


class Reject(Exception):
    """Job ditolak; pesan = teks tetap dari dispatcher (tidak pernah menggemakan nilai dari file job)."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


class LayoutError(Exception):
    pass


# ------------------------------------------------------------------------------------------------ konfigurasi runtime
@dataclass
class Config:
    instance: str
    base_dir: str = "/var/lib/infra-jobs"
    log_dir: str = "/var/log/infra-jobs"
    lock_dir: str = "/run/lock"
    etc_dir: str = "/etc/infra-jobs"
    infra_dir: str = "/opt/infra"  # cwd skrip + file route traefik/dynamic/clients
    scripts_dir: str = "/opt/infra/scripts"
    alert_env_file: str = "/etc/infra-healthcheck/alert.env"
    job_uid: int = -1
    job_gid: int = -1
    root_uid: int = 0  # pemilik wajib dir/skrip/file route (test: uid proses)
    root_gid: int = 0
    kill_grace_s: int = KILL_GRACE_S
    run_budget_s: int = RUN_BUDGET_S
    now: Callable[[], float] = time.time
    log: Callable[[int, str], None] | None = None
    alert: Callable[[str, str], bool] | None = None
    events: list[str] = field(default_factory=list)

    @property
    def inst_dir(self) -> str:
        return os.path.join(self.base_dir, self.instance)


def production_config(instance: str) -> Config:
    user = INSTANCES[instance]["user"]
    pw = pwd.getpwnam(user)  # KeyError → exit 1 (role Ansible belum diterapkan)
    gr = grp.getgrnam(user)
    if pw.pw_gid != gr.gr_gid or pw.pw_uid in (0, 1001) or gr.gr_gid in (0, 1001):
        raise LayoutError(f"user/grup {user} tidak sesuai (uid {pw.pw_uid}, gid {gr.gr_gid})")
    return Config(instance=instance, job_uid=pw.pw_uid, job_gid=gr.gr_gid)


# ------------------------------------------------------------------------------------------------ utilitas
def utc_iso(ts: float) -> str:
    return _dt.datetime.fromtimestamp(ts, _dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _syslog(prio: int, msg: str) -> None:
    syslog.syslog(prio, msg)


def log(cfg: Config, prio: int, msg: str) -> None:
    (cfg.log or _syslog)(prio, msg)


def open_dir(path: str, dir_fd: int | None = None) -> int:
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)


def check_owner_mode(st: os.stat_result, uid: int, gid: int | None, mode: int | None, what: str) -> None:
    if st.st_uid != uid or (gid is not None and st.st_gid != gid):
        raise LayoutError(f"{what}: owner {st.st_uid}:{st.st_gid}, diharapkan {uid}:{gid if gid is not None else '*'}")
    if mode is not None and stat.S_IMODE(st.st_mode) != mode:
        raise LayoutError(f"{what}: mode {stat.S_IMODE(st.st_mode):o}, diharapkan {mode:o}")


def check_root_file(cfg: Config, path: str, *, want_exec: bool = False, max_bytes: int | None = None) -> None:
    """File milik root, reguler (bukan symlink), tidak writable group/other."""
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        raise LayoutError(f"{path}: bukan file reguler")
    if st.st_uid != cfg.root_uid or st.st_mode & 0o022:
        raise LayoutError(f"{path}: harus milik root dan tidak writable group/other")
    if want_exec and not st.st_mode & 0o100:
        raise LayoutError(f"{path}: tidak executable")
    if max_bytes is not None and st.st_size > max_bytes:
        raise LayoutError(f"{path}: terlalu besar")


def check_root_dir(cfg: Config, path: str) -> None:
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != cfg.root_uid or st.st_mode & 0o022:
        raise LayoutError(f"{path}: harus direktori milik root, tidak writable group/other")


def write_atomic(cfg: Config, tmp_dir_fd: int, dst_dir_fd: int, name: str, data: bytes, mode: int, gid: int) -> None:
    """Tulis ke tmp di dir root 0700 (tidak terlihat worker), fchown/fchmod/fsync, lalu rename (satu fs) ke tujuan."""
    tmp = f".tmp-{name}-{time.time_ns()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=tmp_dir_fd)
    try:
        os.fchown(fd, cfg.root_uid, gid)
        os.fchmod(fd, mode)
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, name, src_dir_fd=tmp_dir_fd, dst_dir_fd=dst_dir_fd)


# ------------------------------------------------------------------------------------------------ konfigurasi root
@dataclass
class Limits:
    quota: dict[str, int]
    timeouts: dict[str, int]
    job_types: tuple[str, ...]  # allowlist tipe instance ini (⊆ JOB_TYPES)


def load_limits(cfg: Config) -> Limits:
    """/etc/infra-jobs/<inst>.conf (JSON, opsional; root, tidak writable g/o). Invalid → LayoutError (fail-closed).

    Kunci: `quota` {kunci DEFAULT_QUOTA: int}, `timeouts` {kunci DEFAULT_TIMEOUTS: int},
    `job_types` [tipe JOB_TYPES, unik] (tidak ada → DEFAULT_JOB_TYPES; daftar kosong = tidak ada tipe diizinkan)."""
    quota, timeouts = dict(DEFAULT_QUOTA), dict(DEFAULT_TIMEOUTS)
    path = os.path.join(cfg.etc_dir, f"{cfg.instance}.conf")
    try:
        check_root_file(cfg, path, max_bytes=4096)
    except FileNotFoundError:
        return Limits(quota, timeouts, DEFAULT_JOB_TYPES)
    with open(path, "rb") as fh:
        raw = fh.read(4097)
    try:
        conf = json.loads(raw.decode("ascii"), object_pairs_hook=_no_dup_pairs, parse_float=_no_float,
                          parse_constant=_no_const)
    except (ValueError, UnicodeDecodeError, RecursionError, Reject) as exc:
        raise LayoutError(f"{path}: JSON tidak valid") from exc
    if not isinstance(conf, dict) or set(conf) - {"quota", "timeouts", "job_types"}:
        raise LayoutError(f"{path}: kunci tidak dikenal")
    for sect, target, bounds in (("quota", quota, QUOTA_BOUNDS), ("timeouts", timeouts, TIMEOUT_BOUNDS)):
        val = conf.get(sect, {})
        if not isinstance(val, dict) or set(val) - set(target):
            raise LayoutError(f"{path}: {sect} tidak valid")
        for k, v in val.items():
            if type(v) is not int or not bounds[0] <= v <= bounds[1]:
                raise LayoutError(f"{path}: {sect}.{k} di luar batas {bounds}")
            target[k] = v
    job_types = DEFAULT_JOB_TYPES
    if "job_types" in conf:
        jt = conf["job_types"]
        if (type(jt) is not list or any(type(t) is not str or t not in JOB_TYPES for t in jt)
                or len(set(jt)) != len(jt)):
            raise LayoutError(f"{path}: job_types harus array tipe job yang dikenal, tanpa duplikat")
        job_types = tuple(jt)
    return Limits(quota, timeouts, job_types)


# ------------------------------------------------------------------------------------------------ parsing & validasi
def _no_dup_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k, v in pairs:
        if k in out:
            raise Reject("rejected_validation", "kunci JSON duplikat")
        out[k] = v
    return out


def _no_float(_s: str) -> Any:
    raise Reject("rejected_validation", "angka pecahan tidak diizinkan")


def _no_const(_s: str) -> Any:
    raise Reject("rejected_validation", "NaN/Infinity tidak diizinkan")


def parse_job_bytes(raw: bytes) -> dict[str, Any]:
    if not raw:
        raise Reject("rejected_validation", "file kosong")
    if len(raw) > MAX_JOB_BYTES:
        raise Reject("rejected_validation", f"file > {MAX_JOB_BYTES} byte")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise Reject("rejected_validation", "file memuat byte non-ASCII") from None
    if "\x00" in text:
        raise Reject("rejected_validation", "file memuat NUL")
    try:
        obj = json.loads(text, object_pairs_hook=_no_dup_pairs, parse_float=_no_float, parse_constant=_no_const)
    except Reject:
        raise
    except (ValueError, RecursionError):
        raise Reject("rejected_validation", "JSON tidak valid") from None
    if not isinstance(obj, dict):
        raise Reject("rejected_validation", "JSON bukan objek")
    return obj


def _str(d: dict[str, Any], key: str, rx: re.Pattern[str], what: str, max_len: int = 254) -> str:
    v = d.get(key)
    if type(v) is not str or len(v) > max_len or not rx.fullmatch(v):
        raise Reject("rejected_validation", f"{what} tidak valid")
    return v


def _bool(d: dict[str, Any], key: str, what: str) -> bool:
    v = d.get(key)
    if type(v) is not bool:
        raise Reject("rejected_validation", f"{what} harus boolean")
    return v


def _keys(d: dict[str, Any], required: set[str], optional: set[str], what: str) -> None:
    ks = set(d)
    if ks - required - optional:
        raise Reject("rejected_validation", f"{what}: kunci tidak dikenal")
    if required - ks:
        raise Reject("rejected_validation", f"{what}: kunci wajib hilang ({','.join(sorted(required - ks))})")


def default_host(slug: str, env: str) -> str | None:
    suffix = DEFAULT_HOST_SUFFIX.get(env)
    return slug + suffix if suffix else None


@dataclass
class Job:
    job_id: str
    type: str
    slug: str
    env: str
    dry_run: bool
    actor: str
    args: dict[str, Any]
    pre_dry_run: bool = False
    alert_reason: str | None = None  # aksi sensitif → email (plan 05 §6 sisa risiko)
    rotate: bool = False  # ledger flag "rotate" (kuota rotate_secret_per_day)
    disable: bool = False  # ledger flag "disable" (kuota kc_user_disable_per_hour)

    @property
    def ledger_flags(self) -> str:
        return ",".join(["accepted", *(["rotate"] if self.rotate else []), *(["disable"] if self.disable else [])])


def validate_job(obj: dict[str, Any], instance: str, file_job_id: str,
                 allowed_types: tuple[str, ...] = DEFAULT_JOB_TYPES) -> Job:
    _keys(obj, set(TOP_KEYS), set(), "job")
    if type(obj["v"]) is not int or obj["v"] != 1:
        raise Reject("rejected_validation", "v harus 1")
    job_id = _str(obj, "job_id", UUID_RE, "job_id", 36)
    if job_id != file_job_id:
        raise Reject("rejected_validation", "job_id ≠ nama file")
    jtype = obj["type"]
    if type(jtype) is not str or jtype not in JOB_TYPES:
        raise Reject("rejected_validation", "type tidak dikenal")
    if jtype not in allowed_types:
        raise Reject("rejected_validation", "tipe tidak diizinkan di instance ini")
    slug = _str(obj, "slug", SLUG_RE, "slug", 30)
    env = obj["env"]
    if type(env) is not str or env not in ("prod", "demo", "staging"):
        raise Reject("rejected_validation", "env tidak valid")
    if env not in INSTANCES[instance]["envs"]:
        raise Reject("rejected_validation", "env di luar instance ini (lintas instance)")
    dry_run = _bool(obj, "dry_run", "dry_run")
    actor = _str(obj, "actor", ACTOR_RE, "actor", 140)
    _str(obj, "requested_at", REQUESTED_AT_RE, "requested_at", 40)
    try:
        _dt.datetime.fromisoformat(obj["requested_at"].replace("Z", "+00:00"))
    except ValueError:
        raise Reject("rejected_validation", "requested_at bukan tanggal valid") from None
    args = obj["args"]
    if not isinstance(args, dict):
        raise Reject("rejected_validation", "args harus objek")
    job = Job(job_id, jtype, slug, env, dry_run, actor, {})
    VALIDATORS[jtype](job, args)
    return job


def _host(args: dict[str, Any], key: str, env: str) -> str:
    return _str(args, key, HOST_RE[env], f"args.{key}", 253)


def _hosts(args: dict[str, Any], env: str) -> list[str]:
    hs = args.get("hosts")
    if type(hs) is not list or not 1 <= len(hs) <= MAX_HOSTS:
        raise Reject("rejected_validation", f"args.hosts harus array 1..{MAX_HOSTS}")
    out: list[str] = []
    for h in hs:
        if type(h) is not str or len(h) > 253 or not HOST_RE[env].fullmatch(h):
            raise Reject("rejected_validation", "args.hosts: host tidak valid")
        if h in out:
            raise Reject("rejected_validation", "args.hosts: duplikat")
        out.append(h)
    return out


def v_db_provision(job: Job, args: dict[str, Any]) -> None:
    _keys(args, set(), {"host"}, "args")
    if job.dry_run:
        raise Reject("rejected_validation", "odoo_db_provision tidak mendukung dry_run")
    if "host" in args:
        job.args["host"] = _host(args, "host", job.env)
    elif job.env == "demo":
        raise Reject("rejected_validation", "env demo wajib args.host")


def v_route(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"remove"}, {"host"}, "args")
    if job.dry_run:
        raise Reject("rejected_validation", "odoo_route tidak mendukung dry_run")
    job.args["remove"] = _bool(args, "remove", "args.remove")
    if job.args["remove"]:
        if "host" in args:
            raise Reject("rejected_validation", "args.host tidak boleh bersama remove=true")
        job.alert_reason = "odoo_route remove"
    elif "host" in args:
        job.args["host"] = _host(args, "host", job.env)
    elif job.env == "demo":
        raise Reject("rejected_validation", "env demo wajib args.host")


def v_sso_provision(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"hosts", "rotate_secret", "skip_smoke"}, set(), "args")
    job.args["hosts"] = _hosts(args, job.env)
    job.args["rotate_secret"] = _bool(args, "rotate_secret", "args.rotate_secret")
    job.args["skip_smoke"] = _bool(args, "skip_smoke", "args.skip_smoke")
    job.pre_dry_run = not job.dry_run
    if job.args["rotate_secret"] and not job.dry_run:
        job.rotate = True
        job.alert_reason = "rotate_secret"


def v_sso_disable(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"hosts"}, set(), "args")
    job.args["hosts"] = _hosts(args, job.env)
    job.pre_dry_run = not job.dry_run
    if not job.dry_run:
        job.alert_reason = "odoo_sso_disable"


def v_sso_user(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"action", "email", "admin", "create_kc"}, {"login"}, "args")
    action = args["action"]
    if type(action) is not str or action not in SSO_USER_ACTIONS:
        raise Reject("rejected_validation", "args.action tidak valid")
    job.args["action"] = action
    job.args["email"] = _str(args, "email", EMAIL_RE, "args.email", 254)
    if "login" in args:
        job.args["login"] = _str(args, "login", LOGIN_RE, "args.login", 254)
    job.args["admin"] = _bool(args, "admin", "args.admin")
    job.args["create_kc"] = _bool(args, "create_kc", "args.create_kc")
    if action == "revoke" and (job.args["admin"] or job.args["create_kc"]):
        raise Reject("rejected_validation", "revoke tidak bisa dengan admin/create_kc")
    if action == "resend_invite" and job.args["create_kc"]:
        raise Reject("rejected_validation", "resend_invite tidak bisa dengan create_kc")
    job.pre_dry_run = action in ("grant", "resend_invite") and not job.dry_run


# ---- SaaS Fase 1 (docs/plans/saas-phase-1-contract.md §0, §1). Semua tipe: dry-run pendahulu bila dry_run=false.
def _enum(d: dict[str, Any], key: str, allowed: tuple[str, ...], what: str) -> str:
    v = d.get(key)
    if type(v) is not str or v not in allowed:
        raise Reject("rejected_validation", f"{what} tidak valid")
    return v


def _need_platform(job: Job) -> None:
    if job.slug != PLATFORM_SLUG:
        raise Reject("rejected_validation", f"{job.type} hanya untuk slug platform")


def _deny_platform(job: Job) -> None:
    if job.slug == PLATFORM_SLUG:
        raise Reject("rejected_validation", f"{job.type} tidak berlaku untuk slug platform")


def _email(job: Job, args: dict[str, Any]) -> None:
    job.args["email"] = _str(args, "email", EMAIL_RE, "args.email", 254)


def v_kc_realm_sync(job: Job, args: dict[str, Any]) -> None:
    _keys(args, set(), {"approve"}, "args")
    _need_platform(job)
    job.args["approve"] = _bool(args, "approve", "args.approve") if "approve" in args else False
    if job.env in APPROVE_ENVS and not job.dry_run and not job.args["approve"]:
        raise Reject("rejected_validation", "kc_realm_sync apply di prod/demo wajib args.approve=true")
    job.pre_dry_run = not job.dry_run
    if not job.dry_run:
        job.alert_reason = "kc_realm_sync apply"


def v_kc_org_ensure(job: Job, args: dict[str, Any]) -> None:
    # slug tenant maupun platform (org internal) boleh — kontrak §1.
    _keys(args, {"tenant_id"}, set(), "args")
    job.args["tenant_id"] = _str(args, "tenant_id", UUID_RE, "args.tenant_id", 36)
    job.pre_dry_run = not job.dry_run


def v_kc_user_ensure(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"email", "tenant_id", "invite"}, {"name"}, "args")
    _email(job, args)
    job.args["tenant_id"] = _str(args, "tenant_id", UUID_RE, "args.tenant_id", 36)
    job.args["invite"] = _bool(args, "invite", "args.invite")
    if "name" in args:
        job.args["name"] = _str(args, "name", NAME_RE, "args.name", 100)
    job.pre_dry_run = not job.dry_run


def v_kc_user_set_roles(job: Job, args: dict[str, Any]) -> None:
    # Tidak pernah memberi hak lebih (§0.3, BUG-J5-01): role platform hanya di slug platform, role tenant hanya di
    # tenant; akses Odoo tidak ada untuk slug platform (tidak ada client odoo-platform-<env>).
    _keys(args, {"email", "cp_role"}, {"odoo"}, "args")
    _email(job, args)
    role = _enum(args, "cp_role", CP_ROLES, "args.cp_role")
    if role not in (CP_ROLES_PLATFORM if job.slug == PLATFORM_SLUG else CP_ROLES_TENANT):
        raise Reject("rejected_validation", "args.cp_role tidak diizinkan untuk slug ini")
    job.args["cp_role"] = role
    if "odoo" in args:
        if job.slug == PLATFORM_SLUG:
            raise Reject("rejected_validation", "args.odoo dilarang untuk slug platform")
        job.args["odoo"] = _enum(args, "odoo", ODOO_ACCESS, "args.odoo")
    job.pre_dry_run = not job.dry_run


def v_kc_user_set_enabled(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"email", "enabled"}, set(), "args")
    _email(job, args)
    job.args["enabled"] = _bool(args, "enabled", "args.enabled")
    job.pre_dry_run = not job.dry_run
    if not job.args["enabled"] and not job.dry_run:
        job.disable = True
        job.alert_reason = "kc_user_set_enabled enabled=false"


def v_kc_user_action_email(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"email", "action"}, set(), "args")
    _email(job, args)
    job.args["action"] = _enum(args, "action", KC_EMAIL_ACTIONS, "args.action")
    job.pre_dry_run = not job.dry_run


def v_odoo_user_ensure(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"email", "role", "active"}, {"login", "name"}, "args")
    _deny_platform(job)
    _email(job, args)
    if "login" in args:
        job.args["login"] = _str(args, "login", LOGIN_RE, "args.login", 254)
    if "name" in args:
        job.args["name"] = _str(args, "name", NAME_RE, "args.name", 100)
    job.args["role"] = _enum(args, "role", ODOO_USER_ROLES, "args.role")
    job.args["active"] = _bool(args, "active", "args.active")
    job.pre_dry_run = not job.dry_run


def v_odoo_tenant_config(job: Job, args: dict[str, Any]) -> None:
    _keys(args, {"tenant_check"}, set(), "args")
    _deny_platform(job)
    job.args["tenant_check"] = _enum(args, "tenant_check", TENANT_CHECK_MODES, "args.tenant_check")
    job.pre_dry_run = not job.dry_run
    if job.args["tenant_check"] == "strict" and not job.dry_run:
        job.alert_reason = "odoo_tenant_config strict"


def v_tenant_state(job: Job, args: dict[str, Any]) -> None:
    _keys(args, set(), set(), "args")
    _deny_platform(job)
    job.pre_dry_run = not job.dry_run
    if job.type == "tenant_suspend" and not job.dry_run:
        job.alert_reason = "tenant_suspend"


VALIDATORS: dict[str, Callable[[Job, dict[str, Any]], None]] = {
    "odoo_db_provision": v_db_provision,
    "odoo_route": v_route,
    "odoo_sso_provision": v_sso_provision,
    "odoo_sso_disable": v_sso_disable,
    "odoo_sso_user": v_sso_user,
    "kc_realm_sync": v_kc_realm_sync,
    "kc_org_ensure": v_kc_org_ensure,
    "kc_user_ensure": v_kc_user_ensure,
    "kc_user_set_roles": v_kc_user_set_roles,
    "kc_user_set_enabled": v_kc_user_set_enabled,
    "kc_user_action_email": v_kc_user_action_email,
    "odoo_user_ensure": v_odoo_user_ensure,
    "odoo_tenant_config": v_odoo_tenant_config,
    "tenant_suspend": v_tenant_state,
    "tenant_resume": v_tenant_state,
}


def build_argv(cfg: Config, job: Job, dry: bool) -> list[str]:
    """argv tetap per tipe (plan 05 §4.2). Semua nilai sudah lolos regex. Nama DB/realm/path TIDAK pernah dari job."""
    a = job.args
    script = os.path.join(cfg.scripts_dir, SCRIPTS[job.type])
    sub = KC_USER_SUBCOMMANDS.get(job.type)
    argv = [script, sub, job.slug, job.env] if sub else [script, job.slug, job.env]
    if job.type == "odoo_db_provision":
        if "host" in a:
            argv += ["--host", a["host"]]
    elif job.type == "odoo_route":
        if a["remove"]:
            argv.append("--remove")
        elif "host" in a:
            argv += ["--host", a["host"]]
    elif job.type in ("odoo_sso_provision", "odoo_sso_disable"):
        for h in a["hosts"]:
            argv += ["--host", h]
        if job.type == "odoo_sso_disable":
            argv.append("--disable")
        else:
            if a["rotate_secret"]:
                argv.append("--rotate-secret")
            if a["skip_smoke"]:
                argv.append("--skip-smoke")
    elif job.type == "odoo_sso_user":
        argv += ["--email", a["email"]]
        if "login" in a:
            argv += ["--login", a["login"]]
        if a["create_kc"]:
            argv.append("--create-kc")
        if a["admin"]:
            argv.append("--admin")
        argv.append({"grant": "--grant", "revoke": "--revoke", "resend_invite": "--resend-invite"}[a["action"]])
    elif job.type == "kc_realm_sync":
        if a["approve"]:
            argv.append("--approve")
    elif job.type == "kc_org_ensure":
        argv += ["--tenant-id", a["tenant_id"]]
    elif job.type == "kc_user_ensure":
        argv += ["--email", a["email"], "--tenant-id", a["tenant_id"]]
        if "name" in a:
            argv += ["--name", a["name"]]
        if not a["invite"]:
            argv.append("--no-invite")
    elif job.type == "kc_user_set_roles":
        argv += ["--email", a["email"], "--cp-role", a["cp_role"]]
        if "odoo" in a:
            argv += ["--odoo", a["odoo"]]
    elif job.type == "kc_user_set_enabled":
        argv += ["--email", a["email"], "--enabled", "true" if a["enabled"] else "false"]
    elif job.type == "kc_user_action_email":
        argv += ["--email", a["email"], "--action", a["action"]]
    elif job.type == "odoo_user_ensure":
        argv += ["--email", a["email"]]
        if "login" in a:
            argv += ["--login", a["login"]]
        if "name" in a:
            argv += ["--name", a["name"]]
        argv += ["--role", a["role"], "--active", "true" if a["active"] else "false"]
    elif job.type == "odoo_tenant_config":
        argv += ["--tenant-check", a["tenant_check"]]
    elif job.type == "tenant_suspend":
        argv.append("--suspend")
    elif job.type == "tenant_resume":
        argv.append("--resume")
    else:  # pragma: no cover — VALIDATORS dan cabang di atas harus sinkron
        raise ValueError(f"tipe tanpa argv: {job.type}")
    if dry:
        argv.append("--dry-run")
    return argv


def route_hosts(cfg: Config, slug: str, env: str) -> set[str]:
    """Host(`…`) di traefik/dynamic/clients/<slug>-<env>.yml (root-owned, hasil render-client-route.sh).
    File tidak ada / tidak memenuhi syarat → set kosong."""
    path = os.path.join(cfg.infra_dir, "traefik", "dynamic", "clients", f"{slug}-{env}.yml")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ELOOP):
            return set()
        raise
    try:
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != cfg.root_uid or st.st_mode & 0o022
                or st.st_size > MAX_ROUTE_BYTES):
            return set()
        data = os.read(fd, MAX_ROUTE_BYTES + 1)
    finally:
        os.close(fd)
    if not data.startswith(ROUTE_HEADER):
        return set()
    return {m.decode("ascii") for m in ROUTE_HOST_RE.findall(data)}


def check_hosts(cfg: Config, job: Job) -> None:
    """odoo_sso_*: setiap host harus ada di file route tenant (redirect URI tidak bisa diarahkan ke host asing).
    Pengecualian: skip_smoke=true (onboarding sebelum route, runbook A2) hanya untuk host default
    <slug>.<erp|staging>.bimacreative.tech."""
    if job.type not in ("odoo_sso_provision", "odoo_sso_disable"):
        return
    known = route_hosts(cfg, job.slug, job.env)
    dflt = default_host(job.slug, job.env)
    for h in job.args["hosts"]:
        if h in known:
            continue
        if job.type == "odoo_sso_provision" and job.args["skip_smoke"] and h == dflt:
            continue
        raise Reject("rejected_validation", "args.hosts: host tidak ada di file route tenant")


# ------------------------------------------------------------------------------------------------ ledger & kuota
def read_ledger(work_fd: int, now: float) -> list[tuple[float, str, str, str]]:
    try:
        fd = os.open("ledger", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=work_fd)
    except FileNotFoundError:
        return []
    with os.fdopen(fd, "r", encoding="ascii", errors="replace") as fh:
        lines = fh.read().splitlines()
    out = []
    for line in lines:
        parts = line.split(" ")
        if len(parts) != 4 or not parts[0].isdigit() or not UUID_RE.fullmatch(parts[1]):
            continue
        ts = float(parts[0])
        if now - ts <= LEDGER_KEEP_S:
            out.append((ts, parts[1], parts[2], parts[3]))
    return out


def write_ledger(cfg: Config, work_fd: int, entries: list[tuple[float, str, str, str]]) -> None:
    data = "".join(f"{int(ts)} {jid} {jt} {fl}\n" for ts, jid, jt, fl in entries).encode("ascii")
    write_atomic(cfg, work_fd, work_fd, "ledger", data, 0o600, cfg.root_gid)


def check_quota(job: Job, ledger: list[tuple[float, str, str, str]], quota: dict[str, int], now: float) -> None:
    acc = [(ts, jt, fl) for ts, _jid, jt, fl in ledger if fl.startswith("accepted")]

    def count(window: int, pred: Callable[[str, str], bool]) -> int:
        return sum(1 for ts, jt, fl in acc if now - ts < window and pred(jt, fl))

    if count(3600, lambda jt, fl: True) >= quota["total_per_hour"]:
        raise Reject("rejected_quota", "kuota total job/jam habis")
    for types, window, key, msg in TYPE_QUOTAS:
        if job.type in types and count(window, lambda jt, fl, ts=types: jt in ts) >= quota[key]:
            raise Reject("rejected_quota", msg)
    if job.rotate and count(86400, lambda jt, fl: "rotate" in fl.split(",")) >= quota["rotate_secret_per_day"]:
        raise Reject("rejected_quota", "kuota rotate_secret/24 jam habis")
    if job.disable and count(3600, lambda jt, fl: "disable" in fl.split(",")) >= quota["kc_user_disable_per_hour"]:
        raise Reject("rejected_quota", "kuota kc_user disable/jam habis")


# ------------------------------------------------------------------------------------------------ eksekusi & hasil
def sanitize_line(line: str) -> str:
    # Non-printable (Cc/Cf/Zl/Zp…: ESC, bidi override U+202E, zero-width) → '?'; teks UTF-8 biasa dipertahankan.
    line = "".join(c if c.isprintable() or c == "\t" else "?" for c in line)
    if REDACT_RE.search(line):
        return "[redacted]"
    return line[:TAIL_LINE_MAX]


def make_tail(text: str) -> list[str]:
    lines = [sanitize_line(ln) for ln in text.splitlines()][-TAIL_MAX_LINES:]
    total = 0
    out: list[str] = []
    for ln in reversed(lines):
        total += len(ln.encode()) + 1
        if total > TAIL_MAX_BYTES:
            break
        out.append(ln)
    return list(reversed(out))


def parse_result(text: str) -> dict[str, str] | None:
    """Baris `RESULT k=v …` terakhir → dict dengan kunci allowlist dan nilai ter-regex; kunci lain (secret*) dibuang."""
    last = None
    for ln in text.splitlines():
        if ln.startswith("RESULT "):
            last = ln
    if last is None:
        return None
    out: dict[str, str] = {}
    for tok in last[len("RESULT "):].split(" "):
        k, sep, v = tok.partition("=")
        if sep and k in RESULT_KEYS and RESULT_VAL_RE.fullmatch(v):
            out[k] = v
    return out


def read_segment(log_fd: int, start: int, max_bytes: int = 256 * 1024) -> str:
    end = os.lseek(log_fd, 0, os.SEEK_END)
    begin = max(start, end - max_bytes)
    os.lseek(log_fd, begin, os.SEEK_SET)
    data = b""
    while len(data) < end - begin:
        chunk = os.read(log_fd, end - begin - len(data))
        if not chunk:
            break
        data += chunk
    return data.decode("utf-8", errors="replace")


@dataclass
class PhaseResult:
    exit_code: int | None
    timed_out: bool
    text: str


def run_phase(cfg: Config, argv: list[str], timeout: int, log_fd: int, phase: str) -> PhaseResult:
    os.write(log_fd, f"--- infra-job phase={phase} {utc_iso(cfg.now())} argv={json.dumps(argv)}\n".encode())
    start = os.lseek(log_fd, 0, os.SEEK_END)
    proc = subprocess.Popen(  # noqa: S603 — argv list tetap (build_argv), tanpa shell, env bersih
        argv,
        stdin=subprocess.DEVNULL,
        stdout=log_fd,
        stderr=log_fd,
        cwd=cfg.infra_dir,
        env=dict(CLEAN_ENV),
        close_fds=True,
        start_new_session=True,
        shell=False,
    )
    timed_out = False
    try:
        rc: int | None = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        _killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=cfg.kill_grace_s)
        except subprocess.TimeoutExpired:
            _killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        rc = proc.returncode
    # Tidak ada killpg setelah leader di-reap (pgid bisa dipakai ulang);
    # sisa proses dibunuh systemd (KillMode=control-group).
    text = read_segment(log_fd, start)
    os.write(log_fd, f"--- infra-job phase={phase} exit={rc} timeout={timed_out}\n".encode())
    return PhaseResult(rc, timed_out, text)


def _killpg(pgid: int, sig: int) -> None:
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def classify_failure(ph: PhaseResult) -> str:
    if ph.timed_out:
        return "timeout_state_unknown"
    for ln in reversed(ph.text.splitlines()[-5:]):
        if LOCK_MSG_RE.match(ln.strip()):
            return "locked"
    return "script_exit"


# ------------------------------------------------------------------------------------------------ dispatcher
class Dispatcher:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.fds: dict[str, int] = {}
        self.alerts: list[str] = []
        self.quota = dict(DEFAULT_QUOTA)
        self.timeouts = dict(DEFAULT_TIMEOUTS)
        self.job_types: tuple[str, ...] = DEFAULT_JOB_TYPES
        self.config_error: str | None = None

    # ---- tata letak
    def open_layout(self) -> None:
        cfg = self.cfg
        inst_fd = open_dir(cfg.inst_dir)
        st = os.fstat(inst_fd)
        check_owner_mode(st, cfg.root_uid, None, None, cfg.inst_dir)
        if st.st_mode & 0o022:
            raise LayoutError(f"{cfg.inst_dir}: writable group/other")
        self.fds["inst"] = inst_fd
        for rel, owner, group, mode in LAYOUT:
            parent = self.fds["spool"] if rel.startswith("spool/") else inst_fd
            fd = open_dir(os.path.basename(rel), dir_fd=parent)
            uid = cfg.root_uid if owner == "root" else cfg.job_uid
            gid = cfg.root_gid if group == "root" else cfg.job_gid
            check_owner_mode(os.fstat(fd), uid, gid, mode, f"{cfg.inst_dir}/{rel}")
            self.fds[rel] = fd
        log_parent = cfg.log_dir
        check_root_dir(cfg, log_parent)
        fd = open_dir(os.path.join(log_parent, cfg.instance))
        check_owner_mode(os.fstat(fd), cfg.root_uid, cfg.root_gid, 0o700, f"{log_parent}/{cfg.instance}")
        self.fds["log"] = fd
        check_root_dir(cfg, cfg.scripts_dir)
        check_root_dir(cfg, os.path.join(cfg.scripts_dir, "lib"))

    def check_scripts(self) -> None:
        """Skrip tipe yang diizinkan instance ini: milik root, executable, tidak writable g/o. Skrip tipe di luar
        allowlist tidak diperiksa (boleh belum ada di host). Tidak memenuhi → LayoutError/OSError (run gagal → email
        OnFailure)."""
        for name in sorted({SCRIPTS[t] for t in self.job_types}):
            check_root_file(self.cfg, os.path.join(self.cfg.scripts_dir, name), want_exec=True)

    def close(self) -> None:
        for fd in self.fds.values():
            os.close(fd)
        self.fds.clear()

    # ---- helper
    def disabled(self) -> bool:
        try:
            os.lstat(os.path.join(self.cfg.etc_dir, f"{self.cfg.instance}.disabled"))
            return True
        except FileNotFoundError:
            return False

    def write_result(self, job_id: str, payload: dict[str, Any]) -> None:
        data = (json.dumps(payload, ensure_ascii=True, sort_keys=False) + "\n").encode("ascii")
        write_atomic(self.cfg, self.fds["work"], self.fds["results"], f"{job_id}.json", data, 0o640, self.cfg.job_gid)

    def result_exists(self, job_id: str) -> bool:
        try:
            os.stat(f"{job_id}.json", dir_fd=self.fds["results"], follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False

    def to_rejected(self, wname: str, label: str) -> None:
        dst = f"{label}.{time.time_ns()}"
        try:
            os.rename(wname, dst, src_dir_fd=self.fds["work"], dst_dir_fd=self.fds["rejected"])
        except FileNotFoundError:
            pass

    def base_result(self, job_id: str, jtype: str | None, dry_run: bool | None, started: float) -> dict[str, Any]:
        return {
            "v": 1,
            "job_id": job_id,
            "instance": self.cfg.instance,
            "type": jtype,
            "dry_run": dry_run,
            "state": "running",
            "phase": None,
            "exit_code": None,
            "error_code": None,
            "error_detail": None,
            "started_at": utc_iso(started),
            "finished_at": None,
            "duration_ms": None,
            "result": {},
            "tail": [],
        }

    def finish(self, res: dict[str, Any], started: float, state: str, error_code: str | None = None,
               detail: str | None = None) -> dict[str, Any]:
        now = self.cfg.now()
        res.update(state=state, error_code=error_code, error_detail=detail, finished_at=utc_iso(now),
                   duration_ms=int(max(0.0, now - started) * 1000))
        return res

    # ---- satu run
    def run(self) -> int:
        cfg = self.cfg
        t0 = cfg.now()
        self.open_layout()
        try:
            limits = load_limits(cfg)
            self.quota, self.timeouts, self.job_types = limits.quota, limits.timeouts, limits.job_types
        except LayoutError as exc:
            self.config_error = str(exc)
            log(cfg, syslog.LOG_ERR, f"inst={cfg.instance} konfigurasi tidak valid → semua job disabled: {exc}")
            self.alerts.append(
                f"konfigurasi /etc/infra-jobs/{cfg.instance}.conf tidak valid → semua job ditolak (disabled)")
        self.check_scripts()
        names = sorted(os.listdir(self.fds["spool/new"]))
        processed = 0
        for name in names:
            if processed >= MAX_FILES_PER_RUN or cfg.now() - t0 > cfg.run_budget_s:
                log(cfg, syslog.LOG_WARNING,
                    f"inst={cfg.instance} batas run tercapai; sisa file diproses run berikutnya")
                break
            processed += 1
            self.handle(name)
        self.send_alerts()
        return 0

    def handle(self, name: str) -> None:
        cfg = self.cfg
        started = cfg.now()
        wname = f"job.{time.time_ns()}"
        try:
            os.rename(name, wname, src_dir_fd=self.fds["spool/new"], dst_dir_fd=self.fds["work"])
        except FileNotFoundError:
            return
        if not JOB_FILE_RE.fullmatch(name):
            self.to_rejected(wname, "badname")
            log(cfg, syslog.LOG_WARNING, f"inst={cfg.instance} REJECT nama file tidak valid (dipindah ke rejected/)")
            self.alerts.append("file dengan nama tidak valid di spool/new → rejected/ (tanpa hasil)")
            return
        job_id = name[:-5]
        ledger = read_ledger(self.fds["work"], started)
        if any(e[1] == job_id for e in ledger) or self.result_exists(job_id):
            self.to_rejected(wname, f"{job_id}.duplicate")
            log(cfg, syslog.LOG_WARNING,
                f"inst={cfg.instance} id={job_id} REJECT job_id duplikat (hasil lama dipertahankan)")
            self.alerts.append(f"job={job_id} job_id duplikat — tidak dieksekusi ulang")
            return
        res = self.base_result(job_id, None, None, started)
        digest = "-"
        try:
            raw = self.read_job(wname)
            digest = hashlib.sha256(raw).hexdigest()
            obj = parse_job_bytes(raw)
            if isinstance(obj.get("type"), str) and obj["type"] in JOB_TYPES:
                res["type"] = obj["type"]
            if self.config_error or self.disabled():
                raise Reject("disabled", "dispatcher instance ini dinonaktifkan (kill switch/konfigurasi)")
            job = validate_job(obj, cfg.instance, job_id, self.job_types)
            res["dry_run"] = job.dry_run
            check_hosts(cfg, job)
            check_quota(job, ledger, self.quota, started)
        except Reject as rej:
            flag = "disabled" if rej.code == "disabled" else "rejected"
            ledger.append((started, job_id, res["type"] or "-", flag))
            write_ledger(cfg, self.fds["work"], ledger)
            self.write_result(job_id, self.finish(res, started, "failed", rej.code, rej.detail))
            self.to_rejected(wname, f"{job_id}.json")
            log(cfg, syslog.LOG_WARNING,
                f"inst={cfg.instance} id={job_id} type={res['type'] or '-'} REJECT {rej.code}: {rej.detail} "
                f"sha256={digest}")
            if rej.code.startswith("rejected_"):
                self.alerts.append(f"job={job_id} type={res['type'] or '-'} {rej.code}: {rej.detail}")
            return
        # diterima: catat dulu (idempotensi walau dispatcher mati di tengah jalan) → hasil running → eksekusi
        ledger.append((started, job_id, job.type, job.ledger_flags))
        write_ledger(cfg, self.fds["work"], ledger)
        self.write_result(job_id, res)
        log(cfg, syslog.LOG_INFO,
            f"inst={cfg.instance} id={job_id} type={job.type} slug={job.slug} env={job.env} dry_run={job.dry_run} "
            f"actor={job.actor} START sha256={digest}")
        if job.alert_reason:
            self.alerts.append(f"job={job_id} aksi sensitif {job.alert_reason}: slug={job.slug} env={job.env} "
                               f"actor={job.actor}")
        try:
            self.execute(job, res, started)
        finally:
            try:
                os.unlink(wname, dir_fd=self.fds["work"])
            except FileNotFoundError:
                pass
        log(cfg, syslog.LOG_INFO if res["state"] == "succeeded" else syslog.LOG_WARNING,
            f"inst={cfg.instance} id={job_id} type={job.type} slug={job.slug} env={job.env} actor={job.actor} "
            f"state={res['state']} error={res['error_code'] or '-'} exit={res['exit_code']} "
            f"dur_ms={res['duration_ms']} "
            f"sha256={digest}")

    def read_job(self, wname: str) -> bytes:
        cfg = self.cfg
        wfd = self.fds["work"]
        st = os.stat(wname, dir_fd=wfd, follow_symlinks=False)
        if not stat.S_ISREG(st.st_mode):
            raise Reject("rejected_validation", "bukan file reguler (symlink/FIFO/dir/device)")
        if st.st_uid != cfg.job_uid:
            raise Reject("rejected_validation", "pemilik file bukan user job instance ini")
        if st.st_nlink != 1:
            raise Reject("rejected_validation", "file hardlink (nlink ≠ 1)")
        if stat.S_IMODE(st.st_mode) & ~0o644:
            raise Reject("rejected_validation", "mode file tidak diizinkan (maks 0644)")
        if st.st_size > MAX_JOB_BYTES:
            raise Reject("rejected_validation", f"file > {MAX_JOB_BYTES} byte")
        try:
            fd = os.open(wname, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOCTTY, dir_fd=wfd)
        except OSError:
            raise Reject("rejected_validation", "file tidak bisa dibuka") from None
        try:
            fst = os.fstat(fd)
            if (fst.st_ino, fst.st_dev) != (st.st_ino, st.st_dev) or not stat.S_ISREG(fst.st_mode) or fst.st_nlink != 1:
                raise Reject("rejected_validation", "file berubah saat dibaca")
            raw = b""
            while len(raw) <= MAX_JOB_BYTES:
                chunk = os.read(fd, MAX_JOB_BYTES + 1 - len(raw))
                if not chunk:
                    break
                raw += chunk
        finally:
            os.close(fd)
        return raw

    def open_log(self, job_id: str) -> int:
        return os.open(f"{job_id}.log", os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600,
                       dir_fd=self.fds["log"])

    def execute(self, job: Job, res: dict[str, Any], started: float) -> None:
        cfg = self.cfg
        log_fd = self.open_log(job.job_id)
        try:
            if job.pre_dry_run:
                res["phase"] = "dry_run"
                ph = run_phase(cfg, build_argv(cfg, job, True), self.timeouts["dry_run"], log_fd, "dry_run")
                parsed = parse_result(ph.text)
                res["exit_code"] = ph.exit_code
                res["tail"] = make_tail(ph.text)
                if ph.exit_code != 0 or ph.timed_out:
                    res["result"] = parsed or {}
                    self.finish(res, started, "failed", classify_failure(ph), "dry-run pendahulu gagal")
                    return
                # Tipe lama: `blockers` WAJIB ada dan 0 (tanpa RESULT → blocked_dry_run, perilaku 1.0.0). Tipe Fase 1
                # (kontrak §1: lanjut bila exit 0): baris RESULT wajib, `blockers` opsional tetapi bila ada harus 0.
                if parsed is None and job.type not in LEGACY_JOB_TYPES:
                    self.finish(res, started, "failed", "script_exit", "dry-run pendahulu tanpa baris RESULT")
                    return
                blockers = (parsed or {}).get("blockers", "" if job.type in LEGACY_JOB_TYPES else "0")
                if not blockers.isdigit() or int(blockers) > 0:
                    res["result"] = parsed or {}
                    self.finish(res, started, "failed", "blocked_dry_run",
                                "dry-run melaporkan blocker; tidak diterapkan")
                    return
            res["phase"] = "dry_run" if job.dry_run else "apply"
            timeout = self.timeouts["dry_run"] if job.dry_run else self.timeouts[job.type]
            ph = run_phase(cfg, build_argv(cfg, job, job.dry_run), timeout, log_fd, res["phase"])
            parsed = parse_result(ph.text)
            res["exit_code"] = ph.exit_code
            res["result"] = parsed or {}
            res["tail"] = make_tail(ph.text)
            if ph.timed_out or ph.exit_code != 0:
                self.finish(res, started, "failed", classify_failure(ph), "skrip gagal")
            elif parsed is None:
                self.finish(res, started, "failed", "script_exit", "exit 0 tanpa baris RESULT")
            else:
                self.finish(res, started, "succeeded")
        except Exception as exc:  # noqa: BLE001 — job harus selalu mendapat hasil final
            self.finish(res, started, "failed", "script_exit", f"kesalahan dispatcher: {type(exc).__name__}")
            log(cfg, syslog.LOG_ERR, f"inst={cfg.instance} id={job.job_id} kesalahan dispatcher: {exc!r}")
        finally:
            os.close(log_fd)
            self.write_result(job.job_id, res)

    # ---- alert (satu email per run; maks ALERT_MAX_PER_HOUR per instance, sisanya hanya journal)
    def send_alerts(self) -> None:
        if not self.alerts:
            return
        cfg = self.cfg
        wfd = self.fds["work"]
        now = cfg.now()
        state: dict[str, Any] = {"sent": [], "suppressed": 0}
        try:
            fd = os.open("alert-state", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=wfd)
            with os.fdopen(fd, "rb") as fh:
                loaded = json.loads(fh.read(65536).decode("ascii"))
            if isinstance(loaded, dict):
                state["sent"] = [t for t in loaded.get("sent", []) if isinstance(t, (int, float)) and now - t < 3600]
                sup = loaded.get("suppressed", 0)
                state["suppressed"] = sup if type(sup) is int and sup >= 0 else 0
        except (OSError, ValueError, UnicodeDecodeError):
            pass
        if len(state["sent"]) >= ALERT_MAX_PER_HOUR:
            state["suppressed"] += len(self.alerts)
            log(cfg, syslog.LOG_WARNING, f"inst={cfg.instance} email alert ditahan (batas {ALERT_MAX_PER_HOUR}/jam): "
                                         f"{len(self.alerts)} kejadian — lihat journalctl -t infra-job")
        else:
            host = socket.gethostname()
            subject = f"[infra-job] {host} {cfg.instance}: {len(self.alerts)} kejadian"
            body = [f"Dispatcher infra-job instance {cfg.instance} di {host} ({utc_iso(now)}):", ""]
            body += [f"- {a}" for a in self.alerts]
            if state["suppressed"]:
                body += ["", f"(+ {state['suppressed']} kejadian sebelumnya tidak di-email karena batas anti-spam)"]
            body += ["", "Detail: journalctl -t infra-job; file ditolak di /var/lib/infra-jobs/"
                     f"{cfg.instance}/rejected/ (root). Kill switch: touch /etc/infra-jobs/{cfg.instance}.disabled",
                     "Tidak ada email/PII di pesan ini."]
            ok = (cfg.alert or self._send_mail)(subject, "\n".join(body) + "\n")
            if ok:
                state["sent"].append(now)
                state["suppressed"] = 0
            else:
                log(cfg, syslog.LOG_ERR, f"inst={cfg.instance} email alert GAGAL dikirim ({len(self.alerts)} kejadian)")
        write_atomic(cfg, wfd, wfd, "alert-state", json.dumps(state).encode("ascii"), 0o600, cfg.root_gid)

    def _send_mail(self, subject: str, body: str) -> bool:
        cfg = self.cfg
        env = dict(CLEAN_ENV)
        try:
            check_root_file(cfg, cfg.alert_env_file, max_bytes=16384)
            with open(cfg.alert_env_file, encoding="utf-8") as fh:
                for line in fh:
                    k, sep, v = line.strip().partition("=")
                    if sep and k in ALERT_ENV_KEYS:
                        env[k] = v.strip('"')
            mailer = os.path.join(cfg.scripts_dir, "lib", "infra_alert_mail.py")
            check_root_file(cfg, mailer)
            r = subprocess.run(  # noqa: S603 — argv tetap, tanpa shell
                ["/usr/bin/python3", "-I", mailer, subject], input=body.encode(), env=env, cwd="/",
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=90, check=False)
        except (OSError, LayoutError, subprocess.TimeoutExpired) as exc:
            log(cfg, syslog.LOG_ERR, f"inst={cfg.instance} alert: {type(exc).__name__}: {exc}")
            return False
        if r.returncode != 0:
            log(cfg, syslog.LOG_ERR, f"inst={cfg.instance} alert exit {r.returncode}: "
                                     f"{r.stderr.decode(errors='replace')[-300:]}")
        return r.returncode == 0


def run(cfg: Config) -> int:
    """Satu run dispatcher untuk cfg.instance (dengan flock per instance). Dipakai main() dan unit test."""
    lock_path = os.path.join(cfg.lock_dir, f"infra-job-{cfg.instance}.lock")
    lfd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(lfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    log(cfg, syslog.LOG_WARNING, f"inst={cfg.instance} lock {lock_path} dipegang run lain; keluar")
                    return 0
                time.sleep(0.5)
        d = Dispatcher(cfg)
        try:
            return d.run()
        finally:
            d.close()
    finally:
        os.close(lfd)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in INSTANCES:
        print("pemakaian: infra-job <prod|staging>", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("infra-job: harus root", file=sys.stderr)
        return 2
    os.umask(0o077)
    syslog.openlog("infra-job", syslog.LOG_PID, syslog.LOG_USER)
    inst = argv[1]
    try:
        cfg = production_config(inst)
        return run(cfg)
    except (LayoutError, OSError, KeyError) as exc:
        syslog.syslog(syslog.LOG_ERR, f"inst={inst} FATAL {type(exc).__name__}: {exc}")
        print(f"infra-job: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
