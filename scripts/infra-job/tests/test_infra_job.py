"""Unit test dispatcher infra-job (plan 05 AC-J3). Tanpa efek samping root: semua path di direktori sementara,
skrip palsu (fake) menggantikan scripts/*.sh, alert/log ditangkap di memori.

    python3 -m unittest discover -s scripts/infra-job/tests -v

Sebagai root: uji pemilik file (uid lain) ikut dijalankan (chown di tmp saja). Non-root: uji tsb. di-skip.
Opsional (root + container live, HANYA dry-run skrip asli — read-only): INFRA_JOB_LIVE_DRYRUN=1.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "infra_job.py")
FIXTURES = os.path.join(os.path.dirname(HERE), "contract", "fixtures.json")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))

spec = importlib.util.spec_from_file_location("infra_job", SRC)
ij = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["infra_job"] = ij
spec.loader.exec_module(ij)

IS_ROOT = os.geteuid() == 0
JOB_UID = 64990 if IS_ROOT else os.getuid()
JOB_GID = 64990 if IS_ROOT else os.getgid()
ROOT_UID = 0 if IS_ROOT else os.getuid()
ROOT_GID = 0 if IS_ROOT else os.getgid()

with open(FIXTURES, encoding="ascii") as _fh:
    FX = json.load(_fh)

FAKE_SCRIPT = r"""#!/usr/bin/python3
import json, os, signal, sys, time
HERE = __HERE__
beh = json.load(open(os.path.join(HERE, "behaviour.json")))
dry = "--dry-run" in sys.argv
rec = {"argv": sys.argv, "env": dict(os.environ), "cwd": os.getcwd(), "pid": os.getpid(), "dry": dry}
rd = beh.get("results_dir")
if rd:
    for n in os.listdir(rd):
        rec.setdefault("results_seen", {})[n] = json.load(open(os.path.join(rd, n)))["state"]
with open(os.path.join(HERE, "calls.jsonl"), "a") as fh:
    fh.write(json.dumps(rec) + "\n")
