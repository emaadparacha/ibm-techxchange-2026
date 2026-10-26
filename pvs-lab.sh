#!/usr/bin/env bash
# =============================================================================
#  pvs-lab.sh  |  LAB-1952: Automating & Managing Power Workloads on IBM Power Virtual Server
#                 IBM TechXchange 2026, Atlanta. Driven only by the IBM Cloud CLI.
# =============================================================================
#
#  Built for IBM TechXchange students working in IBM Cloud Shell.
#  Cloud Shell is already logged in as you, so there is no API key to create.
#
#  What it builds, in the order the lab builds it:
#
#                       +-- public subnet --+
#     Cloud Shell --ssh-+                   +-- AIX 7.3 LPAR  (PowerVS workspace, dal10)
#          |            +-- private subnet -+
#          | ssh (floating IP)       |
#          v                   Transit Gateway
#     Ubuntu VSI  --- VPC subnet --- VPC (us-south)
#
#    1. A PowerVS workspace, PowerVS SSH key, private and public subnets,
#       an AIX image copy, and the AIX server (started, not waited for)
#    2. While AIX builds: a VPC with a subnet, an SSH key, an SSH rule,
#       an Ubuntu VSI with a floating IP
#    3. A Transit Gateway connecting the VPC and the workspace
#    4. Once AIX is up: a route on AIX so it answers the VPC
#
#  Usage:   ./pvs-lab.sh <step>
#
#    preflight   Check tools, plugins, login, region, resource group, prefix
#    keys        Create the SSH key pair used for every server
#    powervs     Workspace, PowerVS key, subnets, image, and START the AIX build
#    vpc         VPC, subnet, VPC key, SSH rule, Ubuntu VSI, floating IP
#    gateway     Transit Gateway and its two connections
#    server      Wait for AIX, read its addresses, add the route to the VPC
#    verify      Check both paths: Cloud Shell to AIX, and VSI to AIX
#    ssh         Log in to AIX directly
#    ssh-vpc     Log in to AIX through the VPC server and the gateway
#    catalog     List stock AIX images you can pick from
#    status      Print saved state and live status
#    all         preflight, keys, powervs, vpc, gateway, server, verify
#    destroy     Delete everything this script created (after class)
#
#  Every step is safe to rerun. Resources are found by name before anything
#  is created, so a dropped Cloud Shell session costs you nothing: open a new
#  session and run the same step again.
#
#  Start with your attendee number (1 to 30); every name is built from it:
#      SEAT=7 ./pvs-lab.sh preflight        # resources become pvs-07-vpc, pvs-07-ws, ...
#
#  Settings: override any default below with an environment variable, e.g.
#      VPC_NAME=lab-vpc PVS_ZONE=dal10 ./pvs-lab.sh preflight
#  or put KEY=value lines in ~/pvs-lab/lab.conf.
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"

# ----------------------------------------------------------------------------
# Paths. Everything the script writes lives under one folder in $HOME.
# Cloud Shell keeps $HOME while you are active; it is erased after two hours
# with no session open, so keep the browser tab alive during the lab.
# ----------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/pvs-lab}"
STATE_FILE="$LAB_DIR/state.env"
LOG_FILE="$LAB_DIR/run.log"
KNOWN_HOSTS="$LAB_DIR/known_hosts"
SSH_CONFIG="$LAB_DIR/ssh_config"
mkdir -p "$LAB_DIR"
chmod 700 "$LAB_DIR"

# Optional per-student or per-instructor overrides.
# shellcheck disable=SC1091
[[ -f "$LAB_DIR/lab.conf" ]] && source "$LAB_DIR/lab.conf"

# ----------------------------------------------------------------------------
# Settings (all overridable)
# ----------------------------------------------------------------------------
REGION="${REGION:-us-south}"                 # IBM Cloud region of the VPC
PVS_ZONE="${PVS_ZONE:-dal10}"                # PowerVS datacenter; must be PER-enabled
TG_LOCATION="${TG_LOCATION:-$REGION}"        # Transit Gateway location
RESOURCE_GROUP="${RESOURCE_GROUP:-${RG_NAME:-}}"  # empty = auto-pick (the only group, or one named Default)
VPC_NAME="${VPC_NAME:-}"                     # empty = create <prefix>-vpc; set it to reuse an existing VPC
VPC_ZONE="${VPC_ZONE:-${REGION}-1}"          # zone for the new VPC subnet
SEAT="${SEAT:-}"                             # attendee number, 1 to MAX_SEAT; asked for if empty
MAX_SEAT="${MAX_SEAT:-30}"
LAB_PREFIX="${LAB_PREFIX:-${P:-}}"           # empty = pvs-<two-digit SEAT>; $P from the web page also works
PRIVATE_CIDR="${PRIVATE_CIDR:-192.168.50.0/24}"  # PowerVS private subnet; must not overlap the VPC
DNS_SERVER="${DNS_SERVER:-9.9.9.9}"
PUBLIC_ACCESS="${PUBLIC_ACCESS:-true}"       # add a public subnet so Cloud Shell can SSH in
EXISTING_TG="${EXISTING_TG:-}"               # reuse a Transit Gateway (ID) instead of creating one

SYS_TYPE="${SYS_TYPE:-s1022}"                # Power10 scale-out; s922 also works in dal10
PROC_TYPE="${PROC_TYPE:-shared}"
PROCESSORS="${PROCESSORS:-0.25}"
MEMORY_GB="${MEMORY_GB:-4}"
STORAGE_TIER="${STORAGE_TIER:-tier3}"
AIX_IMAGE_PATTERN="${AIX_IMAGE_PATTERN:-^7300-}"  # newest stock image matching this wins
AIX_IMAGE_NAME="${AIX_IMAGE_NAME:-}"          # set to pin an exact catalog image name

VSI_PROFILE="${VSI_PROFILE:-cx2-2x4}"         # smallest general VPC profile: 2 vCPU, 4 GB
VSI_USER="${VSI_USER:-ubuntu}"                # IBM Ubuntu images put your key on ubuntu, not root
VSI_OS="${VSI_OS:-ubuntu-24-04-amd64}"        # operating_system.name of the VPC stock image
VPC_ROUTE_NET="${VPC_ROUTE_NET:-10.240.0.0}"  # VPC ranges AIX must reach via its private card
VPC_ROUTE_MASK="${VPC_ROUTE_MASK:-255.255.0.0}"

# Same path the web page uses, so the script can pick up a hand-typed lab.
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/pvs-lab}"

# Wait limits in seconds (PowerVS is not fast; these are generous on purpose)
WAIT_VPC="${WAIT_VPC:-300}"
WAIT_VSI="${WAIT_VSI:-600}"
WAIT_WORKSPACE="${WAIT_WORKSPACE:-1200}"
WAIT_TG="${WAIT_TG:-900}"
WAIT_IMAGE="${WAIT_IMAGE:-1200}"
WAIT_INSTANCE="${WAIT_INSTANCE:-2700}"
WAIT_SSH="${WAIT_SSH:-600}"
POLL="${POLL:-20}"

export IBMCLOUD_VERSION_CHECK=false   # no "new version available" prompts mid-lab
export IBMCLOUD_COLOR=false           # plain text keeps the log readable

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_DIM=$'\e[2m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_B=""; C_DIM=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi

# Mirror output to a log file so instructors can ask for it.
# (Not for the interactive ssh step, which needs a real terminal.)
start_log() { exec > >(tee -a "$LOG_FILE") 2>&1; }

