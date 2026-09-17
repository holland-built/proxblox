#!/usr/bin/env bash
# Repeatable NIOS-X (Infoblox On-Prem) deploy to Proxmox — fully hands-off.
# Ships qcow2 local -> Proxmox, builds a thin VM at Infoblox min spec and — if a
# join token is given — builds a cloud-init seed so the appliance self-registers
# to the Infoblox Portal (CSP) on first boot. No console login needed.
#
# Usage:
#   ./deploy-niosx.sh [VMID] [NAME] [JOINTOKEN]
#   VMID auto-allocates from a never-reuse high-water mark on the host
#   (/etc/niosx/last_vmid, seed 200) — delete 203 and the next is still 205, not 203.
#   Reusable join token is stored once at ~/.config/niosx/jointoken (mode 600,
#   outside git), so a normal deploy needs NO args and self-registers:
#     ./deploy-niosx.sh                      # auto VMID, build + join + start
#     ./deploy-niosx.sh 210 edge-dns         # pin a specific VMID + name
#     ./deploy-niosx.sh 210 edge-dns dXMt....ibjt   # override token explicitly
#   No stored token + no arg3 => VM built + STOPPED, no join.
#
# Services: after the host registers, the chosen services are started via
# terraform/. Interactively you are prompted with the list of services this
# tenant supports (fetched live from the API); otherwise pass the flag:
#     ./deploy-niosx.sh --services dns,dhcp
#     ./deploy-niosx.sh --services none      # build the VM, start nothing
#
# Naming: OWNER in config.env prefixes everything, so in a shared CSP tenant
# your objects are obvious: VM/host <owner>-<vmid>, services <owner>-<vmid>-dns.
#
# Networking: the appliance leases via DHCP on the chosen bridge and needs
# outbound HTTPS/443 to csp.infoblox.com. For a static IP instead, see README
# (add a cloud-init network-config).
set -euo pipefail

