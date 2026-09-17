# Prompt for a fresh session

Paste everything in the block below into a new Claude Code session.

---

```
Work on the NIOS-X on Proxmox tooling at ~/AI/HomeSystems/niosx
(public repo: github.com/holland-built/proxblox). Read docs/HANDOFF.md and README.md first,
then run ./niosx test (30s, touches nothing).

WHAT IT IS
One command builds an Infoblox NIOS-X On-Prem VM on Proxmox, lets it self-register
to the Infoblox Portal (CSP) via a cloud-init join token, renames it, and starts
chosen services via OpenTofu. Audience: ~700 Infoblox sales engineers sharing ONE
CSP tenant, mostly network people rather than developers.

  ./niosx deploy | add | check | teardown | list | test
  ./niosx deploy --resume <vmid>     # finish a half-built node
  ./niosx deploy --services dns --no-wait   # build without waiting ~5 min
  ./niosx check [vmid] [--finish]    # ...then finish those later

DONE AND VERIFIED LIVE
- Full lifecycle twice: VM 202 (dns,dhcp) and VM 201 (dns,ntp), both built then
  torn down completely, with a second host provably untouched each time.
- One host is currently live (see `./niosx list`) running DNS + DHCP. Leave it up.
- Next VMID is 207 (never-reuse counter at /etc/niosx/last_vmid on the Proxmox host).
- 2026-09-02: interactive path driven through a real pty at last (48 assertions in
  tests/), which turned up a command injection through the Name prompt — a name of
  x;reboot ran `reboot` as root on the Proxmox host. Fixed, plus --resume, live
  service validation, tenant-wide name check, enforced OWNER, and the teardown
  journal is finally read. See "Fixed on 2026-09-02" in docs/HANDOFF.md.
- 2026-09-02: built sholland-207/208/209 (dns), then added dhcp to all three.
  Four hosts are live now: 203, 207, 208, 209, all dns+dhcp. Next VMID 210.
  `./niosx add` was merging-not-replacing only after a fix — before it, adding
  dhcp would have destroyed each host's running dns on the next apply.
- 2026-09-02: the whole lifecycle re-verified on the CURRENT code with VM 206 —
  deploy, register, rename off the ZTP name, tofu apply (dns up in 2m27s), then
  teardown, which destroyed exactly one service and left host 203's two alone.
- 2026-09-02: --resume proven on real hardware. VM 205 was deliberately failed at
  the disk-import step, resumed, registered in ~2 min, then torn down clean; the
  live host 203 was untouched throughout. VMID counter is now 205, next id 206.

REMAINING WORK, most valuable first
1. Windows. Documented as WSL2-only. The two known traps (CRLF config.env, spaces
   in the image filename) are handled and covered by tests, but nothing has been
   run on an actual Windows machine: wsl --install, the OpenTofu deb, an ssh key
   from WSL to Proxmox, and a 3.2 GB qcow2 read out of /mnt/c.
2. Nothing else is open. --resume, ./niosx add coverage, the tenant name check and
   the teardown journal were all finished and verified on 2026-09-02.

HARD-WON FACTS — do not relearn these (all verified against the live API)
- NEVER set an SMBIOS serial. A made-up serial makes the appliance wait to be
  claimed as purchased hardware; it never uses the join token and never dials CSP,
  with no error anywhere. No serial = registers in ~100 seconds.
- Two different secrets: the join token ends in .ibjt (Portal > System >
  Administration > Join Tokens) and is used by the appliance; the CSP API key
  (Portal > your name > API Keys) is used by Terraform. Swapped gives HTTP 401.
- pool_id is nested at detail_hosts[].pool.pool_id and returned bare; the provider
  requires it prefixed "infra/pool/<id>" or apply fails with "inconsistent result
  after apply".
- Hosts register under a generated name ZTP_<join-token-name>_<digits>. Match hosts
  by MAC using a server-side _filter, never by name, and never client-side paging:
  /api/infra/v1/hosts returned 101 records while detail_hosts returned 500+.
- A failed apply leaves resources tainted; `tofu untaint` rather than letting the
  next apply destroy and recreate live services.
- `qm destroy --purge` does NOT remove the seed ISO, which contains the join token.
- The prompts sit behind `[ -t 0 ]`, so a plain subprocess never reaches them.
  tests/harness.py drives a real pty. Do not "simplify" that away.

CONVENTIONS
- The repo is PUBLIC. No real IPs, MACs, tokens or pool ids in committed files.
  config.env, terraform/secrets.auto.tfvars and terraform/niosx_hosts.json are
  gitignored and hold the real values.
- Proxmox host is in config.env, not in git.
- Use OpenTofu (`tofu`), not terraform.
- teardown is destructive: always --dry-run first. There is deliberately no --all
  and no --yes; --confirm "<exact host name>" is the scripted path.
- Anything a user types (VMID, name, label) is validated in scripts/lib.sh before it can
  reach a root shell on Proxmox, a Portal record or a regex. Add new input there.
- Every change to the scripts: run ./niosx test, and prove a new test fails when
  you break the behaviour on purpose. A green suite proves nothing by itself.
- This tooling is unrelated to the Home Assistant config repo at
  ~/AI/HomeSystems/config. Do not mix them. /whats-next is an HA skill and does not
  apply here.

A recurring failure mode in this codebase has been code that LOOKS like it works:
silent fallbacks, misleading success messages, an assertion comparing "None".
Test the actual code path, not the endpoint.
```
