#!/usr/bin/env python3
"""pwhelper — helper ganti password mailbox self-service untuk webmail (ADR 0012, plan 08).

Berjalan DI DALAM container `mailserver` (DMS 16.0.1) di bawah supervisord (dipasang oleh user-patches.sh), sebagai root
(karena `setup email update` DMS menulis postfix-accounts.cf). Listen HANYA di IP mailserver pada network internal
`webmail-mail` (10.100.16.2) — satu-satunya anggota lain network itu = container `webmail` (Roundcube).

Kontrak (driver `httpapi` plugin password Roundcube 1.7.4, plugins/password/drivers/httpapi.php):
  POST /change   Content-Type: application/x-www-form-urlencoded   Authorization: Bearer <token>
  field: user, curpass, newpass (masing-masing tepat satu kali)
  200 "ok" = sukses; 4xx/5xx = gagal (Roundcube menampilkan pesan umum). Body TIDAK pernah memuat password.

Lapisan pemeriksaan (semua wajib lulus, urutan murah → mahal):
  1. kill switch (file `disabled`) → 503
  2. method/path/Content-Type/Content-Length (≤ 1024) → 4xx
  3. token Bearer (hmac.compare_digest) → 403
  4. rate limit per IP sumber & per alamat (in-memory) → 429
  5. alamat: regex ketat + ADA di allowlist (file) → 403
  6. password: charset ASCII tercetak tanpa spasi/`|`/`:`; baru 10–64 char, huruf + non-huruf, ≠ lama, tidak memuat
     local-part, tidak ada di deny list (hash PBKDF2 password default dari host) → 422
  7. password LAMA diverifikasi independen: IMAP LOGIN ke Dovecot 127.0.0.1:143 → 401 bila gagal
  8. `setup email update <alamat>` dengan password lewat STDIN (bukan argv) → 500 bila gagal
  9. tunggu Dovecot menerima password baru (change detection DMS, ±2–10 s) → 200 "ok"
Audit: JSON per baris ke /var/log/mail/pwhelper.log (host: /var/log/mailserver/dms/pwhelper.log) — tanpa password.
Marker: <STATE>/changed/<alamat> (timestamp) = password saat ini dipilih user (file secret host = password AWAL, basi).
Hanya Python stdlib.
"""
import argparse
import hashlib
import hmac
import imaplib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

CONF_DIR = "/tmp/docker-mailserver/pwhelper"      # = mail/data/config/pwhelper di host (disinkron bootstrap.sh)
TOKEN_FILE = os.path.join(CONF_DIR, "token")
ALLOW_FILE = os.path.join(CONF_DIR, "allowlist.txt")
DENY_FILE = os.path.join(CONF_DIR, "deny.pbkdf2")
DISABLED_FILE = os.path.join(CONF_DIR, "disabled")
STATE_DIR = os.path.join(CONF_DIR, "state")
AUDIT_LOG = "/var/log/mail/pwhelper.log"

ADDR_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}@[a-z0-9-]+(\.[a-z0-9-]+)+$")
# ASCII tercetak 0x21–0x7E KECUALI ':' (0x3A) dan '|' (0x7C) — pemisah postfix-accounts.cf/doveadm; tanpa spasi/kontrol.
PW_CHARS = r"[\x21-\x39\x3b-\x7b\x7d\x7e]"
NEWPW_RE = re.compile(r"^" + PW_CHARS + r"{10,64}$")
CURPW_RE = re.compile(r"^" + PW_CHARS + r"{1,128}$")
MAX_BODY = 1024

# Rate limit (jendela geser, in-memory; reset saat helper restart — lapisan tambahan di atas login_rate_limit Roundcube
# dan rate-limit Traefik). Semua request datang dari IP container webmail, jadi limit IP = limit global webmail.
RL_IP_MAX, RL_IP_WIN = 30, 600          # ≤ 30 request / 10 menit per IP sumber
RL_FAIL_MAX, RL_FAIL_WIN = 5, 900       # ≤ 5 kegagalan (password lama salah / kebijakan) / 15 menit per alamat
RL_OK_MAX, RL_OK_WIN = 3, 3600          # ≤ 3 penggantian sukses / jam per alamat

_lock = threading.Lock()
_hits_ip: dict = {}
_fail_addr: dict = {}
_ok_addr: dict = {}


def _prune(d: dict, key: str, win: int) -> list:
    now = time.monotonic()
    lst = [t for t in d.get(key, []) if now - t < win]
    d[key] = lst
    return lst


