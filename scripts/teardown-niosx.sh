#!/usr/bin/env bash
# Destroy one NIOS-X node: its services, its CSP host record, and its Proxmox VM.
#
#   ./teardown-niosx.sh <vmid> [--label NAME] [--dry-run]
#
# Read-only discovery first, then a typed confirmation, then journalled steps
# that are each safe to re-run. Deliberately handles ONE vmid: there is no
# --all, no ranges and no globs.
set -euo pipefail

usage() {
  cat <<'HELPEOF'
Destroy one NIOS-X node: services, Infoblox CSP host, and the Proxmox VM.

  ./niosx teardown <vmid> [--label NAME] [--dry-run]

  --label NAME   host name, if it is not <OWNER>-<VMID> (needed when the VM
                 is already gone and cannot be matched by MAC)
  --dry-run      show what would be destroyed, change nothing
  --confirm NAME non-interactive: NAME must equal the host name exactly
  -h, --help     this text

Never touches: the VMID counter (ids are never reused), the shared qcow2
image, or your join token file. There is no --all, by design.
HELPEOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${NIOSX_CONFIG:-$HERE/config.env}
[ -f "$CONFIG" ] || { echo "!! missing $CONFIG" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONFIG"
# shellcheck source=/dev/null
. "$HERE/scripts/lib.sh"
niosx_check_no_cr PVE OWNER
# shellcheck disable=SC2034  # read by niosx_die in lib.sh
NIOSX_DIE_CODE=2          # this script uses 2 for "refused before changing anything"

VMID=""; LABEL_OPT=""; DRY=0; CONFIRM_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label)   [ $# -ge 2 ] || { echo "!! --label needs a value" >&2; exit 2; }; LABEL_OPT=$2; shift 2 ;;
    --label=*) LABEL_OPT=${1#*=}; shift ;;
    --dry-run) DRY=1; shift ;;
    --confirm) [ $# -ge 2 ] || { echo "!! --confirm needs the exact host name" >&2; exit 2; }
               CONFIRM_OPT=$2; shift 2 ;;
    --confirm=*) CONFIRM_OPT=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    --all|--force|-y|--yes)
      echo "!! $1 is not supported. Tear down one VMID at a time, on purpose." >&2; exit 2 ;;
    -*)        echo "!! unknown option: $1" >&2; exit 2 ;;
    *)         [ -z "$VMID" ] && VMID=$1 || { echo "!! one VMID at a time" >&2; exit 2; }; shift ;;
  esac
done

[ -n "$VMID" ] || { usage; exit 2; }
case "$VMID" in ''|*[!0-9]*) echo "!! VMID must be a number (got '$VMID')" >&2; exit 2 ;; esac
# validate what the caller typed before it reaches a filter, a regex or a shell
[ -z "$LABEL_OPT" ] || niosx_check_label "$LABEL_OPT" "--label"
[ -z "$CONFIRM_OPT" ] || niosx_check_label "$CONFIRM_OPT" "--confirm"
: "${PVE:?set PVE in config.env}"
: "${OWNER:?set OWNER in config.env}"
case "$OWNER" in CHANGEME|"") echo "!! set a real OWNER in config.env" >&2; exit 2 ;; esac
for t in ssh curl python3 tofu; do
  command -v "$t" >/dev/null 2>&1 || { echo "!! missing required tool: $t" >&2; exit 2; }
done

TF=$HERE/terraform
SEC=${NIOSX_SECRETS:-$TF/secrets.auto.tfvars}
CSP=${CSP_URL:-https://csp.infoblox.com}
# One file, read by this script AND by Terraform: the override sets both.
JSON=${NIOSX_HOSTS_JSON:-$TF/niosx_hosts.json}
[ -z "${NIOSX_HOSTS_JSON:-}" ] || export TF_VAR_hosts_file="$NIOSX_HOSTS_JSON"
JOURNAL_DIR=${NIOSX_STATE_DIR:-$HOME/.config/niosx/teardown}
JOURNAL=$JOURNAL_DIR/$VMID.json

# A journal file only exists between the first destructive step and the last
# one, so finding one here means a previous teardown of this VMID was
# interrupted. Say what it recorded — every step below is safe to re-run.
if [ -f "$JOURNAL" ]; then
  echo "!! a previous teardown of VMID $VMID did not finish" >&2
  python3 - "$JOURNAL" >&2 <<'PY'
import json, os, sys, time
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    d = {}
print("   started : %s" % time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(path))))
for k in ("label", "pve", "mac", "csp_id", "pool"):
    if d.get(k):
        print("   %-8s: %s" % (k, d[k]))