# --help must work on a fresh clone, before config.env exists
usage() {
  cat <<'HELPEOF'
Build a NIOS-X On-Prem VM on Proxmox, let it self-register to the Infoblox
Portal, rename it, and start the services you pick. ~5-10 min, no console.

  ./niosx deploy [--services LIST] [VMID] [NAME] [JOINTOKEN]

  --services LIST   e.g. dns,dhcp   (omit = prompt with your tenant's list)
  --services none   build the VM only, start nothing
  --resume VMID     finish a VM this tool half-built (see README > Resume)
  --no-wait         build and start it, then exit — do not wait ~5 min for it
                    to register and for its services to come up. Track it with
                    ./niosx check, finish it with ./niosx check <vmid> --finish
  -h, --help        this text

  VMID        default: next id from a never-reuse counter (delete 203 -> next 205)
  NAME        default: <OWNER>-<VMID>, e.g. jsmith-203
  JOINTOKEN   default: the stored token file

Setup (see README)
  config.env                      OWNER, PVE, IMG, POOL, BRIDGE
  ~/.config/niosx/jointoken       join token, ends .ibjt
  terraform/secrets.auto.tfvars   CSP API key (a different secret)

Needs DHCP on the bridge and outbound 443 to csp.infoblox.com.
HELPEOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# ---- environment: copy config.env.example -> config.env and fill it in ----
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${NIOSX_CONFIG:-$HERE/config.env}
if [ ! -f "$CONFIG" ]; then
  echo "!! missing $CONFIG" >&2
  echo "   run: cp $HERE/config.env.example $HERE/config.env   then edit it" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"           # PVE, IMG, POOL, BRIDGE, and optional RAM/CORES/DISK

: "${PVE:?set PVE in config.env}"
: "${IMG:?set IMG in config.env}"
: "${POOL:?set POOL in config.env}"
: "${BRIDGE:?set BRIDGE in config.env}"
: "${OWNER:?set OWNER in config.env (prefix for CSP object names)}"
# shellcheck source=/dev/null
. "$HERE/scripts/lib.sh"
niosx_check_no_cr PVE IMG POOL BRIDGE OWNER
niosx_check_owner "$OWNER"
RAM=${RAM:-4096}                                        # MB  (Infoblox floor = 4 GB)
CORES=${CORES:-3}                                       # Infoblox floor = 3 vCPU
DISK=${DISK:-64G}                                       # Infoblox floor = 64 GB (thin)

# ---- flags (before positionals) ----
SERVICES=""; OPT_VMID=""; OPT_NAME=""; OPT_TOKEN=""; RESUME=""; NOWAIT=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --services)
      [ $# -ge 2 ] || { echo "!! --services needs a value, e.g. --services dns,dhcp" >&2; exit 1; }
      case "$2" in -*) echo "!! --services needs a value, got '$2'" >&2; exit 1 ;; esac
      SERVICES=$2; shift 2 ;;
    --services=*) SERVICES=${1#*=}; shift ;;
    --vmid)  [ $# -ge 2 ] || { echo "!! --vmid needs a number" >&2; exit 1; }; OPT_VMID=$2; shift 2 ;;
    --vmid=*) OPT_VMID=${1#*=}; shift ;;
    --name)  [ $# -ge 2 ] || { echo "!! --name needs a value" >&2; exit 1; }; OPT_NAME=$2; shift 2 ;;
    --name=*) OPT_NAME=${1#*=}; shift ;;
    --token) [ $# -ge 2 ] || { echo "!! --token needs a value" >&2; exit 1; }; OPT_TOKEN=$2; shift 2 ;;
    --token=*) OPT_TOKEN=${1#*=}; shift ;;
    --resume)
      RESUME=1
      # --resume 205  and  --resume  (with the id as a positional) both work
      if [ $# -ge 2 ]; then case "$2" in [0-9]*) OPT_VMID=$2; shift ;; esac; fi
      shift ;;
    --resume=*) RESUME=1; OPT_VMID=${1#*=}; shift ;;
    --no-wait|--nowait|--detach) NOWAIT=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*)           echo "!! unknown option: $1  (try --help)" >&2; exit 1 ;;
    *)            ARGS+=("$1"); shift ;;
  esac
done
if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

# ---- preflight: fail before shipping a multi-GB image ----
for t in ssh rsync curl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "!! missing required tool: $t (see README > Prerequisites)" >&2; exit 1; }
done
[ -f "$IMG" ] || { echo "!! qcow2 not found: $IMG   (set IMG in config.env)" >&2; exit 1; }

VMID=${OPT_VMID:-${1:-}}                                # --vmid or arg1; empty => auto-allocate (never reuse)
NAME=${OPT_NAME:-${2:-}}                                # --name or arg2; default <OWNER>-<VMID>
TOKEN_FILE=${NIOSX_TOKEN_FILE:-$HOME/.config/niosx/jointoken}  # reusable token, outside git (mode 600)
# token precedence: --token > arg3 > JOINTOKEN in config.env > token file
JOINTOKEN=${OPT_TOKEN:-${3:-${JOINTOKEN:-$(tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null || true)}}}
JOINTOKEN=$(printf '%s' "$JOINTOKEN" | tr -d '\r\n')

# ask for the things we were not given (interactive only)
if [ -z "$VMID" ] && [ -t 0 ]; then
  if [ -n "$RESUME" ]; then printf 'VMID to resume: '
  else                      printf 'VMID  [Enter = next free id]: '
  fi
  read -r VMID || VMID=""
fi
[ -z "$VMID" ] || niosx_check_vmid "$VMID"
if [ -n "$RESUME" ] && [ -z "$VMID" ]; then
  echo "!! --resume needs the VMID of the half-built VM." >&2
  echo "   e.g. ./niosx deploy --resume 205        (./niosx list shows what exists)" >&2
  exit 1
fi
# on a resume the name comes from the VM that already exists
if [ -z "$NAME" ] && [ -z "$RESUME" ] && [ -t 0 ]; then
  printf 'Name  [Enter = %s-%s]: ' "$OWNER" "${VMID:-<next>}"; read -r NAME || NAME=""
