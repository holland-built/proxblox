# Handoff: NIOS-X on Proxmox tooling

Status as of 2026-09-02. Repo: https://github.com/holland-built/proxblox (public).

## What this is

One command builds an Infoblox NIOS-X On-Prem VM on Proxmox, lets it register
itself to the Infoblox Portal, renames it, and starts the services you choose.
Another removes all of it. Aimed at ~700 sales engineers sharing one CSP tenant.

```bash
./niosx deploy                     # prompts, then does everything
./niosx deploy --services dns --no-wait   # build it, do not wait ~5 min
./niosx check [vmid] [--finish]    # ...then pick those up later
./niosx deploy --resume <vmid>     # finish a half-built node
./niosx add <vmid> <name> <svcs>   # add services to an existing host
./niosx teardown <vmid> --dry-run  # see what would go
./niosx list                       # your VMs vs Portal vs Terraform
./niosx test                       # stubbed suite: no host, no tenant
```

## Verified working

| Path | Evidence |
|------|----------|
| Deploy → register → rename → services | VM 206 (`dns`) on the current code: registered, renamed from its ZTP name, recorded, service created in 2m27s. Earlier: VM 203 (`dns,dhcp`), VM 201 (`dns,ntp`) |
| Teardown, including service removal | VM 206 on the current code: `Resources: 0 added, 0 changed, 1 destroyed`. Earlier: VM 202 and VM 201 |
| Blast-radius isolation | tearing 206 down destroyed exactly its own service and left 203's two, its VM, its Portal record and its state untouched |
| Never-reuse VMIDs | counter at 206 after 201/202/204/205/206 retired |
| **Interactive prompts + numbered menu** | 39 assertions in `tests/`, driven through a real pty |
| **`--resume`** | VM 205, live: deploy failed at disk import, resume imported the disk, built and attached the seed, started it, and it registered in ~2 min; torn down clean afterwards |
| **`./niosx add`** | live on VMs 207/208/209: added dhcp to hosts already running dns, `1 added, 0 changed, 0 destroyed` each time |
| **`--no-wait` / `./niosx check`** | check run live against 207: read Proxmox, the Portal and Terraform state, saw both services up, cleared its own record |

Currently live: VM 203 (named `<OWNER>-203`) running DNS + DHCP (`./niosx list` for its IP).

## Hard-won facts (do not relearn these)

- **Never set an SMBIOS serial.** A made-up serial makes the appliance wait to
  be claimed as purchased hardware; it never uses the join token and never dials
  CSP, with no error anywhere. No serial = registers in ~100s.
- **Two different secrets.** Join token (ends `.ibjt`, from System >
  Administration > Join Tokens) is used by the appliance to enrol. The CSP API
  key (your name > API Keys) is used by Terraform. Swapped = HTTP 401.
- **`pool_id` is nested** at `detail_hosts[].pool.pool_id` and comes back bare;
  the provider needs it prefixed as `infra/pool/<id>` or apply fails with
  "inconsistent result after apply".
- **Hosts register under a generated name** `ZTP_<join-token-name>_<digits>`.
  Match hosts by MAC, not name. Name your join token after yourself.
- **`/api/infra/v1/hosts` is not the full picture.** It returned 101 records
  while `detail_hosts` returned 500+. Use `detail_hosts` with a server-side
  `_filter`, not client-side paging.
- **A tainted resource after a failed apply** will be destroyed and recreated by
  the next apply. `tofu untaint` instead.
- **`--purge` does not remove the seed ISO**, which contains the join token.
- **A query that matches nothing returns a bare `{}`.** There is no `results` key at
  all. Read as a failed lookup, teardown refuses to run on a host that is
  simply not registered. `results` missing = zero matches, not an error.
- **Services are not in `detail_hosts[].configs`.** That only ever lists
  `platform` and `appmgmt`. They live at `/api/infra/v1/services`, and refer to
  their host as `infra/host/<id>` while `detail_hosts` returns that id bare.
  Same prefixed-vs-bare trap as `pool_id`.
- **`/api/infra/v1/services?_limit=500` returned 101 records** and this owner's
  services were not among them. Filter server-side (`_filter=name~"<owner>-"`),
  never page a listing client-side. Same 101 cap as `/hosts`.
- **The prompts are behind `[ -t 0 ]`.** A plain `subprocess` never reaches
  them; that is why they went untested for so long. `tests/harness.py` uses a
  pty. Do not "simplify" that away.

## Fixed on 2026-09-02

| Was | Now |
|-----|-----|
| A VM name went unvalidated and unquoted into `qm create` over ssh; `x;reboot` ran `reboot` as root on the Proxmox host | names are `[A-Za-z0-9-]`, checked before anything ships, and quoted in the remote command |
| `--services` was validated against a hardcoded 2026-09-02 snapshot | validated against the live tenant; the snapshot is a labelled fallback |
| The host name was only unique by convention | checked against the tenant before the build; a clash refuses |
| `OWNER` uniqueness was documented, not enforced | generic and malformed values are refused |
| VMID `7` was accepted and failed after a multi-GB upload | must be 100-999999999, checked up front |
| The teardown journal was written and never read | reported on the next teardown, and by `./niosx list` |
| A failed deploy left a VM you could only delete | `./niosx deploy --resume <vmid>` |
| The host name was spliced into JSON for the CSP rename | built with `json.dumps` |
| `./niosx add <host> dhcp` REPLACED the service list, so it would have destroyed the dns that host was already running | the list is merged; re-adding an existing service is a no-op |
| Teardown refused to run on a host that was not in the Portal, calling it a failed lookup | a bare `{}` is read as zero matches |
| `./niosx list` always showed `-` for services, whatever was running | read from `/api/infra/v1/services`, filtered server-side |
| The image basename picked up a trailing `_` and shipped a duplicate 3.2 GB file | `basename`'s newline is stripped before sanitising |
| CRLF in `config.env` failed three steps later, unrecognisably | named at startup |

## Known gaps

| Gap | Note |
|-----|------|
| Windows | hardened for WSL2 and covered by tests for the two known traps (CRLF, spaces in the image name), but never actually run on Windows |
| Resuming a seed-less VM needs a terminal | matched by name alone, so it asks before touching anything. There is deliberately no `--yes` |
| Service names | services are `<host>-<svc>`, so they are unique once the host name is. Not separately checked |
| `./niosx list` "next VMID" | prints counter+1, which can name an occupied id. Cosmetic: allocation itself skips occupied ids |

## Where things live

| Path | What |
|------|------|
| `config.env` | your settings + join token (gitignored) |
| `~/.config/niosx/jointoken` | alternative token location |
| `terraform/secrets.auto.tfvars` | CSP API key (gitignored) |
| `terraform/niosx_hosts.json` | which hosts/services you manage (gitignored, per-user) |
| `/etc/niosx/last_vmid` (Proxmox) | never-reuse VMID counter |
| `~/.config/niosx/teardown/<vmid>.json` | journal of a teardown in progress |
| `~/.config/niosx/pending/<vmid>.json` | a node built with `--no-wait`, not yet finished |
| `scripts/lib.sh` | shared validators (names, VMIDs, OWNER, CRLF) |
| `tests/` | stubbed suite; `./niosx test` |
| `NIOSX_HOSTS_JSON` | points this script *and* Terraform (`TF_VAR_hosts_file`) at one hosts file, used by the tests |

## If you pick this up

Start with `./niosx test`: 30 seconds, proves the tooling still works without
touching anything. Then `./niosx list`, which shows whether Proxmox, the Portal
and Terraform agree. Always `--dry-run` a teardown first.
