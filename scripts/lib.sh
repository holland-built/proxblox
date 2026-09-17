# shellcheck shell=bash
# Shared validators for the niosx scripts. Sourced, never run directly.
#
# These exist because every one of these strings ends up somewhere dangerous:
# NAME goes into a root shell on the Proxmox host and into a CSP host record,
# OWNER prefixes every object in a tenant shared by hundreds of people, and
# VMID is used unquoted in remote qm commands.

# Every remote command needs root on Proxmox. PVE="root@host" runs them
# directly; any other login runs them through passwordless sudo.
# shellcheck disable=SC2034  # used by the scripts that source this file
case "${PVE:-}" in
  root@*) PVE_SUDO="" ;;
  *)      PVE_SUDO="sudo -n" ;;
esac

niosx_die() {
  echo "!! $1" >&2
  shift
  for line in "$@"; do echo "   $line" >&2; done
  exit "${NIOSX_DIE_CODE:-1}"
}

# Letters, digits and hyphens only, 1-63 chars, no leading/trailing hyphen.
# That is the intersection of what Proxmox accepts as a VM name, what DNS
# accepts as a label, and what is safe to paste into a shell command.
niosx_check_name() {
  n=${1:-}; what=${2:-name}
  [ -n "$n" ] || niosx_die "$what is empty"
  [ ${#n} -le 63 ] || niosx_die "$what is too long (${#n} chars, max 63): $n"
  case "$n" in
    *[!A-Za-z0-9-]*)
      niosx_die "$what \"$n\" contains characters that are not allowed" \
                "Use letters, digits and hyphens only." \
                "This becomes a Proxmox VM name, a Portal host name and part of" \
                "every service name, and it is passed to a root shell on Proxmox." ;;
    -*|*-)
      niosx_die "$what \"$n\" must start and end with a letter or digit" ;;
  esac
}

# Proxmox reserves 1-99; the upper bound is Proxmox's own limit.
niosx_check_vmid() {
  v=${1:-}
  case "$v" in
    ''|*[!0-9]*) niosx_die "VMID must be a number (you gave: \"$v\")" \
                           "Leave it blank to get the next free id." ;;
  esac
  [ "$v" -ge 100 ] || niosx_die "VMID must be 100 or higher (Proxmox reserves 1-99)"
  [ "$v" -le 999999999 ] || niosx_die "VMID must be 999999999 or lower"
}

# OWNER prefixes every object in a SHARED tenant, so a generic value collides
# with another engineer's objects. Enforced, not just documented.
niosx_check_owner() {
  o=${1:-}
  case "$o" in
    ""|CHANGEME) niosx_die "set a real OWNER in config.env" \
                           "Use your corporate login or initials — it must be unique" \
                           "in the tenant, which everyone shares." ;;
  esac
  niosx_check_name "$o" "OWNER"
  [ ${#o} -ge 2 ] || niosx_die "OWNER \"$o\" is too short (2-20 chars)"
  [ ${#o} -le 20 ] || niosx_die "OWNER \"$o\" is too long (2-20 chars)"
  lower=$(printf '%s' "$o" | tr 'A-Z' 'a-z')
  case "$lower" in
    lab|labs|test|tests|demo|poc|temp|tmp|admin|user|users|home|niosx|infoblox|se|sales|eng|dev|prod|changeme|myname|name)
      niosx_die "OWNER \"$o\" is too generic for a shared tenant" \
                "Hundreds of engineers share this one Infoblox tenant. \"$o\" will" \
                "collide with someone else's hosts and services." \
                "Use your corporate login or initials in config.env." ;;
  esac
}

# Looser than niosx_check_name: an unrenamed host really is called
# ZTP_<token>_<digits>, so underscores and dots have to be allowed. Still
# blocks the characters that would break a shell command, a regex or a filter.
niosx_check_label() {
  n=${1:-}; what=${2:-host name}
  [ -n "$n" ] || niosx_die "$what is empty"
  [ ${#n} -le 128 ] || niosx_die "$what is too long (${#n} chars, max 128): $n"
  case "$n" in
    *[!A-Za-z0-9._-]*)
      niosx_die "$what \"$n\" contains characters that are not allowed" \
                "Letters, digits, dot, hyphen and underscore only." ;;
  esac
}

# Windows editors (Notepad, and any editor set to CRLF) leave a carriage return
# at the end of every line. Sourced into bash it becomes part of the value, and
# the failure that follows looks like anything but a line-ending problem:
# ssh to "root@host\r", a qcow2 path that "does not exist", a POOL Proxmox has
# never heard of. Name it instead of letting it surface three steps later.
niosx_check_no_cr() {
  cr=$(printf '\r')
  for var in "$@"; do
    eval "val=\${$var:-}"
    # shellcheck disable=SC2154  # assigned by the eval above
    case "$val" in
      *"$cr"*)
        niosx_die "$var in config.env ends with a carriage return (CRLF line endings)" \
                  "The file was saved by a Windows editor. Fix it with:" \
                  "  sed -i 's/\\r\$//' config.env" \
                  "In WSL, edit it with nano or vi rather than Notepad." ;;
    esac
  done
}