print("   journal : %s" % path)
PY
  echo "   Continuing now finishes whatever is left; each step re-runs safely." >&2
  echo >&2
fi

KEY=$(sed -nE 's/^[[:space:]]*infoblox_api_key[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' \
        "$SEC" 2>/dev/null | tail -1 | tr -d '\r' || true)
case "$KEY" in
  "") echo "!! no CSP API key in $SEC" >&2; exit 2 ;;
  REPLACE_WITH_CSP_API_KEY) echo "!! $SEC still has the placeholder" >&2; exit 2 ;;
  *.ibjt) echo "!! that is a JOIN TOKEN, not a CSP API key" >&2; exit 2 ;;
esac
rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Token $KEY" \
      "$CSP/api/infra/v1/applications" || echo 000)
[ "$rc" = "200" ] || { echo "!! CSP rejected the API key (HTTP $rc)" >&2; exit 2; }

# ---------------- phase 1: discover (read-only) ----------------
NAME_NOTE=""
VM_GONE=0
ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" true >/dev/null 2>&1 \
  || { echo "!! cannot ssh to $PVE — refusing to guess whether VM $VMID exists" >&2; exit 2; }
if VMCONF=$(ssh "$PVE" "$PVE_SUDO qm config $VMID" 2>&1); then
  VM_NAME=$(printf '%s\n' "$VMCONF" | sed -n 's/^name: //p')
  MAC=$(printf '%s\n' "$VMCONF" | sed -nE 's/^net0:.*virtio=([0-9A-Fa-f:]{17}).*/\1/p' | tr 'A-Z' 'a-z')
  VM_LOCK=$(printf '%s\n' "$VMCONF" | sed -n 's/^lock: //p')
  VM_ISO=$(printf '%s\n' "$VMCONF" | sed -n 's/^ide2: //p')
  VM_STATUS=$(ssh "$PVE" "$PVE_SUDO qm status $VMID" 2>/dev/null | awk '{print $2}') || VM_STATUS=unknown
  [ -n "$MAC" ] || { echo "!! could not read a net0 MAC for VM $VMID — refusing" >&2; exit 2; }
elif printf '%s' "$VMCONF" | grep -q 'does not exist'; then
  VM_GONE=1; VM_NAME=""; MAC=""; VM_LOCK=""; VM_ISO=""; VM_STATUS="does not exist"
else
  echo "!! qm config $VMID failed on $PVE:" >&2; printf '   %s\n' "$VMCONF" >&2; exit 2
fi
[ -z "$VM_LOCK" ] || { echo "!! VM $VMID is locked ($VM_LOCK) — retry later" >&2; exit 2; }

if [ "$VM_GONE" = "0" ] && [ -n "$LABEL_OPT" ] && [ "$LABEL_OPT" != "$VM_NAME" ]; then
  echo "!! --label '$LABEL_OPT' does not match VM $VMID's name '$VM_NAME'." >&2
  echo "   --label is only for a VM that is already gone." >&2; exit 2
fi
LABEL=${LABEL_OPT:-${VM_NAME:-$OWNER-$VMID}}
niosx_check_label "$LABEL" "host name"

csp_lookup() {  # $1 = filter expression; prints ERR on any failure
  out=$(curl -s --max-time 40 -w '\n%{http_code}' -G -H "Authorization: Token $KEY" \
        --data-urlencode "_filter=$1" "$CSP/api/infra/v1/detail_hosts" 2>/dev/null) || { printf 'ERR'; return 0; }
  printf '%s' "$out" | python3 -c '
import sys,json
raw=sys.stdin.read().rsplit("\n",1)
if len(raw)!=2 or raw[1].strip()!="200": print("ERR"); raise SystemExit
try: d=json.loads(raw[0])
except Exception: print("ERR"); raise SystemExit
if not isinstance(d,dict): print("ERR"); raise SystemExit
# no match at all comes back as a bare {}: zero hosts, not a failed query
r=d.get("results") or []
if not isinstance(r,list): print("ERR"); raise SystemExit
h=r[0] if r else {}
US="\x1f"
print(US.join([str(len(r)), h.get("id") or "", h.get("display_name") or "",
               ((h.get("pool") or {}).get("pool_id") or ""), h.get("ip_address") or ""]))
' 2>/dev/null || printf 'ERR'
}

