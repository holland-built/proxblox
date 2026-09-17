#!/usr/bin/env bash
# Wait for a NIOS-X VM to register in CSP, rename it, then start services on it.
#
#   ./add-services.sh <vmid> <label> <dns,dhcp>
#
# The host is matched by MAC address using a server-side filter — ZTP assigns an
# auto-generated "ZTP_<join-token-name>_<digits>" display name, so name matching
# is useless, and a shared tenant can hold far more hosts than one page.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${NIOSX_CONFIG:-$HERE/config.env}
[ -f "$CONFIG" ] || { echo "!! missing $CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"
# shellcheck source=/dev/null
. "$HERE/scripts/lib.sh"
niosx_check_no_cr PVE

VMID=${1:?usage: add-services.sh <vmid> <label> <services>}
LABEL=${2:?usage: add-services.sh <vmid> <label> <services>}
SERVICES=${3:?usage: add-services.sh <vmid> <label> <services>}
niosx_check_vmid "$VMID"
niosx_check_name "$LABEL" "host name"
SERVICES=$(printf '%s' "$SERVICES" | tr -d '[:space:]')
case "$SERVICES" in
  ""|none) echo "!! no services requested — nothing to do" >&2; exit 1 ;;
esac

TF=$HERE/terraform
SEC=${NIOSX_SECRETS:-$TF/secrets.auto.tfvars}
# One file, read by this script AND by Terraform: the override sets both.
JSON=${NIOSX_HOSTS_JSON:-$TF/niosx_hosts.json}
[ -z "${NIOSX_HOSTS_JSON:-}" ] || export TF_VAR_hosts_file="$NIOSX_HOSTS_JSON"
CSP=${CSP_URL:-https://csp.infoblox.com}
command -v tofu >/dev/null 2>&1 || { echo "!! missing required tool: tofu" >&2; exit 1; }

KEY=$(sed -nE 's/^[[:space:]]*infoblox_api_key[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' \
        "$SEC" 2>/dev/null | tail -1 | tr -d '\r' || true)
case "$KEY" in
  "") echo "!! no CSP API key in $SEC" >&2; exit 1 ;;
  REPLACE_WITH_CSP_API_KEY) echo "!! $SEC still has the placeholder" >&2; exit 1 ;;
  *.ibjt) echo "!! that is a JOIN TOKEN, not a CSP API key (Portal > your name > API Keys)" >&2; exit 1 ;;
esac

# validate requested services against what the tenant actually offers
APPS=$(curl -s --max-time 20 -H "Authorization: Token $KEY" "$CSP/api/infra/v1/applications" \
       | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin).get("results",{}).get("applications",[])))' 2>/dev/null || true)
if [ -n "$APPS" ]; then
  for want in $(printf '%s' "$SERVICES" | tr ',' ' '); do
    case ",$APPS," in
      *",$want,"*) ;;
      *) echo "!! '$want' is not offered by this tenant. valid: $APPS" >&2; exit 1 ;;
    esac
  done
else
  echo "!! could not verify service names with CSP (continuing)" >&2
fi

# MAC of the VM (explicit failure, not masked by pipefail)
if ! VMCONF=$(ssh "$PVE" "$PVE_SUDO qm config $VMID" 2>&1); then
  echo "!! could not read config for VM $VMID on $PVE:" >&2
  printf '%s\n' "$VMCONF" >&2; exit 1
fi
MAC=$(printf '%s\n' "$VMCONF" | sed -nE 's/^net0:.*virtio=([0-9A-Fa-f:]{17}).*/\1/p' | tr 'A-Z' 'a-z')
[ -n "$MAC" ] || { echo "!! no net0 MAC found for VM $VMID" >&2; exit 1; }

# one server-side filtered lookup — returns id + pool for this host only
lookup() {
  curl -s --max-time 40 -G -H "Authorization: Token $KEY" \
       --data-urlencode "_filter=mac_address==\"$MAC\"" \
       "$CSP/api/infra/v1/detail_hosts" \
  | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("\t"); raise SystemExit
r=(d.get("results") or [])
h=r[0] if r else {}
print("%s\x1f%s" % (h.get("id") or "", ((h.get("pool") or {}).get("pool_id") or "")))
' 2>/dev/null || printf '\037'
}

echo ">> waiting for VM $VMID (mac $MAC) to register in CSP (up to 30 min)..."
HOSTID=""; POOL=""
for i in $(seq 1 60); do
  IFS=$(printf '\037') read -r HOSTID POOL <<EOF2
$(lookup)
EOF2
  [ -n "${POOL:-}" ] && break
  echo "   [$i/60] not registered yet..."
  sleep 30
done
[ -n "${POOL:-}" ] || { echo "!! timed out waiting for VM $VMID to register in CSP" >&2; exit 1; }
echo ">> registered. pool_id = infra/pool/$POOL"

# Rename away from the generated ZTP name. PATCH returns 501; PUT needs pool_id.
if [ -n "${HOSTID:-}" ]; then
  BODY=$(python3 -c 'import json,sys; print(json.dumps({"display_name": sys.argv[1], "pool_id": sys.argv[2]}))' \
           "$LABEL" "infra/pool/$POOL")
  rc=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --max-time 40 \
        -H "Authorization: Token $KEY" -H 'Content-Type: application/json' \
        -d "$BODY" \
        "$CSP/api/infra/v1/hosts/$HOSTID" || echo 000)
  if [ "$rc" = "200" ]; then echo ">> renamed host in CSP to $LABEL"
  else echo "!! rename failed (HTTP $rc) — continuing; host keeps its ZTP name" >&2; fi
fi

python3 - "$JSON" "$LABEL" "infra/pool/$POOL" "$SERVICES" <<'PY'
import json,sys
path,label,pool,svcs = sys.argv[1:5]
try:
    d = json.load(open(path))
except Exception:
    d = {}
# ADD, not replace. Overwriting the list would make `add <host> dhcp` destroy
# the dns service that host is already running on the next apply.
have = (d.get(label) or {}).get("services") or []
want = [s for s in svcs.split(",") if s]
merged = have + [s for s in want if s not in have]
d[label] = {"pool_id": pool, "services": merged}
with open(path,"w") as f:
    json.dump(d,f,indent=2); f.write("\n")
added = [s for s in want if s not in have]
print(f">> {path}: {label} now runs {','.join(merged)}"
      + (f" (added {','.join(added)})" if added else " (nothing new)"))
PY

echo ">> starting services on $LABEL: $SERVICES"
cd "$TF"
tofu apply -auto-approve
