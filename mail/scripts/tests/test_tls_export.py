"""Uji mail/scripts/tls-export.py dengan acme.json SINTETIS (sertifikat self-signed dibuat openssl per uji).

Jalankan (host, python3 + openssl, tanpa root, tanpa jaringan):
    python3 -m unittest discover -s /opt/infra/mail/scripts/tests -v
Tidak pernah membaca acme.json asli. Uji terhadap SALINAN acme.json asli: docs/03-operations/mail.md §TLS.
"""

from __future__ import annotations

import base64
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "tls-export.py"
DOMAIN = "mail.example.test"
SNI = "mail.client.test"  # hostname mail per domain client (ADR 0011)
OPENSSL = "/usr/bin/openssl"


def make_cert(workdir: Path, name: str, cn: str, days: int = 90, expired: bool = False) -> tuple[bytes, bytes]:
    """Buat pasangan (cert_pem, key_pem) EC P-256; expired=True → notAfter di masa lalu (openssl ca -selfsign)."""
    key = workdir / f"{name}.key"
    crt = workdir / f"{name}.crt"
    subprocess.run(  # noqa: S603
        [OPENSSL, "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)],
        check=True,
        capture_output=True,
    )
    if not expired:
        subprocess.run(  # noqa: S603
            [
                OPENSSL,
                "req",
                "-x509",
                "-key",
                str(key),
                "-out",
                str(crt),
                "-days",
                str(days),
                "-subj",
                f"/CN={cn}",
                "-addext",
                f"subjectAltName=DNS:{cn}",
            ],
            check=True,
            capture_output=True,
        )
    else:
        ca = workdir / f"{name}-ca"
        (ca / "new").mkdir(parents=True)
        (ca / "index.txt").write_text("")
        (ca / "serial").write_text("01\n")
        cnf = ca / "ca.cnf"
        cnf.write_text(
            f"[ca]\ndefault_ca=d\n[d]\ndir={ca}\nnew_certs_dir={ca}/new\ndatabase={ca}/index.txt\n"
            f"serial={ca}/serial\ndefault_md=sha256\npolicy=p\ncopy_extensions=copy\nunique_subject=no\n"
            "[p]\ncommonName=supplied\n"
        )
        csr = workdir / f"{name}.csr"
        subprocess.run(  # noqa: S603
            [
                OPENSSL,
                "req",
                "-new",
                "-key",
                str(key),
                "-out",
                str(csr),
                "-subj",
                f"/CN={cn}",
                "-addext",
                f"subjectAltName=DNS:{cn}",
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(  # noqa: S603
            [
                OPENSSL,
                "ca",
                "-batch",
                "-config",
                str(cnf),
                "-selfsign",
                "-keyfile",
                str(key),
                "-in",
                str(csr),
                "-out",
                str(crt),
                "-startdate",
                "20200101000000Z",
                "-enddate",
                "20200201000000Z",
                "-notext",
            ],
            check=True,
            capture_output=True,
        )
    return crt.read_bytes(), key.read_bytes()


def acme_doc(entries: list[tuple[str, bytes, bytes]], resolver: str = "le-http") -> dict:
    certs = [
        {
            "domain": {"main": main},
            "certificate": base64.b64encode(c).decode(),
            "key": base64.b64encode(k).decode(),
            "Store": "default",
        }
        for main, c, k in entries
    ]
    return {resolver: {"Account": {"Email": "x@example.test"}, "Certificates": certs}}


class TlsExportBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.acme = self.tmp / "acme.json"
        self.out = self.tmp / "tls"
        self.cert, self.key = make_cert(self.tmp, "a", DOMAIN)
        self.other_cert, self.other_key = make_cert(self.tmp, "b", "other.example.test")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write_acme(self, entries: list[tuple[str, bytes, bytes]], resolver: str = "le-http") -> None:
        self.acme.write_text(json.dumps(acme_doc(entries, resolver)))

    def run_export(self, *extra: str) -> subprocess.CompletedProcess[str]:
        cmd = [sys.executable, str(SCRIPT), "--acme", str(self.acme), "--out", str(self.out), "--domain", DOMAIN]
        res = subprocess.run([*cmd, *extra], capture_output=True, text=True, check=False)  # noqa: S603
        # Kunci privat tidak boleh pernah muncul di output (journal).
        self.assertNotIn("PRIVATE KEY", res.stdout + res.stderr)
        self.assertNotIn(base64.b64encode(self.key).decode()[:40], res.stdout + res.stderr)
        return res

    def assert_exported(self, cert: bytes, key: bytes) -> None:
        self.assertEqual((self.out / "fullchain.pem").read_bytes(), cert)
        self.assertEqual((self.out / "privkey.pem").read_bytes(), key)
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.out / "fullchain.pem").stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE((self.out / "privkey.pem").stat().st_mode), 0o600)
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["fullchain.pem", "privkey.pem"])