if [ -n "$MAC" ]; then MATCH=$(csp_lookup "mac_address==\"$MAC\"")
else                   MATCH=$(csp_lookup "display_name==\"$LABEL\""); fi
case "$MATCH" in
  ERR|"") echo "!! CSP lookup failed — refusing to assume this host is unregistered." >&2; exit 2 ;;
esac
IFS=$(printf '\037') read -r N_MATCH CSP_ID CSP_NAME CSP_POOL CSP_IP <<EOF2
$MATCH
EOF2
case "${N_MATCH:-}" in ''|*[!0-9]*) echo "!! unreadable CSP response — refusing." >&2; exit 2 ;; esac
[ "$N_MATCH" -le 1 ] || { echo "!! $N_MATCH CSP hosts matched — ambiguous, refusing. Clean up in the Portal." >&2; exit 2; }
if [ "$N_MATCH" = "1" ]; then
  [ -n "$CSP_ID" ] && [ -n "$CSP_NAME" ] && [ -n "$CSP_POOL" ] \
    || { echo "!! incomplete CSP record (id/name/pool missing) — refusing." >&2; exit 2; }
fi

# ---------------- phase 2: refuse on any mismatch ----------------
if [ "$N_MATCH" = "1" ]; then
  # Matched by MAC => identity is proven; a differing display name is cosmetic
  # (renamed in the Portal, or deployed before the naming convention). Show both
  # names in the confirmation and require the Portal name to be typed.
  if [ "$VM_GONE" = "0" ] && [ -n "$VM_NAME" ] && [ "$VM_NAME" != "$CSP_NAME" ]; then
    NAME_NOTE="   NOTE: Proxmox calls it '$VM_NAME', the Portal calls it '$CSP_NAME' (matched by MAC)."
  fi
  # add-services.sh keys niosx_hosts.json and the Terraform resources by the
  # CSP display name, so that is the authoritative label once we have a match.
  if [ -z "$LABEL_OPT" ] && [ -n "$CSP_NAME" ]; then LABEL=$CSP_NAME; niosx_check_label "$LABEL" "Portal host name"; fi
  if [ "$VM_GONE" = "1" ]; then
    [ "$CSP_NAME" = "$LABEL" ] || { echo "!! name-only match '$CSP_NAME' != '$LABEL'. Nothing done." >&2; exit 2; }
    case "$CSP_NAME" in
      "$OWNER"-*) : ;;
      *) echo "!! '$CSP_NAME' does not start with '$OWNER-' — refusing to delete a host that may not be yours." >&2; exit 2 ;;
    esac
  fi
fi

JSON_POOL=$(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print((d.get(sys.argv[2]) or {}).get("pool_id",""))' "$JSON" "$LABEL" 2>/dev/null || true)
if [ -n "$JSON_POOL" ] && [ -n "$CSP_POOL" ] && [ "$JSON_POOL" != "infra/pool/$CSP_POOL" ]; then
  echo "!! local record ($JSON_POOL) disagrees with Portal (infra/pool/$CSP_POOL). Nothing done." >&2; exit 2
fi

if ! STATE_ALL=$(cd "$TF" && tofu state list 2>&1); then
  echo "!! could not read Terraform state — refusing:" >&2; printf '   %s\n' "$STATE_ALL" >&2; exit 2
fi
STATE_RES=$(printf '%s\n' "$STATE_ALL" | grep -E "^bloxone_infra_service\.svc\[\"$LABEL-[A-Za-z0-9_]+\"\]$" || true)

# nothing to do at all?
if [ "$VM_GONE" = "1" ] && [ "$N_MATCH" = "0" ] && [ -z "$STATE_RES" ] && [ -z "$JSON_POOL" ]; then
  echo "Nothing to tear down for VMID $VMID / '$LABEL' — no VM, no Portal host, no services."
  echo "If a seed ISO might remain: ssh $PVE $PVE_SUDO rm -f /var/lib/vz/template/iso/seed-niosx-$VMID.iso"
  exit 0
fi

# on the name-only path require local evidence this host is ours
if [ "$VM_GONE" = "1" ] && [ -z "$LABEL_OPT" ] && [ -z "$JSON_POOL" ] && [ -z "$STATE_RES" ]; then
  echo "!! VM $VMID is gone and nothing local ties '$LABEL' to you." >&2
  echo "   Refusing to delete a Portal host on a name guess. Pass --label if you are sure." >&2
  exit 2
fi

# ---------------- confirmation ----------------
echo
echo "About to PERMANENTLY destroy — this cannot be undone."
echo
printf '  Proxmox   VM %s  "%s"  %s\n' "$VMID" "${VM_NAME:-<gone>}" "$VM_STATUS"
[ -n "$MAC" ] && printf '            MAC %s   seed %s\n' "$MAC" "${VM_ISO:-none}"
if [ "$N_MATCH" = "1" ]; then
  printf '  Portal    host "%s"  ip %s\n' "$CSP_NAME" "${CSP_IP:-?}"
  printf '            id %s\n' "$CSP_ID"
  [ -z "${NAME_NOTE:-}" ] || printf '%s\n' "$NAME_NOTE"
else
  printf '  Portal    not registered (nothing to delete)\n'
fi
if [ -n "$STATE_RES" ]; then
  echo "  Services  managed by you -> stopped and removed:"
  printf '%s\n' "$STATE_RES" | sed 's/^/              /' 
else
  echo "  Services  none of yours in Terraform state"
fi
echo "  Secrets   seed ISO for $VMID on the Proxmox host -> deleted"
echo
echo "  VMID $VMID is retired; the next deploy will NOT reuse it."
case "$STATE_RES" in *dhcp*) echo "  WARNING: this host serves DHCP — clients will lose leases." ;; esac
echo
if [ "$DRY" = "1" ]; then echo "(--dry-run: nothing changed)"; exit 0; fi
if [ -n "$CONFIRM_OPT" ]; then
  typed=$CONFIRM_OPT                       # non-interactive, but still double-keyed:
                                           # the exact host name must be given
