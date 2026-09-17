# proxblox

![Proxmox VE](https://img.shields.io/badge/Proxmox-VE-E57000?logo=proxmox&logoColor=white)
![OpenTofu](https://img.shields.io/badge/OpenTofu-IaC-FFDA18?logo=opentofu&logoColor=black)
![Infoblox](https://img.shields.io/badge/Infoblox-NIOS--X-0F6EB4)
![Runs on](https://img.shields.io/badge/runs%20on-macOS%20%7C%20Linux%20%7C%20WSL2-555)
![Tests](https://img.shields.io/badge/tests-.%2Fniosx%20test-2EA44F)

One command builds a NIOS-X On-Prem VM on Proxmox. The VM registers itself with
the Infoblox Portal, gets renamed to `<you>-<vmid>`, and starts the services you
pick. It takes 5 to 10 minutes and you never log in to a console.

## Commands

| Command | What it does |
|---------|--------------|
| `./niosx deploy` | Build a VM, join it to the Portal, start services |
| `./niosx add <vmid> <name> <services>` | Add services to a host you already have |
| `./niosx list` | Compare your VMs, the Portal and Terraform |
| `./niosx check [vmid] [--finish]` | Pick up nodes you built with `--no-wait` |
| `./niosx teardown <vmid> --dry-run` | Show what a teardown would remove |
| `./niosx test` | Run the test suite. It contacts no host and no tenant |

## Quick start

1. Install `ssh`, `rsync`, `curl`, `python3` and [OpenTofu](https://opentofu.org). On a Mac: `brew install opentofu`.
2. Copy the settings file and fill in `OWNER`, `PVE`, `IMG`, `POOL` and `BRIDGE`:
   ```bash
   # make your own copy of the settings file, then open it to edit
   cp config.env.example config.env && nano config.env
   ```
3. Save your join token (Portal: System > Administration > Join Tokens):
   ```bash
   # make a private folder for the token
   mkdir -p ~/.config/niosx
   # write the token into a file (paste yours in place of PASTE-JOIN-TOKEN.ibjt)
   printf '%s\n' 'PASTE-JOIN-TOKEN.ibjt' > ~/.config/niosx/jointoken
   # let only you read the file
   chmod 600 ~/.config/niosx/jointoken
   ```
4. Save your API key (Portal: your name, top right > API Keys):
   ```bash
   # make your own copy of the secrets file
   cp terraform/secrets.auto.tfvars.example terraform/secrets.auto.tfvars
   # open it and paste your key: infoblox_api_key = "PASTE-API-KEY"
   nano terraform/secrets.auto.tfvars
   ```
5. Set up Terraform once, then deploy:
   ```bash
   # download the Infoblox plugin Terraform needs (one time only)
   cd terraform && tofu init && cd ..
   # build the VM, join it to the Portal, start services
   ./niosx deploy
   ```

When it finishes, the host shows up in the Portal under Infrastructure > Hosts
as `<you>-<vmid>`.

## What you need

| Where | Needs |
|-------|-------|
| Your machine | `ssh`, `rsync`, `curl`, `python3`, `tofu`. Windows users need WSL2 (see below) |
| Proxmox host | Your own SSH login with passwordless `sudo` (see below), `genisoimage`, and a storage named `local` that holds ISOs |
| VM storage | A `zfspool` or `lvmthin` storage. `dir` and NFS storage do not work |
| Network | DHCP on the bridge, and outbound port 443 from the VM to csp.infoblox.com |

<details>
<summary><b>Proxmox login: use your own user, not root</b></summary>

Set `PVE` in `config.env` to your own login, for example `PVE="jsmith@pve1"`.
The scripts run each Proxmox command through `sudo -n`, so the login needs
passwordless sudo. `PVE="root@pve1"` still works and skips `sudo`, but a
personal login shows who did what in the host's logs.

What the login is used for:

| Needs | Why |
|-------|-----|
| `qm` | Create, import the disk, start, stop and destroy VMs |
| `genisoimage` | Build the join seed ISO |
| Write access to `/var/lib/vz/template/qcow` and `/var/lib/vz/template/iso` | Upload the qcow2 and store the seed ISO |
| Write access to `/etc/niosx` | Keep the VMID counter |
| Read access to `/etc/pve/qemu-server` | `./niosx list` reads VM configs |
| `rsync` | Copy the qcow2 to the host |

A Proxmox admin creates the login one time. The easiest place is the Proxmox
web UI: click the node, then Shell. Replace `jsmith` with your name and
`PASTE-YOUR-PUBLIC-KEY` with the output of `cat ~/.ssh/id_ed25519.pub` on your
machine:

```bash
# install sudo, plus the two tools the scripts use on the host
apt install -y sudo rsync genisoimage
# create the user, with no password (it logs in by SSH key only)
adduser --disabled-password --gecos "" jsmith
# let the user run admin commands without typing a password
echo 'jsmith ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/jsmith
# sudo ignores that file unless only root can change it
chmod 440 /etc/sudoers.d/jsmith
# make the user's private SSH folder
install -d -m 700 -o jsmith -g jsmith /home/jsmith/.ssh
# allow your key to log in as the user
echo 'PASTE-YOUR-PUBLIC-KEY' > /home/jsmith/.ssh/authorized_keys
# SSH ignores the key file unless only the user can read it
chown jsmith:jsmith /home/jsmith/.ssh/authorized_keys && chmod 600 /home/jsmith/.ssh/authorized_keys
```

Check it from your machine. It should print `root` without asking for a password:

```bash
# log in as jsmith and ask sudo who it runs as; prints root if it all works
ssh jsmith@pve1 sudo -n whoami
```

</details>

## Repo layout

| Path | Holds |
|------|-------|
| `niosx` | The one command you run |
| `config.env.example` | Settings template. Your copy, `config.env`, is gitignored |
| `scripts/` | The scripts `niosx` calls |
| `terraform/` | Starts services on registered hosts ([details](terraform/README.md)) |
| `tests/` | Stubbed test suite ([details](tests/README.md)) |
| `docs/` | Handoff notes for whoever works on this next |

## More detail

<details>
<summary><b>Join token vs API key</b></summary>

People mix these up. The scripts refuse a swapped secret, but it helps to know which is which.

| | Join token | CSP API key |
|---|---|---|
| Looks like | Long string ending in `.ibjt` | Long string, no `.ibjt` |
| Portal page | System > Administration > Join Tokens | Your name (top right) > API Keys |
| Used by | The appliance, once, to enrol itself | Terraform, on every run, acting as you |
| Goes in | `~/.config/niosx/jointoken` | `terraform/secrets.auto.tfvars` |

Name the join token after yourself. For about 2 minutes before the rename, the
host is called `ZTP_<token-name>_<digits>`.

Both files are gitignored. That stops accidents, but it does not stop
`git add -f`, screenshots or shell history. The join token is also written into
a seed ISO that stays on the Proxmox host.

</details>

<details>
<summary><b>Deploy options</b></summary>

```bash
./niosx deploy                          # prompts for services
./niosx deploy --services dns,dhcp      # no prompt
./niosx deploy --services none          # build the VM only
./niosx deploy 210 edge-dns             # pick the VMID and name
```

The prompt lists the services your tenant offers, read live from
`/api/infra/v1/applications`:

```
Services available in this tenant:
   dfp,dns,dhcp,cdc,anycast,orpheus,msad,authn,ntp,discovery,dgw

Which should run on the new host?  (comma-separated, or 'none')
services [dns,dhcp]:
```

Registration takes about 2 to 3 minutes and services about 3 to 5 more. The
script waits up to 30 minutes.

| Arg / flag | Meaning | Default |
|------------|---------|---------|
| 1st arg | VMID | Next id from the counter |
| 2nd arg | VM name | `<owner>-<vmid>` |
| 3rd arg | Join token | The stored token file |
| `--services LIST` | Start these services and skip the prompt | Prompts |
| `--resume VMID` | Finish a half-built VM | |
| `--no-wait` | Return once the VM is running | Waits |

</details>

<details>
<summary><b>Build now, finish later (<code>--no-wait</code>)</b></summary>

Most of a deploy is waiting. `--no-wait` gives you your shell back in about 2
minutes, once the VM is running:

```bash
./niosx deploy --services dns --no-wait     # run it as many times as you like
```

Each run leaves a note in `~/.config/niosx/pending/<vmid>.json`. Later:

```bash
./niosx check                 # what happened to them?
./niosx check --finish        # start services on any that have registered
./niosx check 207 --finish    # just that one
```

```
  207   <you>-207        vm:running  portal:<you>-207 10.0.0.9              services:dns,dhcp
        ready. Finish with: ./niosx check 207 --finish
```

Without `--finish`, `check` only reads. A node leaves the list once its
services run. If its VM is gone, `check` says so and stops retrying it.

Finish nodes one at a time. `--finish` runs Terraform against a local state
file, and two applies at once will fight. Building several with `--no-wait` at
the same time is fine.

</details>

<details>
<summary><b>Resume a half-built node</b></summary>

If a deploy dies after the VM exists, `./niosx list` shows it and flags a VM
with no join seed (it will never register on its own):

```
  250    sholland-250    aa:bb:cc:dd:ee:ff   stopped   <- no join seed: ./niosx deploy --resume 250
```

```bash
./niosx deploy --resume 250                    # finish it
./niosx deploy --resume 250 --services dns     # finish it and start services
```

Resume checks what the VM already has and runs only the missing steps: import
the disk, attach the join seed, start the VM, add services. If the VM already
booted without a seed, resume stops it, adds the seed and starts it again. An
appliance that boots without cloud-init never reads one later.

Resume only touches a VM that carries this tool's seed ISO or is named
`<OWNER>-<vmid>`. If only the name matches, it asks you to confirm, so run it
in a terminal. There is no `--yes`.

</details>

<details>
<summary><b>Teardown</b></summary>

```bash
./niosx teardown <vmid> --dry-run    # show what would go, change nothing
./niosx teardown <vmid>              # asks you to type the host name
```

Teardown removes, in order: the host's services (through a Terraform plan it
checks touches only that host), the Portal host record, the Proxmox VM and
disk, and the seed ISO that holds your join token. The VMID is retired.

There is no `--all` and no `--yes`. For scripts, `--confirm "<host name>"`
needs the exact name.

> [!WARNING]
> Do not run `tofu destroy` to remove one host. It destroys the services of
> every host in your state. Do not run `qm destroy` first either, because that
> leaves an orphan record in the Portal.

</details>

<details>
<summary><b>Naming in a shared tenant</b></summary>

Many people share one Infoblox tenant, so `OWNER` from `config.env` prefixes
everything: the VM and Portal host are `<owner>-<vmid>`, and services are
`<owner>-<vmid>-dns`. Use your corporate login or initials.

| If | Then |
|----|------|
| `OWNER` is `CHANGEME`, empty, or generic (`lab`, `test`, `demo`, `poc`, `se`...) | Refused before anything is built |
| A name has characters outside `A-Z a-z 0-9 -` | Refused, because the name reaches a root shell on Proxmox |
| The host name already exists in the tenant | Refused, with the name that clashed |

Use your own API key, never a shared one, so every action traces back to a person.

</details>

<details>
<summary><b>Windows (WSL2)</b></summary>

Only WSL2 with Ubuntu works. Git Bash and PowerShell lack `rsync` and `python3`.

```powershell
# in PowerShell opened as admin: install WSL2 with Ubuntu, then reboot
wsl --install
```

```bash
# all of this runs inside Ubuntu
# install the tools the scripts use
sudo apt update && sudo apt install -y git rsync python3 curl openssh-client
# download OpenTofu's installer, run it, then delete it
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh
sudo ./install-opentofu.sh --install-method deb
rm -f install-opentofu.sh
# make an SSH key and print it; give it to your Proxmox admin (see Proxmox login)
ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub
# stop git turning line endings into Windows ones, which breaks the scripts
git config --global core.autocrlf input
# download this repo into your Linux home folder
git clone https://github.com/holland-built/proxblox ~/proxblox && cd ~/proxblox
# check the tools work, without touching Proxmox or the Portal
./niosx test
```

- Clone into your Linux home (`~`), not `/mnt/c`. Copying the qcow2 from there is much slower.
- Your Windows downloads are at `/mnt/c/Users/<you>/Downloads/`. Use that path for `IMG`. Spaces in the file name are fine.
- Create the token file with `printf` inside WSL. Notepad adds a carriage return that breaks registration.
- Edit `config.env` with `nano` or `vi`. If it has Windows line endings, the scripts stop and tell you.

Status: the line-ending and space-in-filename cases have tests, but nobody has
run the whole path on a Windows machine yet. If you are first, please report
what broke.

</details>

<details>
<summary><b>Troubleshooting</b></summary>

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CSP rejected the API key (HTTP 401)` | Join token in `secrets.auto.tfvars`, or an old key | Get the API key from your name > API Keys |
| `does not look like a join token` | API key in the token file | The join token ends in `.ibjt` |
| `timed out waiting ... to register` | No DHCP lease, no outbound 443, or a CR in the token | Check the VM got an IP; `tr -d '\r'` the token file |
| Registered but never finishes | An SMBIOS serial is set | Never set one (see Reference) |
| `VMID already exists` | Id in use | Leave out the VMID |
| `genisoimage: command not found` | Missing on Proxmox | `ssh <you>@<pve> sudo apt install -y genisoimage` |
| `sudo: a password is required` | Your Proxmox login lacks passwordless sudo | Add the `/etc/sudoers.d/<you>` file (see Proxmox login) |
| `volume ... does not exist` after import | `POOL` is a `dir` storage | Use `zfspool` or `lvmthin` |
| `inconsistent result after apply` | Bare pool id | Use `infra/pool/<id>` |
| Deleted the VM, host still in Portal | Orphan record | Portal > Infrastructure > Hosts > Remove, or `DELETE /api/infra/v1/hosts/<id>` |
| `OWNER "lab" is too generic` | Shared tenant | Use your login or initials in `config.env` |
| `name ... contains characters that are not allowed` | Space, quote or `;` in a name | Letters, digits and hyphens only |
| `already exists in this shared tenant` | That host name is taken | Pick another `--name`, or tear the old one down |
| `PVE in config.env ends with a carriage return` | Saved by a Windows editor | `sed -i 's/\r$//' config.env` |
| Deploy died after the VM was created | Half-built node | `./niosx deploy --resume <vmid>` |

</details>

<details>
<summary><b>Reference: VMIDs, specs, console, static IP, env vars</b></summary>

### VMIDs are never reused

With no VMID given, the next id comes from a counter at `/etc/niosx/last_vmid`
on the Proxmox host (starts at 200). It only goes up, so deleting 203 does not
free 203. Ids in use are skipped. A VMID you pass yourself skips the counter.

### VM size

4096 MB RAM (balloon), 3 vCPU, 64 GB thin disk, 1 virtio NIC, q35, serial
console. This is Infoblox's smallest supported size (the 5 kQPS tier). Disk use
starts near 2.4 GB. Change `RAM`, `CORES` or `DISK` in `config.env`.

### Never set an SMBIOS serial

Infoblox uses serial numbers to provision hardware it sold. A VM with a made-up
serial waits to be claimed as hardware. It ignores the join token and never
contacts the Portal, and nothing logs an error.

| SMBIOS serial | Result |
|---------------|--------|
| None | Registered in about 100 seconds |
| Made-up value | No outbound 443, never registered |
| Removed, then rebooted | Contacted the Portal right away |

The script sets no serial. The console password comes from the serial, so there
is no console password. Manage the host through the Portal or API.

### Console

To read raw serial console output from the Proxmox host:

```bash
# press Enter on the VM's serial console and print what comes back for 3 seconds
{ printf "\n"; sleep 1; } | sudo socat -T3 - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0
```

### Static IP

The script only does DHCP. To set a static IP by hand, add a cloud-init v2
`network-config` to the seed before `genisoimage` runs:

```yaml
version: 2
ethernets:
  nic0:
    match: { macaddress: "<vm-mac>" }
    addresses: [<ip>/<prefix>]
    gateway4: <gateway>
    nameservers: { addresses: [<dns1>, <dns2>] }
```

### Environment overrides

You normally leave these alone. The tests use them so they never read your real files.

| Variable | Points at |
|----------|-----------|
| `NIOSX_CONFIG` | `config.env` |
| `NIOSX_SECRETS` | `terraform/secrets.auto.tfvars` |
| `NIOSX_TOKEN_FILE` | `~/.config/niosx/jointoken` |
| `NIOSX_STATE_DIR` | `~/.config/niosx/teardown` |
| `NIOSX_PENDING_DIR` | `~/.config/niosx/pending` (the `--no-wait` notes) |
| `NIOSX_HOSTS_JSON` | `terraform/niosx_hosts.json`. Also sets `TF_VAR_hosts_file` so scripts and Terraform read the same file |

</details>
