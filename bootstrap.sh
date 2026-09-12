#!/usr/bin/env bash
# Bootstrap a disposable Ubuntu/Debian development machine. Run as root via sudo -E.
set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CODE_SERVER_CONFIG_DIR="/root/.config/code-server"
readonly CODE_SERVER_USER_DIR="/root/.local/share/code-server/User"
readonly OPENCODE_CONFIG_DIR="/root/.config/opencode"
readonly OPENCODE_WEB_ENV="/root/.config/opencode/web.env"
readonly WORKSPACE="/root/workspace"
readonly OPENCODE_SERVICE="/etc/systemd/system/opencode-web.service"
CURRENT_STAGE="startup"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf 'ERROR: bootstrap failed during %s (line %s, exit %s)\n' "$CURRENT_STAGE" "$1" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_root_and_supported_os() {
  CURRENT_STAGE="system checks"
  [[ $EUID -eq 0 ]] || fail 'Run with sudo -E so required environment variables are preserved.'
  [[ -r /etc/os-release ]] || fail 'Cannot identify the operating system: /etc/os-release is missing.'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) fail "This bootstrap supports Ubuntu or Debian, not ${ID:-unknown}." ;;
  esac
}

require_value() {
  local name=$1
  [[ -n "${!name:-}" ]] || fail "$name must be set before bootstrap runs."
}

install_packages() {
  CURRENT_STAGE="installing apt packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl git vim tmux jq ca-certificates openssh-client docker.io npm
  systemctl enable --now docker
}

install_tailscale() {
  CURRENT_STAGE="installing Tailscale"
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled
}

tailscale_connected() {
  tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null
}

connect_tailscale() {
  CURRENT_STAGE="connecting Tailscale"
  if tailscale_connected; then
    log 'Tailscale is already connected; retaining its existing registration.'
    return
  fi

  require_value TS_AUTHKEY
  local -a up_args=(up --auth-key="$TS_AUTHKEY" --hostname=ephemeral-devbox)
  if [[ -n "${TS_TAGS:-}" ]]; then
    up_args+=(--advertise-tags="$TS_TAGS")
  fi
  tailscale "${up_args[@]}"
  tailscale_connected || fail 'Tailscale did not reach the Running state.'
}

install_code_server() {
  CURRENT_STAGE="installing code-server"
  if ! command -v code-server >/dev/null 2>&1; then
    curl -fsSL https://code-server.dev/install.sh | sh
  fi
}

write_code_server_config() {
  CURRENT_STAGE="writing code-server configuration"
  require_value CODE_SERVER_PASSWORD
  install -d -m 700 "$CODE_SERVER_CONFIG_DIR"
  CODE_SERVER_PASSWORD="$CODE_SERVER_PASSWORD" python3 - "$PROJECT_DIR/config/code-server.yaml.template" "$CODE_SERVER_CONFIG_DIR/config.yaml" <<'PY'
import json
import os
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text()
password = os.environ["CODE_SERVER_PASSWORD"]
if "\n" in password or "\r" in password:
    raise SystemExit("CODE_SERVER_PASSWORD must not contain a newline")
if "__CODE_SERVER_PASSWORD__" not in template:
    raise SystemExit("code-server template placeholder is missing")
# JSON strings are valid YAML double-quoted scalars and preserve special characters safely.
Path(sys.argv[2]).write_text(template.replace("__CODE_SERVER_PASSWORD__", json.dumps(password)))
PY
  chmod 600 "$CODE_SERVER_CONFIG_DIR/config.yaml"
  restore_code_server_customizations
  systemctl enable --now code-server@root
  systemctl is-active --quiet code-server@root
}