def audit(**kw) -> None:
    kw = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **kw}
    line = json.dumps(kw, ensure_ascii=True, separators=(",", ":"))
    try:
        fd = os.open(AUDIT_LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o640)
        with os.fdopen(fd, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line, flush=True)  # juga ke log supervisor


def read_small(path: str, limit: int = 65536) -> str:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="utf-8") as f:
        return f.read(limit)


def load_allowlist() -> set:
    out = set()
    for ln in read_small(ALLOW_FILE).splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#") and ADDR_RE.fullmatch(ln):
            out.add(ln)
    return out


def in_denylist(pw: str) -> bool:
    """deny.pbkdf2: baris `pbkdf2_sha256$<iter>$<salt_hex>$<hash_hex>` (dibuat host dari password default)."""
    try:
        data = read_small(DENY_FILE)
    except FileNotFoundError:
        return False
    for ln in data.splitlines():
        parts = ln.strip().split("$")
        if len(parts) != 4 or parts[0] != "pbkdf2_sha256":
            continue
        it, salt, want = int(parts[1]), bytes.fromhex(parts[2]), bytes.fromhex(parts[3])
        got = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, it)
        if hmac.compare_digest(got, want):
            return True
    return False


def imap_auth_ok(user: str, pw: str) -> bool:
    """Verifikasi independen lewat Dovecot (loopback 143: cleartext diizinkan untuk localhost)."""
    try:
        m = imaplib.IMAP4("127.0.0.1", 143, timeout=15)
    except OSError:
        raise
    try:
        m.login(user, pw)
        try:
            m.logout()
        except Exception:
            pass
        return True
    except imaplib.IMAP4.error:
        return False
    finally:
        try:
            m.shutdown()
        except Exception:
            pass


def set_password(user: str, pw: str) -> bool:
    # `setup email update <alamat>` membaca password dari STDIN (read -r -s, Enter + Confirm) bila argumen ke-2 kosong
    # (helpers/database/manage/postfix-accounts.sh `_password_request_if_missing`) → password tidak di argv proses ini.
    r = subprocess.run(
        ["/usr/local/bin/setup", "email", "update", user],
        input=f"{pw}\n{pw}\n", text=True, capture_output=True, timeout=60,
        env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"},
        close_fds=True,
    )
    return r.returncode == 0


def mark_changed(user: str) -> None:
    d = os.path.join(STATE_DIR, "changed")
    os.makedirs(d, mode=0o700, exist_ok=True)
    p = os.path.join(d, user)
    fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%S%z") + "\n")
    os.replace(p + ".tmp", p)


