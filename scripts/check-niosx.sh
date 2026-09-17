#!/usr/bin/env bash
# What happened to the nodes you started and did not wait for.
#
#   ./niosx check            status of every node still being built
#   ./niosx check 207        just that one
#   ./niosx check --finish   start the services on any that have registered
#
# `deploy --no-wait` drops a small record in ~/.config/niosx/pending/<vmid>.json.
# This reads those, asks Proxmox and the Portal what is true now, and clears the
# record once the node is finished. Read-only unless you pass --finish.
set -euo pipefail

usage() {
  cat <<'HELPEOF'
Check on nodes started with `deploy --no-wait`.

  ./niosx check [VMID] [--finish]

  VMID       only this node (default: all pending)
  --finish   for any node that has registered, start the services it is
             waiting for (this is the part deploy --no-wait skipped)

Nodes disappear from this list once their services are running.
HELPEOF
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${NIOSX_CONFIG:-$HERE/config.env}
[ -f "$CONFIG" ] || { echo "!! missing $CONFIG" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONFIG"
# shellcheck source=/dev/null
. "$HERE/scripts/lib.sh"
niosx_check_no_cr PVE OWNER
: "${PVE:?set PVE in config.env}"

FINISH=0; ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --finish)  FINISH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "!! unknown option: $1" >&2; exit 2 ;;
    *)         ONE=$1; niosx_check_vmid "$ONE"; shift ;;
  esac
done

TF=$HERE/terraform
SEC=${NIOSX_SECRETS:-$TF/secrets.auto.tfvars}
CSP=${CSP_URL:-https://csp.infoblox.com}
PENDING_DIR=${NIOSX_PENDING_DIR:-$HOME/.config/niosx/pending}
KEY=$(sed -nE 's/^[[:space:]]*infoblox_api_key[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' \
        "$SEC" 2>/dev/null | tail -1 | tr -d '\r' || true)

# every service Terraform already manages, fetched once
STATE=$( (cd "$TF" && tofu state list) 2>/dev/null || true)

found=0
for rec in "$PENDING_DIR"/*.json; do
  [ -e "$rec" ] || continue
  IFS='|' read -r VMID NAME WANT <<EOF2
$(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print("%s|%s|%s" % (d.get("vmid",""), d.get("name",""), d.get("services","")))' "$rec")
EOF2
  [ -n "$VMID" ] || continue
  [ -z "$ONE" ] || [ "$ONE" = "$VMID" ] || continue
  found=1

  # 1. is the VM still there, and what is its MAC?
  if VMCONF=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$PVE_SUDO qm config $VMID" 2>/dev/null); then
    MAC=$(printf '%s\n' "$VMCONF" | sed -nE 's/^net0:.*virtio=([0-9A-Fa-f:]{17}).*/\1/p' | tr 'A-Z' 'a-z')
    VMSTATE=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$PVE_SUDO qm status $VMID" 2>/dev/null | awk '{print $2}')
  else
    MAC=""; VMSTATE="gone"
  fi

  # 2. has it registered in the tenant yet? (by MAC — the name is generated)
  PORTAL="unknown"
  if [ -n "$MAC" ] && [ -n "$KEY" ]; then
    PORTAL=$(curl -s --max-time 25 -G -H "Authorization: Token $KEY" \
               --data-urlencode "_filter=mac_address==\"$MAC\"" \
               "$CSP/api/infra/v1/detail_hosts" 2>/dev/null \
             | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("unknown"); raise SystemExit
r=d.get("results") or []            # no match at all comes back as {}
if not r: print("not yet"); raise SystemExit
h=r[0]
print("%s %s" % (h.get("display_name") or "?", h.get("ip_address") or "?"))' 2>/dev/null || printf 'unknown')
  fi

  # 3. are the services it wanted already running?
  missing=""
  for s in $(printf '%s' "$WANT" | tr ',' ' '); do
    case "$STATE" in
      *"bloxone_infra_service.svc[\"$NAME-$s\"]"*) ;;
      *) missing="${missing:+$missing,}$s" ;;
    esac
  done

  printf '  %-5s %-16s vm:%-8s portal:%-42s services:%s\n' \
    "$VMID" "$NAME" "$VMSTATE" "$PORTAL" "${WANT:-none}"

  if [ "$VMSTATE" = "gone" ]; then
    echo "        VM is gone. Remove the record: rm $rec"
    continue
  fi
  case "$PORTAL" in
    "not yet") echo "        still registering (usually ~2 min from boot)"; continue ;;
    unknown)   echo "        could not ask the Portal (no API key, or it did not answer)"; continue ;;
  esac
  if [ -z "$WANT" ] || [ -z "$missing" ]; then
    echo "        done — clearing $rec"
    rm -f "$rec"
    continue
  fi
  if [ "$FINISH" = 1 ]; then
    echo "        starting: $missing"
    if "$HERE/scripts/add-services.sh" "$VMID" "$NAME" "$missing"; then
      rm -f "$rec"
      echo "        done — record cleared"
    else
      echo "!! could not start $missing on $NAME — record kept" >&2
    fi
  else
    echo "        ready. Finish with: ./niosx check $VMID --finish"
  fi
done

if [ "$found" = 0 ]; then
  if [ -n "$ONE" ]; then echo "  nothing pending for VMID $ONE"
  else echo "  nothing pending — every node you started has finished"; fi
fi