ts()     { date '+%H:%M:%S'; }
banner() { printf '\n%s== %s ==%s\n' "$C_B$C_C" "$*" "$C_0"; }
info()   { printf '%s[%s]%s %s\n' "$C_DIM" "$(ts)" "$C_0" "$*"; }
ok()     { printf '%s[%s] OK%s  %s\n' "$C_G" "$(ts)" "$C_0" "$*"; }
warn()   { printf '%s[%s] !!%s  %s\n' "$C_Y" "$(ts)" "$C_0" "$*"; }
die()    { printf '%s[%s] XX  %s%s\n' "$C_R" "$(ts)" "$*" "$C_0"; exit 1; }

# Print a command (to stderr, so captured output stays clean), then run it.
run() {
  printf '%s  $ %s%s\n' "$C_DIM" "$(printf '%q ' "$@")" "$C_0" >&2
  "$@"
}

fmt_secs() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

on_err() {
  local code=$? line=$1 cmd=$2
  printf '\n%s[%s] XX  Failed (exit %s) at line %s:%s\n    %s\n' "$C_R" "$(ts)" "$code" "$line" "$C_0" "$cmd"
  printf '    Full log: %s\n' "$LOG_FILE"
  printf '    Fix the cause and rerun the same step. Finished work is detected and skipped.\n'
  exit "$code"
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

# ----------------------------------------------------------------------------
# State. A small KEY='value' file so later steps know earlier results.
# It is a cache only: resources are always re-discovered by name.
# ----------------------------------------------------------------------------
# shellcheck disable=SC1090
load_state() { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"; return 0; }

save_state() {
  local key=$1 val=$2 tmp="$STATE_FILE.tmp"
  touch "$STATE_FILE"
  grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
  printf '%s=%q\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  printf -v "$key" '%s' "$val"
}

require_state() {
  local k
  for k in "$@"; do
    [[ -n "${!k:-}" ]] || die "Missing $k. Run the earlier steps first (try: ./pvs-lab.sh status)."
  done
}

# ----------------------------------------------------------------------------
# Waiting. wait_until "what" timeout interval check_fn [args]
# check_fn returns 0 when ready, 1 to keep waiting, 2 for a hard failure,
# and may set LAST_STATUS for the progress line.
# ----------------------------------------------------------------------------
LAST_STATUS=""
wait_until() {
  local what=$1 limit=$2 every=$3; shift 3
  local start=$SECONDS rc
  while true; do
    rc=0; "$@" || rc=$?
    if (( rc == 0 )); then ok "$what (after $(fmt_secs $((SECONDS - start))))"; return 0; fi
    if (( rc == 2 )); then die "$what failed: status ${LAST_STATUS:-unknown}"; fi
    if (( SECONDS - start >= limit )); then
      die "Gave up waiting for $what after $(fmt_secs "$limit") (last status: ${LAST_STATUS:-unknown}). Rerun the step to keep waiting."
    fi
    info "waiting for $what: ${LAST_STATUS:-pending} ($(fmt_secs $((SECONDS - start))) elapsed)"
    sleep "$every"
  done
}

# ----------------------------------------------------------------------------
# JSON helpers. The CLI's JSON shapes differ between commands and versions,
# so lookups search the whole document for an object with a matching name.
# PowerVS instances use "serverName" rather than "name".
# ----------------------------------------------------------------------------
json_find_name() {   # json_find_name <json> <name>  -> compact object or nothing
  jq -c --arg n "$2" 'first(.. | objects | select((.name? == $n) or (.serverName? == $n))) // empty' <<<"$1" 2>/dev/null || true
}
json_id() {          # json_id <object-json>  -> best-guess identifier
  jq -r '.pvmInstanceID // .networkID // .imageID // .sshKeyID // .id // empty' <<<"$1" 2>/dev/null || true
}
pi_json() { ibmcloud pi "$@" --json 2>/dev/null || true; }

# Does a CLI subcommand accept a flag? Keeps the script working across plugin versions.
supports_flag() { local flag=$1; shift; "$@" --help 2>&1 | grep -q -- "$flag"; }

# ----------------------------------------------------------------------------
# Names. Every resource is prefixed per student so many people can share one
# lab account without collisions.
# ----------------------------------------------------------------------------
# The prefix comes from the attendee number (1 to MAX_SEAT): 7 becomes pvs-07.
seat_prefix() {
  local seat=${1:-}
  if [[ -z "$seat" && -t 0 ]]; then
    read -r -p "Your attendee number (1-$MAX_SEAT): " seat
  fi
  if ! [[ "$seat" =~ ^[0-9]+$ ]] || (( 10#$seat < 1 || 10#$seat > MAX_SEAT )); then
    # stderr, because this function's stdout is captured as the prefix
    printf '%s[%s] XX  Attendee number must be 1 to %s. Rerun with: SEAT=<number> ./pvs-lab.sh preflight%s\n' \
      "$C_R" "$(ts)" "$MAX_SEAT" "$C_0" >&2
    return 1
  fi
  printf 'pvs-%02d' "$((10#$seat))"
}

set_names() {
  WS_NAME="${LAB_PREFIX}-ws"
  KEY_NAME="${LAB_PREFIX}-key"
  PRIV_NAME="${LAB_PREFIX}-priv"
  PUB_NAME="${LAB_PREFIX}-pub"
  TG_NAME="${LAB_PREFIX}-tg"
  AIX_NAME="${LAB_PREFIX}-aix"
}

target_workspace() {
  require_state WS_CRN
  ibmcloud pi workspace target "$WS_CRN" >/dev/null
}

# =============================================================================
# STEP: preflight
# =============================================================================
cmd_preflight() {
  banner "Preflight: Cloud Shell, CLI, account, VPC"

  # --- Tools -----------------------------------------------------------------
  local t missing=()
  for t in ibmcloud jq ssh ssh-keygen python3 timeout; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  (( ${#missing[@]} == 0 )) || die "Missing tools: ${missing[*]}. Cloud Shell has these; are you in Cloud Shell?"
  ok "Tools present: ibmcloud, jq, ssh, ssh-keygen, python3"

  # --- Login -----------------------------------------------------------------
  # Cloud Shell signs you in automatically. Outside Cloud Shell, run
  # "ibmcloud login --sso" (or --apikey) first.
  ibmcloud iam oauth-tokens >/dev/null 2>&1 \
    || die "Not logged in. In Cloud Shell this is automatic; elsewhere run: ibmcloud login --sso"
  local account
  account=$(ibmcloud target --output json | jq -r '.account.name // "unknown"')
  ok "Logged in, account: $account"

  # --- Plugins ---------------------------------------------------------------
  # Checked by whether the command works. The Transit Gateway plugin is
  # named tg-cli but its command is "ibmcloud tg".
  local cmd plugin pair
  for pair in "pi power-iaas" "is vpc-infrastructure" "tg tg-cli"; do
    read -r cmd plugin <<<"$pair"
    if ibmcloud "$cmd" help >/dev/null 2>&1; then
      ok "ibmcloud $cmd is available"
    else
      warn "ibmcloud $cmd is missing, installing plugin $plugin"
      run ibmcloud plugin install "$plugin" -f \
        || die "Could not install the $plugin plugin."
      ibmcloud "$cmd" help >/dev/null 2>&1 || die "ibmcloud $cmd still does not work after installing $plugin."
      ok "ibmcloud $cmd is available"
    fi
  done

  # --- Region and resource group --------------------------------------------
  # Group names differ between accounts, so never assume "Default".
  run ibmcloud target -r "$REGION" >/dev/null
  local groups rg_id
  groups=$(ibmcloud resource groups --output json 2>/dev/null || echo '[]')
  if [[ -z "$RESOURCE_GROUP" ]]; then
    if (( $(jq 'length' <<<"$groups") == 1 )); then
      RESOURCE_GROUP=$(jq -r '.[0].name' <<<"$groups")
    elif jq -e 'any(.[]; .name == "Default")' <<<"$groups" >/dev/null; then
      RESOURCE_GROUP="Default"
    else
      warn "Resource groups you can see:"
      jq -r '.[].name' <<<"$groups" | sed 's/^/      /'
      die "Pick one and rerun: RESOURCE_GROUP=<name> ./pvs-lab.sh preflight"
    fi
  fi
  rg_id=$(jq -r --arg n "$RESOURCE_GROUP" 'first(.[] | select(.name == $n) | .id) // empty' <<<"$groups")
  if [[ -z "$rg_id" ]]; then
    warn "Resource groups you can see:"
    jq -r '.[].name' <<<"$groups" | sed 's/^/      /'
    die "Resource group '$RESOURCE_GROUP' not found. Rerun with RESOURCE_GROUP=<name>."
  fi
  run ibmcloud target -g "$RESOURCE_GROUP" >/dev/null
  save_state RESOURCE_GROUP "$RESOURCE_GROUP"
  save_state RG_ID "$rg_id"
  ok "Targeted region $REGION, resource group $RESOURCE_GROUP"

  # --- Lab prefix ------------------------------------------------------------
  if [[ -z "$LAB_PREFIX" ]]; then LAB_PREFIX=$(seat_prefix "$SEAT") || exit 1; fi
  save_state LAB_PREFIX "$LAB_PREFIX"
  ok "Your lab prefix: ${C_B}${LAB_PREFIX}${C_0}  (every resource you create starts with this)"

  save_state PRIVATE_CIDR "$PRIVATE_CIDR"

  # --- PowerVS zone -----------------------------------------------------------
  if ibmcloud pi datacenter get "$PVS_ZONE" >/dev/null 2>&1; then
    ok "PowerVS datacenter $PVS_ZONE is available"
  else
    warn "Could not confirm datacenter $PVS_ZONE (continuing). List them with: ibmcloud pi datacenter list"
  fi
  save_state PVS_ZONE "$PVS_ZONE"

  printf '\n%sReady.%s Next: ./pvs-lab.sh keys\n' "$C_B" "$C_0"
}

# =============================================================================
# STEP: vpc
# =============================================================================
check_vpc_status() {      # check_vpc_status <vpc-id>
  LAST_STATUS=$(ibmcloud is vpc "$1" --output json 2>/dev/null | jq -r '.status // "unknown"' || echo unknown)
  case "$LAST_STATUS" in available) return 0 ;; failed) return 2 ;; *) return 1 ;; esac
}

check_vsi_status() {      # check_vsi_status <instance-id>
  LAST_STATUS=$(ibmcloud is instance "$1" --output json 2>/dev/null | jq -r '.status // "unknown"' || echo unknown)
  case "$LAST_STATUS" in running) return 0 ;; failed) return 2 ;; *) return 1 ;; esac
}

check_subnet_status() {   # check_subnet_status <subnet-id>
  LAST_STATUS=$(ibmcloud is subnet "$1" --output json 2>/dev/null | jq -r '.status // "unknown"' || echo unknown)
  case "$LAST_STATUS" in available) return 0 ;; failed) return 2 ;; *) return 1 ;; esac
}