class TlsExportTest(TlsExportBase):
    def test_export_only_target_domain(self) -> None:
        self.write_acme([("other.example.test", self.other_cert, self.other_key), (DOMAIN, self.cert, self.key)])
        res = self.run_export()
        self.assertEqual(res.returncode, 0, res.stdout)
        self.assertIn("exported", res.stdout)
        self.assert_exported(self.cert, self.key)

    def test_idempotent_no_rewrite(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key)])
        self.assertEqual(self.run_export().returncode, 0)
        before = [(self.out / n).stat() for n in ("fullchain.pem", "privkey.pem")]
        res = self.run_export()
        self.assertEqual(res.returncode, 0)
        self.assertIn("unchanged", res.stdout)
        after = [(self.out / n).stat() for n in ("fullchain.pem", "privkey.pem")]
        self.assertEqual([(s.st_ino, s.st_mtime_ns) for s in before], [(s.st_ino, s.st_mtime_ns) for s in after])

    def test_renewal_replaces_both(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key)])
        self.assertEqual(self.run_export().returncode, 0)
        new_cert, new_key = make_cert(self.tmp, "renew", DOMAIN)
        self.write_acme([(DOMAIN, new_cert, new_key)])
        res = self.run_export()
        self.assertEqual(res.returncode, 0)
        self.assertIn("exported", res.stdout)
        self.assert_exported(new_cert, new_key)

    def assert_rejected_untouched(self, *extra: str) -> None:
        good_cert, good_key = make_cert(self.tmp, "good", DOMAIN)
        acme_bad = self.acme.read_text()
        self.write_acme([(DOMAIN, good_cert, good_key)])
        self.assertEqual(self.run_export().returncode, 0)
        self.acme.write_text(acme_bad)
        res = self.run_export(*extra)
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertIn("ERROR", res.stdout)
        self.assert_exported(good_cert, good_key)

    def test_missing_domain_rejected(self) -> None:
        self.write_acme([("other.example.test", self.other_cert, self.other_key)])
        self.assert_rejected_untouched()

    def test_wrong_resolver_rejected(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key)], resolver="le-http-staging")
        self.assert_rejected_untouched()

    def test_duplicate_rejected(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (DOMAIN, self.cert, self.key)])
        self.assert_rejected_untouched()

    def test_key_mismatch_rejected(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.other_key)])
        self.assert_rejected_untouched()

    def test_hostname_mismatch_rejected(self) -> None:
        # Entri acme.json berlabel DOMAIN tetapi sertifikatnya untuk host lain.
        self.write_acme([(DOMAIN, self.other_cert, self.other_key)])
        self.assert_rejected_untouched()

    def test_expired_rejected(self) -> None:
        old_cert, old_key = make_cert(self.tmp, "old", DOMAIN, expired=True)
        self.write_acme([(DOMAIN, old_cert, old_key)])
        self.assert_rejected_untouched()

    def test_invalid_json_rejected(self) -> None:
        self.acme.write_text("{not json")
        self.assert_rejected_untouched()

    def test_expiring_soon_exports_and_exit_2(self) -> None:
        short_cert, short_key = make_cert(self.tmp, "short", DOMAIN, days=5)
        self.write_acme([(DOMAIN, short_cert, short_key)])
        res = self.run_export("--warn-days", "20")
        self.assertEqual(res.returncode, 2, res.stdout)
        self.assertIn("WARNING", res.stdout)
        self.assert_exported(short_cert, short_key)

    def test_dry_run_writes_nothing(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key)])
        res = self.run_export("--dry-run")
        self.assertEqual(res.returncode, 0, res.stdout)
        self.assertFalse(self.out.exists())

    def test_permissive_dir_tightened(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key)])
        self.out.mkdir()
        os.chmod(self.out, 0o755)  # noqa: S103 - kasus uji: dir terlalu longgar harus dikencangkan
        self.assertEqual(self.run_export().returncode, 0)
        self.assert_exported(self.cert, self.key)


