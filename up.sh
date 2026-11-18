#!/usr/bin/env bash
#
# up.sh - create the VM from the resources prepared by init.sh, give it a
# floating IP, wait until SSH and cloud-init are done, and print how to
# connect. Optionally restores the newest backup from the bucket.
#
# Safe to rerun: an existing server is reused instead of duplicated.

set -euo pipefail
cd "$(dirname "$0")"

[[ -f config.env ]] || { echo "ERROR: config.env not found" >&2; exit 1; }
# shellcheck disable=SC1091
source config.env
[[ -n "${OS_CLOUD:-}" ]] && export OS_CLOUD

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
made() { printf '    created: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# A project-local known_hosts file, so a reused floating IP with a new host
# key never collides with your ~/.ssh/known_hosts. down.sh deletes it.
KNOWN_HOSTS="$PWD/.known_hosts"
SSH_KEY="${SSH_KEY:-${PUBKEY_FILE%.pub}}"
ssh_opts=(
  -i "$SSH_KEY" -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=5 -o LogLevel=ERROR
)

get_fip() {
  local port
  port="$(openstack port list --server "$SERVER_NAME" -f value -c ID | head -n1 || true)"
  [[ -n "$port" ]] || return 0
  openstack floating ip list --port "$port" -f value -c "Floating IP Address" | head -n1 || true
}

# --- Preflight --------------------------------------------------------------
command -v openstack >/dev/null 2>&1 || die "openstack CLI not found"
[[ -f cloud-init.yaml ]] || die "cloud-init.yaml not found next to up.sh"
[[ -f "$SSH_KEY" ]] || die "private key $SSH_KEY not found (set SSH_KEY in config.env)"

log "Checking authentication and init.sh resources"
openstack token issue -f value -c expires >/dev/null 2>&1 \
  || die "cannot authenticate (set OS_CLOUD or source your openrc file)"
openstack keypair show "$KEY_NAME"        >/dev/null 2>&1 || die "keypair $KEY_NAME missing: run ./init.sh"
openstack security group show "$SG_NAME"  >/dev/null 2>&1 || die "security group $SG_NAME missing: run ./init.sh"
openstack network show "$NET_NAME"        >/dev/null 2>&1 || die "network $NET_NAME missing: run ./init.sh"
ok "resources found"

if [[ -z "${EXTERNAL_NET:-}" ]]; then
  EXTERNAL_NET="$(openstack network list --external -f value -c Name | head -n1)"
  [[ -n "$EXTERNAL_NET" ]] || die "no external network found; set EXTERNAL_NET in config.env"
fi

# --- Server -----------------------------------------------------------------
log "Server: $SERVER_NAME"
if openstack server show "$SERVER_NAME" >/dev/null 2>&1; then
  ok "already exists, reusing"
else
  openstack server create "$SERVER_NAME" \
    --flavor "$FLAVOR" \
    --image "$IMAGE_ID" \
    --key-name "$KEY_NAME" \
    --network "$NET_NAME" \
    --security-group "$SG_NAME" \
    --user-data cloud-init.yaml \
    --wait >/dev/null
  made "$SERVER_NAME ($FLAVOR)"
fi

status="$(openstack server show "$SERVER_NAME" -f value -c status)"
[[ "$status" == "ACTIVE" ]] || die "server status is $status, not ACTIVE. Inspect it, or run ./down.sh --no-backup to clean up."
ok "status ACTIVE"

# --- Floating IP ------------------------------------------------------------
log "Floating IP"
fip="$(get_fip)"
if [[ -n "$fip" ]]; then
  ok "already attached: $fip"
else
  fip="$(openstack floating ip create "$EXTERNAL_NET" -f value -c floating_ip_address)"
  openstack server add floating ip "$SERVER_NAME" "$fip"
  made "$fip attached"
fi

# --- Wait for SSH and cloud-init -------------------------------------------
log "Waiting for SSH on $fip"
for i in $(seq 1 60); do
  if ssh "${ssh_opts[@]}" "$SSH_USER@$fip" true 2>/dev/null; then
    ok "SSH is up"
    break
  fi
  [[ "$i" -lt 60 ]] || die "SSH not reachable after 5 minutes (check the security group allows your current IP)"
  sleep 5
done

log "Waiting for cloud-init to finish"
if ssh "${ssh_opts[@]}" "$SSH_USER@$fip" 'cloud-init status --wait' ; then
  ok "cloud-init done"
else
  echo "    warning: cloud-init reported a problem. Check with:"
  echo "    ssh ${ssh_opts[*]} $SSH_USER@$fip 'sudo cat /var/log/cloud-init-output.log'"
fi

# --- Optional restore -------------------------------------------------------
if [[ "${RESTORE_LATEST:-0}" == "1" ]]; then
  log "Restoring newest backup from $BUCKET_NAME"
  command -v age >/dev/null 2>&1 || die "age not installed (needed to decrypt the backup)"
  [[ -f "$AGE_IDENTITY" ]] || die "age identity file $AGE_IDENTITY not found"
  latest="$(openstack object list "$BUCKET_NAME" --prefix backups/ -f value -c Name | sort | tail -n1)"
  if [[ -z "$latest" ]]; then
    echo "    no backups found, skipping"
  else
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    openstack object save --file "$tmp" "$BUCKET_NAME" "$latest"
    parent="$(dirname "$BACKUP_REMOTE_DIR")"
    if [[ "${BACKUP_ENCRYPT:-1}" == "1" ]]; then
      age -d -i "$AGE_IDENTITY" "$tmp" | ssh "${ssh_opts[@]}" "$SSH_USER@$fip" "tar -C '$parent' -xzf -"
    else
      ssh "${ssh_opts[@]}" "$SSH_USER@$fip" "tar -C '$parent' -xzf -" < "$tmp"
    fi
    ok "restored $latest into $parent"
  fi
fi

# --- Summary ----------------------------------------------------------------
log "Ready"
printf '    server : %s (%s)\n' "$SERVER_NAME" "$FLAVOR"
printf '    ip     : %s\n' "$fip"
printf '    ssh    : ssh -i %s -o UserKnownHostsFile=%s %s@%s\n' "$SSH_KEY" "$KNOWN_HOSTS" "$SSH_USER" "$fip"
printf '    stop   : ./down.sh\n'