fi
[ -z "$NAME" ] || niosx_check_name "$NAME" "name"

REMOTE=/var/lib/vz/template/qcow
# The name is reused inside a remote shell command. A downloaded image often
# has spaces in it (Windows especially), so keep only characters that survive
# the trip; the local file is untouched.
BASENAME=$(printf '%s' "$(basename "$IMG")" | tr -c 'A-Za-z0-9._-' '_')

# NOTE: do NOT set an SMBIOS serial. Infoblox uses serial numbers for ZTP of
# *purchased hardware*; a made-up serial makes the appliance wait to be claimed
# as hardware and it never uses the join token — it won't even dial CSP.
# Verified: identical VM registered in ~100s with no serial, and never
# registered with serial=NIOSX-<vmid>. Removing the serial fixed it immediately.

# ---- CSP credentials and the service list this tenant actually offers ----
SEC=${NIOSX_SECRETS:-$HERE/terraform/secrets.auto.tfvars}
CSP=${CSP_URL:-https://csp.infoblox.com}
# Fallback only, used when the API is unreachable. Snapshot of
# /api/infra/v1/applications on 2026-09-02 — the live fetch is authoritative.
CACHED_APPS="dfp,dns,dhcp,cdc,anycast,orpheus,msad,authn,ntp,discovery,dgw"
PENDING_DIR=${NIOSX_PENDING_DIR:-$HOME/.config/niosx/pending}

csp_key() {                 # prints the CSP API key, or explains why it cannot
  if [ ! -f "$SEC" ]; then
    echo "!! missing $SEC" >&2
    echo "   cp terraform/secrets.auto.tfvars.example terraform/secrets.auto.tfvars, then add your CSP API key" >&2
    return 1
  fi
  k=$(sed -nE 's/^[[:space:]]*infoblox_api_key[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$SEC" | tail -1 | tr -d '\r')
  case "$k" in
    ""|REPLACE_WITH_CSP_API_KEY)
      echo "!! $SEC still has the placeholder — paste your CSP API key" >&2
      echo "   Portal > your name (top-right) > API Keys" >&2; return 1 ;;
    *.ibjt)
      echo "!! $SEC contains a JOIN TOKEN (it ends in .ibjt), not an API key." >&2
      echo "   Join token belongs in : $TOKEN_FILE" >&2
      echo "   API key comes from    : Portal > your name (top-right) > API Keys" >&2; return 1 ;;
  esac
  printf '%s' "$k"
}

# Sets APPS and APPS_SRC (live|cached). Return: 0 ok, 1 unreachable, 2 fatal
# (missing or rejected key) — the caller must not silently continue on 2.
APPS=""; APPS_SRC=""
fetch_apps() {
  k=$(csp_key) || return 2
  body=$(curl -s -w '\n%{http_code}' --max-time 20 -H "Authorization: Token $k" \
          "$CSP/api/infra/v1/applications" || true)
  code=$(printf '%s' "$body" | tail -1)
  case "$code" in
    200)
      APPS=$(printf '%s' "$body" | sed '$d' \
             | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin).get("results",{}).get("applications",[])))' 2>/dev/null || true)
      [ -n "$APPS" ] || return 1
      APPS_SRC=live; return 0 ;;
    401|403)
      echo "!! CSP rejected the API key (HTTP $code)." >&2
      echo "   Regenerate: Portal > your name (top-right) > API Keys" >&2; return 2 ;;
    *) return 1 ;;
  esac
}

use_cached_apps() {         # always says out loud that the list may be stale
  APPS=$CACHED_APPS; APPS_SRC=cached
  echo "!! could not reach the CSP applications API — using a cached list" >&2
  echo "   (snapshot 2026-09-02; a service added to your tenant since then will" >&2
  echo "    be rejected here — retry when the API is reachable)" >&2
}

