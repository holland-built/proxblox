"""Run the niosx scripts against a real pty, with stubbed ssh/rsync/curl/tofu.

The interactive path only exists behind `[ -t 0 ]`, so a plain subprocess never
reaches it. Everything here talks to stubs: no Proxmox host and no CSP tenant
is contacted, and the repo's own config.env / secrets are never read.
"""
import os, pty, select, shutil, subprocess, tempfile, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STUBS = os.path.join(REPO, "tests", "stubs")


class Workspace:
    """A throwaway config.env + qcow2 + join token + API key."""

    def __init__(self, owner="tester"):
        self.dir = tempfile.mkdtemp(prefix="niosx-test-")
        self.img = os.path.join(self.dir, "fake.qcow2")
        open(self.img, "w").write("not a real image\n")
        self.config = os.path.join(self.dir, "config.env")
        open(self.config, "w").write(
            'OWNER="%s"\nPVE="root@stub-proxmox.invalid"\nIMG="%s"\n'
            "POOL=local-zfs\nBRIDGE=vmbr0\n" % (owner, self.img))
        self.token = os.path.join(self.dir, "jointoken")
        open(self.token, "w").write("FAKE-TOKEN-not-a-real-one.ibjt\n")
        self.secrets = os.path.join(self.dir, "secrets.auto.tfvars")
        open(self.secrets, "w").write('infoblox_api_key = "FAKE-API-KEY-for-tests"\n')
        self.hosts_json = os.path.join(self.dir, "niosx_hosts.json")
        self.pending_dir = os.path.join(self.dir, "pending")
        self.log = os.path.join(self.dir, "stub.log")
        self.capture = os.path.join(self.dir, "remote.txt")

    def env(self, extra=None):
        e = dict(os.environ)
        e["PATH"] = STUBS + os.pathsep + e["PATH"]
        e["NIOSX_CONFIG"] = self.config
        e["NIOSX_TOKEN_FILE"] = self.token
        e["NIOSX_SECRETS"] = self.secrets
        e["NIOSX_STATE_DIR"] = os.path.join(self.dir, "teardown")
        e["NIOSX_HOSTS_JSON"] = self.hosts_json
        e["NIOSX_PENDING_DIR"] = self.pending_dir
        e["STUB_LOG"] = self.log
        e["STUB_CAPTURE"] = self.capture
        e["TERM"] = "dumb"
        e.update(extra or {})
        return e

    def read(self, path):
        try:
            return open(path).read()
        except OSError:
            return ""

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def run(script, args=(), inputs=(), env_extra=None, ws=None, timeout=30):
    """Drive `script` on a pty, answering prompts in order. Returns (rc, output)."""
    own = ws is None
    ws = ws or Workspace()
    try:
        master, slave = pty.openpty()
        p = subprocess.Popen([os.path.join(REPO, "scripts", script)] + list(args),
                             stdin=slave, stdout=slave, stderr=slave,
                             env=ws.env(env_extra), cwd=REPO,
                             close_fds=True, preexec_fn=os.setsid)
        os.close(slave)
        out, pending, quiet = b"", list(inputs), 0.0
        deadline = time.time() + timeout
        while True:
            if time.time() > deadline:
                out += b"\n[[TIMEOUT]]\n"
                p.kill()
                break
            r, _, _ = select.select([master], [], [], 0.25)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                out, quiet = out + chunk, 0.0
                continue
            quiet += 0.25
            if p.poll() is not None and quiet > 0.5:
                break
            if pending and quiet >= 0.5:      # output went quiet: a prompt is waiting
                os.write(master, (pending.pop(0) + "\n").encode())
                quiet = 0.0
        try:
            p.wait(timeout=5)
        except Exception:
            p.kill()
        os.close(master)
        return p.returncode, out.decode(errors="replace")
    finally:
        if own:
            ws.cleanup()


# ---- tiny assertion runner (shared by the test files) ----
RESULTS = {"passed": 0, "failed": []}


def case(title, script="deploy-niosx.sh", args=(), inputs=(), env=None, owner="tester",
         setup=None, after=None, rc=None, has=(), hasnt=(), log_has=(), log_hasnt=(),
         capture_has=()):
    """Run one scenario and check what a person would have seen."""
    ws = Workspace(owner=owner)
    try:
        if setup:
            setup(ws)
        got_rc, out = run(script, args=args, inputs=inputs, env_extra=env, ws=ws)
        log, cap = ws.read(ws.log), ws.read(ws.capture)
        problems = []
        if rc is not None and got_rc != rc:
            problems.append("exit %s, wanted %s" % (got_rc, rc))
        problems += ["missing from output: %r" % s for s in has if s not in out]
        problems += ["should not be in output: %r" % s for s in hasnt if s in out]
        problems += ["stub never saw: %s" % s for s in log_has if s not in log]
        problems += ["stub should not have seen: %s" % s for s in log_hasnt if s in log]
        problems += ["missing from the remote script: %r" % s for s in capture_has if s not in cap]
        if after:
            problems += list(after(ws) or [])
        if problems:
            RESULTS["failed"].append((title, problems, out))
            print("FAIL  %s" % title)
            for p in problems:
                print("        %s" % p)
        else:
            RESULTS["passed"] += 1
            print("ok    %s" % title)
    finally:
        ws.cleanup()


def report():
    print()
    print("%d passed, %d failed" % (RESULTS["passed"], len(RESULTS["failed"])))
    if RESULTS["failed"]:
        title, _, out = RESULTS["failed"][0]
        print("\n--- output of the first failure (%s) ---" % title)
        print(out)
    return 1 if RESULTS["failed"] else 0
