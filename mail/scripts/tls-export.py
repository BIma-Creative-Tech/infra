#!/usr/bin/env python3
"""Ekspor sertifikat + kunci SATU hostname dari acme.json Traefik untuk docker-mailserver (QA-T17B-02 / B18).

Menggantikan mount acme.json penuh (kunci privat SEMUA hostname) ke container mailserver. Hanya
`<out>/fullchain.pem` (0644) dan `<out>/privkey.pem` (0600) milik root yang ditulis, di direktori 0700; direktori
itu di-mount read-only ke DMS (`SSL_TYPE=manual`, SSL_CERT_PATH/SSL_KEY_PATH — docs DMS v16.0.1 security/ssl.md
§Bring Your Own Certificates). Change detection DMS (helpers/change-detection.sh, check-for-changes.sh
`_ssl_changes`) memantau kedua file → `_setup_ssl` + reload Postfix/Dovecot saat isinya berubah.

Dijalankan root oleh mail-tls-export.service (dipicu .path saat acme.json berubah + .timer harian), role Ansible
`mail_tls_export`. Idempoten: bila isi sama, tidak ada file yang disentuh (DMS tidak reload).

Validasi sebelum menulis (gagal → exit 1, file lama TIDAK diubah): tepat satu sertifikat untuk domain di resolver,
PEM valid, sertifikat berlaku untuk hostname (openssl -checkhost), belum kedaluwarsa, kunci cocok dengan sertifikat.
Setelah ekspor/unchanged: sertifikat yang terpasang kedaluwarsa < --warn-days hari → exit 2 (OnFailure → alert).

Isi kunci privat TIDAK pernah dicetak; ke openssl dialirkan lewat stdin. Output hanya metadata (serial, notAfter).
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

CERT_NAME = "fullchain.pem"
KEY_NAME = "privkey.pem"
CERT_MODE = 0o644
KEY_MODE = 0o600
DIR_MODE = 0o700
OPENSSL = "/usr/bin/openssl"
EXIT_OK = 0
EXIT_ERROR = 1
EXIT_EXPIRING = 2


class ExportError(Exception):
    """Kegagalan validasi/ekspor; pesan aman untuk log (tanpa isi kunci)."""


def log(msg: str) -> None:
    print(msg, flush=True)


def openssl(args: list[str], data: bytes) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(  # noqa: S603 - argumen tetap, tanpa shell
        [OPENSSL, *args], input=data, capture_output=True, check=False, timeout=30
    )


def find_cert(acme: dict, resolver: str, domain: str) -> tuple[bytes, bytes]:
    store = acme.get(resolver)
    if not isinstance(store, dict):
        raise ExportError(f"resolver '{resolver}' tidak ada di acme.json")
    matches = []
    for entry in store.get("Certificates") or []:
        dom = entry.get("domain") or {}
        names = [dom.get("main"), *(dom.get("sans") or [])]
        if domain in names:
            matches.append(entry)
    if len(matches) != 1:
        raise ExportError(f"butuh tepat 1 sertifikat untuk {domain} di resolver {resolver}, ditemukan {len(matches)}")
    try:
        cert = base64.b64decode(matches[0]["certificate"], validate=True)
        key = base64.b64decode(matches[0]["key"], validate=True)
    except (KeyError, TypeError, binascii.Error) as exc:
        raise ExportError(f"field certificate/key tidak valid untuk {domain}: {type(exc).__name__}") from None
    return cert, key


def validate(cert: bytes, key: bytes, domain: str) -> None:
    if not cert.startswith(b"-----BEGIN CERTIFICATE-----"):
        raise ExportError("sertifikat bukan PEM")
    if not (key.startswith(b"-----BEGIN ") and b"PRIVATE KEY-----" in key.split(b"\n", 1)[0]):
        raise ExportError("kunci bukan PEM private key")
    chk = openssl(["x509", "-noout", "-checkhost", domain], cert)
    if chk.returncode != 0 or b"does match certificate" not in chk.stdout:
        raise ExportError(f"sertifikat tidak berlaku untuk {domain} (checkhost)")
    if openssl(["x509", "-noout", "-checkend", "0"], cert).returncode != 0:
        raise ExportError("sertifikat sudah kedaluwarsa")
    cert_pub = openssl(["x509", "-noout", "-pubkey"], cert)
    key_pub = openssl(["pkey", "-pubout"], key)
    if cert_pub.returncode != 0 or key_pub.returncode != 0:
        raise ExportError("openssl gagal membaca sertifikat/kunci")
    if cert_pub.stdout != key_pub.stdout:
        raise ExportError("kunci privat tidak cocok dengan sertifikat")


def cert_meta(cert: bytes) -> str:
    out = openssl(["x509", "-noout", "-serial", "-enddate", "-issuer"], cert)
    return " ".join(out.stdout.decode(errors="replace").split("\n")).strip()


def write_atomic(path: Path, data: bytes, mode: int) -> None:
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def read_or_none(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None


def export(args: argparse.Namespace) -> int:
    out = Path(args.out)
    try:
        acme = json.loads(Path(args.acme).read_text())
    except (OSError, ValueError) as exc:
        raise ExportError(f"gagal membaca {args.acme}: {type(exc).__name__}") from None
    cert, key = find_cert(acme, args.resolver, args.domain)
    validate(cert, key, args.domain)

    if not out.is_dir():
        if args.dry_run:
            log(f"dry-run: {out} belum ada (akan dibuat {oct(DIR_MODE)})")
        else:
            out.mkdir(mode=DIR_MODE, parents=False)
    elif not args.dry_run and (out.stat().st_mode & 0o077):
        os.chmod(out, DIR_MODE)

    cert_path, key_path = out / CERT_NAME, out / KEY_NAME
    same = read_or_none(cert_path) == cert and read_or_none(key_path) == key
    if same:
        # Pastikan mode tetap benar (idempoten) tanpa mengubah isi (DMS hanya membandingkan isi).
        if not args.dry_run:
            os.chmod(cert_path, CERT_MODE)
            os.chmod(key_path, KEY_MODE)
        log(f"unchanged domain={args.domain} {cert_meta(cert)}")
    elif args.dry_run:
        log(f"dry-run: akan menulis domain={args.domain} {cert_meta(cert)}")
    else:
        # Kunci & cert ditulis ke file sementara lalu di-rename berurutan (jendela antar-rename ~µs). Bila poll DMS
        # (2 s) tepat jatuh di antaranya, poll berikutnya melihat perubahan kedua dan memuat ulang pasangan lengkap.
        write_atomic(key_path, key, KEY_MODE)
        write_atomic(cert_path, cert, CERT_MODE)
        log(f"exported domain={args.domain} {cert_meta(cert)}")

    installed = read_or_none(cert_path) if not args.dry_run else cert
    if installed is None or openssl(["x509", "-noout", "-checkend", str(args.warn_days * 86400)], installed).returncode:
        log(f"WARNING: sertifikat {args.domain} kedaluwarsa < {args.warn_days} hari (perpanjangan Traefik gagal?)")
        return EXIT_EXPIRING
    return EXIT_OK


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--acme", default="/opt/infra/traefik/acme/acme.json")
    p.add_argument("--resolver", default="le-http")
    p.add_argument("--domain", default="mail.bimacreative.tech")
    p.add_argument("--out", default="/opt/infra/mail/data/tls")
    p.add_argument("--warn-days", type=int, default=20, help="exit 2 bila sertifikat terpasang habis < N hari")
    p.add_argument("--dry-run", action="store_true", help="validasi saja, tidak menulis apa pun")
    args = p.parse_args()
    os.umask(0o077)
    try:
        return export(args)
    except ExportError as exc:
        log(f"ERROR: {exc} — file di {args.out} tidak diubah")
        return EXIT_ERROR
    except OSError as exc:
        # Tulis gagal (disk penuh, read-only, izin): write_atomic menghapus file sementara; file lama tetap utuh.
        log(f"ERROR: I/O {type(exc).__name__} errno={exc.errno} path={exc.filename}")
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