# ---- which services to start once it registers? ----
if [ -z "$SERVICES" ] && [ -t 0 ]; then
  if fetch_apps; then fa=0; else fa=$?; fi
  if [ "$fa" = 2 ]; then exit 1; fi
  if [ "$fa" != 0 ]; then use_cached_apps; fi
  echo
  echo
  echo "Services available in this tenant:"
  n=1
  for a in $(printf '%s' "$APPS" | tr ',' ' '); do printf '   %2d) %s\n' "$n" "$a"; n=$((n + 1)); done
  echo
  echo "Pick numbers or names, comma-separated. Enter = dns,dhcp. 'none' = skip."
  printf 'services: '
  read -r choice || choice=""
  choice=${choice:-dns,dhcp}
  case "$choice" in
    none|NONE|None) SERVICES=none ;;
    *)
      SERVICES=""
      for tok in $(printf '%s' "$choice" | tr ',' ' '); do
        case "$tok" in
          *[!0-9]*)  pick=$tok ;;                    # a name
          0|0*)      echo "!! there is no service numbered $tok — the list starts at 1" >&2; exit 1 ;;
          *)         pick=$(printf '%s' "$APPS" | tr ',' '\n' | sed -n "${tok}p") ;;
        esac
        [ -n "$pick" ] || { echo "!! no service numbered $tok" >&2; exit 1; }
        SERVICES="${SERVICES:+$SERVICES,}$pick"
      done ;;
  esac
fi
SERVICES=${SERVICES:-none}
SERVICES=$(printf '%s' "$SERVICES" | tr -d '[:space:]')
echo ">> services: $SERVICES"

# join token must actually look like a join token
if [ -n "$JOINTOKEN" ]; then
  case "$JOINTOKEN" in
    *.ibjt) ;;
    *) echo "!! that does not look like a join token (should end in .ibjt)." >&2
       echo "   Get one: Portal > System > Administration > Join Tokens" >&2; exit 1 ;;
  esac
fi

# If services will be started: prove the key works and check the names BEFORE
# the big upload. This runs for --services too, so a flag is validated against
# the live tenant rather than against the snapshot above.
if [ "$SERVICES" != "none" ]; then
  command -v tofu >/dev/null 2>&1 || { echo "!! missing required tool: tofu (brew install opentofu)" >&2; exit 1; }
  if [ -z "$APPS" ]; then
    if fetch_apps; then fa=0; else fa=$?; fi
    if [ "$fa" = 2 ]; then exit 1; fi
    if [ "$fa" != 0 ]; then use_cached_apps; fi
  fi
  for want in $(printf '%s' "$SERVICES" | tr ',' ' '); do
    case ",$APPS," in
      *",$want,"*) ;;
      *) echo "!! '$want' is not a service this tenant offers." >&2
         echo "   valid: $APPS" >&2
         if [ "$APPS_SRC" = cached ]; then
           echo "   (that list is the cached snapshot — the tenant API was unreachable)" >&2
         fi
         exit 1 ;;
    esac
  done
  if [ "$APPS_SRC" = live ]; then echo ">> CSP API key OK"; fi
fi

# ---- resume: finish a VM this tool already half-built ----
# Everything below is driven by these four flags, so a resume runs exactly the
# steps that are missing and a normal deploy runs all of them.
NEED_IMAGE=1; NEED_CREATE=1; NEED_DISK=1; NEED_SEED=1; NEED_START=1

