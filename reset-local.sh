#!/usr/bin/env bash
# Remove local ephemeral-devbox state for rebuild testing. This never touches cloud resources.
set -Eeuo pipefail

readonly WORKSPACE="/root/workspace"

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
systemctl disable --now code-server@root 2>/dev/null || true
systemctl disable --now opencode-web 2>/dev/null || true

if command -v tailscale >/dev/null 2>&1; then
  log 'Removing Tailscale Serve rules...'
  tailscale serve reset || log 'Tailscale Serve reset was skipped because Tailscale is unavailable.'
fi

log 'Removing generated configuration and code-server user data...'
rm -rf /root/.config/code-server /root/.config/opencode /root/.local/share/code-server
rm -f /etc/systemd/system/opencode-web.service
rm -f /etc/systemd/resolved.conf.d/90-ephemeral-devbox.conf
systemctl daemon-reload
systemctl restart systemd-resolved 2>/dev/null || true

if [[ -e "$WORKSPACE" ]]; then
  log "Removing $WORKSPACE..."
  rm -rf "$WORKSPACE"
fi

cat <<'EOF'
Local reset completed.

Not removed: installed packages, Docker, Tailscale login/state, Tailscale account/auth keys,
SSH keys, remote Git repositories, ECS resources, cloud disks, or security groups.
EOF