cmd_vpc() {
  banner "VPC"
  load_state
  require_state LAB_PREFIX RESOURCE_GROUP PRIVATE_CIDR
  ibmcloud target -r "$REGION" -g "$RESOURCE_GROUP" >/dev/null

  # --- 1. The VPC -------------------------------------------------------------
  # A VPC is your private network in IBM Cloud. Creating one is free, and the
  # CLI gives it one address prefix per zone (10.240.0.0/18 and so on).
  local name="${VPC_NAME:-${LAB_PREFIX}-vpc}" vpcs vpc vpc_id
  vpcs=$(ibmcloud is vpcs --output json 2>/dev/null || echo '[]')
  vpc=$(jq -c --arg n "$name" 'first(.[]? | select(.name == $n)) // empty' <<<"$vpcs")
  if [[ -n "$vpc" ]]; then
    ok "VPC $name exists"
    if [[ -z "${VPC_CREATED:-}" ]]; then
      if [[ "$name" == "${LAB_PREFIX}-vpc" ]]; then save_state VPC_CREATED true; else save_state VPC_CREATED false; fi
    fi
  else
    [[ "$name" == "${LAB_PREFIX}-vpc" ]] || die "VPC '$name' not found in $REGION. Unset VPC_NAME to create ${LAB_PREFIX}-vpc instead."
    run ibmcloud is vpc-create "$name" >/dev/null
    vpcs=$(ibmcloud is vpcs --output json 2>/dev/null || echo '[]')
    vpc=$(jq -c --arg n "$name" 'first(.[]? | select(.name == $n)) // empty' <<<"$vpcs")
    [[ -n "$vpc" ]] || die "Created VPC $name but cannot find it."
    save_state VPC_CREATED true
  fi
  vpc_id=$(jq -r '.id' <<<"$vpc")
  wait_until "VPC $name to be available" "$WAIT_VPC" 10 check_vpc_status "$vpc_id"
  save_state VPC_NAME "$name"
  save_state VPC_ID "$vpc_id"
  save_state VPC_CRN "$(jq -r '.crn' <<<"$vpc")"

  # --- 2. One subnet, only in a VPC this script created ----------------------
  # Gives the VPC somewhere to put servers later: 256 addresses in one zone.
  if [[ "${VPC_CREATED:-false}" == "true" ]]; then
    local sn_name="${LAB_PREFIX}-vpc-sn" sn_id
    sn_id=$(ibmcloud is subnets --vpc "$vpc_id" --output json 2>/dev/null \
            | jq -r --arg n "$sn_name" 'first(.[]? | select(.name == $n) | .id) // empty' || true)
    if [[ -n "$sn_id" ]]; then
      ok "VPC subnet $sn_name exists"
    else
      run ibmcloud is subnet-create "$sn_name" "$vpc_id" --zone "$VPC_ZONE" --ipv4-address-count 256 >/dev/null
      sn_id=$(ibmcloud is subnets --vpc "$vpc_id" --output json \
              | jq -r --arg n "$sn_name" 'first(.[]? | select(.name == $n) | .id) // empty')
      [[ -n "$sn_id" ]] || die "Created subnet $sn_name but cannot find it."
    fi
    wait_until "VPC subnet $sn_name to be available" "$WAIT_VPC" 10 check_subnet_status "$sn_id"
    save_state VPC_SUBNET_ID "$sn_id"
  fi

  # --- 3. CIDR overlap check --------------------------------------------------
  # Transit Gateway refuses overlapping ranges, and failing here is far
  # cheaper than failing 20 minutes into the network step.
  local prefixes
  prefixes=$(ibmcloud is vpc-address-prefixes "$vpc_id" --output json 2>/dev/null | jq -r '.[].cidr' || true)
  if [[ -n "$prefixes" ]]; then
    local clash
    # shellcheck disable=SC2086
    if ! clash=$(python3 - "$PRIVATE_CIDR" $prefixes <<'PYEOF'
import ipaddress, sys
mine = ipaddress.ip_network(sys.argv[1], strict=False)
bad = [c for c in sys.argv[2:] if mine.overlaps(ipaddress.ip_network(c, strict=False))]
print(" ".join(bad))
sys.exit(1 if bad else 0)
PYEOF
    ); then
      die "PRIVATE_CIDR $PRIVATE_CIDR overlaps VPC prefix(es): $clash. Rerun with PRIVATE_CIDR=<other /24>."
    fi
    ok "PowerVS private CIDR $PRIVATE_CIDR does not overlap the VPC"
  else
    warn "Could not read VPC address prefixes; skipping overlap check"
  fi

    # --- 4. A server inside the VPC ---------------------------------------------
  # An Ubuntu VSI in the VPC subnet, reachable from Cloud Shell through a
  # floating IP. From it you reach AIX's private address across the Transit
  # Gateway, the way an application in the VPC would.
  [[ -n "${VPC_SUBNET_ID:-}" ]] || { warn "No VPC subnet from this script, so no VPC server is created."; return 0; }

  # VPC keeps its own SSH keys, separate from PowerVS. Same public key.
  local vkey="${LAB_PREFIX}-vpckey" vkey_id
  vkey_id=$(ibmcloud is keys --output json 2>/dev/null \
            | jq -r --arg n "$vkey" 'first(.[]? | select(.name == $n) | .id) // empty' || true)
  if [[ -n "$vkey_id" ]]; then
    ok "VPC SSH key $vkey exists"
  else
    run ibmcloud is key-create "$vkey" "@$SSH_KEY_FILE.pub" >/dev/null
    vkey_id=$(ibmcloud is keys --output json | jq -r --arg n "$vkey" 'first(.[]? | select(.name == $n) | .id) // empty')
    [[ -n "$vkey_id" ]] || die "Created VPC key $vkey but cannot find it."
  fi
  save_state VPC_KEY_ID "$vkey_id"

  # The default security group only lets in traffic from its own members.
  # Allow SSH from anywhere so Cloud Shell can reach the VSI.
  local sg_id has_rule
  sg_id=$(ibmcloud is vpc "$vpc_id" --output json | jq -r '.default_security_group.id')
  has_rule=$(ibmcloud is security-group-rules "$sg_id" --output json 2>/dev/null \
             | jq -r '[.. | objects | select(.direction? == "inbound" and .protocol? == "tcp" and .port_min? == 22)] | length' || echo 0)
  if (( has_rule > 0 )); then
    ok "Security group already allows SSH"
  else
    run ibmcloud is security-group-rule-add "$sg_id" inbound tcp --port-min 22 --port-max 22 --remote 0.0.0.0/0 >/dev/null
    ok "Security group now allows SSH on port 22"
  fi
  # Let AIX's private subnet ping the VSI, so the return path can be tested.
  local has_icmp
  has_icmp=$(ibmcloud is security-group-rules "$sg_id" --output json 2>/dev/null \
             | jq -r '[.. | objects | select(.direction? == "inbound" and .protocol? == "icmp")] | length' || echo 0)
  if (( has_icmp > 0 )); then
    ok "Security group already allows ping"
  else
    run ibmcloud is security-group-rule-add "$sg_id" inbound icmp --remote "$PRIVATE_CIDR" >/dev/null
    ok "Security group now allows ping from $PRIVATE_CIDR"
  fi
  save_state SG_ID "$sg_id"

  # The VSI itself.
  local vsi="${LAB_PREFIX}-vsi" vsi_id
  vsi_id=$(ibmcloud is instances --output json 2>/dev/null \
           | jq -r --arg n "$vsi" 'first(.[]? | select(.name == $n) | .id) // empty' || true)
  if [[ -n "$vsi_id" ]]; then
    ok "VPC server $vsi exists"
  else
    local img
    img=$(ibmcloud is images --visibility public --output json \
          | jq -r --arg os "$VSI_OS" 'first(.[]? | select(.status == "available" and .operating_system.name == $os) | .id) // empty')
    [[ -n "$img" ]] || die "No public image for $VSI_OS. List them: ibmcloud is images --visibility public"
    run ibmcloud is instance-create "$vsi" "$vpc_id" "$VPC_ZONE" "$VSI_PROFILE" "$VPC_SUBNET_ID" \
        --image "$img" --keys "$vkey_id" >/dev/null
    vsi_id=$(ibmcloud is instances --output json | jq -r --arg n "$vsi" 'first(.[]? | select(.name == $n) | .id) // empty')
    [[ -n "$vsi_id" ]] || die "Created $vsi but cannot find it."
  fi
  wait_until "VPC server $vsi to be running" "$WAIT_VSI" 10 check_vsi_status "$vsi_id"
  save_state VSI_ID "$vsi_id"

  # New VSIs use a network attachment that points to a virtual network
  # interface (VNI); older ones have a classic network interface. A floating
  # IP binds to the VNI in the first case and to the interface in the second.
  local vj vni nic
  vj=$(ibmcloud is instance "$vsi_id" --output json)
  vni=$(jq -r '.primary_network_attachment.virtual_network_interface.id // empty' <<<"$vj")
  [[ -n "$vni" ]] || nic=$(jq -r '.primary_network_interface.id // empty' <<<"$vj")
  save_state VSI_PRIVATE_IP "$(jq -r '.primary_network_attachment.primary_ip.address
                                      // .primary_network_interface.primary_ip.address // empty' <<<"$vj")"

  # A floating IP is a public address mapped to the VSI's private one.
  local fip="${LAB_PREFIX}-fip" fip_json
  fip_json=$(ibmcloud is floating-ips --output json 2>/dev/null \
             | jq -c --arg n "$fip" 'first(.[]? | select(.name == $n)) // empty' || true)
  if [[ -n "$fip_json" ]]; then
    ok "Floating IP $fip exists"
  else
    local fargs=()
    if [[ -n "$vni" ]]; then
      fargs=(--vni "$vni")
    elif [[ -n "${nic:-}" ]]; then
      fargs=(--nic "$nic" --in "$vsi_id")
    else
      die "Could not find the VSI's network interface for the floating IP."
    fi
    run ibmcloud is floating-ip-reserve "$fip" "${fargs[@]}" >/dev/null
    fip_json=$(ibmcloud is floating-ips --output json | jq -c --arg n "$fip" 'first(.[]? | select(.name == $n)) // empty')
    [[ -n "$fip_json" ]] || die "Reserved $fip but cannot find it."
  fi
  save_state FIP_ID "$(jq -r '.id' <<<"$fip_json")"
  save_state VSI_PUBLIC_IP "$(jq -r '.address' <<<"$fip_json")"
  ok "VPC server $vsi: private ${VSI_PRIVATE_IP:-?}, public $VSI_PUBLIC_IP"

  printf '\n%sVPC ready.%s Next: ./pvs-lab.sh gateway\n' "$C_B" "$C_0"
}