if [ -n "$RESUME" ]; then
  if ! EXIST=$(ssh "$PVE" "$PVE_SUDO qm config $VMID" 2>/dev/null); then
    echo "!! VM $VMID does not exist on $PVE — there is nothing to resume." >&2
    echo "   Build a new one: ./niosx deploy" >&2; exit 1
  fi
  EX_NAME=$(printf '%s\n' "$EXIST" | sed -n 's/^name: //p')
  EX_STAT=$(ssh "$PVE" "$PVE_SUDO qm status $VMID" 2>/dev/null | awk '{print $2}')
  HAS_SEED=0; case "$EXIST" in *"seed-niosx-$VMID.iso"*) HAS_SEED=1 ;; esac
  HAS_DISK=0; case "$EXIST" in *"scsi0:"*) HAS_DISK=1 ;; esac

  # Only touch a VM that is plainly ours: it carries our seed ISO, or it is
  # named with this OWNER's prefix. Anything else gets left alone.
  OURS=0
  if [ "$HAS_SEED" = 1 ]; then OURS=1; fi
  case "$EX_NAME" in "$OWNER"-*) OURS=1 ;; esac
  if [ "$OURS" != 1 ]; then
    echo "!! VM $VMID is \"$EX_NAME\" — it has no niosx seed and does not start with \"$OWNER-\"." >&2
    echo "   It was not built by this tool. Refusing to touch it." >&2; exit 1
  fi

  NAME=${EX_NAME:-$OWNER-$VMID}
  niosx_check_name "$NAME" "existing VM name"

  NEED_CREATE=0
  if [ "$HAS_DISK" = 1 ]; then NEED_DISK=0; fi
  NEED_IMAGE=$NEED_DISK                       # the image is only needed to import
  if [ "$HAS_SEED" = 1 ]; then NEED_SEED=0; fi
  if [ "$EX_STAT" = "running" ]; then NEED_START=0; fi
  # a VM that booted without a seed never registers: it has to be reseeded
  if [ "$NEED_SEED" = 1 ]; then NEED_START=1; fi

  echo ">> resuming $NAME (VM $VMID, $EX_STAT)"
  echo "   disk imported : $([ "$HAS_DISK" = 1 ] && echo yes || echo 'no  -> will import')"
  echo "   join seed     : $([ "$HAS_SEED" = 1 ] && echo yes || echo 'no  -> will build and attach')"
  echo "   services      : $SERVICES"
  if [ "$NEED_SEED" = 1 ] && [ -z "$JOINTOKEN" ]; then
    echo "!! this VM still needs a join seed, but no join token is configured." >&2
    echo "   Put one in $TOKEN_FILE (it ends in .ibjt)." >&2; exit 1
  fi
  if [ "$HAS_SEED" != 1 ]; then
    # matched by name only — make a human agree before we start changing it
    if [ -t 0 ]; then
      printf 'Resume this VM? [y/N]: '; read -r yn || yn=""
      case "$yn" in y|Y|yes|YES) ;; *) echo "Aborted — nothing changed."; exit 2 ;; esac
    else
      echo "!! matched by name only and there is no terminal to confirm on." >&2
      echo "   Re-run interactively, or tear it down: ./niosx teardown $VMID --dry-run" >&2
      exit 2
    fi
  fi
fi

# ---- allocate VMID: never-reuse high-water mark on the Proxmox host ----
# (single-quoted remote script; $(), $(()) etc. evaluate ON the host)
if [ -z "$VMID" ]; then
  # (no single quotes in here: it is wrapped in bash -c '...' for sudo)
  VMID=$(ssh "$PVE" "$PVE_SUDO bash -c '"'
    mkdir -p /etc/niosx
    exec 9>/etc/niosx/.vmid.lock; flock 9          # serialize concurrent deploys
    last=$(cat /etc/niosx/last_vmid 2>/dev/null || echo 200)
    case "$last" in ""|*[!0-9]*) last=200 ;; esac
    [ "$last" -ge 200 ] || last=200
    n=$((last + 1))
    while qm status "$n" >/dev/null 2>&1; do n=$((n + 1)); done   # skip occupied ids
    printf "%s\n" "$n" > /etc/niosx/last_vmid
    printf "%s\n" "$n"
  '"'")
  echo ">> allocated VMID $VMID (high-water mark — freed ids never reused)"
fi
NAME=${NAME:-$OWNER-$VMID}
niosx_check_name "$NAME" "name"

