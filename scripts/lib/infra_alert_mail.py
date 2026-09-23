#!/usr/bin/env python3
"""Kirim email alert infra (H7) — dipanggil scripts/infra-healthcheck.sh.

    infra_alert_mail.py "<subject>" < body.txt

Konfigurasi dari environment (dirender role Ansible `healthcheck` ke /etc/infra-healthcheck/alert.env):
  ALERT_TO             penerima, pisahkan dengan koma (default postmaster@bimacreative.tech)
  ALERT_FROM           pengirim = user SMTP AUTH (default alerts@bimacreative.tech)
  ALERT_SMTP_HOST      default mail.bimacreative.tech
  ALERT_SMTP_PORT      default 587 (submission, STARTTLS wajib — docs/03-operations/mail.md)
  ALERT_PASSWORD_FILE  default /opt/infra/mail/secrets/<ALERT_FROM>.password (600 root, dibuat mailbox-add.sh)
Password dibaca dari file (tidak pernah di argv/env). Sertifikat server diverifikasi (hostname + CA sistem).
Hanya pustaka standar Python 3 (smtplib, ssl, email).
"""
import os
import socket
import ssl
import smtplib
import sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        print("pemakaian: infra_alert_mail.py '<subject>' < body", file=sys.stderr)
        return 2
    sender = os.environ.get("ALERT_FROM", "alerts@bimacreative.tech")
    rcpts = [r.strip() for r in os.environ.get("ALERT_TO", "postmaster@bimacreative.tech").split(",") if r.strip()]
    host = os.environ.get("ALERT_SMTP_HOST", "mail.bimacreative.tech")
    port = int(os.environ.get("ALERT_SMTP_PORT", "587"))
    pw_file = os.environ.get("ALERT_PASSWORD_FILE", f"/opt/infra/mail/secrets/{sender}.password")
    if not rcpts:
        print("ALERT_TO kosong", file=sys.stderr)
        return 2
    with open(pw_file, encoding="utf-8") as fh:
        password = fh.read().strip()

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = ", ".join(rcpts)
    msg["Subject"] = sys.argv[1].strip()
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=sender.split("@", 1)[1])
    msg["X-Infra-Alert"] = socket.gethostname()
    msg["Auto-Submitted"] = "auto-generated"  # RFC 3834: jangan dibalas auto-responder
    msg.set_content(sys.stdin.read())

    ctx = ssl.create_default_context()
    with smtplib.SMTP(host, port, timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=ctx)
        smtp.ehlo()
        smtp.login(sender, password)
        refused = smtp.send_message(msg, from_addr=sender, to_addrs=rcpts)
    if refused:
        print(f"sebagian penerima ditolak: {sorted(refused)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, smtplib.SMTPException) as exc:
        # Pesan exception smtplib/ssl tidak memuat password.
        print(f"gagal kirim email: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