# =============================================================================
# STEP: keys
# =============================================================================
cmd_keys() {
  banner "SSH key for the AIX server"
  load_state
  require_state LAB_PREFIX

  if [[ -f "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE.pub" ]]; then
    ok "Key pair already exists: $SSH_KEY_FILE"
  else
    # RSA 4096 matches what PowerVS and AIX's OpenSSH accept everywhere.
    mkdir -p "$(dirname "$SSH_KEY_FILE")"; chmod 700 "$(dirname "$SSH_KEY_FILE")"
    run ssh-keygen -q -t rsa -b 4096 -N "" -C "$LAB_PREFIX" -f "$SSH_KEY_FILE"
    ok "Created $SSH_KEY_FILE and $SSH_KEY_FILE.pub"
  fi
  chmod 600 "$SSH_KEY_FILE"
  save_state SSH_KEY_FILE "$SSH_KEY_FILE"

  printf '\nPublic key (PowerVS gets this one; the private half never leaves Cloud Shell):\n'
  cut -c1-60 "$SSH_KEY_FILE.pub" | sed 's/$/ .../'
  printf '\nNext: ./pvs-lab.sh powervs\n'
}

# =============================================================================
# STEP: powervs  (workspace, key, subnets, image, and START the AIX build)
# =============================================================================
check_workspace_active() {
  local inst
  inst=$(ibmcloud resource service-instances --service-name power-iaas --output json 2>/dev/null \
         | jq -c --arg n "$WS_NAME" 'first(.[]? | select(.name == $n)) // empty' || true)
  [[ -n "$inst" ]] || { LAST_STATUS="not listed yet"; return 1; }
  LAST_STATUS=$(jq -r '.state // "unknown"' <<<"$inst")
  WS_CRN=$(jq -r '.crn' <<<"$inst")
  WS_ID=$(jq -r '.guid // .id' <<<"$inst")
  case "$LAST_STATUS" in
    active) return 0 ;;
    failed|removed) return 2 ;;
    *) return 1 ;;
  esac
}