if [ -z "$RESUME" ]; then
  # If the caller pinned a VMID, say something useful *before* shipping the
  # image. (Auto-allocated ids already skip anything occupied.)
  if EXIST=$(ssh "$PVE" "$PVE_SUDO qm config $VMID" 2>/dev/null); then
    ex_name=$(printf '%s\n' "$EXIST" | sed -n 's/^name: //p')
    ex_stat=$(ssh "$PVE" "$PVE_SUDO qm status $VMID" 2>/dev/null | awk '{print $2}')
    echo "!! VMID $VMID is already in use: \"$ex_name\" ($ex_stat)" >&2
    if printf '%s\n' "$EXIST" | grep -q "seed-niosx-$VMID.iso"; then
      echo "   It was built by this tool. If it is a leftover from a failed run:" >&2
      echo "     ./niosx deploy --resume $VMID        # finish it" >&2
      echo "     ./niosx teardown $VMID --dry-run     # or remove it" >&2
    else
      echo "   It was NOT built by this tool — leave it alone." >&2
    fi
    echo "   Or omit --vmid to get the next free id." >&2
    exit 1
  fi

  # The tenant is shared by hundreds of engineers, so the host name has to be
  # free tenant-wide, not just on this Proxmox host. A tenant with no match
  # answers with a bare {} — no "results" key at all — which is a free name,
  # NOT a failed query. Only a non-200 or unparseable body counts as skipped.
  if k=$(csp_key 2>/dev/null); then
    nm=$(curl -s -w '\n%{http_code}' --max-time 20 -G -H "Authorization: Token $k" \
           --data-urlencode "_filter=display_name==\"$NAME\"" \
           "$CSP/api/infra/v1/detail_hosts" || true)
    nm_code=$(printf '%s' "$nm" | tail -1)
    if [ "$nm_code" = 200 ]; then
      taken=$(printf '%s' "$nm" | sed '$d' | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
if not isinstance(d, dict):
    print("?"); raise SystemExit
r = d.get("results")
print(len(r) if isinstance(r, list) else (0 if r is None else "?"))' 2>/dev/null || printf '?')
    else
      taken="?"
    fi
    case "$taken" in
      0)      echo ">> name check: \"$NAME\" is free in the tenant" ;;
      ""|"?") echo ">> name check: skipped (the tenant name query answered HTTP $nm_code)" ;;
      *)      echo "!! \"$NAME\" already exists in this shared tenant ($taken host(s))." >&2
              echo "   OWNER=\"$OWNER\" is not unique, or you already built this host." >&2
              echo "   Pick another name: ./niosx deploy --vmid $VMID --name <something-unique>" >&2
              exit 1 ;;
    esac
  else
    echo ">> name check: skipped (no CSP API key configured)"
  fi
fi

if [ "$NEED_IMAGE" = 1 ]; then
  echo ">> 1/6  Ship image local -> Proxmox"
  ssh "$PVE" "$PVE_SUDO mkdir -p $REMOTE"
  rsync -aP ${PVE_SUDO:+--rsync-path="$PVE_SUDO rsync"} "$IMG" "$PVE:$REMOTE/$BASENAME"
else
  echo ">> 1/6  image not needed (disk already imported) — skipped"
fi

if [ "$NEED_CREATE" = 1 ]; then
  echo ">> 2/6  Build VM $VMID"
  # shellcheck disable=SC2087   # deliberate: these values are expanded locally
  ssh "$PVE" "$PVE_SUDO bash -s" <<EOF
set -euo pipefail
if qm status $VMID >/dev/null 2>&1; then
  echo "!! VMID $VMID appeared since the preflight check — aborting." >&2; exit 1
fi
qm create $VMID --name "$NAME" --machine q35 --ostype l26 \
  --memory $RAM --balloon $RAM --cores $CORES \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=$BRIDGE \
  --serial0 socket --vga serial0
EOF
else
  echo ">> 2/6  VM $VMID already exists — skipped"
fi

if [ "$NEED_DISK" = 1 ]; then
  echo ">> 3/6  Import disk (thin zvol on $POOL)"
  # shellcheck disable=SC2087   # deliberate: these values are expanded locally
  ssh "$PVE" "$PVE_SUDO bash -s" <<EOF
