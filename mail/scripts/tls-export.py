#!/usr/bin/env python3
"""Ekspor sertifikat + kunci hostname mail (allowlist eksplisit) dari acme.json Traefik untuk docker-mailserver.

QA-T17B-02 / B18: menggantikan mount acme.json penuh (kunci privat SEMUA hostname) ke container mailserver.
ADR 0011 (2026-09-25): selain hostname utama, hostname mail per domain client (SNI) boleh diekspor bila disebut
eksplisit dengan --sni-domain.

Tata letak (`--out`, di-mount read-only ke DMS sebagai /etc/dms-tls):
  <out>/fullchain.pem (0644), <out>/privkey.pem (0600)       — hostname utama (--domain), SSL_CERT_PATH/SSL_KEY_PATH
                                                               DMS (docs DMS v16.0.1 security/ssl.md §Bring Your Own
                                                               Certificates); change detection DMS → reload.
  <out>/<sni-domain>/privkey.pem (0600), fullchain.pem (0600), chain.pem (0600, kunci diikuti fullchain — format
                                                               smtpd_tls_chain_files/tls_server_sni_maps Postfix)
                                                               — dipakai Dovecot `local_name` + Postfix
                                                               `tls_server_sni_maps`; reload oleh mail-tls-reload.path.
Semua direktori 0700 root. Urutan tulis per hostname SNI: privkey → chain → fullchain (fullchain terakhir = pemicu
unit reload, sehingga pasangan sudah lengkap saat reload).

Dijalankan root oleh mail-tls-export.service (dipicu .path saat acme.json berubah + .timer harian), role Ansible
`mail_tls_export`. Idempoten: bila isi sama, tidak ada file yang disentuh (tidak ada reload).

Validasi per hostname sebelum menulis (gagal → hostname itu dilewati, file lamanya TIDAK diubah; hostname lain tetap
diproses): tepat satu sertifikat untuk hostname di resolver, PEM valid, sertifikat berlaku untuk hostname (openssl
-checkhost), belum kedaluwarsa, kunci cocok dengan sertifikat. Exit: 0 ok · 1 ada hostname gagal · 2 ada sertifikat
terpasang yang kedaluwarsa < --warn-days hari (dan tidak ada yang gagal).

Isi kunci privat TIDAK pernah dicetak; ke openssl dialirkan lewat stdin. Output hanya metadata (serial, notAfter).
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

CERT_NAME = "fullchain.pem"
KEY_NAME = "privkey.pem"
CHAIN_NAME = "chain.pem"
CERT_MODE = 0o644
KEY_MODE = 0o600
SNI_FILE_MODE = 0o600
DIR_MODE = 0o700
OPENSSL = "/usr/bin/openssl"
EXIT_OK = 0
EXIT_ERROR = 1
EXIT_EXPIRING = 2
# FQDN huruf kecil, ≥ 2 label, tanpa '/', '..', wildcard — nama dipakai sebagai nama subdirektori.
FQDN_RE = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$")


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


def ensure_dir(path: Path, dry_run: bool) -> None:
    if path.is_symlink():
        raise ExportError(f"{path} adalah symlink — ditolak")
    if not path.is_dir():
        if dry_run:
            log(f"dry-run: {path} belum ada (akan dibuat {oct(DIR_MODE)})")
        else:
            path.mkdir(mode=DIR_MODE, parents=False)
    elif not dry_run and (path.stat().st_mode & 0o7777) != DIR_MODE:
        os.chmod(path, DIR_MODE)


def export_one(acme: dict, args: argparse.Namespace, domain: str, outdir: Path, sni: bool) -> int:
    """Ekspor satu hostname ke outdir. Return EXIT_OK / EXIT_EXPIRING; ExportError bila validasi gagal."""
    cert, key = find_cert(acme, args.resolver, domain)
    validate(cert, key, domain)
    ensure_dir(outdir, args.dry_run)

    # (nama file, isi, mode) — urutan = urutan tulis; file terakhir = pemicu reload.
    if sni:
        files = [
            (KEY_NAME, key, SNI_FILE_MODE),
            (CHAIN_NAME, key + cert, SNI_FILE_MODE),
            (CERT_NAME, cert, SNI_FILE_MODE),
        ]
    else:
        files = [(KEY_NAME, key, KEY_MODE), (CERT_NAME, cert, CERT_MODE)]

    same = all(read_or_none(outdir / name) == data for name, data, _ in files)
    if same:
        # Pastikan mode tetap benar (idempoten) tanpa mengubah isi. chmod HANYA bila mode berbeda: chmod memicu
        # IN_ATTRIB → systemd PathChanged= (mail-tls-reload.path) → reload yang tidak perlu (teramati 2026-09-25).
        if not args.dry_run:
            for name, _, mode in files:
                if (outdir / name).stat().st_mode & 0o7777 != mode:
                    os.chmod(outdir / name, mode)
        log(f"unchanged domain={domain} {cert_meta(cert)}")
    elif args.dry_run:
        log(f"dry-run: akan menulis domain={domain} {cert_meta(cert)}")
    else:
        # Tiap file tmp + rename; jendela antar-rename ~µs. Hostname utama: bila poll DMS (2 s) tepat jatuh di
        # antaranya, poll berikutnya memuat pasangan lengkap. SNI: reload dipicu fullchain.pem (ditulis terakhir).
        for name, data, mode in files:
            write_atomic(outdir / name, data, mode)
        log(f"exported domain={domain} {cert_meta(cert)}")

    installed = read_or_none(outdir / CERT_NAME) if not args.dry_run else cert
    if installed is None or openssl(["x509", "-noout", "-checkend", str(args.warn_days * 86400)], installed).returncode:
        log(f"WARNING: sertifikat {domain} kedaluwarsa < {args.warn_days} hari (perpanjangan Traefik gagal?)")
        return EXIT_EXPIRING
    return EXIT_OK


def check_args(args: argparse.Namespace) -> None:
    for d in [args.domain, *args.sni_domain]:
        if not FQDN_RE.match(d):
            raise ExportError(f"nama host tidak valid: {d!r}")
    if args.domain in args.sni_domain:
        raise ExportError(f"--sni-domain {args.domain} sama dengan --domain")
    if len(set(args.sni_domain)) != len(args.sni_domain):
        raise ExportError("--sni-domain duplikat")


def export(args: argparse.Namespace) -> int:
    check_args(args)
    out = Path(args.out)
    try:
        acme = json.loads(Path(args.acme).read_text())
    except (OSError, ValueError) as exc:
        raise ExportError(f"gagal membaca {args.acme}: {type(exc).__name__}") from None

    targets = [(args.domain, out, False)] + [(d, out / d, True) for d in args.sni_domain]
    codes = []
    for domain, outdir, sni in targets:
        if sni and not args.dry_run and not out.is_dir():
            # Hostname utama gagal pada run pertama → dir induk belum ada; jangan membuat induk dengan mode lain.
            log(f"ERROR: domain={domain}: {out} belum ada — file tidak diubah")
            codes.append(EXIT_ERROR)
            continue
        try:
            codes.append(export_one(acme, args, domain, outdir, sni))
        except ExportError as exc:
            # Satu hostname gagal (mis. perpanjangan domain client gagal) TIDAK menghentikan hostname lain (ADR 0011).
            log(f"ERROR: domain={domain}: {exc} — file di {outdir} tidak diubah")
            codes.append(EXIT_ERROR)

    if out.is_dir():
        allowed = set(args.sni_domain)
        stale = sorted(p.name for p in out.iterdir() if p.is_dir() and p.name not in allowed)
        if stale:
            log(f"NOTE: subdirektori di luar allowlist (tidak diperbarui lagi; hapus manual): {' '.join(stale)}")

    if EXIT_ERROR in codes:
        return EXIT_ERROR
    return EXIT_EXPIRING if EXIT_EXPIRING in codes else EXIT_OK


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--acme", default="/opt/infra/traefik/acme/acme.json")
    p.add_argument("--resolver", default="le-http")
    p.add_argument("--domain", default="mail.bimacreative.tech", help="hostname utama → <out>/{fullchain,privkey}.pem")
    p.add_argument(
        "--sni-domain",
        action="append",
        default=[],
        metavar="FQDN",
        help="hostname mail client (SNI, ADR 0011) → <out>/<FQDN>/{privkey,chain,fullchain}.pem; boleh berulang",
    )
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