restore_code_server_customizations() {
  CURRENT_STAGE="restoring code-server customizations"
  install -d -m 700 "$CODE_SERVER_USER_DIR"
  install -m 600 "$PROJECT_DIR/config/code-server-settings.json.template" "$CODE_SERVER_USER_DIR/settings.json"
  install -m 600 "$PROJECT_DIR/config/code-server-keybindings.json.template" "$CODE_SERVER_USER_DIR/keybindings.json"

  local installed extension
  installed=$(code-server --list-extensions 2>/dev/null || true)
  while IFS= read -r extension || [[ -n "$extension" ]]; do
    [[ -z "$extension" || "$extension" == \#* ]] && continue
    if [[ $'\n'"$installed"$'\n' == *$'\n'"$extension"$'\n'* ]]; then
      log "code-server extension already installed: $extension"
      continue
    fi
    log "Installing code-server extension: $extension"
    code-server --install-extension "$extension"
    installed+=$'\n'"$extension"
  done < "$PROJECT_DIR/config/code-server-extensions.txt"
}

install_opencode() {
  CURRENT_STAGE="installing OpenCode"
  if ! command -v opencode >/dev/null 2>&1; then
    curl -fsSL https://opencode.ai/install | bash
  fi
  # The official installer commonly uses this directory before a new login shell is opened.
  export PATH="/root/.opencode/bin:$PATH"
  OPENCODE_BINARY="$(command -v opencode || true)"
  [[ -n "$OPENCODE_BINARY" ]] || fail 'OpenCode installation completed but opencode is not on PATH.'
  OPENCODE_BINARY="$(readlink -f "$OPENCODE_BINARY")"
  export OPENCODE_BINARY
}

write_opencode_config() {
  CURRENT_STAGE="writing OpenCode configuration"
  require_value OPENCODE_GO_KEY
  install -d -m 700 "$OPENCODE_CONFIG_DIR"
  OPENCODE_GO_KEY="$OPENCODE_GO_KEY" \
  GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}" \
  E2B_API_KEY="${E2B_API_KEY:-}" \
  FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-}" \
  python3 - "$PROJECT_DIR/config/opencode.json.template" "$OPENCODE_CONFIG_DIR/opencode.json" <<'PY'
import json
import os
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
data = json.loads(source.read_text())

replacements = {
    "__OPENCODE_GO_KEY__": os.environ["OPENCODE_GO_KEY"],
    "__GITHUB_PERSONAL_ACCESS_TOKEN__": os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"],
    "__E2B_API_KEY__": os.environ["E2B_API_KEY"],
    "__FIRECRAWL_API_KEY__": os.environ["FIRECRAWL_API_KEY"],
}

def replace(value):
    if isinstance(value, dict):
        return {key: replace(item) for key, item in value.items()}
    if isinstance(value, list):
        return [replace(item) for item in value]
    return replacements.get(value, value)

data = replace(data)
destination.write_text(json.dumps(data, indent=2) + "\n")
json.loads(destination.read_text())
PY
  chmod 600 "$OPENCODE_CONFIG_DIR/opencode.json"
}

write_opencode_web_env() {
  CURRENT_STAGE="writing OpenCode Web authentication"
  if [[ -z "${OPENCODE_WEB_PASSWORD:-}" ]]; then
    rm -f "$OPENCODE_WEB_ENV"
    return
  fi
  local username=${OPENCODE_WEB_USERNAME:-opencode}
  OPENCODE_WEB_PASSWORD="$OPENCODE_WEB_PASSWORD" OPENCODE_WEB_USERNAME="$username" \
    python3 - "$OPENCODE_WEB_ENV" <<'PY'
import os
import sys
from pathlib import Path

def quote(value):
    if "\n" in value or "\r" in value:
        raise SystemExit("OpenCode Web credentials must not contain a newline")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

content = "\n".join((
    "OPENCODE_SERVER_PASSWORD=" + quote(os.environ["OPENCODE_WEB_PASSWORD"]),
    "OPENCODE_SERVER_USERNAME=" + quote(os.environ["OPENCODE_WEB_USERNAME"]),
    "",
))
Path(sys.argv[1]).write_text(content)
PY
  chmod 600 "$OPENCODE_WEB_ENV"
}

write_opencode_service() {
  CURRENT_STAGE="creating OpenCode Web service"
  install -d -m 755 "$WORKSPACE"
  OPENCODE_BINARY="$OPENCODE_BINARY" python3 - "$PROJECT_DIR/config/opencode-web.service.template" "$OPENCODE_SERVICE" <<'PY'
import os
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text()
binary = os.environ["OPENCODE_BINARY"]
if "__OPENCODE_BINARY__" not in template:
    raise SystemExit("OpenCode service template placeholder is missing")
Path(sys.argv[2]).write_text(template.replace("__OPENCODE_BINARY__", binary))
PY
  chmod 644 "$OPENCODE_SERVICE"
  systemctl daemon-reload
  systemctl enable --now opencode-web
  systemctl is-active --quiet opencode-web
}

configure_tailscale_serve() {
  CURRENT_STAGE="configuring Tailscale Serve"
  # This machine owns Serve configuration exclusively, so reset avoids stale rules on reruns.
  tailscale serve reset
  tailscale serve --https=443 --bg --yes http://127.0.0.1:8080
  tailscale serve --https=8443 --bg --yes http://127.0.0.1:4096
  tailscale serve status --json >/dev/null
}

configure_git_ssh() {
  CURRENT_STAGE="configuring Git SSH"
  [[ -n "${GIT_SSH_PRIVATE_KEY:-}" ]] || return
  install -d -m 700 /root/.ssh
  if [[ ! -e /root/.ssh/id_ed25519 ]]; then
    (umask 077; printf '%s\n' "$GIT_SSH_PRIVATE_KEY" > /root/.ssh/id_ed25519)
    chmod 600 /root/.ssh/id_ed25519
  else
    warn 'Keeping existing /root/.ssh/id_ed25519; it was not overwritten.'
  fi

  touch /root/.ssh/known_hosts
  chmod 600 /root/.ssh/known_hosts
  local scan merged
  scan=$(mktemp)
  merged=$(mktemp)
  if ssh-keyscan -T 10 -H github.com gitee.com >"$scan" 2>/dev/null; then
    sort -u /root/.ssh/known_hosts "$scan" >"$merged"
    install -m 600 "$merged" /root/.ssh/known_hosts
  else
    warn 'Could not retrieve Git host keys; SSH clone may ask for host verification.'
  fi
  rm -f "$scan"
  rm -f "$merged"
}

prepare_workspace() {
  CURRENT_STAGE="preparing workspace"
  if [[ -z "${GIT_REPO:-}" ]]; then
    install -d -m 755 "$WORKSPACE"
    return
  fi

  if [[ -d "$WORKSPACE/.git" ]]; then
    log "Workspace already contains a Git repository; skipping clone."
    return
  fi
  if [[ -e "$WORKSPACE" ]]; then
    [[ -d "$WORKSPACE" ]] || fail "$WORKSPACE exists and is not a directory; refusing to overwrite it."
    local -a entries
    shopt -s nullglob dotglob
    entries=("$WORKSPACE"/*)
    shopt -u nullglob dotglob
    ((${#entries[@]} == 0)) || fail "$WORKSPACE exists and is not a Git repository; refusing to overwrite it."
  fi
  rmdir "$WORKSPACE" 2>/dev/null || true
  git clone "$GIT_REPO" "$WORKSPACE"
}

serve_url() {
  local port=$1 dns_name
  dns_name=$(tailscale status --json | jq -r '.Self.DNSName // empty')
  dns_name=${dns_name%.}
  [[ -n "$dns_name" ]] || return 1
  if [[ "$port" == 443 ]]; then
    printf 'https://%s\n' "$dns_name"
  else
    printf 'https://%s:%s\n' "$dns_name" "$port"
  fi
}

print_summary() {
  CURRENT_STAGE="printing summary"
  local code_url opencode_url
  code_url=$(serve_url 443 || printf 'Run: tailscale serve status')
  opencode_url=$(serve_url 8443 || printf 'Run: tailscale serve status')
  cat <<EOF
========================================
 Ephemeral Devbox Ready
========================================

Hostname:
ephemeral-devbox

Tailscale:
CONNECTED

Docker:
RUNNING

code-server:
RUNNING

OpenCode Web:
RUNNING

Workspace:
$WORKSPACE

code-server URL:
$code_url

OpenCode URL:
$opencode_url

========================================
EOF
}

main() {
  require_root_and_supported_os
  log '[1/10] Installing packages'
  install_packages
  log '[2/10] Installing Tailscale'
  install_tailscale
  log '[3/10] Connecting Tailscale'
  connect_tailscale
  log '[4/10] Installing and configuring code-server'
  install_code_server
  write_code_server_config
  log '[5/10] Installing OpenCode'
  install_opencode
  log '[6/10] Configuring OpenCode'
  write_opencode_config
  write_opencode_web_env
  log '[7/10] Starting OpenCode Web'
  write_opencode_service
  log '[8/10] Configuring Tailscale Serve'
  configure_tailscale_serve
  log '[9/10] Configuring Git SSH'
  configure_git_ssh
  log '[10/10] Preparing workspace and verifying services'
  prepare_workspace
  systemctl is-active --quiet docker
  systemctl is-active --quiet tailscaled
  systemctl is-active --quiet code-server@root
  systemctl is-active --quiet opencode-web
  print_summary
}

main "$@"
