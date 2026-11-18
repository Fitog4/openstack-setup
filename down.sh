#!/usr/bin/env bash
#
# down.sh - back up BACKUP_REMOTE_DIR from the VM into the bucket, then delete
# the server, its floating IP and any volumes named "<SERVER_NAME>-*", and
# print what is left in the project.
#
# If the backup fails the script stops BEFORE deleting anything.
# It never touches the keypair, security group, network or bucket.
#
# Usage: ./down.sh [-y|--yes] [--no-backup]

set -euo pipefail
cd "$(dirname "$0")"

[[ -f config.env ]] || { echo "ERROR: config.env not found" >&2; exit 1; }
# shellcheck disable=SC1091
source config.env
[[ -n "${OS_CLOUD:-}" ]] && export OS_CLOUD

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ASSUME_YES=0
DO_BACKUP=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes)     ASSUME_YES=1 ;;
    --no-backup)  DO_BACKUP=0 ;;
    -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
    *)            die "unknown option: $arg" ;;
  esac
done

KNOWN_HOSTS="$PWD/.known_hosts"
SSH_KEY="${SSH_KEY:-${PUBKEY_FILE%.pub}}"
ssh_opts=(
  -i "$SSH_KEY" -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=10 -o LogLevel=ERROR
)

tmp=""
trap '[[ -n "$tmp" ]] && rm -f "$tmp"' EXIT

# --- Preflight --------------------------------------------------------------
command -v openstack >/dev/null 2>&1 || die "openstack CLI not found"
openstack token issue -f value -c expires >/dev/null 2>&1 \
  || die "cannot authenticate (set OS_CLOUD or source your openrc file)"

server_exists=0
if openstack server show "$SERVER_NAME" >/dev/null 2>&1; then
  server_exists=1
fi

# Look up the port and floating IPs now, while the server still exists.
port_id=""
fip_ids=""
fip_addr=""
if [[ "$server_exists" == "1" ]]; then
  port_id="$(openstack port list --server "$SERVER_NAME" -f value -c ID | head -n1 || true)"
  if [[ -n "$port_id" ]]; then
    fip_ids="$(openstack floating ip list --port "$port_id" -f value -c ID || true)"
    fip_addr="$(openstack floating ip list --port "$port_id" -f value -c "Floating IP Address" | head -n1 || true)"
  fi
fi

# Validate backup prerequisites BEFORE anything destructive.
if [[ "$server_exists" == "1" && "$DO_BACKUP" == "1" ]]; then
  [[ -n "$fip_addr" ]] || die "server has no floating IP to back up from. Use --no-backup to skip."
  [[ -f "$SSH_KEY" ]]  || die "private key $SSH_KEY not found (set SSH_KEY in config.env)"
  openstack container show "$BUCKET_NAME" >/dev/null 2>&1 \
    || die "container $BUCKET_NAME not found (run ./init.sh with CREATE_BUCKET=1)"
  if [[ "${BACKUP_ENCRYPT:-1}" == "1" ]]; then
    command -v age >/dev/null 2>&1 || die "age not installed (sudo apt install age), or set BACKUP_ENCRYPT=0"
    [[ -n "${AGE_RECIPIENT:-}" ]]  || die "AGE_RECIPIENT is empty. Create a key with: age-keygen -o age-key.txt"
  else
    echo "WARNING: BACKUP_ENCRYPT=0, the backup will be stored UNENCRYPTED." >&2
  fi
fi

# --- Confirm ----------------------------------------------------------------
log "Plan"
if [[ "$server_exists" == "1" ]]; then
  printf '    server %s will be deleted (ip: %s)\n' "$SERVER_NAME" "${fip_addr:-none}"
  if [[ "$DO_BACKUP" == "1" ]]; then
    printf '    %s will be backed up to container %s first\n' "$BACKUP_REMOTE_DIR" "$BUCKET_NAME"
  else
    printf '    NO backup (--no-backup)\n'
  fi
else
  printf '    server %s not found; only cleaning up leftovers\n' "$SERVER_NAME"
fi
printf '    volumes named %s-* will be deleted\n' "$SERVER_NAME"

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# --- Backup -----------------------------------------------------------------
if [[ "$server_exists" == "1" && "$DO_BACKUP" == "1" ]]; then
  log "Backing up $BACKUP_REMOTE_DIR from $fip_addr"
  parent="$(dirname "$BACKUP_REMOTE_DIR")"
  base="$(basename "$BACKUP_REMOTE_DIR")"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  obj="backups/${SERVER_NAME}-${ts}.tar.gz"
  tmp="$(mktemp)"

  if [[ "${BACKUP_ENCRYPT:-1}" == "1" ]]; then
    obj="${obj}.age"
    ssh "${ssh_opts[@]}" "$SSH_USER@$fip_addr" "tar -C '$parent' -czf - '$base'" \
      | age -r "$AGE_RECIPIENT" > "$tmp"
  else
    ssh "${ssh_opts[@]}" "$SSH_USER@$fip_addr" "tar -C '$parent' -czf - '$base'" > "$tmp"
  fi

  [[ -s "$tmp" ]] || die "backup file is empty; nothing was deleted"
  openstack object create "$BUCKET_NAME" "$tmp" --name "$obj" >/dev/null
  ok "uploaded $obj ($(wc -c < "$tmp") bytes)"
fi

# --- Delete -----------------------------------------------------------------
log "Deleting server"
if [[ "$server_exists" == "1" ]]; then
  openstack server delete "$SERVER_NAME" --wait
  ok "server deleted"
else
  ok "no server to delete"
fi

log "Releasing floating IPs"
if [[ -n "$fip_ids" ]]; then
  for id in $fip_ids; do
    openstack floating ip delete "$id"
    ok "released $id"
  done
else
  ok "none attached"
fi

log "Deleting volumes named ${SERVER_NAME}-*"
vol_ids="$(openstack volume list -f value -c ID -c Name \
  | awk -v p="${SERVER_NAME}-" 'index($2, p) == 1 { print $1 }' || true)"
if [[ -n "$vol_ids" ]]; then
  for id in $vol_ids; do
    # A volume can take a few seconds to detach after the server is gone.
    for _ in $(seq 1 30); do
      if openstack volume delete "$id" 2>/dev/null; then
        ok "deleted volume $id"
        break
      fi
      sleep 2
    done
  done
else
  ok "none found"
fi

rm -f "$KNOWN_HOSTS"

# --- Verify -----------------------------------------------------------------
log "What is left in the project (should show no servers, volumes or floating IPs)"
echo "--- servers";      openstack server list -c ID -c Name -c Status
echo "--- volumes";      openstack volume list -c ID -c Name -c Status
echo "--- floating ips"; openstack floating ip list -c ID -c "Floating IP Address" -c Port