b = beh.get("dry" if dry else "apply", {})
if b.get("ignore_term"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
for line in b.get("lines", []):
    print(line, flush=True)
if b.get("sleep"):
    time.sleep(b["sleep"])
res = b.get("result")
if res is None:
    res = "RESULT db=acme_co_prod changed=1" + (" mode=dry-run blockers=%d" % b.get("blockers", 0) if dry else "")
if res:
    print(res, flush=True)
sys.exit(b.get("exit", 0))
"""


def new_id() -> str:
    return str(uuid.uuid4())


class Env:
    """Tata letak sementara yang meniru role Ansible infra_jobs."""

    def __init__(self, instance: str = "prod", job_types: tuple[str, ...] | list[str] | None = None) -> None:
        self.tmp = tempfile.mkdtemp(prefix="infra-job-test-")
        os.chmod(self.tmp, 0o755)
        self.instance = instance
        self.base = os.path.join(self.tmp, "var-lib")
        self.inst = os.path.join(self.base, instance)
        self.logd = os.path.join(self.tmp, "log")
        self.etc = os.path.join(self.tmp, "etc")
        self.infra = os.path.join(self.tmp, "infra")
        self.scripts = os.path.join(self.infra, "scripts")
        self.fake = os.path.join(self.tmp, "fake")
        self.lock = os.path.join(self.tmp, "lock")
        for d in (self.base, self.inst, self.logd, self.etc, self.infra, self.scripts,
                  os.path.join(self.scripts, "lib"),
                  self.fake, self.lock, os.path.join(self.infra, "traefik", "dynamic", "clients")):
            os.makedirs(d, exist_ok=True)
            os.chmod(d, 0o755)
        self.mk(os.path.join(self.inst, "spool"), ROOT_UID, JOB_GID, 0o730)
        self.mk(os.path.join(self.inst, "spool", "tmp"), JOB_UID, JOB_GID, 0o700)
        self.mk(os.path.join(self.inst, "spool", "new"), ROOT_UID, JOB_GID, 0o730)
        self.mk(os.path.join(self.inst, "work"), ROOT_UID, ROOT_GID, 0o700)
        self.mk(os.path.join(self.inst, "rejected"), ROOT_UID, ROOT_GID, 0o700)
        self.mk(os.path.join(self.inst, "results"), ROOT_UID, JOB_GID, 0o750)
        self.mk(os.path.join(self.logd, instance), ROOT_UID, ROOT_GID, 0o700)
        script = FAKE_SCRIPT.replace("__HERE__", repr(self.fake))
        for name in set(ij.SCRIPTS.values()):
            p = os.path.join(self.scripts, name)
            with open(p, "w") as fh:
                fh.write(script)
            os.chmod(p, 0o755)
        self.behaviour({})
        for fname, hosts in FX["route_files"].items():
            self.route_file(fname, hosts)
        self.alerts: list[tuple[str, str]] = []
        self.logs: list[str] = []
        self.clock: float | None = None
        if job_types is not None:
            self.conf({"job_types": list(job_types)})

    def conf(self, obj: dict | str) -> None:
        """/etc/infra-jobs/<inst>.conf (seperti template Ansible instance.conf.j2)."""
        p = os.path.join(self.etc, f"{self.instance}.conf")
        with open(p, "w") as fh:
            fh.write(obj if isinstance(obj, str) else json.dumps(obj))
        os.chmod(p, 0o644)

    @staticmethod
    def mk(path: str, uid: int, gid: int, mode: int) -> None:
        os.makedirs(path, exist_ok=True)
        if IS_ROOT:
            os.chown(path, uid, gid)
        os.chmod(path, mode)

    def route_file(self, fname: str, hosts: list[str], header: bool = True) -> str:
        p = os.path.join(self.infra, "traefik", "dynamic", "clients", fname)
        body = ("# DIRENDER OTOMATIS oleh scripts/render-client-route.sh dari templates/traefik-client.yml\n" if header
                else "# manual\n")
        body += "http:\n  routers:\n" + "".join(
            f"    r{i}:\n      rule: \"Host(`{h}`)\"\n" for i, h in enumerate(hosts))
        with open(p, "w") as fh:
            fh.write(body)
        os.chmod(p, 0o644)
        return p

    def behaviour(self, beh: dict) -> None:
        beh = dict(beh)
        beh.setdefault("results_dir", os.path.join(self.inst, "results"))
        with open(os.path.join(self.fake, "behaviour.json"), "w") as fh:
            json.dump(beh, fh)

    def cfg(self, **kw) -> ij.Config:
        c = ij.Config(instance=self.instance, base_dir=self.base, log_dir=self.logd, lock_dir=self.lock,
                      etc_dir=self.etc,
                      infra_dir=self.infra, scripts_dir=self.scripts, job_uid=JOB_UID, job_gid=JOB_GID,
                      root_uid=ROOT_UID, root_gid=ROOT_GID, kill_grace_s=1,
                      log=lambda prio, msg: self.logs.append(msg),
                      alert=lambda s, b: (self.alerts.append((s, b)), True)[1])
        if self.clock is not None:
            c.now = lambda: self.clock  # type: ignore[assignment]
        for k, v in kw.items():
            setattr(c, k, v)
        return c

    def run(self, **kw) -> int:
        return ij.run(self.cfg(**kw))

    # ---- penulisan job seperti worker (tmp → rename new)
    def put(self, content: bytes | str | dict, name: str | None = None, uid: int = JOB_UID, mode: int = 0o600) -> str:
        if isinstance(content, dict):
            content = json.dumps(content)
        if isinstance(content, str):
            content = content.encode("utf-8")
        if name is None:
            name = new_id() + ".json"
        tmpp = os.path.join(self.inst, "spool", "tmp", "x" + str(time.time_ns()))
        with open(tmpp, "wb") as fh:
            fh.write(content)
        if IS_ROOT:
            os.chown(tmpp, uid, JOB_GID)
        os.chmod(tmpp, mode)
        os.rename(tmpp, os.path.join(self.inst, "spool", "new", name))
        return name

    def put_job(self, job: dict, **kw) -> str:
        job = dict(job)
        jid = kw.pop("job_id", None) or new_id()
        job["job_id"] = jid
        self.put(job, name=jid + ".json", **kw)
        return jid

    def result(self, jid: str) -> dict | None:
        p = os.path.join(self.inst, "results", jid + ".json")
        if not os.path.exists(p):
            return None
        with open(p) as fh:
            return json.load(fh)

    def calls(self) -> list[dict]:
        p = os.path.join(self.fake, "calls.jsonl")
        if not os.path.exists(p):
            return []
        with open(p) as fh:
            return [json.loads(ln) for ln in fh]

    def new_empty(self) -> bool:
        return os.listdir(os.path.join(self.inst, "spool", "new")) == []

    def rejected(self) -> list[str]:
        return os.listdir(os.path.join(self.inst, "rejected"))

    def ledger(self, entries: list[tuple[float, str, str, str]]) -> None:
        p = os.path.join(self.inst, "work", "ledger")
        with open(p, "w") as fh:
            for ts, jid, jt, fl in entries:
                fh.write(f"{int(ts)} {jid} {jt} {fl}\n")
        os.chmod(p, 0o600)

    def ledger_lines(self) -> list[list[str]]:
        with open(os.path.join(self.inst, "work", "ledger")) as fh:
            return [ln.split(" ") for ln in fh.read().splitlines()]

    def cleanup(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


def fx_valid(name: str) -> dict:
    return next(c for c in FX["valid"] if c["name"] == name)


USER_GRANT = fx_valid("sso_user_grant")["job"]
SSO_PROV = fx_valid("sso_provision")["job"]
ROUTE = fx_valid("route_render_prod")["job"]
DB = fx_valid("db_provision_prod_default_host")["job"]


class Base(unittest.TestCase):
    instance = "prod"

    def setUp(self) -> None:
        self.env = Env(self.instance)

    def tearDown(self) -> None:
        self.env.cleanup()

    def assertRejected(self, jid: str, code: str = "rejected_validation") -> dict:
        r = self.env.result(jid)
        self.assertIsNotNone(r, "hasil tidak ditulis")
        assert r is not None
        self.assertEqual(r["state"], "failed")
        self.assertEqual(r["error_code"], code, r.get("error_detail"))
        self.assertEqual(self.env.calls(), [], "skrip tidak boleh dijalankan")
        self.assertTrue(self.env.new_empty(), "spool/new harus kosong (tidak ada loop pemicu)")
        return r


# ============================================================================== negatif: kontrak JSON (fixture bersama)
class TestContractInvalid(Base):
    """Setiap kasus fixtures.json invalid[] → ditolak dengan error_code yang diharapkan, skrip tidak dijalankan."""


def _make_invalid(case: dict):
    def test(self: Base) -> None:
        self.env.cleanup()
        self.env = Env(case["instance"], job_types=ij.JOB_TYPES)
        jid = new_id()
        if "raw" in case:
            # nama file = job_id fixture, agar penolakan berasal dari kasus itu sendiri (bukan mismatch job_id)
            jid = USER_GRANT["job_id"]
            self.env.put(case["raw"], name=jid + ".json")
        else:
            job = dict(case["job"])
            fname_id = job["job_id"] if case["name"] == "job_id_uppercase" else None
            if case["name"] == "job_id_mismatch":
                self.env.put(job, name=jid + ".json")
            elif fname_id:
                # nama file valid (huruf kecil) tetapi isi job_id huruf besar → mismatch/regex
                self.env.put(job, name=job["job_id"].lower() + ".json")
                jid = job["job_id"].lower()
            else:
                job["job_id"] = jid
                self.env.put(job, name=jid + ".json")
        self.assertEqual(self.env.run(), 0)
        r = self.assertRejected(jid, case["error_code"])
        self.assertTrue(r["error_detail"])
        self.assertTrue(any(case["error_code"] in a[1] for a in self.env.alerts), "alert email wajib untuk rejected_*")
    return test


for _c in FX["invalid"]:
    setattr(TestContractInvalid, f"test_{_c['name']}", _make_invalid(_c))


# ============================================================================== positif: kontrak (argv persis)
class TestContractValid(Base):
    pass


def _make_valid(case: dict):
    def test(self: Base) -> None:
        self.env.cleanup()
        self.env = Env(case["instance"], job_types=ij.JOB_TYPES)
        jid = self.env.put_job(case["job"])
        self.assertEqual(self.env.run(), 0)
        r = self.env.result(jid)
        assert r is not None
        self.assertEqual(r["state"], "succeeded", r)
        calls = self.env.calls()
        apply = [c for c in calls if not c["dry"]] if not case["job"]["dry_run"] else calls
        self.assertEqual(len(apply), 1)
        argv = apply[0]["argv"]
        self.assertEqual([os.path.relpath(argv[0], self.env.scripts), *argv[1:]], case["argv"])
        pre = [c for c in calls if c["dry"]]
        expect_pre = (not case["job"]["dry_run"]) and (
            case["job"]["type"] in ("odoo_sso_provision", "odoo_sso_disable", *ij.PHASE1_JOB_TYPES)
            or (case["job"]["type"] == "odoo_sso_user" and case["job"]["args"]["action"] != "revoke"))
        if not case["job"]["dry_run"]:
            self.assertEqual(len(pre), 1 if expect_pre else 0, "dry-run pendahulu")
            if expect_pre:
                self.assertEqual(pre[0]["argv"], [*argv, "--dry-run"])
    return test


for _c in FX["valid"]:
    setattr(TestContractValid, f"test_{_c['name']}", _make_valid(_c))


# ============================================================================== negatif: file/filesystem
class TestFileLevel(Base):
    def test_symlink_to_shadow_not_read(self) -> None:
        jid = new_id()
        os.symlink("/etc/shadow", os.path.join(self.env.inst, "spool", "new", jid + ".json"))
        self.env.run()
        r = self.assertRejected(jid)
        self.assertNotIn("root:", json.dumps(r))
        self.assertIn("bukan file reguler", r["error_detail"])

    def test_symlink_to_valid_job(self) -> None:
        jid = new_id()
        target = os.path.join(self.env.tmp, "real.json")
        with open(target, "w") as fh:
            json.dump(dict(USER_GRANT, job_id=jid), fh)
        os.symlink(target, os.path.join(self.env.inst, "spool", "new", jid + ".json"))
        self.env.run()
        self.assertRejected(jid)

    def test_hardlink_nlink2(self) -> None:
        jid = new_id()
        name = self.env.put(dict(USER_GRANT, job_id=jid), name=jid + ".json")
        os.link(os.path.join(self.env.inst, "spool", "new", name), os.path.join(self.env.inst, "spool", "tmp", "keep"))
        self.env.run()
        self.assertIn("hardlink", self.assertRejected(jid)["error_detail"])

    def test_fifo_no_hang(self) -> None:
        jid = new_id()
        os.mkfifo(os.path.join(self.env.inst, "spool", "new", jid + ".json"))
        t = time.monotonic()
        self.env.run()
        self.assertLess(time.monotonic() - t, 5)
        self.assertRejected(jid)

    def test_directory_named_like_job(self) -> None:
        jid = new_id()
        os.mkdir(os.path.join(self.env.inst, "spool", "new", jid + ".json"))
        self.env.run()
        self.assertRejected(jid)

    def test_oversize(self) -> None:
        jid = new_id()
        job = dict(USER_GRANT, job_id=jid)
        raw = json.dumps(job)[:-1] + ', "pad": "' + "x" * 9000 + '"}'
        self.env.put(raw, name=jid + ".json")
        self.env.run()
        self.assertIn("8192", self.assertRejected(jid)["error_detail"])

    @unittest.skipUnless(IS_ROOT, "butuh root untuk chown")
    def test_wrong_owner_deploy_uid(self) -> None:
        jid = self.env.put_job(USER_GRANT, uid=1001)
        self.env.run()
        self.assertIn("pemilik", self.assertRejected(jid)["error_detail"])

    @unittest.skipUnless(IS_ROOT, "butuh root untuk chown")
    def test_wrong_owner_root(self) -> None:
        jid = self.env.put_job(USER_GRANT, uid=0)
        self.env.run()
        self.assertRejected(jid)

    def test_mode_world_writable(self) -> None:
        jid = self.env.put_job(USER_GRANT, mode=0o666)
        self.env.run()
        self.assertIn("mode", self.assertRejected(jid)["error_detail"])

    def test_mode_setuid_exec(self) -> None:
        try:
            jid = self.env.put_job(USER_GRANT, mode=0o4755)
        except PermissionError:
            self.skipTest("setuid diblok lingkungan (RestrictSUIDSGID=yes) — kasus tidak bisa dibuat")
        self.env.run()
        self.assertRejected(jid)

    def test_bad_filenames_moved_no_result(self) -> None:
        for name in ("job.json", "x", ".hidden.json", "a\nb.json", new_id().upper() + ".json", new_id() + ".json.tmp",
                     new_id() + ".JSON", "..json"):
            self.env.put(dict(USER_GRANT), name=name)
        self.env.run()
        self.assertTrue(self.env.new_empty())
        self.assertEqual(os.listdir(os.path.join(self.env.inst, "results")), [])
        self.assertEqual(len([n for n in self.env.rejected() if n.startswith("badname")]), 8)
        self.assertEqual(self.env.calls(), [])
        self.assertEqual(len(self.env.alerts), 1, "satu email per run")

    def test_duplicate_job_id_result_exists(self) -> None:
        jid = self.env.put_job(USER_GRANT)
        self.env.run()
        first = self.env.result(jid)
        self.env.put_job(USER_GRANT, job_id=jid)
        self.env.run()
        self.assertEqual(self.env.result(jid), first, "hasil lama tidak ditimpa")
        self.assertEqual(len([c for c in self.env.calls() if not c["dry"]]), 1, "tidak dieksekusi dua kali")
        self.assertTrue(self.env.new_empty())

    def test_duplicate_job_id_ledger_only(self) -> None:
        jid = new_id()
        self.env.ledger([(time.time() - 60, jid, "odoo_sso_user", "accepted")])
        self.env.put_job(USER_GRANT, job_id=jid)
        self.env.run()
        self.assertIsNone(self.env.result(jid))
        self.assertEqual(self.env.calls(), [])

    def test_max_files_per_run(self) -> None:
        for _ in range(ij.MAX_FILES_PER_RUN + 3):
            self.env.put(b"{bad")
        self.env.run()
        self.assertEqual(len(os.listdir(os.path.join(self.env.inst, "spool", "new"))), 3)
        self.env.run()
        self.assertTrue(self.env.new_empty())


# ======================================================================== negatif: tata letak / kill switch / kuota
class TestLayoutAndSwitches(Base):
    def test_new_dir_world_writable_refused(self) -> None:
        os.chmod(os.path.join(self.env.inst, "spool", "new"), 0o777)
        jid = self.env.put_job(USER_GRANT)
        with self.assertRaises(ij.LayoutError):
            self.env.run()
        self.assertIsNone(self.env.result(jid))
        self.assertEqual(self.env.calls(), [])

    def test_results_symlink_refused(self) -> None:
        res = os.path.join(self.env.inst, "results")
        os.rename(res, res + ".real")
        os.symlink(res + ".real", res)
        self.env.put_job(USER_GRANT)
        with self.assertRaises(OSError):
            self.env.run()
        self.assertEqual(self.env.calls(), [])

    @unittest.skipUnless(IS_ROOT, "butuh root untuk chown")
    def test_script_not_root_owned_refused(self) -> None:
        os.chown(os.path.join(self.env.scripts, "odoo-sso-user.sh"), 1001, 1001)
        self.env.put_job(USER_GRANT)
        with self.assertRaises(ij.LayoutError):
            self.env.run()
        self.assertEqual(self.env.calls(), [])

    def test_script_group_writable_refused(self) -> None:
        os.chmod(os.path.join(self.env.scripts, "provision-odoo-db.sh"), 0o775)
        self.env.put_job(DB)
        with self.assertRaises(ij.LayoutError):
            self.env.run()

    def test_kill_switch_disabled(self) -> None:
        open(os.path.join(self.env.etc, "prod.disabled"), "w").close()
        jid = self.env.put_job(USER_GRANT)
        self.env.run()
        self.assertRejected(jid, "disabled")

    def test_invalid_config_is_fail_closed(self) -> None:
        p = os.path.join(self.env.etc, "prod.conf")
        with open(p, "w") as fh:
            fh.write('{"quota": {"total_per_hour": 999999}}')
        os.chmod(p, 0o644)
        jid = self.env.put_job(USER_GRANT)
        self.env.run()
        self.assertRejected(jid, "disabled")
        self.assertTrue(self.env.alerts)

    def test_config_group_writable_is_fail_closed(self) -> None:
        p = os.path.join(self.env.etc, "prod.conf")
        with open(p, "w") as fh:
            fh.write("{}")
        os.chmod(p, 0o666)
        jid = self.env.put_job(USER_GRANT)
        self.env.run()
        self.assertRejected(jid, "disabled")

    def test_quota_total_per_hour(self) -> None:
        now = time.time()
        self.env.ledger([(now - 10 - i, new_id(), "odoo_route", "accepted") for i in range(60)])
        jid = self.env.put_job(ROUTE)
        self.env.run()
        self.assertRejected(jid, "rejected_quota")
        self.assertTrue(any("rejected_quota" in a[1] for a in self.env.alerts))

    def test_quota_total_window_expires(self) -> None:
        now = time.time()
        self.env.ledger([(now - 3700, new_id(), "odoo_route", "accepted") for _ in range(60)])
        jid = self.env.put_job(ROUTE)
        self.env.run()
        self.assertEqual(self.env.result(jid)["state"], "succeeded")

    def test_quota_rejected_jobs_not_counted(self) -> None:
        now = time.time()
        self.env.ledger([(now - 10, new_id(), "odoo_route", "rejected") for _ in range(80)])
        jid = self.env.put_job(ROUTE)
        self.env.run()
        self.assertEqual(self.env.result(jid)["state"], "succeeded")

    def test_quota_db_provision_per_day(self) -> None:
        now = time.time()
        self.env.ledger([(now - 3600 * (i + 2), new_id(), "odoo_db_provision", "accepted") for i in range(3)])
        jid = self.env.put_job(DB)
        self.env.run()
        self.assertRejected(jid, "rejected_quota")

    def test_quota_sso_user_per_hour(self) -> None:
        now = time.time()
        self.env.ledger([(now - 30, new_id(), "odoo_sso_user", "accepted") for _ in range(30)])
        jid = self.env.put_job(USER_GRANT)
        self.env.run()
        self.assertRejected(jid, "rejected_quota")

    def test_quota_rotate_per_day(self) -> None:
        now = time.time()
        self.env.ledger([(now - 7200, new_id(), "odoo_sso_provision", "accepted,rotate") for _ in range(5)])
        job = fx_valid("sso_provision_rotate")["job"]
        jid = self.env.put_job(job)
        self.env.run()
        self.assertRejected(jid, "rejected_quota")
        # tanpa rotate tetap boleh
        jid2 = self.env.put_job(SSO_PROV)
        self.env.run()
        self.assertEqual(self.env.result(jid2)["state"], "succeeded")

    def test_quota_config_override(self) -> None:
        p = os.path.join(self.env.etc, "prod.conf")
        with open(p, "w") as fh:
            fh.write('{"quota": {"total_per_hour": 1}}')
        os.chmod(p, 0o644)
        a = self.env.put_job(ROUTE)
        self.env.run()
        b = self.env.put_job(ROUTE)
        self.env.run()
        self.assertEqual(self.env.result(a)["state"], "succeeded")
        self.assertEqual(self.env.result(b)["error_code"], "rejected_quota")

    def test_seventy_jobs_61st_rejected(self) -> None:
        """Plan 05 §6 D: 70 job dalam 1 jam → ke-61 dst. rejected_quota."""
        ids = [self.env.put_job(ROUTE) for _ in range(70)]
        self.env.run()
        states = [self.env.result(j)["error_code"] for j in ids]
        self.assertEqual(states.count(None), 60)
        self.assertEqual(states.count("rejected_quota"), 10)


class TestStagingInstance(Base):
    instance = "staging"

    def test_prod_job_in_staging_spool(self) -> None:
        jid = self.env.put_job(USER_GRANT)  # env=prod
        self.env.run()
        r = self.assertRejected(jid)
        self.assertIn("lintas instance", r["error_detail"])

    def test_sso_host_from_other_tenant_route(self) -> None:
        job = fx_valid("sso_provision_dry_run")["job"]
        job = dict(job, slug="other", args=dict(job["args"]))
        jid = self.env.put_job(job)  # host acme-co.staging… tidak ada di route other-staging.yml
        self.env.run()
        self.assertRejected(jid)

    def test_route_file_without_header_ignored(self) -> None:
        self.env.route_file("acme-co-staging.yml", ["acme-co.staging.bimacreative.tech"], header=False)
        jid = self.env.put_job(fx_valid("sso_provision_dry_run")["job"])
        self.env.run()
        self.assertRejected(jid)

    def test_route_file_symlink_ignored(self) -> None:
        clients = os.path.join(self.env.infra, "traefik", "dynamic", "clients")
        real = self.env.route_file("real.yml", ["acme-co.staging.bimacreative.tech"])
        os.unlink(os.path.join(clients, "acme-co-staging.yml"))
        os.symlink(real, os.path.join(clients, "acme-co-staging.yml"))
        jid = self.env.put_job(fx_valid("sso_provision_dry_run")["job"])
        self.env.run()
        self.assertRejected(jid)

    def test_route_file_group_writable_ignored(self) -> None:
        p = self.env.route_file("acme-co-staging.yml", ["acme-co.staging.bimacreative.tech"])
        os.chmod(p, 0o664)
        jid = self.env.put_job(fx_valid("sso_provision_dry_run")["job"])
        self.env.run()
        self.assertRejected(jid)

    @unittest.skipUnless(IS_ROOT, "butuh root untuk chown")
    def test_route_file_not_root_owned_ignored(self) -> None:
        p = self.env.route_file("acme-co-staging.yml", ["acme-co.staging.bimacreative.tech"])
        os.chown(p, 1001, 1001)
        jid = self.env.put_job(fx_valid("sso_provision_dry_run")["job"])
        self.env.run()
        self.assertRejected(jid)


# ============================================================================== eksekusi
class TestExecution(Base):
    def test_clean_environment_and_cwd(self) -> None:
        os.environ["INFRA_DIR"] = "/tmp/evil"
        os.environ["KC_HOST"] = "evil.example"
        try:
            self.env.put_job(ROUTE)
            self.env.run()
        finally:
            del os.environ["INFRA_DIR"], os.environ["KC_HOST"]
        c = self.env.calls()[0]
        self.assertEqual(set(c["env"]), {"PATH", "LANG"})
        self.assertEqual(c["env"], ij.CLEAN_ENV)
        self.assertEqual(c["cwd"], self.env.infra)

    def test_running_state_visible_during_execution(self) -> None:
        jid = self.env.put_job(ROUTE)
        self.env.run()
        self.assertEqual(self.env.calls()[0]["results_seen"], {jid + ".json": "running"})
        self.assertEqual(self.env.result(jid)["state"], "succeeded")

    def test_result_file_mode_owner_and_no_tmp(self) -> None:
        jid = self.env.put_job(ROUTE)
        self.env.run()
        res_dir = os.path.join(self.env.inst, "results")
        self.assertEqual(os.listdir(res_dir), [jid + ".json"])
        st = os.stat(os.path.join(res_dir, jid + ".json"))
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o640)
        self.assertEqual((st.st_uid, st.st_gid), (ROOT_UID, JOB_GID))
        logp = os.path.join(self.env.logd, "prod", jid + ".log")
        self.assertEqual(stat.S_IMODE(os.stat(logp).st_mode), 0o600)
        self.assertEqual(os.listdir(os.path.join(self.env.inst, "work")), ["ledger"])

    def test_result_allowlist_drops_secret_keys(self) -> None:
        self.env.behaviour({"apply": {"result": "RESULT db=acme_co_prod pool=pool-a host=acme-co.erp.bimacreative.tech "
                                                "created=yes changed=3 secret=/opt/infra/odoo/pool-a/secrets/x "
                                                "secret_file=/x/y evil=1 route=a;b token=abc"}})
        jid = self.env.put_job(DB)
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual(r["result"], {"db": "acme_co_prod", "pool": "pool-a", "host": "acme-co.erp.bimacreative.tech",
                                       "created": "yes", "changed": "3"})

    def test_tail_redaction_and_limits(self) -> None:
        lines = [f"line {i}" for i in range(100)]
        lines += ["client_secret=abc123", "Authorization: Bearer xyz", "ctl \x1b[31m red", "bidi \u202eevil",
                  "panah \u2192 ok", "x" * 2000]
        self.env.behaviour({"apply": {"lines": lines}})
        jid = self.env.put_job(ROUTE)
        self.env.run()
        tail = self.env.result(jid)["tail"]
        self.assertLessEqual(len(tail), 40)
        self.assertLessEqual(sum(len(t) + 1 for t in tail), 8192)
        blob = "\n".join(tail)
        self.assertNotIn("abc123", blob)
        self.assertNotIn("xyz", blob)
        self.assertNotIn("\x1b", blob)
        self.assertNotIn("\u202e", blob)
        self.assertIn("panah \u2192 ok", tail)
        self.assertIn("[redacted]", tail)
        self.assertTrue(all(len(t) <= 400 for t in tail))
        with open(os.path.join(self.env.logd, "prod", jid + ".log")) as fh:
            self.assertIn("client_secret=abc123", fh.read(), "log penuh root tetap lengkap")

    def test_exit0_without_result_is_failed(self) -> None:
        self.env.behaviour({"apply": {"result": ""}})
        jid = self.env.put_job(ROUTE)
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["error_code"], r["exit_code"]), ("failed", "script_exit", 0))

    def test_nonzero_exit(self) -> None:
        self.env.behaviour({"apply": {"exit": 1, "result": "", "lines": ["ERROR: DB belum ada"]}})
        jid = self.env.put_job(ROUTE)
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["error_code"], r["exit_code"]), ("failed", "script_exit", 1))

    def test_lock_collision_is_locked(self) -> None:
        self.env.behaviour({"apply": {"exit": 1, "result": "",
                                      "lines": ["ERROR: provisioning acme_co_prod sedang berjalan (lock)"]}})
        jid = self.env.put_job(DB)
        self.env.run()
        self.assertEqual(self.env.result(jid)["error_code"], "locked")

    def test_timeout_kills_process_group(self) -> None:
        p = os.path.join(self.env.etc, "prod.conf")
        with open(p, "w") as fh:
            fh.write('{"timeouts": {"odoo_route": 5}}')
        os.chmod(p, 0o644)
        self.env.behaviour({"apply": {"sleep": 120, "ignore_term": True}})
        jid = self.env.put_job(ROUTE)
        t = time.monotonic()
        self.env.run()
        self.assertLess(time.monotonic() - t, 20)
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["error_code"]), ("failed", "timeout_state_unknown"))
        pid = self.env.calls()[0]["pid"]
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_blockers_in_pre_dry_run_blocks_apply(self) -> None:
        self.env.behaviour({"dry": {"blockers": 1}})
        jid = self.env.put_job(USER_GRANT)
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["error_code"], r["phase"]), ("failed", "blocked_dry_run", "dry_run"))
        self.assertEqual([c["dry"] for c in self.env.calls()], [True], "apply tidak boleh jalan")

    def test_pre_dry_run_without_blockers_field_blocks(self) -> None:
        self.env.behaviour({"dry": {"result": "RESULT db=x changed=0"}})
        jid = self.env.put_job(SSO_PROV)
        self.env.run()
        self.assertEqual(self.env.result(jid)["error_code"], "blocked_dry_run")
        self.assertEqual(len(self.env.calls()), 1)

    def test_pre_dry_run_script_failure(self) -> None:
        self.env.behaviour({"dry": {"exit": 1, "result": ""}})
        jid = self.env.put_job(USER_GRANT)
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["error_code"], r["phase"]), ("script_exit", "dry_run"))
        self.assertEqual(len(self.env.calls()), 1)

    def test_revoke_has_no_pre_dry_run(self) -> None:
        job = fx_valid("sso_user_revoke")["job"]
        self.env.cleanup()
        self.env = Env("staging")
        self.env.put_job(job)
        self.env.run()
        self.assertEqual([c["dry"] for c in self.env.calls()], [False])

    def test_resend_invite_argv_never_implies_grant(self) -> None:
        # BUG-J5-01: resend_invite (juga admin=true dari CP) → hanya --resend-invite; tidak pernah --grant/--create-kc.
        job = json.loads(json.dumps(fx_valid("sso_user_resend")["job"]))
        job["args"]["admin"] = True
        jid = self.env.put_job(job)
        self.env.run()
        self.assertEqual(self.env.result(jid)["state"], "succeeded")
        calls = self.env.calls()
        self.assertEqual([c["dry"] for c in calls], [True, False], "resend_invite wajib dry-run pendahulu")
        for c in calls:
            self.assertIn("--resend-invite", c["argv"])
            self.assertNotIn("--grant", c["argv"])
            self.assertNotIn("--create-kc", c["argv"])

    def test_resend_invite_blocked_in_pre_dry_run(self) -> None:
        # User dicabut → skrip melaporkan blocker di dry-run → apply (email) tidak pernah jalan.
        self.env.behaviour({"dry": {"blockers": 1}})
        jid = self.env.put_job(fx_valid("sso_user_resend")["job"])
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["error_code"], r["phase"]), ("failed", "blocked_dry_run", "dry_run"))
        self.assertEqual([c["dry"] for c in self.env.calls()], [True], "apply tidak boleh jalan")

    def test_dry_run_job_reports_blockers_as_succeeded(self) -> None:
        self.env.cleanup()
        self.env = Env("staging")
        self.env.behaviour({"dry": {"blockers": 2}})
        jid = self.env.put_job(fx_valid("sso_provision_dry_run")["job"])
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["result"].get("blockers"), r["phase"]), ("succeeded", "2", "dry_run"))

    def test_sensitive_actions_alert(self) -> None:
        for name in ("route_remove", "sso_disable", "sso_provision_rotate"):
            self.env.put_job(fx_valid(name)["job"])
        self.env.run()
        self.assertEqual(len(self.env.alerts), 1)
        body = self.env.alerts[0][1]
        for word in ("odoo_route remove", "odoo_sso_disable", "rotate_secret"):
            self.assertIn(word, body)

    def test_alert_body_has_no_email(self) -> None:
        job = json.loads(json.dumps(USER_GRANT))
        job["args"]["email"] = "rahasia@acme.co.id"
        job["slug"] = "-bad"
        jid = self.env.put_job(job)
        self.env.run()
        self.assertRejected(jid)
        self.assertNotIn("rahasia", json.dumps(self.env.alerts))
        self.assertNotIn("rahasia", json.dumps(self.env.logs))
        self.assertNotIn("rahasia", json.dumps(self.env.result(jid)))

    def test_success_logs_have_no_email(self) -> None:
        self.env.put_job(USER_GRANT)
        self.env.run()
        self.assertNotIn("budi@", json.dumps(self.env.logs))
        self.assertTrue(any("state=succeeded" in m for m in self.env.logs))

    def test_alert_rate_limit(self) -> None:
        for _ in range(ij.ALERT_MAX_PER_HOUR + 2):
            self.env.put(b"{bad", name=new_id() + ".json")
            self.env.run()
        self.assertEqual(len(self.env.alerts), ij.ALERT_MAX_PER_HOUR)
        self.assertTrue(any("ditahan" in m for m in self.env.logs))

    def test_ledger_pruned_after_7_days(self) -> None:
        old = new_id()
        self.env.ledger([(time.time() - 8 * 86400, old, "odoo_route", "accepted")])
        self.env.put_job(ROUTE)
        self.env.run()
        with open(os.path.join(self.env.inst, "work", "ledger")) as fh:
            self.assertNotIn(old, fh.read())


class TestUnitsParsing(unittest.TestCase):
    def test_parse_result_last_line(self) -> None:
        txt = "RESULT db=a changed=1\nfoo\nRESULT db=b changed=2 secret_file=/x\n"
        self.assertEqual(ij.parse_result(txt), {"db": "b", "changed": "2"})

    def test_parse_result_value_regex(self) -> None:
        self.assertEqual(ij.parse_result("RESULT db=a$(id) changed=1"), {"changed": "1"})

    def test_parse_rejects_oversize_even_if_stat_lies(self) -> None:
        with self.assertRaises(ij.Reject):
            ij.parse_job_bytes(b"{" + b" " * 9000 + b"}")

    def test_fixture_counts(self) -> None:
        self.assertGreaterEqual(len(FX["invalid"]), 40)


# =================================================================== SaaS Fase 1 (docs/plans/saas-phase-1-contract.md)
PHASE1 = ij.PHASE1_JOB_TYPES
ALL_TYPES = ij.JOB_TYPES


def fx_job(name: str, **over) -> dict:
    job = json.loads(json.dumps(fx_valid(name)["job"]))
    job.update(over)
    return job


class TestPhase1Fixtures(unittest.TestCase):
    def test_every_new_type_has_valid_and_three_invalid(self) -> None:
        for t in PHASE1:
            self.assertGreaterEqual(len([c for c in FX["valid"] if c["job"]["type"] == t]), 1, t)
            self.assertGreaterEqual(len([c for c in FX["invalid"] if c.get("job", {}).get("type") == t]), 3, t)

    def test_scripts_map_and_versions(self) -> None:
        self.assertEqual(ij.VERSION, "1.2.0")
        self.assertEqual(set(ij.VALIDATORS), set(ALL_TYPES))
        self.assertEqual(set(ij.SCRIPTS), set(ALL_TYPES))
        self.assertTrue(set(ALL_TYPES) - {"dry_run"} <= set(ij.DEFAULT_TIMEOUTS))
        self.assertEqual(ij.DEFAULT_JOB_TYPES, ij.LEGACY_JOB_TYPES)
        self.assertEqual(len(PHASE1), 10)
        self.assertEqual({ij.SCRIPTS[t] for t in ij.KC_USER_SUBCOMMANDS}, {"kc-user.sh"})
        for k, v in {"kc_user_per_hour": 60, "kc_user_disable_per_hour": 20, "kc_action_email_per_hour": 20,
                     "kc_realm_sync_per_day": 10, "tenant_state_per_day": 20, "odoo_user_per_hour": 60}.items():
            self.assertEqual(ij.DEFAULT_QUOTA[k], v, k)
        for k, v in {"kc_realm_sync": 300, "kc_org_ensure": 120, "kc_user_ensure": 120, "kc_user_set_roles": 120,
                     "kc_user_set_enabled": 120, "kc_user_action_email": 120, "odoo_user_ensure": 300,
                     "odoo_tenant_config": 300, "tenant_suspend": 60, "tenant_resume": 60}.items():
            self.assertEqual(ij.DEFAULT_TIMEOUTS[k], v, k)

    def test_result_keys_phase1(self) -> None:
        txt = ("RESULT realm=platform-staging org=8f1d kc_user=5f0c7d7e-1111-4222-8333-944455556666 "
               "roles=client_admin,odoo_admin enabled=false state=suspended tenant=7c9e6679 changed=1 "
               "secret=x client_secret=y")
        self.assertEqual(ij.parse_result(txt), {
            "realm": "platform-staging", "org": "8f1d", "kc_user": "5f0c7d7e-1111-4222-8333-944455556666",
            "roles": "client_admin,odoo_admin", "enabled": "false", "state": "suspended", "tenant": "7c9e6679",
            "changed": "1"})


class TestPhase1Validators(unittest.TestCase):
    """Uji langsung validate_job/build_argv (tanpa spool) — matriks aturan §0.3 'tidak pernah memberi hak lebih'."""

    CFG = ij.Config(instance="staging", scripts_dir="/s")

    def job(self, jtype: str, slug: str, args: dict, env: str = "staging", dry_run: bool = False) -> dict:
        return {"v": 1, "job_id": "3f2c7a9e-1b4d-4e8a-9c3f-5a6b7c8d9e0f", "type": jtype, "slug": slug, "env": env,
                "dry_run": dry_run, "actor": "user:x", "requested_at": "2026-09-25T10:00:00Z", "args": args}

    def validate(self, obj: dict, instance: str = "staging") -> ij.Job:
        return ij.validate_job(obj, instance, obj["job_id"], ALL_TYPES)

    def test_cp_role_matrix(self) -> None:
        for slug in ("platform", "acme-co"):
            for role in ij.CP_ROLES:
                for odoo in (None, *ij.ODOO_ACCESS):
                    args = {"email": "a@b.co", "cp_role": role}
                    if odoo is not None:
                        args["odoo"] = odoo
                    ok_role = role in (("none", "superadmin", "ops") if slug == "platform"
                                       else ("none", "client_admin", "client_user"))
                    ok = ok_role and not (slug == "platform" and odoo is not None)
                    with self.subTest(slug=slug, role=role, odoo=odoo):
                        if not ok:
                            with self.assertRaises(ij.Reject) as cm:
                                self.validate(self.job("kc_user_set_roles", slug, args))
                            self.assertEqual(cm.exception.code, "rejected_validation")
                            continue
                        job = self.validate(self.job("kc_user_set_roles", slug, args))
                        self.assertEqual(job.alert_reason, f"kc_user_set_roles cp_role={role}"
                                         if role in ("superadmin", "ops") else None)
                        dry = self.validate(self.job("kc_user_set_roles", slug, args, dry_run=True))
                        self.assertIsNone(dry.alert_reason)
                        argv = ij.build_argv(self.CFG, job, False)
                        self.assertEqual(argv[:6], ["/s/kc-user.sh", "roles", slug, "staging", "--email", "a@b.co"])
                        self.assertEqual(argv[6:8], ["--cp-role", role])
                        self.assertEqual(argv[8:], ["--odoo", odoo] if odoo is not None else [])
                        # tidak ada role lain/flag tambahan di argv
                        self.assertEqual([a for a in argv if a in ij.CP_ROLES], [role] + ([odoo] if odoo == "none"
                                                                                           else []))

    def test_platform_rules(self) -> None:
        for jtype, args in (("odoo_user_ensure", {"email": "a@b.co", "role": "user", "active": True}),
                            ("odoo_tenant_config", {"tenant_check": "off"}), ("tenant_suspend", {}),
                            ("tenant_resume", {})):
            with self.subTest(jtype=jtype):
                with self.assertRaises(ij.Reject):
                    self.validate(self.job(jtype, "platform", args))
                self.validate(self.job(jtype, "acme-co", args))
        with self.assertRaises(ij.Reject):
            self.validate(self.job("kc_realm_sync", "acme-co", {}))
        for slug in ("platform", "acme-co"):
            self.validate(self.job("kc_org_ensure", slug, {"tenant_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7"}))

    def test_realm_sync_approve_rule(self) -> None:
        for env, inst in (("prod", "prod"), ("demo", "prod"), ("staging", "staging")):
            for dry in (False, True):
                for approve in (None, False, True):
                    args = {} if approve is None else {"approve": approve}
                    ok = dry or env == "staging" or approve is True
                    with self.subTest(env=env, dry=dry, approve=approve):
                        obj = self.job("kc_realm_sync", "platform", args, env=env, dry_run=dry)
                        if not ok:
                            with self.assertRaises(ij.Reject):
                                self.validate(obj, inst)
                            continue
                        job = self.validate(obj, inst)
                        self.assertEqual(job.pre_dry_run, not dry)
                        self.assertEqual(job.alert_reason, None if dry else "kc_realm_sync apply")
                        argv = ij.build_argv(self.CFG, job, dry)
                        self.assertEqual("--approve" in argv, approve is True)

    def test_name_regex(self) -> None:
        good = ("Budi", "O'Neil", "Budi Santoso, S.T.", "A", ".Budi", "B" * 100, "Budi-Santoso", "1st")
        bad = ("", " Budi", "-Budi", "--name", "B" * 101, "Budi\tX", "Budi\nX", "José", "Budi;id", "Budi$(id)",
               "Budi`id`", "Budi/x", "Budi_x", "Budi\x00")
        for n in good:
            self.assertTrue(ij.NAME_RE.fullmatch(n), n)
        for n in bad:
            with self.subTest(name=n), self.assertRaises(ij.Reject):
                self.validate(self.job("kc_user_ensure", "acme-co", {
                    "email": "a@b.co", "tenant_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "invite": True,
                    "name": n}))

    def test_pre_dry_run_set_for_all_new_types(self) -> None:
        for c in FX["valid"]:
            if c["job"]["type"] in PHASE1:
                job = ij.validate_job(c["job"], c["instance"], c["job"]["job_id"], ALL_TYPES)
                self.assertEqual(job.pre_dry_run, not c["job"]["dry_run"], c["name"])

    def test_alert_reasons(self) -> None:
        expect = {"kc_realm_sync_staging_apply": "kc_realm_sync apply", "kc_realm_sync_prod_approved":
                  "kc_realm_sync apply", "kc_user_set_enabled_false": "kc_user_set_enabled enabled=false",
                  "odoo_tenant_config_strict": "odoo_tenant_config strict", "tenant_suspend_staging": "tenant_suspend",
                  "kc_user_set_roles_platform_superadmin": "kc_user_set_roles cp_role=superadmin",
                  "kc_user_set_roles_platform_ops": "kc_user_set_roles cp_role=ops",
                  "kc_user_ensure_platform_adopt": "kc_user_ensure adopt"}
        for c in FX["valid"]:
            if c["job"]["type"] in PHASE1:
                job = ij.validate_job(c["job"], c["instance"], c["job"]["job_id"], ALL_TYPES)
                self.assertEqual(job.alert_reason, expect.get(c["name"]), c["name"])

    def test_kc_user_ensure_adopt(self) -> None:
        """Kontrak v1.2 (QA F1a): `adopt` opsional bool (default false) → argv `--adopt`; apply → alert."""
        base = {"email": "a@b.co", "tenant_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "invite": False}
        for slug in ("platform", "acme-co"):
            for dry in (False, True):
                for adopt in (None, False, True):
                    args = dict(base) if adopt is None else {**base, "adopt": adopt}
                    with self.subTest(slug=slug, dry=dry, adopt=adopt):
                        job = self.validate(self.job("kc_user_ensure", slug, args, dry_run=dry))
                        self.assertIs(job.args["adopt"], adopt is True)
                        self.assertEqual(job.alert_reason, "kc_user_ensure adopt" if adopt and not dry else None)
                        self.assertFalse(job.sends_email)
                        argv = ij.build_argv(self.CFG, job, dry)
                        self.assertEqual(argv.count("--adopt"), 1 if adopt else 0)
                        self.assertEqual(argv[:8], ["/s/kc-user.sh", "ensure", slug, "staging", "--email", "a@b.co",
                                                    "--tenant-id", "7c9e6679-7425-40de-944b-e07fc1f90ae7"])
                        self.assertEqual(argv[8:], ["--no-invite", *(["--adopt"] if adopt else []),
                                                    *(["--dry-run"] if dry else [])])
        for bad in ("true", "false", 1, 0, None, [], {}):
            with self.subTest(bad=bad), self.assertRaises(ij.Reject) as cm:
                self.validate(self.job("kc_user_ensure", "acme-co", {**base, "adopt": bad}))
            self.assertEqual((cm.exception.code, cm.exception.detail),
                             ("rejected_validation", "args.adopt harus boolean"))
        # adopt hanya untuk kc_user_ensure (tipe user lain menolak kunci tambahan)
        for jtype, args in (("kc_user_set_roles", {"email": "a@b.co", "cp_role": "client_user"}),
                            ("kc_user_set_enabled", {"email": "a@b.co", "enabled": True})):
            with self.subTest(jtype=jtype), self.assertRaises(ij.Reject):
                self.validate(self.job(jtype, "acme-co", {**args, "adopt": True}))

    def test_disallowed_type_rejected_before_args(self) -> None:
        obj = self.job("kc_user_set_roles", "acme-co", {"email": "a@b.co", "cp_role": "client_user"})
        with self.assertRaises(ij.Reject) as cm:
            ij.validate_job(obj, "staging", obj["job_id"])  # default = 5 tipe lama
        self.assertEqual((cm.exception.code, cm.exception.detail),
                         ("rejected_validation", "tipe tidak diizinkan di instance ini"))
        obj["type"] = "kc_user_delete"
        with self.assertRaises(ij.Reject) as cm:
            ij.validate_job(obj, "staging", obj["job_id"], ALL_TYPES)
        self.assertEqual(cm.exception.detail, "type tidak dikenal")


class TestPhase1Allowlist(Base):
    """Allowlist tipe per instance (kontrak §0.5): conf tanpa `job_types` → hanya 5 tipe lama."""

    PROD_CASES = ("kc_realm_sync_prod_approved", "kc_org_ensure_platform", "kc_user_ensure_no_invite",
                  "kc_user_set_roles_client_user", "kc_user_set_enabled_true", "kc_user_action_email_configure_totp",
                  "odoo_user_ensure_user_inactive", "odoo_tenant_config_compat_demo", "tenant_suspend_prod_dry_run",
                  "tenant_resume_demo")

    def test_prod_default_rejects_every_new_type(self) -> None:
        self.assertEqual({fx_valid(n)["job"]["type"] for n in self.PROD_CASES}, set(PHASE1))
        ids = [self.env.put_job(fx_job(n)) for n in self.PROD_CASES]
        self.env.run()
        for jid in ids:
            r = self.assertRejected(jid)
            self.assertEqual(r["error_detail"], "tipe tidak diizinkan di instance ini")
            self.assertIn(r["type"], PHASE1)
        self.assertTrue(any("tipe tidak diizinkan" in a[1] for a in self.env.alerts))

    def test_prod_conf_without_job_types_rejects(self) -> None:
        self.env.conf({"quota": {"total_per_hour": 60}})
        jid = self.env.put_job(fx_job("kc_user_set_enabled_true"))
        self.env.run()
        self.assertEqual(self.assertRejected(jid)["error_detail"], "tipe tidak diizinkan di instance ini")

    def test_staging_without_conf_rejects(self) -> None:
        self.env.cleanup()
        self.env = Env("staging")
        jid = self.env.put_job(fx_job("kc_user_ensure_invite_name"))
        self.env.run()
        self.assertEqual(self.assertRejected(jid)["error_detail"], "tipe tidak diizinkan di instance ini")

    def test_staging_conf_all_types_accepts(self) -> None:
        self.env.cleanup()
        self.env = Env("staging", job_types=ALL_TYPES)
        names = [c["name"] for c in FX["valid"] if c["instance"] == "staging"]
        ids = [self.env.put_job(fx_job(n)) for n in names]
        self.env.run()
        for n, jid in zip(names, ids, strict=True):
            self.assertEqual(self.env.result(jid)["state"], "succeeded", n)

    def test_subset_allowlist(self) -> None:
        self.env.cleanup()
        self.env = Env("staging", job_types=["odoo_route", "kc_user_ensure"])
        ok1 = self.env.put_job(fx_job("kc_user_ensure_invite_name"))
        ok2 = self.env.put_job(fx_job("route_render_default"))
        bad1 = self.env.put_job(fx_job("kc_user_set_roles_client_admin_odoo_admin"))
        bad2 = self.env.put_job(fx_job("sso_user_revoke"))  # tipe lama di luar allowlist juga ditolak
        self.env.run()
        self.assertEqual(self.env.result(ok1)["state"], "succeeded")
        self.assertEqual(self.env.result(ok2)["state"], "succeeded")
        for jid in (bad1, bad2):
            r = self.env.result(jid)
            self.assertEqual((r["error_code"], r["error_detail"]),
                             ("rejected_validation", "tipe tidak diizinkan di instance ini"))
        executed = {c["argv"][1] for c in self.env.calls()}
        self.assertEqual(executed, {"ensure", "acme-co"})

    def test_empty_allowlist_rejects_everything(self) -> None:
        self.env.conf({"job_types": []})
        jid = self.env.put_job(ROUTE)
        self.env.run()
        self.assertEqual(self.assertRejected(jid)["error_detail"], "tipe tidak diizinkan di instance ini")

    def test_invalid_job_types_fail_closed(self) -> None:
        for bad in ('"kc_user_ensure"', '["kc_user_ensure", "kc_user_ensure"]', '["nope"]', "[1]", '{"a": 1}',
                    '["KC_USER_ENSURE"]', "null", '[["odoo_route"]]', "true"):
            with self.subTest(bad=bad):
                self.env.conf('{"job_types": ' + bad + "}")
                jid = self.env.put_job(ROUTE)
                self.env.run()
                self.assertRejected(jid, "disabled")

    def test_load_limits(self) -> None:
        cfg = self.env.cfg()
        lim = ij.load_limits(cfg)
        self.assertEqual(lim.job_types, ij.LEGACY_JOB_TYPES)
        self.env.conf({"job_types": ["kc_user_ensure"], "timeouts": {"kc_user_ensure": 30},
                       "quota": {"kc_action_email_per_hour": 5}})
        lim = ij.load_limits(cfg)
        self.assertEqual(lim.job_types, ("kc_user_ensure",))
        self.assertEqual(lim.timeouts["kc_user_ensure"], 30)
        self.assertEqual(lim.quota["kc_action_email_per_hour"], 5)
        self.assertEqual(lim.quota["total_per_hour"], 60)

    def test_missing_script_for_allowed_type_is_layout_error(self) -> None:
        self.env.cleanup()
        self.env = Env("staging", job_types=ALL_TYPES)
        os.unlink(os.path.join(self.env.scripts, "kc-user.sh"))
        self.env.put_job(fx_job("route_render_default"))
        with self.assertRaises(FileNotFoundError):
            self.env.run()
        self.assertEqual(self.env.calls(), [])

    def test_group_writable_script_for_allowed_type_is_layout_error(self) -> None:
        self.env.cleanup()
        self.env = Env("staging", job_types=ALL_TYPES)
        os.chmod(os.path.join(self.env.scripts, "tenant-state.sh"), 0o775)
        self.env.put_job(fx_job("route_render_default"))
        with self.assertRaises(ij.LayoutError):
            self.env.run()
        self.assertEqual(self.env.calls(), [])

    def test_new_scripts_absent_ok_when_not_allowed(self) -> None:
        for name in {ij.SCRIPTS[t] for t in PHASE1}:
            os.unlink(os.path.join(self.env.scripts, name))
        jid = self.env.put_job(ROUTE)
        self.env.run()
        self.assertEqual(self.env.result(jid)["state"], "succeeded")


class TestPhase1Execution(Base):
    instance = "staging"

    def setUp(self) -> None:
        self.env = Env("staging", job_types=ALL_TYPES)

    def test_pre_dry_run_chain(self) -> None:
        jid = self.env.put_job(fx_job("kc_user_set_roles_client_admin_odoo_admin"))
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["phase"]), ("succeeded", "apply"))
        calls = self.env.calls()
        self.assertEqual([c["dry"] for c in calls], [True, False])
        self.assertEqual(calls[0]["argv"], [*calls[1]["argv"], "--dry-run"])
        self.assertEqual(calls[1]["argv"][1:4], ["roles", "acme-co", "staging"])

    def test_pre_dry_run_failure_blocks_apply(self) -> None:
        self.env.behaviour({"dry": {"exit": 3, "result": "", "lines": ["ERROR: user milik tenant lain"]}})
        jid = self.env.put_job(fx_job("kc_user_ensure_invite_name"))
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["error_code"], r["phase"], r["exit_code"]),
                         ("failed", "script_exit", "dry_run", 3))
        self.assertEqual([c["dry"] for c in self.env.calls()], [True])

    def test_pre_dry_run_blockers_block_apply(self) -> None:
        self.env.behaviour({"dry": {"blockers": 1}})
        jid = self.env.put_job(fx_job("tenant_suspend_staging"))
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["error_code"], r["phase"]), ("blocked_dry_run", "dry_run"))
        self.assertEqual([c["dry"] for c in self.env.calls()], [True])

    def test_pre_dry_run_blockers_non_digit_blocks(self) -> None:
        self.env.behaviour({"dry": {"result": "RESULT org=x changed=1 blockers=x"}})
        jid = self.env.put_job(fx_job("kc_org_ensure_tenant"))
        self.env.run()
        self.assertEqual(self.env.result(jid)["error_code"], "blocked_dry_run")
        self.assertEqual(len(self.env.calls()), 1)

    def test_pre_dry_run_without_blockers_key_proceeds(self) -> None:
        # Kontrak §1: tipe Fase 1 lanjut apply bila dry-run exit 0 (RESULT skrip §1.1 tidak memuat `blockers`).
        self.env.behaviour({"dry": {"result": "RESULT kc_user=abc roles=client_admin changed=1 mode=plan"},
                            "apply": {"result": "RESULT kc_user=abc roles=client_admin changed=1"}})
        jid = self.env.put_job(fx_job("kc_user_set_roles_client_admin_odoo_admin"))
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual(r["state"], "succeeded")
        self.assertEqual(r["result"], {"kc_user": "abc", "roles": "client_admin", "changed": "1"})
        self.assertEqual([c["dry"] for c in self.env.calls()], [True, False])

    def test_pre_dry_run_without_result_line_fails(self) -> None:
        self.env.behaviour({"dry": {"result": ""}})
        jid = self.env.put_job(fx_job("odoo_tenant_config_strict"))
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["error_code"], r["phase"]), ("failed", "script_exit", "dry_run"))
        self.assertEqual(len(self.env.calls()), 1)

    def test_dry_run_job_single_call(self) -> None:
        jid = self.env.put_job(fx_job("kc_realm_sync_staging_plan"))
        self.env.run()
        r = self.env.result(jid)
        self.assertEqual((r["state"], r["phase"]), ("succeeded", "dry_run"))
        self.assertEqual([c["dry"] for c in self.env.calls()], [True])
        self.assertEqual(self.env.alerts, [])

    def test_sensitive_actions_alert(self) -> None:
        for n in ("kc_realm_sync_staging_apply", "kc_user_set_enabled_false", "odoo_tenant_config_strict",
                  "tenant_suspend_staging"):
            self.env.put_job(fx_job(n))
        self.env.run()
        self.assertEqual(len(self.env.alerts), 1)
        body = self.env.alerts[0][1]
        for word in ("kc_realm_sync apply", "kc_user_set_enabled enabled=false", "odoo_tenant_config strict",
                     "aksi sensitif tenant_suspend"):
            self.assertIn(word, body)
        self.assertNotIn("budi@", body)

    def test_platform_role_grant_alerts(self) -> None:
        self.env.put_job(fx_job("kc_user_set_roles_platform_superadmin"))
        self.env.put_job(fx_job("kc_user_set_roles_platform_ops", env="staging"))
        self.env.run()
        self.assertEqual(len(self.env.alerts), 1)
        body = self.env.alerts[0][1]
        self.assertIn("kc_user_set_roles cp_role=superadmin", body)
        self.assertIn("kc_user_set_roles cp_role=ops", body)
        self.assertNotIn("ops@bimacreative", body)

    def test_platform_role_grant_dry_run_no_alert(self) -> None:
        self.env.put_job(fx_job("kc_user_set_roles_platform_superadmin", dry_run=True))
        self.env.put_job(fx_job("kc_user_set_roles_platform_ops", env="staging", dry_run=True))
        self.env.put_job(fx_job("kc_user_set_roles_none_odoo_none", env="staging"))
        self.env.run()
        self.assertEqual(self.env.alerts, [])

    def test_non_sensitive_no_alert(self) -> None:
        for n in ("kc_user_ensure_invite_name", "kc_user_set_roles_client_admin_odoo_admin",
                  "kc_user_action_email_update_password", "odoo_user_ensure_admin_full", "kc_org_ensure_tenant"):
            self.env.put_job(fx_job(n))
        self.env.put_job(fx_job("tenant_suspend_staging", dry_run=True))
        self.env.put_job(fx_job("kc_user_set_enabled_false", dry_run=True))
        self.env.put_job(fx_job("odoo_tenant_config_strict", dry_run=True))
        self.env.put_job(fx_job("kc_realm_sync_staging_apply", dry_run=True))
        self.env.run()
        self.assertEqual(self.env.alerts, [])

    def test_logs_and_alerts_have_no_email(self) -> None:
        job = fx_job("kc_user_set_enabled_false")
        job["args"]["email"] = "rahasia@acme.co.id"
        jid = self.env.put_job(job)
        bad = fx_job("kc_user_set_roles_client_admin_odoo_admin")
        bad["args"]["email"] = "rahasia2@acme.co.id"
        bad["args"]["cp_role"] = "superadmin"
        bad_id = self.env.put_job(bad)
        self.env.run()
        self.assertEqual(self.env.result(jid)["state"], "succeeded")
        self.assertEqual(self.env.result(bad_id)["error_code"], "rejected_validation")
        blob = json.dumps([self.env.alerts, self.env.logs, self.env.result(bad_id)])
        self.assertNotIn("rahasia", blob)


class TestPhase1Quota(Base):
    instance = "staging"

    def setUp(self) -> None:
        self.env = Env("staging")
        # total_per_hour dinaikkan agar kuota per tipe yang diuji (bukan kuota total)
        self.env.conf({"job_types": list(ALL_TYPES), "quota": {"total_per_hour": 10000}})
        self.now = time.time()

    def fill(self, n: int, jtypes: tuple[str, ...], age: float = 30, flags: str = "accepted") -> None:
        self.env.ledger([(self.now - age - i, new_id(), jtypes[i % len(jtypes)], flags) for i in range(n)])

    def state(self, name: str, **over) -> tuple[str, str | None]:
        jid = self.env.put_job(fx_job(name, **over))
        self.env.run()
        r = self.env.result(jid)
        return r["state"], r["error_code"]

    def test_kc_user_per_hour(self) -> None:
        self.fill(60, tuple(ij.KC_USER_SUBCOMMANDS))
        self.assertEqual(self.state("kc_user_ensure_invite_name"), ("failed", "rejected_quota"))
        self.assertEqual(self.state("kc_user_set_roles_client_admin_odoo_admin"), ("failed", "rejected_quota"))
        self.assertEqual(self.state("odoo_user_ensure_admin_full")[0], "succeeded")

    def test_kc_user_per_hour_window(self) -> None:
        self.fill(60, ("kc_user_ensure",), age=3700)
        self.assertEqual(self.state("kc_user_ensure_invite_name")[0], "succeeded")

    def test_kc_user_disable_per_hour(self) -> None:
        self.fill(20, ("kc_user_set_enabled",), flags="accepted,disable")
        self.assertEqual(self.state("kc_user_set_enabled_false"), ("failed", "rejected_quota"))
        self.assertEqual(self.state("kc_user_set_enabled_false", dry_run=True)[0], "succeeded")
        self.assertEqual(self.state("kc_user_set_enabled_true", env="staging")[0], "succeeded")

    def test_disable_flag_written_only_for_apply(self) -> None:
        a = self.env.put_job(fx_job("kc_user_set_enabled_false"))
        b = self.env.put_job(fx_job("kc_user_set_enabled_false", dry_run=True))
        self.env.run()
        flags = {ln[1]: ln[3] for ln in self.env.ledger_lines()}
        self.assertEqual((flags[a], flags[b]), ("accepted,disable", "accepted"))

    def test_kc_action_email_per_hour(self) -> None:
        self.fill(20, ("kc_user_action_email",))
        self.assertEqual(self.state("kc_user_action_email_update_password"), ("failed", "rejected_quota"))
        self.assertEqual(self.state("kc_user_ensure_invite_name"), ("failed", "rejected_quota"))  # undangan = email
        self.assertEqual(self.state("kc_user_set_roles_client_admin_odoo_admin")[0], "succeeded")

    def test_invite_counts_toward_action_email(self) -> None:
        self.fill(20, ("kc_user_action_email",))
        self.assertEqual(self.state("kc_user_ensure_invite_name"), ("failed", "rejected_quota"))
        # tanpa undangan / dry-run: tidak mengirim email → tidak terkena kuota email
        self.assertEqual(self.state("kc_user_ensure_no_invite", env="staging")[0], "succeeded")
        self.assertEqual(self.state("kc_user_ensure_invite_name", dry_run=True)[0], "succeeded")

    def test_invite_apply_consumes_action_email_quota(self) -> None:
        self.fill(20, ("kc_user_ensure",), flags="accepted,email")
        self.assertEqual(self.state("kc_user_action_email_update_password"), ("failed", "rejected_quota"))

    def test_email_flag_written_only_for_invite_apply(self) -> None:
        a = self.env.put_job(fx_job("kc_user_ensure_invite_name"))
        b = self.env.put_job(fx_job("kc_user_ensure_invite_name", dry_run=True))
        c = self.env.put_job(fx_job("kc_user_ensure_no_invite", env="staging"))
        self.env.run()
        flags = {ln[1]: ln[3] for ln in self.env.ledger_lines()}
        self.assertEqual((flags[a], flags[b], flags[c]), ("accepted,email", "accepted", "accepted"))

    def test_invite_email_quota_override(self) -> None:
        self.env.conf({"job_types": list(ALL_TYPES), "quota": {"kc_action_email_per_hour": 1}})
        self.assertEqual(self.state("kc_user_ensure_invite_name")[0], "succeeded")
        self.assertEqual(self.state("kc_user_action_email_update_password"), ("failed", "rejected_quota"))

    def test_kc_realm_sync_per_day(self) -> None:
        self.fill(10, ("kc_realm_sync",), age=7200)
        self.assertEqual(self.state("kc_realm_sync_staging_plan"), ("failed", "rejected_quota"))

    def test_kc_realm_sync_per_day_window(self) -> None:
        self.fill(10, ("kc_realm_sync",), age=86400 + 60)
        self.assertEqual(self.state("kc_realm_sync_staging_apply")[0], "succeeded")

    def test_tenant_state_per_day(self) -> None:
        self.fill(20, ("tenant_suspend", "tenant_resume"), age=7200)
        self.assertEqual(self.state("tenant_suspend_staging"), ("failed", "rejected_quota"))
        self.assertEqual(self.state("tenant_resume_demo", env="staging"), ("failed", "rejected_quota"))
        self.assertEqual(self.state("odoo_tenant_config_strict")[0], "succeeded")

    def test_odoo_user_per_hour(self) -> None:
        self.fill(60, ("odoo_user_ensure",))
        self.assertEqual(self.state("odoo_user_ensure_admin_full"), ("failed", "rejected_quota"))
        self.assertEqual(self.state("kc_user_ensure_invite_name")[0], "succeeded")

    def test_total_per_hour_still_applies(self) -> None:
        self.env.conf({"job_types": list(ALL_TYPES)})
        self.fill(60, ("kc_org_ensure",))
        self.assertEqual(self.state("kc_org_ensure_tenant"), ("failed", "rejected_quota"))

    def test_quota_override_new_key(self) -> None:
        self.env.conf({"job_types": list(ALL_TYPES), "quota": {"kc_action_email_per_hour": 1}})
        self.assertEqual(self.state("kc_user_action_email_update_password")[0], "succeeded")
        self.assertEqual(self.state("kc_user_action_email_update_password"), ("failed", "rejected_quota"))

    def test_timeout_override_new_type(self) -> None:
        self.env.conf({"job_types": list(ALL_TYPES), "timeouts": {"tenant_suspend": 5}})
        self.env.behaviour({"apply": {"sleep": 120, "ignore_term": True}})
        t = time.monotonic()
        jid = self.env.put_job(fx_job("tenant_suspend_staging"))
        self.env.run()
        self.assertLess(time.monotonic() - t, 20)
        self.assertEqual(self.env.result(jid)["error_code"], "timeout_state_unknown")


# ============================================================================== fixture control plane (J2)
CP_FX = os.path.join(HERE, "fixtures", "control-plane")  # asal: lihat fixtures/control-plane/ORIGIN.txt


def _cp_load(name: str) -> list | dict:
    with open(os.path.join(CP_FX, name), encoding="utf-8") as fh:
        return json.load(fh)


def _cp_request_to_file(req: dict) -> dict:
    """Bentuk request CP (dryRun) → file job v1 (seperti worker J2 menulis spool).
    Kunci lain dipertahankan apa adanya."""
    out = {"v": 1, "job_id": new_id(), "actor": "user:5f0c7d7e-1111-4222-8333-944455556666",
           "requested_at": "2026-09-25T10:00:00Z"}
    for k, v in req.items():
        out["dry_run" if k == "dryRun" else k] = v
    return out


class TestControlPlaneFixtures(Base):
    """Setiap job-valid.json diterima + dieksekusi; setiap job-invalid.json ditolak rejected_validation (J2 fixture)."""

    def test_result_fixture_keys_subset_of_dispatcher_result(self) -> None:
        cp = _cp_load("result-valid.json")
        jid = self.env.put_job(ROUTE)
        self.env.run()
        mine = self.env.result(jid)
        self.assertTrue(set(cp) <= set(mine), set(cp) - set(mine))
        for k in cp:
            if cp[k] is not None and mine[k] is not None:
                self.assertIs(type(mine[k]), type(cp[k]), k)
        self.assertIn(mine["state"], ("running", "succeeded", "failed"))
        self.assertEqual(ij.parse_result("RESULT " + " ".join(f"{k}={v}" for k, v in cp["result"].items())),
                         {k: v for k, v in cp["result"].items() if not k.startswith("secret")})


def _make_cp_valid(i: int, job: dict):
    def test(self: Base) -> None:
        inst = "staging" if job["env"] == "staging" else "prod"
        self.env.cleanup()
        self.env = Env(inst)
        self.env.put(job, name=job["job_id"] + ".json")
        self.env.run()
        r = self.env.result(job["job_id"])
        assert r is not None
        self.assertEqual(r["state"], "succeeded", r)
        self.assertEqual(len([c for c in self.env.calls() if c["dry"] == job["dry_run"]]), 1)
    return test


def _make_cp_invalid(i: int, case: dict):
    def test(self: Base) -> None:
        self.env.cleanup()
        self.env = Env(case["instance"])
        job = _cp_request_to_file(case["job"])
        self.env.put(job, name=job["job_id"] + ".json")
        self.env.run()
        self.assertRejected(job["job_id"])
    return test


for _i, _j in enumerate(_cp_load("job-valid.json")):
    setattr(TestControlPlaneFixtures, f"test_cp_valid_{_i:02d}_{_j['type']}", _make_cp_valid(_i, _j))
for _i, _c in enumerate(_cp_load("job-invalid.json")):
    setattr(TestControlPlaneFixtures, f"test_cp_invalid_{_i:02d}", _make_cp_invalid(_i, _c))


# ============================================================================== opsional: skrip ASLI, dry-run saja
LIVE = IS_ROOT and os.environ.get("INFRA_JOB_LIVE_DRYRUN") == "1" and shutil.which("docker") is not None


@unittest.skipUnless(LIVE, "set INFRA_JOB_LIVE_DRYRUN=1 (root, container staging hidup) — hanya dry-run, read-only")
class TestLiveDryRunRealScripts(unittest.TestCase):
    """Dispatcher → skrip asli repo (scripts/*.sh) → container/Keycloak staging live, HANYA mode --dry-run.
    Hasil/log di tmp; route file asli /opt/infra/traefik/dynamic/clients; cwd /opt/infra."""

    def setUp(self) -> None:
        self.env = Env("staging")
        self.env.infra = "/opt/infra"
        # Pengaman: wrapper yang HANYA meneruskan pemanggilan --dry-run ke skrip asli repo; apply → exit 99 tanpa efek.
        self.env.scripts = os.path.join(self.env.tmp, "live-scripts")
        os.makedirs(os.path.join(self.env.scripts, "lib"))
        os.chmod(self.env.scripts, 0o755)
        for name in set(ij.SCRIPTS.values()):
            p = os.path.join(self.env.scripts, name)
            with open(p, "w") as fh:
                fh.write('#!/bin/bash\n'
                         '[[ " $* " == *" --dry-run "* ]] || { echo "LIVE-TEST: apply diblok"; exit 99; }\n'
                         f'exec {os.path.join(REPO, "scripts", name)} "$@"\n')
            os.chmod(p, 0o755)

    def tearDown(self) -> None:
        self.env.cleanup()

    def _run(self, job: dict) -> dict:
        jid = self.env.put_job(job)
        self.env.run()
        r = self.env.result(jid)
        assert r is not None
        with open(os.path.join(self.env.logd, "staging", jid + ".log")) as fh:
            self.log = fh.read()
        return r

    def test_sso_provision_dry_run_ssotest(self) -> None:
        job = dict(fx_valid("sso_provision_dry_run")["job"], slug="ssotest",
                   args={"hosts": ["ssotest.staging.bimacreative.tech"], "rotate_secret": False, "skip_smoke": False})
        r = self._run(job)
        self.assertEqual(r["state"], "succeeded", r)
        self.assertEqual(r["result"]["blockers"], "0")
        self.assertEqual(r["result"]["client"], "odoo-ssotest-staging")
        self.assertNotIn("secret_file", r["result"])

    def test_sso_disable_dry_run_ssotest(self) -> None:
        job = dict(fx_valid("sso_provision_dry_run")["job"], type="odoo_sso_disable", slug="ssotest",
                   args={"hosts": ["ssotest.staging.bimacreative.tech"]})
        r = self._run(job)
        self.assertEqual(r["state"], "succeeded", r)
        self.assertEqual(r["result"]["mode"], "dry-run,disable")

    def test_sso_user_grant_unknown_login_blocked_without_apply(self) -> None:
        """AC-J7 (sebagian): grant ke login yang tidak ada → blocked_dry_run, TANPA user Keycloak baru/undangan."""
        job = dict(USER_GRANT, env="staging", slug="ssotest",
                   args={"action": "grant", "email": "j1-dispatcher-test@example.com",
                         "login": "j1-no-such-login", "admin": False, "create_kc": True})
        r = self._run(job)
        self.assertEqual((r["state"], r["error_code"]), ("failed", "blocked_dry_run"), r)
        self.assertNotIn("phase=apply", self.log, "apply tidak boleh dijalankan")
        self.assertIn("BLOKIR", self.log)


if __name__ == "__main__":
    unittest.main()
