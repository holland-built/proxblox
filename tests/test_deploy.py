#!/usr/bin/env python3
"""What a human at a terminal actually gets. Run: python3 tests/test_deploy.py

Nothing here reaches a real Proxmox host or the Infoblox tenant — see
tests/stubs. Each case drives a real pty, because the prompts only exist
behind `[ -t 0 ]`.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import case, report

VM_FULL = ("name: tester-250\n"
           "scsi0: local-zfs:vm-250-disk-0,discard=on,size=64G,ssd=1\n"
           "ide2: local:iso/seed-niosx-250.iso,media=cdrom\n"
           "net0: virtio=aa:bb:cc:dd:ee:ff,bridge=vmbr0\n")
VM_NO_SEED = ("name: tester-250\n"
              "scsi0: local-zfs:vm-250-disk-0,discard=on,size=64G,ssd=1\n"
              "net0: virtio=aa:bb:cc:dd:ee:ff,bridge=vmbr0\n")
VM_FOREIGN = ("name: someone-elses-vm\n"
              "scsi0: local-zfs:vm-250-disk-0,size=32G\n")


HALT = {"STUB_HALT": "1"}          # stop at the first step that would change anything
PIN = ("--vmid", "250", "--name", "tester-250")

# ---- the service menu: does it render, and does it parse both forms? ----
case("menu renders, Enter takes the default", inputs=["", "", ""], env=HALT,
     has=["Services available in this tenant:", "1) dfp", "11) dgw",
          ">> services: dns,dhcp"])
case("numbers pick services", inputs=["", "", "2,3"], env=HALT, has=[">> services: dns,dhcp"])
case("names pick services", inputs=["", "", "dns,ntp"], env=HALT, has=[">> services: dns,ntp"])
case("numbers and names mixed", inputs=["", "", "2,ntp"], env=HALT, has=[">> services: dns,ntp"])
case("spaces around the list", inputs=["", "", " dns , ntp "], env=HALT, has=[">> services: dns,ntp"])
case("none skips services", inputs=["", "", "none"], env=HALT, has=[">> services: none"])
case("NONE also skips services", inputs=["", "", "NONE"], env=HALT, has=[">> services: none"])
case("0 is rejected, not treated as a name", inputs=["", "", "0"], rc=1,
     has=["there is no service numbered 0"], log_hasnt=["RSYNC"])
case("out-of-range number is rejected", inputs=["", "", "99"], rc=1,
     has=["!! no service numbered 99"], log_hasnt=["RSYNC"])
case("unknown service name is rejected", inputs=["", "", "banana"], rc=1,
     has=["is not a service this tenant offers"], log_hasnt=["RSYNC"])

# ---- the tenant list itself ----
case("unreachable API falls back to the cached list, and says so",
     inputs=["", "", ""], env=dict(HALT, STUB_APPS_FAIL="1"),
     has=["using a cached list", "snapshot 2026-09-02", ">> services: dns,dhcp"])
case("--services is validated against the LIVE tenant, not the snapshot",
     args=("--services", "dns") + PIN, env=HALT,
     has=[">> CSP API key OK"])
case("--services with a bogus name is rejected before the upload",
     args=("--services", "banana") + PIN, rc=1,
     has=["is not a service this tenant offers"], log_hasnt=["RSYNC"])
case("a rejected API key stops the deploy before the upload",
     args=("--services", "dns") + PIN, env={"STUB_HTTP": "401"}, rc=1,
     has=["CSP rejected the API key (HTTP 401)"], log_hasnt=["RSYNC"])

# ---- names and ids that would otherwise reach a root shell ----
case("VMID must be a number", inputs=["abc"], rc=1,
     has=["VMID must be a number"], log_hasnt=["RSYNC"])
case("VMID below Proxmox's floor is refused", inputs=["42"], rc=1,
     has=["VMID must be 100 or higher"], log_hasnt=["RSYNC"])
case("a name with a space is refused", inputs=["", "my host"], rc=1,
     has=["contains characters that are not allowed"], log_hasnt=["RSYNC"])
case("a name that would inject a command is refused", inputs=["", "x;reboot"], rc=1,
     has=["contains characters that are not allowed"], log_hasnt=["RSYNC"])
case("a name cannot start with a hyphen", inputs=["", "-nope"], rc=1,
     has=["must start and end with a letter or digit"], log_hasnt=["RSYNC"])
case("a generic OWNER is refused (shared tenant)", owner="lab", inputs=["", "", "none"], rc=1,
     has=["is too generic for a shared tenant"], log_hasnt=["RSYNC"])
case("the VM name reaches Proxmox quoted",
     args=("--services", "none") + PIN,
     capture_has=['--name "tester-250"'])

# ---- the shared tenant: names must be free tenant-wide ----
case("a name already in the tenant is refused",
     args=("--services", "none") + PIN, env={"STUB_NAME_TAKEN": "1"}, rc=1,
     has=["already exists in this shared tenant"], log_hasnt=["RSYNC"])
case("a free name is reported as checked",
     args=("--services", "none") + PIN,
     has=['name check: "tester-250" is free in the tenant'])

# ---- --resume ----
case("resume needs a VMID", args=("--resume",), inputs=[""], rc=1,
     has=["--resume needs the VMID"])
case("resume refuses a VM that does not exist",
     args=("--resume", "250", "--services", "none"), rc=1,
     has=["there is nothing to resume"])
case("resume refuses a VM that is not ours",
     args=("--resume", "250", "--services", "none"),
     env={"STUB_QM_CONFIG": VM_FOREIGN}, rc=1,
     has=["was not built by this tool"], log_hasnt=["REMOTE-SCRIPT"])
case("resume of a complete VM skips every finished step",
     args=("--resume", "250", "--services", "none"),
     env={"STUB_QM_CONFIG": VM_FULL, "STUB_QM_STATUS": "stopped"},
     has=["image not needed", "already exists — skipped", "disk already imported — skipped",
          "join seed already attached — skipped", ">> 5/6  Start 250"],
     log_has=["QM-START"], log_hasnt=["RSYNC"])
case("resume of a running VM starts nothing",
     args=("--resume", "250", "--services", "none"),
     env={"STUB_QM_CONFIG": VM_FULL, "STUB_QM_STATUS": "running"},
     has=["already running — skipped"], log_hasnt=["QM-START"])
case("resume builds the missing join seed after a confirmation",
     args=("--resume", "250", "--services", "none"), inputs=["y"],
     env={"STUB_QM_CONFIG": VM_NO_SEED, "STUB_QM_STATUS": "stopped"},
     has=["Resume this VM?", "4/6  Build cloud-init join seed"],
     capture_has=["genisoimage", "seed-niosx-250.iso"], log_has=["QM-START"])
case("answering no to the resume prompt changes nothing",
     args=("--resume", "250", "--services", "none"), inputs=["n"],
     env={"STUB_QM_CONFIG": VM_NO_SEED}, rc=2,
     has=["Aborted"], log_hasnt=["REMOTE-SCRIPT", "QM-START"])

# ---- WSL2 / Windows hazards, checked here because nobody has a Windows box ----
def crlf_config(ws):
    text = open(ws.config).read().replace("\n", "\r\n")   # read first: "w" truncates
    open(ws.config, "w").write(text)


def spacey_image(ws):
    spaced = os.path.join(ws.dir, "NIOS-X OnPrem v4.qcow2")
    open(spaced, "w").write("x")
    cfg = open(ws.config).read()
    open(ws.config, "w").write(cfg.replace(ws.img, spaced))


case("CRLF in config.env is named, not left to surface later",
     setup=crlf_config, inputs=["", "", "none"], rc=1,
     has=["carriage return", "config.env"], log_hasnt=["RSYNC"])
case("an image name with spaces still lands on Proxmox intact",
     setup=spacey_image, args=("--services", "none") + PIN,
     capture_has=['"/var/lib/vz/template/qcow/NIOS-X_OnPrem_v4.qcow2"'], log_has=["RSYNC"])

# ---- the Proxmox login: root runs commands directly, anyone else via sudo ----
def non_root_login(ws):
    cfg = open(ws.config).read()
    open(ws.config, "w").write(cfg.replace("root@stub-proxmox.invalid", "jsmith@stub-proxmox.invalid"))


case("a non-root Proxmox login runs every remote command through sudo",
     setup=non_root_login, args=("--services", "none") + PIN,
     log_has=["SSH-SUDO", "RSYNC-SUDO", "REMOTE-SCRIPT", "QM-START"])
case("a root Proxmox login does not use sudo",
     args=("--services", "none") + PIN,
     log_has=["REMOTE-SCRIPT", "QM-START"], log_hasnt=["SSH-SUDO", "RSYNC-SUDO"])
case("a non-root login allocates the VMID through sudo",
     setup=non_root_login, args=("--services", "none"), inputs=["", ""], env=HALT,
     log_has=["SSH-SUDO", "ALLOCATE"])

sys.exit(report())
