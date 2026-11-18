#!/usr/bin/env bash
#
# init.sh - one-time, idempotent setup of the OpenStack resources that
# up.sh / down.sh rely on: keypair, security group, private network,
# subnet, router and (optionally) an object storage container.
#
# Safe to run repeatedly: every step checks whether the resource exists.
# It never creates a server and never deletes anything.

set -euo pipefail
cd "$(dirname "$0")"

# --- Load config ------------------------------------------------------------
if [[ ! -f config.env ]]; then
  echo "ERROR: config.env not found next to init.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source config.env

if [[ -n "${OS_CLOUD:-}" ]]; then
  export OS_CLOUD
fi

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
made() { printf '    created: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------
command -v openstack >/dev/null 2>&1 \
  || die "openstack CLI not found (pip install python-openstackclient)"

log "Checking OpenStack authentication"
openstack token issue -f value -c expires >/dev/null 2>&1 \
  || die "cannot authenticate. Set OS_CLOUD (clouds.yaml) or source your application-credential openrc file."
ok "authenticated"

log "Checking flavor and image"
openstack flavor show "$FLAVOR" >/dev/null 2>&1 \
  || die "flavor '$FLAVOR' not found (run: openstack flavor list)"
ok "flavor $FLAVOR"
openstack image show "$IMAGE_ID" >/dev/null 2>&1 \
  || die "image id '$IMAGE_ID' not found (run: openstack image list)"
ok "image $IMAGE_ID"

# --- Keypair ----------------------------------------------------------------
log "Keypair: $KEY_NAME"
if openstack keypair show "$KEY_NAME" >/dev/null 2>&1; then
  ok "exists"
else
  [[ -f "$PUBKEY_FILE" ]] || die "public key not found at $PUBKEY_FILE (set PUBKEY_FILE in config.env)"
  openstack keypair create --public-key "$PUBKEY_FILE" "$KEY_NAME" >/dev/null
  made "$KEY_NAME from $PUBKEY_FILE"
fi

# --- Security group ---------------------------------------------------------
log "Security group: $SG_NAME"
if [[ -z "${ALLOWED_CIDR:-}" ]]; then
  my_ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  [[ "$my_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "could not detect your public IPv4; set ALLOWED_CIDR in config.env"
  ALLOWED_CIDR="${my_ip}/32"
  echo "    detected your IP: $ALLOWED_CIDR"
fi

if openstack security group show "$SG_NAME" >/dev/null 2>&1; then
  ok "group exists"
else
  openstack security group create "$SG_NAME" \
    --description "AI test VM: inbound from $ALLOWED_CIDR only" >/dev/null
  made "$SG_NAME"
fi

# Existing ingress rules as "min:max cidr" lines, for idempotent matching.
existing_rules="$(openstack security group rule list "$SG_NAME" \
  --protocol tcp --ingress -f value -c "Port Range" -c "IP Range" 2>/dev/null || true)"

for port in $SG_TCP_PORTS; do
  if grep -qx "${port}:${port} ${ALLOWED_CIDR}" <<<"$existing_rules"; then
    ok "tcp/$port from $ALLOWED_CIDR already allowed"
  else
    openstack security group rule create "$SG_NAME" \
      --protocol tcp --dst-port "$port" --remote-ip "$ALLOWED_CIDR" \
      --ingress >/dev/null
    made "rule tcp/$port from $ALLOWED_CIDR"
  fi
done
echo "    note: if your public IP changes, add a rule for the new one or rerun with a new ALLOWED_CIDR."

# --- Network, subnet, router ------------------------------------------------
log "Network: $NET_NAME"
if openstack network show "$NET_NAME" >/dev/null 2>&1; then
  ok "network exists"
else
  openstack network create "$NET_NAME" >/dev/null
  made "$NET_NAME"
fi

log "Subnet: $SUBNET_NAME ($SUBNET_RANGE)"
if openstack subnet show "$SUBNET_NAME" >/dev/null 2>&1; then
  ok "subnet exists"
else
  openstack subnet create "$SUBNET_NAME" \
    --network "$NET_NAME" \
    --subnet-range "$SUBNET_RANGE" \
    --dns-nameserver 1.1.1.1 --dns-nameserver 9.9.9.9 >/dev/null
  made "$SUBNET_NAME"
fi

log "Router: $ROUTER_NAME"
if [[ -z "${EXTERNAL_NET:-}" ]]; then
  EXTERNAL_NET="$(openstack network list --external -f value -c Name | head -n1)"
  [[ -n "$EXTERNAL_NET" ]] || die "no external network found; set EXTERNAL_NET in config.env"
  echo "    detected external network: $EXTERNAL_NET"
fi

if openstack router show "$ROUTER_NAME" >/dev/null 2>&1; then
  ok "router exists"
else
  openstack router create "$ROUTER_NAME" >/dev/null
  made "$ROUTER_NAME"
fi

# Setting the gateway again is harmless if it is already set.
openstack router set "$ROUTER_NAME" --external-gateway "$EXTERNAL_NET"
ok "gateway -> $EXTERNAL_NET"

# 'add subnet' errors if the subnet is already attached, which is fine.
if openstack router add subnet "$ROUTER_NAME" "$SUBNET_NAME" 2>/dev/null; then
  made "attached $SUBNET_NAME to $ROUTER_NAME"
else
  ok "subnet already attached (or attach failed; verify below)"
fi

# --- Object storage (optional) ----------------------------------------------
if [[ "${CREATE_BUCKET:-0}" == "1" ]]; then
  log "Object storage container: $BUCKET_NAME"
  if openstack container show "$BUCKET_NAME" >/dev/null 2>&1; then
    ok "container exists"
  else
    openstack container create "$BUCKET_NAME" >/dev/null
    made "$BUCKET_NAME"
  fi
else
  log "Object storage: skipped (CREATE_BUCKET=0)"
fi

# --- Summary ----------------------------------------------------------------
log "Done. Resources ready for up.sh:"
printf '    flavor   : %s\n' "$FLAVOR"
printf '    image    : %s\n' "$IMAGE_ID"
printf '    keypair  : %s\n' "$KEY_NAME"
printf '    sec group: %s (tcp %s from %s)\n' "$SG_NAME" "$SG_TCP_PORTS" "$ALLOWED_CIDR"
printf '    network  : %s / %s via %s -> %s\n' "$NET_NAME" "$SUBNET_NAME" "$ROUTER_NAME" "$EXTERNAL_NET"