check_image_active() {   # check_image_active <name>
  local obj
  obj=$(json_find_name "$(pi_json image list)" "$1")
  [[ -n "$obj" ]] || { LAST_STATUS="copying"; return 1; }
  LAST_STATUS=$(jq -r '.state // "unknown"' <<<"$obj")
  WS_IMAGE_ID=$(json_id "$obj")
  case "$LAST_STATUS" in active) return 0 ;; failed|error) return 2 ;; *) return 1 ;; esac
}

check_instance_active() {   # check_instance_active <id>
  local j
  j=$(pi_json instance get "$1")
  LAST_STATUS=$(jq -r '.status // "unknown"' <<<"$j" 2>/dev/null || echo unknown)
  case "$LAST_STATUS" in ACTIVE) return 0 ;; ERROR) return 2 ;; *) return 1 ;; esac
}

catalog_json() { pi_json image list-catalog; }

cmd_powervs() {
  banner "PowerVS workspace, key, subnets, and the AIX server build"
  load_state
  require_state LAB_PREFIX RESOURCE_GROUP RG_ID SSH_KEY_FILE PVS_ZONE PRIVATE_CIDR
  set_names
  ibmcloud target -r "$REGION" -g "$RESOURCE_GROUP" >/dev/null

  # --- 1. Workspace -----------------------------------------------------------
  # A workspace is the PowerVS container for servers, images, subnets, keys.
  # Creation takes roughly 5 to 15 minutes.
  if check_workspace_active || [[ "$LAST_STATUS" != "not listed yet" ]]; then
    ok "Workspace $WS_NAME exists (state: $LAST_STATUS)"
  else
    run ibmcloud pi workspace create "$WS_NAME" --datacenter "$PVS_ZONE" --group "$RG_ID" --plan public
  fi
  wait_until "workspace $WS_NAME to be active" "$WAIT_WORKSPACE" "$POLL" check_workspace_active
  save_state WS_CRN "$WS_CRN"
  save_state WS_ID "$WS_ID"
  save_state WS_NAME "$WS_NAME"

  # Every "ibmcloud pi" command after this acts on this workspace.
  run ibmcloud pi workspace target "$WS_CRN" >/dev/null
  ok "CLI now targets $WS_NAME"

  # --- 2. PowerVS SSH key -----------------------------------------------------
  # PowerVS injects this public key into root's authorized_keys at deploy.
  if ibmcloud pi ssh-key get "$KEY_NAME" >/dev/null 2>&1; then
    ok "PowerVS SSH key $KEY_NAME exists"
  else
    run ibmcloud pi ssh-key create "$KEY_NAME" --key "$(cat "$SSH_KEY_FILE.pub")" >/dev/null
    ok "Imported PowerVS SSH key $KEY_NAME"
  fi
  save_state KEY_NAME "$KEY_NAME"

  # --- 3. Private subnet ------------------------------------------------------
  # This is the network the Transit Gateway advertises to the VPC.
  local subnets obj
  subnets=$(pi_json subnet list)
  obj=$(json_find_name "$subnets" "$PRIV_NAME")
  if [[ -z "$obj" ]]; then
    run ibmcloud pi subnet create "$PRIV_NAME" --net-type private \
        --cidr-block "$PRIVATE_CIDR" --dns-servers "$DNS_SERVER" >/dev/null
    subnets=$(pi_json subnet list)
    obj=$(json_find_name "$subnets" "$PRIV_NAME")
  else
    ok "Private subnet $PRIV_NAME exists"
  fi
  [[ -n "$obj" ]] || die "Cannot find subnet $PRIV_NAME after creating it."
  save_state PRIV_NAME "$PRIV_NAME"
  save_state PRIV_SUBNET_ID "$(json_id "$obj")"
  ok "Private subnet $PRIV_NAME ($PRIVATE_CIDR)"

  # --- 4. Public subnet -------------------------------------------------------
  # Cloud Shell runs on the internet, not inside your VPC, so it cannot reach
  # the private subnet. A public subnet gives the AIX server an address
  # Cloud Shell can SSH to. Set PUBLIC_ACCESS=false to skip it.
  if [[ "$PUBLIC_ACCESS" == "true" ]]; then
    obj=$(json_find_name "$subnets" "$PUB_NAME")
    if [[ -z "$obj" ]]; then
      run ibmcloud pi subnet create "$PUB_NAME" --net-type public >/dev/null
      subnets=$(pi_json subnet list)
      obj=$(json_find_name "$subnets" "$PUB_NAME")
    else
      ok "Public subnet $PUB_NAME exists"
    fi
    [[ -n "$obj" ]] || die "Cannot find subnet $PUB_NAME after creating it."
    save_state PUB_NAME "$PUB_NAME"
    save_state PUB_SUBNET_ID "$(json_id "$obj")"
    ok "Public subnet $PUB_NAME"
  else
    warn "PUBLIC_ACCESS=false: no public subnet. Cloud Shell will not be able to SSH to the server directly."
  fi

  # --- 5. Pick a stock image and copy it in ----------------------------------
  # Servers boot from images inside the workspace, so the stock image is
  # copied in first. Stock image names cannot be changed.
  local catalog pick img_name img_id
  catalog=$(catalog_json)
  if [[ -n "$AIX_IMAGE_NAME" ]]; then
    pick=$(jq -c --arg n "$AIX_IMAGE_NAME" 'first((.images? // .)[]? | select(.name == $n)) // empty' <<<"$catalog")
    [[ -n "$pick" ]] || die "Image '$AIX_IMAGE_NAME' is not in the catalog. See: ./pvs-lab.sh catalog"
  else
    pick=$(jq -c --arg p "$AIX_IMAGE_PATTERN" '[ (.images? // .)[]? | select((.name // "") | test($p)) ] | sort_by(.name) | last // empty' <<<"$catalog")
    [[ -n "$pick" ]] || die "No catalog image matches '$AIX_IMAGE_PATTERN'. See: ./pvs-lab.sh catalog"
  fi
  img_name=$(jq -r '.name' <<<"$pick")
  img_id=$(jq -r '.imageID // .id' <<<"$pick")
  ok "Stock image: $img_name"
  if check_image_active "$img_name" || [[ "$LAST_STATUS" != "copying" ]]; then
    ok "Image $img_name already in workspace (state: $LAST_STATUS)"
  else
    run ibmcloud pi image create "$img_id" >/dev/null
  fi
  wait_until "image $img_name to be active in the workspace" "$WAIT_IMAGE" "$POLL" check_image_active "$img_name"
  save_state IMAGE_NAME "$img_name"
  save_state WS_IMAGE_ID "$WS_IMAGE_ID"

  # --- 6. Start the AIX server build (no waiting) ----------------------------
  # The build takes 15 to 20 minutes, so this step only starts it. The vpc and
  # gateway steps run while it builds; the server step waits for it.
  local inst inst_id=""
  inst=$(json_find_name "$(pi_json instance list)" "$AIX_NAME")
  if [[ -n "$inst" ]]; then
    inst_id=$(json_id "$inst")
    ok "Server $AIX_NAME exists"
  else
    local args=(
      --image "$WS_IMAGE_ID"
      --sys-type "$SYS_TYPE"
      --processor-type "$PROC_TYPE"
      --processors "$PROCESSORS"
      --memory "$MEMORY_GB"
      --storage-tier "$STORAGE_TIER"
      --key-name "$KEY_NAME"
    )
    # One --subnets per network card. The public one goes first so it is the
    # primary card and carries the default route back to Cloud Shell.
    [[ -n "${PUB_SUBNET_ID:-}" ]] && args+=(--subnets "$PUB_SUBNET_ID")
    args+=(--subnets "$PRIV_SUBNET_ID")
    run ibmcloud pi instance create "$AIX_NAME" "${args[@]}" >/dev/null
    local tries=0
    while [[ -z "$inst_id" && $tries -lt 10 ]]; do
      inst=$(json_find_name "$(pi_json instance list)" "$AIX_NAME")
      inst_id=$(json_id "$inst"); tries=$((tries + 1)); [[ -n "$inst_id" ]] || sleep 6
    done
    [[ -n "$inst_id" ]] || die "Created $AIX_NAME but cannot find it in the instance list."
    ok "AIX build started. It takes 15 to 20 minutes; build the VPC side meanwhile."
  fi
  save_state AIX_NAME "$AIX_NAME"
  save_state AIX_ID "$inst_id"

  printf '\n%sAIX is building.%s Next: ./pvs-lab.sh vpc\n' "$C_B" "$C_0"
}