set -euo pipefail
qm importdisk $VMID "$REMOTE/$BASENAME" $POOL
qm set $VMID --scsi0 $POOL:vm-$VMID-disk-0,discard=on,ssd=1
qm set $VMID --boot order=scsi0
qm resize $VMID scsi0 $DISK
zfs get -H used,volsize,refreservation rpool/data/vm-$VMID-disk-0 || true
EOF
else
  echo ">> 3/6  disk already imported — skipped"
fi

if [ -n "$JOINTOKEN" ]; then
  if [ "$NEED_SEED" = 1 ]; then
    echo ">> 4/6  Build cloud-init join seed + attach (auto-register to CSP)"
    # shellcheck disable=SC2087   # deliberate: these values are expanded locally
  ssh "$PVE" "$PVE_SUDO bash -s" <<EOF
set -euo pipefail
# an appliance that already booted without a seed will never read one: stop it
if qm status $VMID 2>/dev/null | grep -q running; then
  echo ">> stopping $VMID to attach the join seed"
  qm stop $VMID
  for i in \$(seq 1 30); do qm status $VMID | grep -q stopped && break; sleep 2; done
fi
D=/tmp/niosx-seed-$VMID; rm -rf "\$D"; mkdir -p "\$D"; cd "\$D"
cat > user-data <<YAML
#cloud-config
host_setup:
  jointoken: "$JOINTOKEN"
YAML
cat > meta-data <<YAML
instance-id: niosx-$VMID-\$(date +%s)
local-hostname: $NAME
YAML
genisoimage -quiet -output /var/lib/vz/template/iso/seed-niosx-$VMID.iso -volid cidata -joliet -rock user-data meta-data
# the seed carries the join token: keep it unreadable and leave no cleartext copy
chmod 600 /var/lib/vz/template/iso/seed-niosx-$VMID.iso
cd /; rm -rf "\$D"
qm set $VMID --ide2 local:iso/seed-niosx-$VMID.iso,media=cdrom
EOF
  else
    echo ">> 4/6  join seed already attached — skipped"
  fi

  if [ "$NEED_START" = 1 ]; then
    echo ">> 5/6  Start $VMID (leases DHCP, then registers to CSP)"
    ssh "$PVE" "$PVE_SUDO qm start $VMID"
    echo ">> VM $VMID starting + auto-registering."
  else
    echo ">> 5/6  VM $VMID already running — skipped"
  fi

  if [ -n "$NOWAIT" ]; then
    # Leave a note to ourselves so `./niosx check` can pick this up later,
    # instead of the caller having to remember what was still in flight.
    mkdir -p "$PENDING_DIR"; chmod 700 "$PENDING_DIR" 2>/dev/null || true
    python3 -c '
import json, sys
path, vmid, name, svcs, pve = sys.argv[1:6]
json.dump({"vmid": vmid, "name": name,
           "services": "" if svcs == "none" else svcs, "pve": pve},
          open(path, "w"), indent=2)' \
      "$PENDING_DIR/$VMID.json" "$VMID" "$NAME" "$SERVICES" "$PVE"
    echo ">> 6/6  not waiting — it registers on its own in ~2 min"
    echo ">> DONE. $NAME is building. Services still to start: ${SERVICES}"
    echo "   Check on it: ./niosx check"
    echo "   Finish it:   ./niosx check $VMID --finish"
  elif [ "$SERVICES" != "none" ]; then
    echo ">> 6/6  Adding services once it registers"
    "$HERE/scripts/add-services.sh" "$VMID" "$NAME" "$SERVICES"
    echo ">> DONE. $NAME deployed and running: $SERVICES"
  else
    echo ">> DONE. VM started. Registration happens on its own (~2-3 min) - not verified here."
    echo "   Start some later: ./niosx add $VMID $NAME dns,dhcp"
  fi
else
  echo ">> 4/6  No join token given — VM built + STOPPED. Start with: ssh $PVE $PVE_SUDO qm start $VMID"
  echo ">> To join later: re-run with the token as arg3, or attach a seed manually (see README)."
fi