else
  [ -r /dev/tty ] || { echo "!! confirmation needs a terminal, or pass --confirm '<host name>'" >&2; exit 2; }
  printf 'Type the host name exactly to continue: '
  read -r typed < /dev/tty || typed=""
fi
[ "$typed" = "${CSP_NAME:-$LABEL}" ] || { echo "Aborted — nothing changed." >&2; exit 2; }

# ---------------- phase 3: execute (journalled, each step re-runnable) ----------------
mkdir -p "$JOURNAL_DIR"; chmod 700 "$JOURNAL_DIR" 2>/dev/null || true
python3 -c '
import json,sys
json.dump(dict(zip(["vmid","pve","label","mac","csp_id","pool"],sys.argv[2:])), open(sys.argv[1],"w"), indent=2)
' "$JOURNAL" "$VMID" "$PVE" "$LABEL" "$MAC" "$CSP_ID" "$CSP_POOL"

# A. services — scoped apply; refuse if the plan touches anything else
if [ -n "$STATE_RES" ] || [ -n "$JSON_POOL" ]; then
  echo ">> removing services for $LABEL"
  # exact set of resource addresses this teardown is allowed to delete
  EXPECT=$(python3 -c '
import json,sys
label=sys.argv[2]
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
svcs=(d.get(label) or {}).get("services") or []
print("\n".join("bloxone_infra_service.svc[\"%s-%s\"]" % (label,s) for s in svcs))' "$JSON" "$LABEL")
  # anything already in state for this label must also be covered
  EXPECT=$(printf '%s\n%s\n' "$EXPECT" "$STATE_RES" | sed '/^$/d' | sort -u)
  [ -f "$JSON" ] || printf '{}\n' > "$JSON"
  [ -f "$JSON.bak" ] || cp "$JSON" "$JSON.bak"
  trap 'if [ -f "$JSON.bak" ]; then mv "$JSON.bak" "$JSON"; echo "!! aborted — $JSON restored" >&2; fi; rm -f "$TF/td.plan"' EXIT HUP INT TERM
  python3 -c '
import json,sys
p,label=sys.argv[1],sys.argv[2]
d=json.load(open(p)); d.pop(label,None)
json.dump(d,open(p,"w"),indent=2); open(p,"a").write("\n")' "$JSON" "$LABEL"
  cd "$TF"
  if ! tofu plan -input=false -out=td.plan >/dev/null 2>&1; then
    mv "$JSON.bak" "$JSON"; echo "!! tofu plan failed — JSON restored, nothing changed" >&2; exit 3
  fi
  if ! BAD=$(tofu show -json td.plan | python3 -c '
import sys,json
label=sys.argv[1]
expect=set(a for a in sys.argv[2].split("\n") if a)
d=json.load(sys.stdin)
bad=[]
seen=set()
for c in d.get("resource_changes",[]):
    acts=(c.get("change") or {}).get("actions") or []
    if acts==["no-op"]: continue
    addr=c.get("address","")
    before=(c.get("change") or {}).get("before") or {}
    ok = (acts==["delete"] and c.get("type")=="bloxone_infra_service"
          and addr in expect
          and (before.get("tags") or {}).get("host")==label)
    if ok: seen.add(addr)
    else:  bad.append(addr+" "+",".join(acts))
for missing in sorted(expect-seen):
    bad.append(missing+" EXPECTED-BUT-NOT-PLANNED")
print("\n".join(bad))' "$LABEL" "$EXPECT"); then
    echo "!! could not inspect the plan — refusing" >&2; exit 3
  fi
  if [ -n "$BAD" ]; then
    mv "$JSON.bak" "$JSON"; rm -f td.plan
    echo "!! plan would touch more than $LABEL's services — refusing:" >&2
    printf '%s\n' "$BAD" | sed 's/^/   /' >&2
    echo "   Run 'tofu plan' yourself; your state has drifted." >&2; exit 3
  fi
  trap - EXIT HUP INT TERM
  if ! tofu apply -input=false td.plan; then
    rm -f td.plan
    echo "!! tofu apply failed part-way. $JSON already has $LABEL removed —" >&2
    echo "   re-run this teardown to finish, or run 'tofu plan' in $TF" >&2
    exit 3
  fi
  rm -f td.plan "$JSON.bak"
  cd "$HERE"
fi

# B. stop the VM BEFORE deleting the CSP record, so it cannot re-enrol
if [ "$VM_GONE" = "0" ] && [ "$VM_STATUS" != "stopped" ]; then
  echo ">> stopping VM $VMID"
  ssh "$PVE" "$PVE_SUDO qm stop $VMID --timeout 60" >/dev/null 2>&1 || true
  ssh "$PVE" "$PVE_SUDO bash -c 'for i in \$(seq 1 30); do qm status $VMID | grep -q stopped && exit 0; sleep 2; done; exit 1'" \
    || { echo "!! VM did not stop; nothing deleted in the Portal" >&2; exit 3; }
fi

# C. delete the CSP host
if [ -n "$CSP_ID" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE --max-time 40 \
          -H "Authorization: Token $KEY" "$CSP/api/infra/v1/hosts/$CSP_ID" || echo 000)
  case "$code" in
    204|200|404) echo ">> CSP host removed (HTTP $code)" ;;
    *) echo "!! failed to delete CSP host (HTTP $code); VM is stopped but intact" >&2; exit 3 ;;
  esac