# =============================================================================
# STEP: catalog
# =============================================================================
cmd_catalog() {
  banner "Stock AIX images"
  load_state; target_workspace
  catalog_json | jq -r --arg p "$AIX_IMAGE_PATTERN" '
      [ (.images? // .)[]? | select((.name // "") | test($p)) ]
      | sort_by(.name) | reverse | .[] | "  \(.name)"' \
    || die "Could not read the image catalog."
  printf '\nThe newest one is used by default. To pin one:\n  AIX_IMAGE_NAME=<name> ./pvs-lab.sh powervs\n'
}

# =============================================================================
# STEP: gateway  (Transit Gateway and both connections)
# =============================================================================
check_tg_status() {   # check_tg_status <gateway-id>
  LAST_STATUS=$(ibmcloud tg gateway "$1" --output json 2>/dev/null | jq -r '.status // "unknown"' || echo unknown)
  case "$LAST_STATUS" in available) return 0 ;; failed) return 2 ;; *) return 1 ;; esac
}

check_tg_conn() {     # check_tg_conn <gateway-id> <connection-id>
  LAST_STATUS=$(ibmcloud tg connection "$1" "$2" --output json 2>/dev/null | jq -r '.status // "unknown"' || echo unknown)
  case "$LAST_STATUS" in attached) return 0 ;; failed|detached) return 2 ;; *) return 1 ;; esac
}

ensure_tg_connection() {   # ensure_tg_connection <gw> <name> <type> <network-crn>; sets CONN_ID
  local gw=$1 name=$2 type=$3 crn=$4 conns conn_id
  conns=$(ibmcloud tg connections "$gw" --output json 2>/dev/null || echo '[]')
  conn_id=$(jq -r --arg c "$crn" 'first(.. | objects | select(.network_id? == $c) | .id) // empty' <<<"$conns")
  if [[ -n "$conn_id" ]]; then
    ok "Transit Gateway already connected to $type"
  else
    run ibmcloud tg connection-create "$gw" --name "$name" --network-type "$type" --network-id "$crn" >/dev/null
    conns=$(ibmcloud tg connections "$gw" --output json 2>/dev/null || echo '[]')
    conn_id=$(jq -r --arg c "$crn" 'first(.. | objects | select(.network_id? == $c) | .id) // empty' <<<"$conns")
    [[ -n "$conn_id" ]] || die "Created the $type connection but cannot find it."
  fi
  wait_until "Transit Gateway connection to $type" "$WAIT_TG" "$POLL" check_tg_conn "$gw" "$conn_id"
  CONN_ID=$conn_id
}

cmd_gateway() {
  banner "Transit Gateway"
  load_state
  require_state LAB_PREFIX RESOURCE_GROUP RG_ID VPC_CRN WS_CRN
  set_names
  ibmcloud target -r "$REGION" -g "$RESOURCE_GROUP" >/dev/null

  # Local routing is enough: the VPC (us-south) and dal10 are in one region.
  local tg_id
  if [[ -n "$EXISTING_TG" ]]; then
    tg_id="$EXISTING_TG"
    ok "Reusing Transit Gateway $tg_id (EXISTING_TG)"
    save_state TG_CREATED "false"
  else
    tg_id=$(ibmcloud tg gateways --output json 2>/dev/null \
            | jq -r --arg n "$TG_NAME" 'first(.. | objects | select(.name? == $n) | .id) // empty' || true)
    if [[ -n "$tg_id" ]]; then
      ok "Transit Gateway $TG_NAME exists"
    else
      local tg_args=(--name "$TG_NAME" --location "$TG_LOCATION" --output json)
      supports_flag --resource-group-id ibmcloud tg gateway-create && tg_args+=(--resource-group-id "$RG_ID")
      tg_id=$(run ibmcloud tg gateway-create "${tg_args[@]}" | jq -r '.id // empty' || true)
      if [[ -z "$tg_id" ]]; then
        tg_id=$(ibmcloud tg gateways --output json | jq -r --arg n "$TG_NAME" 'first(.. | objects | select(.name? == $n) | .id) // empty')
      fi
      [[ -n "$tg_id" ]] || die "Could not create or find Transit Gateway $TG_NAME (account quota is 10 by default)."
    fi
    save_state TG_CREATED "true"
  fi
  save_state TG_ID "$tg_id"
  wait_until "Transit Gateway to be available" "$WAIT_TG" "$POLL" check_tg_status "$tg_id"

  # One connection per network. The workspace connection only works in
  # PER-enabled zones such as dal10.
  ensure_tg_connection "$tg_id" "${LAB_PREFIX}-vpc-conn" vpc "$VPC_CRN"
  save_state TG_VPC_CONN "$CONN_ID"
  ensure_tg_connection "$tg_id" "${LAB_PREFIX}-pvs-conn" power_virtual_server "$WS_CRN"
  save_state TG_PVS_CONN "$CONN_ID"

  printf '\n%sGateway ready.%s Next: ./pvs-lab.sh server\n' "$C_B" "$C_0"
}

