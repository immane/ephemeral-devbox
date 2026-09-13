#!/usr/bin/env bash
# Remove local ephemeral-devbox state for rebuild testing. This never touches cloud resources.
set -Eeuo pipefail

readonly DEVBOX_HOME="/home/devbox"
readonly WORKSPACE="$DEVBOX_HOME/workspace"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail 'Run with sudo ./reset-local.sh [--force].'

force=false
case "${1:-}" in
  '') ;;
  --force) force=true ;;
  *) fail 'Usage: reset-local.sh [--force]' ;;
esac

if [[ -e "$WORKSPACE" ]] && [[ "$force" != true ]]; then
  if [[ ! -t 0 ]]; then
    fail "$WORKSPACE would be deleted. Re-run with --force in non-interactive mode."
  fi
  read -r -p "Delete $WORKSPACE and local service configuration? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || { log 'Cancelled.'; exit 0; }
fi

log 'Stopping local services...'
systemctl disable --now code-server@devbox code-server@root 2>/dev/null || true
systemctl disable --now opencode-web 2>/dev/null || true
systemctl disable --now opencode-go-relay 2>/dev/null || true

if command -v tailscale >/dev/null 2>&1; then
  log 'Removing Tailscale Serve rules...'
  tailscale serve reset || log 'Tailscale Serve reset was skipped because Tailscale is unavailable.'
fi

log 'Removing generated configuration and code-server user data...'
rm -rf "$DEVBOX_HOME/.config/code-server" "$DEVBOX_HOME/.local/share/code-server" "$DEVBOX_HOME/.config/opencode" "$DEVBOX_HOME/.grok"
rm -f /etc/systemd/system/opencode-web.service
rm -f /etc/systemd/system/opencode-go-relay.service
rm -f /usr/local/bin/opencode-go-relay.mjs
rm -f /etc/systemd/resolved.conf.d/90-ephemeral-devbox-external.conf
log 'Restoring original apt sources...'
restored=false
for marker in /etc/apt/sources.list.created.ephemeral-devbox /etc/apt/sources.list.d/*.created.ephemeral-devbox; do
  [[ -e "$marker" ]] || continue
  rm -f "${marker%.created.ephemeral-devbox}" "$marker"
  log "Removed generated ${marker%.created.ephemeral-devbox}"
  restored=true
done
for backup in /etc/apt/sources.list.orig.ephemeral-devbox /etc/apt/sources.list.d/*.orig.ephemeral-devbox; do
  [[ -e "$backup" ]] || continue
  mv -f "$backup" "${backup%.orig.ephemeral-devbox}"
  log "Restored ${backup%.orig.ephemeral-devbox}"
  restored=true
done
[[ "$restored" == true ]] || log 'No apt backups to restore.'
systemctl daemon-reload
systemctl restart systemd-resolved 2>/dev/null || true

if [[ -e "$WORKSPACE" ]]; then
  log "Removing $WORKSPACE..."
  rm -rf "$WORKSPACE"
fi

cat <<'EOF'
Local reset completed.

Not removed: installed apt packages, Docker, Tailscale login/state, Tailscale account/auth keys,
SSH keys, remote Git repositories, ECS resources, cloud disks, or security groups.
EOF