def policy_error(user: str, cur: str, new: str) -> str | None:
    if not NEWPW_RE.fullmatch(new):
        return "newpass_charset_or_length"
    if not re.search(r"[A-Za-z]", new) or not re.search(r"[^A-Za-z]", new):
        return "newpass_classes"
    if new == cur:
        return "newpass_equals_old"
    local = user.split("@", 1)[0]
    if len(local) >= 3 and local.lower() in new.lower():
        return "newpass_contains_localpart"
    if in_denylist(new):
        return "newpass_denylisted"
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "pwhelper"
    sys_version = ""
    protocol_version = "HTTP/1.0"
    timeout = 10  # detik — StreamRequestHandler: socket timeout (slowloris)

    def log_message(self, fmt, *args):  # jangan log default (bisa memuat path/query)
        return

    def _reply(self, code: int, body: str) -> None:
        b = (body + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=ascii")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            return self._reply(200, "ok")
        return self._reply(404, "not_found")

    def do_POST(self):
        ip = self.client_address[0]
        user = "-"
        try:
            if os.path.exists(DISABLED_FILE):
                audit(ip=ip, user=user, result="reject", reason="disabled")
                return self._reply(503, "disabled")
            if self.path != "/change":
                return self._reply(404, "not_found")
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/x-www-form-urlencoded":
                return self._reply(415, "bad_content_type")
            try:
                length = int(self.headers.get("Content-Length") or "-1")
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY:
                return self._reply(413, "bad_length")
            auth = self.headers.get("Authorization") or ""
            token = read_small(TOKEN_FILE).strip()
            if len(token) < 32 or not hmac.compare_digest(auth.encode(), f"Bearer {token}".encode()):
                audit(ip=ip, user=user, result="reject", reason="bad_token")
                return self._reply(403, "forbidden")

            with _lock:
                hits = _prune(_hits_ip, ip, RL_IP_WIN)
                if len(hits) >= RL_IP_MAX:
                    audit(ip=ip, user=user, result="reject", reason="ratelimit_ip")
                    return self._reply(429, "ratelimit")
                hits.append(time.monotonic())

            raw = self.rfile.read(length).decode("ascii", errors="strict")
            q = parse_qs(raw, keep_blank_values=True, strict_parsing=True, max_num_fields=3)
            if set(q) != {"user", "curpass", "newpass"} or any(len(v) != 1 for v in q.values()):
                audit(ip=ip, user=user, result="reject", reason="bad_fields")
                return self._reply(400, "bad_request")
            user_in, cur, new = q["user"][0], q["curpass"][0], q["newpass"][0]
            if not ADDR_RE.fullmatch(user_in):
                audit(ip=ip, user="-invalid-", result="reject", reason="bad_user_format")
                return self._reply(403, "forbidden")
            user = user_in
            if user not in load_allowlist():
                audit(ip=ip, user=user, result="reject", reason="not_allowlisted")
                return self._reply(403, "forbidden")

            with _lock:
                if len(_prune(_fail_addr, user, RL_FAIL_WIN)) >= RL_FAIL_MAX:
                    audit(ip=ip, user=user, result="reject", reason="ratelimit_user_fail")
                    return self._reply(429, "ratelimit")
                if len(_prune(_ok_addr, user, RL_OK_WIN)) >= RL_OK_MAX:
                    audit(ip=ip, user=user, result="reject", reason="ratelimit_user_ok")
                    return self._reply(429, "ratelimit")

            if not CURPW_RE.fullmatch(cur):
                with _lock:
                    _fail_addr.setdefault(user, []).append(time.monotonic())
                audit(ip=ip, user=user, result="reject", reason="curpass_charset")
                return self._reply(401, "bad_current")
            err = policy_error(user, cur, new)
            if err:
                with _lock:
                    _fail_addr.setdefault(user, []).append(time.monotonic())
                audit(ip=ip, user=user, result="reject", reason=err)
                return self._reply(422, "policy")
            if not imap_auth_ok(user, cur):
                with _lock:
                    _fail_addr.setdefault(user, []).append(time.monotonic())
                audit(ip=ip, user=user, result="reject", reason="bad_current")
                return self._reply(401, "bad_current")
            if not set_password(user, new):
                audit(ip=ip, user=user, result="error", reason="setup_failed")
                return self._reply(500, "error")
            # Tunggu change detection DMS memperbarui passdb Dovecot agar sesi Roundcube (yang langsung memakai password
            # baru) tidak terputus. Maks ±40 s.
            ok = False
            for _ in range(20):
                time.sleep(2)
                if imap_auth_ok(user, new):
                    ok = True
                    break
            with _lock:
                _ok_addr.setdefault(user, []).append(time.monotonic())
            try:
                mark_changed(user)
            except OSError:
                pass
            if not ok:
                audit(ip=ip, user=user, result="error", reason="not_propagated")
                return self._reply(500, "error")
            audit(ip=ip, user=user, result="ok", reason="changed")
            return self._reply(200, "ok")
        except (UnicodeDecodeError, ValueError):
            audit(ip=ip, user=user, result="reject", reason="bad_encoding")
            return self._reply(400, "bad_request")
        except Exception as e:  # jangan bocorkan detail ke klien
            audit(ip=ip, user=user, result="error", reason=type(e).__name__)
            return self._reply(500, "error")


class Server(HTTPServer):
    # Single-threaded (bukan ThreadingHTTPServer): penggantian password diserialkan — tidak ada balapan antar
    # `setup email update`. Beban sangat kecil (belasan user).
    allow_reuse_address = True
    request_queue_size = 8


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", required=True)
    ap.add_argument("--port", type=int, default=8080)
    a = ap.parse_args()
    if not re.fullmatch(r"10\.\d{1,3}\.\d{1,3}\.\d{1,3}", a.bind):
        print("bind harus IP privat 10.x (network internal webmail-mail)", file=sys.stderr)
        return 2
    # Tunggu interface network internal siap (container baru start).
    for _ in range(30):
        try:
            srv = Server((a.bind, a.port), Handler)
            break
        except OSError:
            time.sleep(2)
    else:
        print(f"gagal bind {a.bind}:{a.port}", file=sys.stderr)
        return 1
    socket.setdefaulttimeout(20)
    audit(ip="-", user="-", result="start", reason=f"listen {a.bind}:{a.port}")
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