# =============================================================================
# STEP: server  (wait for AIX, read its addresses, add the route to the VPC)
# =============================================================================
check_port22() {   # check_port22 <ip>
  if timeout 5 bash -c "exec 3<>/dev/tcp/$1/22" 2>/dev/null; then return 0; fi
  LAST_STATUS="port 22 closed"; return 1
}

# All SSH goes through one small config file so the jump through the VPC
# server uses the same key and known_hosts as the direct connection.
write_ssh_config() {
  cat > "$SSH_CONFIG" <<EOF
Host *
  User root
  IdentityFile $SSH_KEY_FILE
  IdentitiesOnly yes
  UserKnownHostsFile $KNOWN_HOSTS
  StrictHostKeyChecking accept-new
  ConnectTimeout 15
  ServerAliveInterval 30
EOF
  chmod 600 "$SSH_CONFIG"
}

private_gateway() {   # first usable address of PRIVATE_CIDR, e.g. 192.168.50.1
  python3 -c 'import ipaddress,sys; print(next(ipaddress.ip_network(sys.argv[1], strict=False).hosts()))' "$PRIVATE_CIDR"
}

cmd_server() {
  banner "Wait for the AIX server, then route it to the VPC"
  load_state
  require_state LAB_PREFIX WS_CRN AIX_ID PRIV_SUBNET_ID SSH_KEY_FILE
  set_names
  target_workspace

  # Usually 15 to 20 minutes from the powervs step. BUILD, then ACTIVE.
  wait_until "server $AIX_NAME to be ACTIVE" "$WAIT_INSTANCE" 30 check_instance_active "$AIX_ID"

  local j priv_ip pub_ip
  j=$(pi_json instance get "$AIX_ID")
  priv_ip=$(jq -r --arg id "$PRIV_SUBNET_ID" --arg n "$PRIV_NAME" \
            'first(.networks[]? | select(.networkID == $id or .networkName == $n) | .ipAddress) // empty' <<<"$j")
  pub_ip=$(jq -r 'first(.networks[]? | select((.externalIP // "") != "") | .externalIP) // empty' <<<"$j")
  if [[ -z "$pub_ip" && -n "${PUB_SUBNET_ID:-}" ]]; then
    pub_ip=$(jq -r --arg id "$PUB_SUBNET_ID" --arg n "$PUB_NAME" \
             'first(.networks[]? | select(.networkID == $id or .networkName == $n) | .ipAddress) // empty' <<<"$j")
  fi
  save_state AIX_PRIVATE_IP "$priv_ip"
  save_state AIX_PUBLIC_IP "$pub_ip"
  ok "Private IP (VPC side via Transit Gateway): ${priv_ip:-unknown}"
  ok "Public IP (Cloud Shell side):              ${pub_ip:-none}"

  [[ -n "$pub_ip" ]] || die "No public IP, so Cloud Shell cannot reach the server to add its route."

  # sshd can start a few minutes after the server reports ACTIVE.
  wait_until "SSH on $pub_ip:22" "$WAIT_SSH" 15 check_port22 "$pub_ip"

  # AIX's default route leaves through the public card. Replies to the VPC
  # must go back through the private card instead, so add a route for the
  # VPC's 10.240.0.0/16 via the private subnet's gateway. Safe to rerun.
  write_ssh_config
  local gw; gw=$(private_gateway)
  info "Adding a route on AIX: $VPC_ROUTE_NET/$VPC_ROUTE_MASK via $gw"
  run ssh -F "$SSH_CONFIG" -o BatchMode=yes "$pub_ip" \
      "netstat -rn | grep -q '^${VPC_ROUTE_NET%.0.0}' || route add -net $VPC_ROUTE_NET -netmask $VPC_ROUTE_MASK $gw; netstat -rn | grep '^${VPC_ROUTE_NET%.0.0}'"
  ok "AIX routes the VPC through the private subnet"

  printf '\n%sServer ready.%s Next: ./pvs-lab.sh verify\n' "$C_B" "$C_0"
}

# =============================================================================
# STEP: verify  (both paths to AIX)
# =============================================================================
cmd_verify() {
  banner "Verify both paths to AIX"
  load_state
  require_state WS_CRN AIX_ID SSH_KEY_FILE AIX_PUBLIC_IP
  target_workspace
  write_ssh_config

  info "Servers in the workspace"
  run ibmcloud pi instance list || true
  info "Subnets"
  run ibmcloud pi subnet list || true
  if [[ -n "${TG_ID:-}" ]]; then
    info "Transit Gateway connections"
    run ibmcloud tg connections "$TG_ID" || true
  fi

  # Path 1: Cloud Shell to AIX over the internet, through the public subnet.
  info "Path 1: Cloud Shell -> AIX public address"
  run ssh -F "$SSH_CONFIG" -o BatchMode=yes "$AIX_PUBLIC_IP" \
      'echo "host: $(hostname)  oslevel: $(oslevel -s)"; ifconfig -a | grep "inet "'
  ok "Path 1 works"

  # Path 2: Cloud Shell to the VPC server, then across the Transit Gateway to
  # AIX's private address. ProxyCommand makes the VSI the jump host.
  if [[ -n "${VSI_PUBLIC_IP:-}" && -n "${AIX_PRIVATE_IP:-}" ]]; then
    wait_until "SSH on the VPC server $VSI_PUBLIC_IP:22" "$WAIT_SSH" 10 check_port22 "$VSI_PUBLIC_IP"
    info "Path 2a: VPC server pings AIX's private address across the gateway"
    run ssh -F "$SSH_CONFIG" -o BatchMode=yes "$VSI_USER@$VSI_PUBLIC_IP" "ping -c 3 $AIX_PRIVATE_IP"
    info "Path 2b: SSH to AIX's private address, jumping through the VPC server"
    run ssh -F "$SSH_CONFIG" -o BatchMode=yes \
        -o ProxyCommand="ssh -F $SSH_CONFIG -o BatchMode=yes -W %h:%p $VSI_USER@$VSI_PUBLIC_IP" \
        "root@$AIX_PRIVATE_IP" 'echo "reached $(hostname) on its private address"'
    ok "Path 2 works"
  else
    warn "No VPC server or private address saved, so path 2 is skipped. Run ./pvs-lab.sh vpc and server."
  fi

  printf '\n%sBoth paths work.%s Log in with: ./pvs-lab.sh ssh  or  ./pvs-lab.sh ssh-vpc\n' "$C_B$C_G" "$C_0"
}

cmd_ssh() {
  load_state
  require_state AIX_PUBLIC_IP SSH_KEY_FILE
  write_ssh_config
  info "Connecting to root@$AIX_PUBLIC_IP (type exit to come back to Cloud Shell)"
  exec ssh -F "$SSH_CONFIG" "$AIX_PUBLIC_IP"
}

cmd_ssh_vpc() {
  load_state
  require_state VSI_PUBLIC_IP AIX_PRIVATE_IP SSH_KEY_FILE
  write_ssh_config
  info "Connecting to AIX at $AIX_PRIVATE_IP through the VPC server $VSI_PUBLIC_IP"
  exec ssh -F "$SSH_CONFIG" -o ProxyCommand="ssh -F $SSH_CONFIG -W %h:%p $VSI_USER@$VSI_PUBLIC_IP" "root@$AIX_PRIVATE_IP"
}