fi

# D. destroy the VM
if [ "$VM_GONE" = "0" ]; then
  echo ">> destroying VM $VMID"
  ssh "$PVE" "$PVE_SUDO qm destroy $VMID --purge --destroy-unreferenced-disks 1" >/dev/null 2>&1 \
    || { echo "!! qm destroy failed — run it by hand on $PVE" >&2; exit 3; }
fi

# E. secrets: the seed carries the join token
if ! ssh "$PVE" "$PVE_SUDO bash -c 'set -e; rm -f /var/lib/vz/template/iso/seed-niosx-$VMID.iso; rm -rf /tmp/niosx-seed-$VMID; test ! -e /var/lib/vz/template/iso/seed-niosx-$VMID.iso'"; then
  echo "!! could not remove the seed for $VMID — IT CONTAINS YOUR JOIN TOKEN." >&2
  echo "   Run: ssh $PVE $PVE_SUDO bash -c 'rm -f /var/lib/vz/template/iso/seed-niosx-$VMID.iso; rm -rf /tmp/niosx-seed-$VMID'" >&2
  exit 3
fi

# raise the never-reuse counter so a pinned VMID is retired too (monotonic)
ssh "$PVE" "$PVE_SUDO bash -c 'mkdir -p /etc/niosx; exec 9>/etc/niosx/.vmid.lock; flock 9; l=\$(cat /etc/niosx/last_vmid 2>/dev/null || echo 200); [ \"\$l\" -ge $VMID ] || echo $VMID > /etc/niosx/last_vmid'" >/dev/null 2>&1 || true

rm -f "$JOURNAL"
echo
echo ">> DONE. $LABEL is gone from Proxmox and the Portal. VMID $VMID will not be reused."