class TlsExportSniTest(TlsExportBase):
    """ADR 0011: hostname SNI (allowlist --sni-domain) → <out>/<fqdn>/{privkey,chain,fullchain}.pem, per host."""

    def setUp(self) -> None:
        super().setUp()
        self.sni_cert, self.sni_key = make_cert(self.tmp, "sni", SNI)

    def run_export(self, *extra: str) -> subprocess.CompletedProcess[str]:
        res = super().run_export(*extra)
        self.assertNotIn(base64.b64encode(self.sni_key).decode()[:40], res.stdout + res.stderr)
        return res

    def assert_sni_exported(self, cert: bytes, key: bytes) -> None:
        d = self.out / SNI
        self.assertEqual(stat.S_IMODE(d.stat().st_mode), 0o700)
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["chain.pem", "fullchain.pem", "privkey.pem"])
        self.assertEqual((d / "privkey.pem").read_bytes(), key)
        self.assertEqual((d / "fullchain.pem").read_bytes(), cert)
        # Format smtpd_tls_chain_files / tls_server_sni_maps: kunci DULU, lalu rantai sertifikat.
        self.assertEqual((d / "chain.pem").read_bytes(), key + cert)
        for name in ("privkey.pem", "fullchain.pem", "chain.pem"):
            self.assertEqual(stat.S_IMODE((d / name).stat().st_mode), 0o600, name)

    def test_primary_and_sni_exported(self) -> None:
        self.write_acme(
            [
                ("other.example.test", self.other_cert, self.other_key),
                (DOMAIN, self.cert, self.key),
                (SNI, self.sni_cert, self.sni_key),
            ]
        )
        res = self.run_export("--sni-domain", SNI)
        self.assertEqual(res.returncode, 0, res.stdout)
        self.assertIn(f"exported domain={SNI}", res.stdout)
        # Hostname utama tidak berubah tata letaknya (path SSL_CERT_PATH/SSL_KEY_PATH DMS tetap).
        self.assertEqual((self.out / "fullchain.pem").read_bytes(), self.cert)
        self.assertEqual((self.out / "privkey.pem").read_bytes(), self.key)
        self.assert_sni_exported(self.sni_cert, self.sni_key)
        # Hanya allowlist: tidak ada dir untuk other.example.test.
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["fullchain.pem", SNI, "privkey.pem"])

    def test_sni_idempotent_no_rewrite(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        names = ("privkey.pem", "chain.pem", "fullchain.pem")
        before = [((self.out / SNI / n).stat().st_ino, (self.out / SNI / n).stat().st_mtime_ns) for n in names]
        res = self.run_export("--sni-domain", SNI)
        self.assertEqual(res.returncode, 0)
        self.assertIn(f"unchanged domain={SNI}", res.stdout)
        after = [((self.out / SNI / n).stat().st_ino, (self.out / SNI / n).stat().st_mtime_ns) for n in names]
        self.assertEqual(before, after)

    def test_unchanged_does_not_touch_ctime(self) -> None:
        # chmod tanpa perlu = IN_ATTRIB → systemd PathChanged= memicu reload Postfix/Dovecot yang tidak perlu.
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        paths = [self.out, self.out / "fullchain.pem", self.out / "privkey.pem", self.out / SNI]
        paths += [self.out / SNI / n for n in ("privkey.pem", "chain.pem", "fullchain.pem")]
        before = [p.stat().st_ctime_ns for p in paths]
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        self.assertEqual(before, [p.stat().st_ctime_ns for p in paths])

    def test_wrong_mode_fixed(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        os.chmod(self.out / SNI / "chain.pem", 0o644)
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        self.assert_sni_exported(self.sni_cert, self.sni_key)

    def test_sni_renewal_replaces_all(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        new_cert, new_key = make_cert(self.tmp, "sni-renew", SNI)
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, new_cert, new_key)])
        res = self.run_export("--sni-domain", SNI)
        self.assertEqual(res.returncode, 0, res.stdout)
        self.assertIn(f"unchanged domain={DOMAIN}", res.stdout)
        self.assertIn(f"exported domain={SNI}", res.stdout)
        self.assert_sni_exported(new_cert, new_key)

    def test_sni_failure_does_not_block_primary(self) -> None:
        # Sertifikat client belum terbit / perpanjangan gagal → hostname utama tetap diekspor, exit 1 (alert).
        self.write_acme([(DOMAIN, self.cert, self.key)])
        res = self.run_export("--sni-domain", SNI)
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertIn(f"ERROR: domain={SNI}", res.stdout)
        self.assert_exported(self.cert, self.key)
        self.assertFalse((self.out / SNI).exists())

    def test_sni_bad_cert_keeps_old_files(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.other_key)])  # kunci salah
        res = self.run_export("--sni-domain", SNI)
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assert_sni_exported(self.sni_cert, self.sni_key)

    def test_primary_failure_does_not_block_sni(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        new_cert, new_key = make_cert(self.tmp, "sni-renew2", SNI)
        self.write_acme([(DOMAIN, self.cert, self.other_key), (SNI, new_cert, new_key)])
        res = self.run_export("--sni-domain", SNI)
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertIn(f"ERROR: domain={DOMAIN}", res.stdout)
        self.assertEqual((self.out / "fullchain.pem").read_bytes(), self.cert)
        self.assertEqual((self.out / "privkey.pem").read_bytes(), self.key)
        self.assert_sni_exported(new_cert, new_key)

    def test_invalid_sni_names_rejected(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key)])
        for bad in ("../etc", "Mail.Client.test", "*.client.test", "client", "a/b.test", DOMAIN, ".", ".."):
            res = self.run_export("--sni-domain", bad)
            self.assertEqual(res.returncode, 1, (bad, res.stdout))
            self.assertIn("ERROR", res.stdout)
        self.assertFalse(self.out.exists())

    def test_duplicate_sni_rejected(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        res = self.run_export("--sni-domain", SNI, "--sni-domain", SNI)
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertFalse(self.out.exists())

    def test_sni_symlink_dir_rejected(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export().returncode, 0)
        target = self.tmp / "elsewhere"
        target.mkdir()
        (self.out / SNI).symlink_to(target)
        res = self.run_export("--sni-domain", SNI)
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertEqual(list(target.iterdir()), [])

    def test_stale_sni_dir_reported(self) -> None:
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, self.sni_cert, self.sni_key)])
        self.assertEqual(self.run_export("--sni-domain", SNI).returncode, 0)
        res = self.run_export()  # hostname dikeluarkan dari allowlist → file lama tidak dihapus otomatis, dilaporkan
        self.assertEqual(res.returncode, 0, res.stdout)
        self.assertIn(f"NOTE: subdirektori di luar allowlist (tidak diperbarui lagi; hapus manual): {SNI}", res.stdout)

    def test_sni_expiring_soon_exit_2(self) -> None:
        short_cert, short_key = make_cert(self.tmp, "sni-short", SNI, days=5)
        self.write_acme([(DOMAIN, self.cert, self.key), (SNI, short_cert, short_key)])
        res = self.run_export("--sni-domain", SNI, "--warn-days", "20")
        self.assertEqual(res.returncode, 2, res.stdout)
        self.assertIn(f"WARNING: sertifikat {SNI}", res.stdout)
        self.assert_sni_exported(short_cert, short_key)


if __name__ == "__main__":
    unittest.main()