# =============================================================================
# STEP: status
# =============================================================================
cmd_status() {
  banner "Status"
  load_state
  if [[ ! -s "$STATE_FILE" ]]; then warn "No state yet. Start with ./pvs-lab.sh preflight"; return 0; fi
  printf '%sSaved state (%s):%s\n' "$C_DIM" "$STATE_FILE" "$C_0"
  sed 's/^/  /' "$STATE_FILE"
  if [[ -n "${WS_CRN:-}" ]]; then
    ibmcloud pi workspace target "$WS_CRN" >/dev/null 2>&1 || true
    [[ -n "${AIX_ID:-}" ]] && { check_instance_active "$AIX_ID" || true; printf '\n  Server status:  %s\n' "$LAST_STATUS"; }
  fi
  [[ -n "${TG_ID:-}" ]] && { check_tg_status "$TG_ID" || true; printf '  Gateway status: %s\n' "$LAST_STATUS"; }
  [[ -n "${VSI_ID:-}" ]] && { check_vsi_status "$VSI_ID" || true; printf '  VPC server:     %s\n' "$LAST_STATUS"; }
  return 0
}

# =============================================================================
# STEP: destroy (after class)
# =============================================================================
retry() {   # retry <seconds> <what> cmd...
  local limit=$1 what=$2; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start >= limit )) && { warn "Could not delete $what; delete it in the console."; return 0; }
    info "retrying delete of $what"; sleep "$POLL"
  done
  ok "Deleted $what"
}

wait_instance_gone() {   # soft wait: never aborts the teardown
  local start=$SECONDS
  while [[ -n "$(json_find_name "$(pi_json instance list)" "$AIX_NAME")" ]]; do
    (( SECONDS - start >= 1800 )) && { warn "Server still listed after 30m; continuing anyway"; return 0; }
    info "waiting for server deletion ($(fmt_secs $((SECONDS - start))) elapsed)"; sleep "$POLL"
  done
  ok "Server deleted"
}

cmd_destroy() {
  banner "Destroy everything this script created"
  load_state
  require_state LAB_PREFIX
  set_names
  printf 'This deletes the AIX server, image copy, subnets, PowerVS key, the VPC server and floating IP,\n'
  printf 'Transit Gateway connections%s, and workspace for %s%s%s.\n' \
    "$([[ "${TG_CREATED:-true}" == "true" ]] && echo ', the gateway')" "$C_B" "$LAB_PREFIX" "$C_0"
  if [[ "${VPC_CREATED:-false}" == "true" ]]; then
    printf 'It also deletes the VPC %s and its subnet. ' "${VPC_NAME:-}"
  else
    printf 'The VPC is not touched. '
  fi
  printf 'Type the prefix to confirm: '
  local answer; read -r answer
  [[ "$answer" == "$LAB_PREFIX" ]] || die "Not confirmed. Nothing deleted."

  if [[ -n "${WS_CRN:-}" ]] && ibmcloud pi workspace target "$WS_CRN" >/dev/null 2>&1; then
    local inst; inst=$(json_find_name "$(pi_json instance list)" "$AIX_NAME")
    if [[ -n "$inst" ]]; then
      run ibmcloud pi instance delete "$(json_id "$inst")" || true
      wait_instance_gone
    fi
    # Subnets stay "in use" for a few minutes after the server is gone.
    [[ -n "${PUB_SUBNET_ID:-}" ]]  && retry 900 "public subnet"  ibmcloud pi subnet delete "$PUB_SUBNET_ID"
    [[ -n "${PRIV_SUBNET_ID:-}" ]] && retry 900 "private subnet" ibmcloud pi subnet delete "$PRIV_SUBNET_ID"
    [[ -n "${WS_IMAGE_ID:-}" ]]    && retry 300 "image copy"     ibmcloud pi image delete "$WS_IMAGE_ID"
    retry 120 "PowerVS SSH key" ibmcloud pi ssh-key delete "$KEY_NAME"
  fi

  if [[ -n "${TG_ID:-}" ]]; then
    [[ -n "${TG_PVS_CONN:-}" ]] && retry 600 "gateway connection to workspace" ibmcloud tg connection-delete "$TG_ID" "$TG_PVS_CONN" -f
    [[ -n "${TG_VPC_CONN:-}" ]] && retry 600 "gateway connection to VPC"       ibmcloud tg connection-delete "$TG_ID" "$TG_VPC_CONN" -f
    if [[ "${TG_CREATED:-true}" == "true" ]]; then
      retry 900 "Transit Gateway" ibmcloud tg gateway-delete "$TG_ID" -f
    fi
  fi

  # The VPC goes only if this script created it, after the gateway is gone.
  if [[ "${VPC_CREATED:-false}" == "true" && -n "${VPC_ID:-}" ]]; then
    [[ -n "${FIP_ID:-}" ]] && retry 300 "floating IP" ibmcloud is floating-ip-release "$FIP_ID" -f
    if [[ -n "${VSI_ID:-}" ]]; then
      retry 300 "VPC server" ibmcloud is instance-delete "$VSI_ID" -f
      local t0=$SECONDS
      while ibmcloud is instance "$VSI_ID" >/dev/null 2>&1 && (( SECONDS - t0 < 600 )); do
        info "waiting for the VPC server to go"; sleep "$POLL"
      done
    fi
    [[ -n "${VPC_KEY_ID:-}" ]] && retry 120 "VPC SSH key" ibmcloud is key-delete "$VPC_KEY_ID" -f
    [[ -n "${VPC_SUBNET_ID:-}" ]] && retry 600 "VPC subnet" ibmcloud is subnet-delete "$VPC_SUBNET_ID" -f
    retry 600 "VPC" ibmcloud is vpc-delete "$VPC_ID" -f
  fi

  if [[ -n "${WS_CRN:-}" ]]; then
    retry 900 "workspace" ibmcloud resource service-instance-delete "$WS_CRN" -f --recursive
  fi

  mv "$STATE_FILE" "$STATE_FILE.destroyed.$(date +%s)" 2>/dev/null || true
  ok "Done. The SSH key pair was kept; delete it with: rm -f $SSH_KEY_FILE*"
}

# =============================================================================
# Entry point
# =============================================================================
usage() {
  sed -n '/^#  Usage:/,/^#  Every step/p' "$0" | sed 's/^# \{0,2\}//' | sed '$d'
  printf 'Version %s. Log: %s\n' "$SCRIPT_VERSION" "$LOG_FILE"
}

main() {
  local step=${1:-help}
  [[ "$step" == ssh* ]] || start_log
  printf '%s--- pvs-lab %s | %s | %s ---%s\n' "$C_DIM" "$SCRIPT_VERSION" "$step" "$(date '+%F %T')" "$C_0"
  case "$step" in
    preflight) cmd_preflight ;;
    keys)      cmd_keys ;;
    powervs)   cmd_powervs ;;
    vpc)       cmd_vpc ;;
    gateway)   cmd_gateway ;;
    server)    cmd_server ;;
    verify)    cmd_verify ;;
    ssh)       cmd_ssh ;;
    ssh-vpc)   cmd_ssh_vpc ;;
    catalog)   cmd_catalog ;;
    status)    cmd_status ;;
    destroy)   cmd_destroy ;;
    all)       cmd_preflight; cmd_keys; cmd_powervs; cmd_vpc; cmd_gateway; cmd_server; cmd_verify ;;
    help|-h|--help) usage ;;
    *) usage; die "Unknown step: $step" ;;
  esac
}

main "$@"
