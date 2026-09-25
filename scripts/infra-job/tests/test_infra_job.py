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

    def __init__(self, instance: str = "prod") -> None:
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
        self.env = Env(case["instance"])
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
        self.env = Env(case["instance"])
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
            case["job"]["type"] in ("odoo_sso_provision", "odoo_sso_disable")
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
