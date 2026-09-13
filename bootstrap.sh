#!/usr/bin/env bash
# Bootstrap a disposable Ubuntu/Debian development machine. Run as root via sudo -E.
set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CODE_SERVER_CONFIG_DIR="/root/.config/code-server"
readonly CODE_SERVER_USER_DIR="/root/.local/share/code-server/User"
readonly EXTERNAL_DNS_DROP_IN="/etc/systemd/resolved.conf.d/90-ephemeral-devbox-external.conf"
readonly GROK_CONFIG_DIR="/root/.grok"
readonly OPENCODE_CONFIG_DIR="/root/.config/opencode"
readonly OPENCODE_WEB_ENV="/root/.config/opencode/web.env"
readonly RELAY_SCRIPT="/usr/local/bin/opencode-go-relay.mjs"
readonly RELAY_SERVICE="/etc/systemd/system/opencode-go-relay.service"
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

load_secrets_env() {
  CURRENT_STAGE="loading secrets"
  local secrets_file="$PROJECT_DIR/secrets.env"
  if [[ -f "$secrets_file" ]]; then
    local meta
    meta=$(stat -c '%a %u' "$secrets_file" 2>/dev/null || printf '')
    case "$meta" in
      '600 0'|'400 0') ;;
      '') fail "Cannot inspect $secrets_file; refusing to load secrets." ;;
      *) fail "$secrets_file must be owned by root with mode 600 or 400 (found: $meta); refusing to source it as root." ;;
    esac
    log "Loading secrets from $secrets_file (values in the file take precedence)."
    set -a
    # shellcheck disable=SC1090
    . "$secrets_file"
    set +a
  else
    log 'No secrets.env next to bootstrap.sh; using the inherited environment.'
  fi
  unexport_secrets
}

unexport_secrets() {
  # Secrets must not leak into child processes (notably the third-party
  # installer shells below). Consumers in this script use shell variables or
  # per-command environment, so unexporting is safe.
  local name
  for name in TS_AUTHKEY TS_TAGS CODE_SERVER_PASSWORD OPENCODE_WEB_PASSWORD OPENCODE_WEB_USERNAME OPENCODE_GO_KEY GIT_SSH_PRIVATE_KEY GIT_REPO GITHUB_PERSONAL_ACCESS_TOKEN E2B_API_KEY FIRECRAWL_API_KEY; do
    export -n "$name" 2>/dev/null || true
  done
}

install_packages() {
  CURRENT_STAGE="installing apt packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl git vim tmux jq ca-certificates openssh-client docker.io npm nodejs
  systemctl enable --now docker
}

configure_external_dns() {
  CURRENT_STAGE="configuring external service DNS"
  install -d -m 755 /etc/systemd/resolved.conf.d
  install -m 644 "$PROJECT_DIR/config/external-dns.conf.template" "$EXTERNAL_DNS_DROP_IN"
  systemctl enable --now systemd-resolved
  systemctl restart systemd-resolved
  systemctl is-active --quiet systemd-resolved
}

fetch_and_run_installer() {
  # Download a third-party installer, verify its SHA256 when a pinned value
  # is provided, and run it. Piping curl to sh can never be fully safe; the
  # *_INSTALL_SHA256 variables (see secrets.env.example) turn a silent
  # compromise into a hard failure, and the hash is always logged for audit.
  local stage=$1 url=$2 sha_var=$3
  shift 3
  CURRENT_STAGE="$stage"
  local tmp expected actual
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$url"
  expected="${!sha_var:-}"
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ -n "$expected" ]]; then
    if [[ "$actual" != "$expected" ]]; then
      rm -f "$tmp"
      fail "Checksum mismatch for $url (sha256=$actual, expected ${sha_var})."
    fi
    log "Verified $url (sha256=$actual)."
  else
    log "WARNING: $sha_var is unset; running $url unverified (sha256=$actual)."
  fi
  bash "$tmp" "$@"
  rm -f "$tmp"
}

install_tailscale() {
  CURRENT_STAGE="installing Tailscale"
  # Installs the binary and enables the daemon only; the daemon is started in
  # connect_tailscale so no Tailscale routes exist before the late connect
  # step (see main), keeping the Alibaba Cloud VPC intranet usable until then.
  if ! command -v tailscale >/dev/null 2>&1; then
    fetch_and_run_installer "installing Tailscale" https://tailscale.com/install.sh TAILSCALE_INSTALL_SHA256
  fi
  systemctl enable tailscaled
}

switch_apt_to_tsinghua() {
  CURRENT_STAGE="switching apt sources to Tsinghua mirrors"
  # Must run before `tailscale up`: after Tailscale routes are installed the
  # Alibaba Cloud VPC intranet mirror is unreachable, so later apt use needs
  # a public mirror. The initial package install stays on the intranet mirror
  # for speed; switch here while intranet access still works.
  # Follows https://mirrors.tuna.tsinghua.edu.cn/help/ubuntu/ : normal suites
  # come from the Tsinghua mirror, security updates stay on the official
  # source because mirror sync delay can postpone security fixes.
  local codename arch mirror_uri os_id
  # shellcheck disable=SC1091
  os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [[ -n "$codename" ]] || fail 'Cannot determine the distribution codename for the mirror switch.'
  arch="$(dpkg --print-architecture 2>/dev/null || printf 'amd64')"
  mirror_uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu'
  case "$arch" in
    arm64|armhf|ppc64el|riscv64|s390x) mirror_uri='https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports' ;;
  esac
  OS_ID="$os_id" CODENAME="$codename" MIRROR_URI="$mirror_uri" python3 - <<'PY'
import glob
import os
from pathlib import Path

os_id = os.environ["OS_ID"]
codename = os.environ["CODENAME"]
mirror = os.environ["MIRROR_URI"]
components = "main restricted universe multiverse"
backup_suffix = ".orig.ephemeral-devbox"

deb822 = Path(os.environ.get("APT_DEB822", "/etc/apt/sources.list.d/ubuntu.sources"))
legacy = Path(os.environ.get("APT_LEGACY", "/etc/apt/sources.list"))
dropins = os.environ.get("APT_DROPINS", "/etc/apt/sources.list.d/*")
keyring = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
tuna_host = "mirrors.tuna.tsinghua.edu.cn"
intranet_markers = ("aliyun", "aliyuncs", "mirrors.cloud.aliyuncs.com")


def backup(path: Path) -> None:
    target = path.with_name(path.name + backup_suffix)
    if path.exists() and not target.exists():
        target.write_bytes(path.read_bytes())


def has_active_intranet_line(text: str) -> bool:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            if any(marker in stripped for marker in intranet_markers):
                return True
    return False


def comment_out_intranet_lines(path: Path) -> bool:
    text = path.read_text()
    changed = False
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and any(m in stripped for m in intranet_markers):
            out.append("# disabled by ephemeral-devbox (intranet mirror unreachable after Tailscale up): " + line)
            changed = True
        else:
            out.append(line)
    if changed:
        backup(path)
        path.write_text("\n".join(out) + ("\n" if out else ""))
    return changed


if os_id == "debian":
    content = (
        f"Types: deb\nURIs: https://{tuna_host}/debian/\n"
        f"Suites: {codename} {codename}-updates {codename}-backports\n"
        f"Components: {components}\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\n"
        f"Types: deb\nURIs: https://{tuna_host}/debian-security/\n"
        f"Suites: {codename}-security\n"
        f"Components: {components}\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n"
    )
    candidates = (
        Path(os.environ.get(
            "APT_DEBIAN_SOURCES",
            "/etc/apt/sources.list.d/debian.sources",
        )),
        deb822,
        legacy,
    )
    target = next((p for p in candidates if p.exists()), candidates[0])
    current = target.read_text() if target.exists() else ""
    backup(target)
    if tuna_host in current:
        print(f"{target} already points to Tsinghua; skipping rewrite")
    else:
        target.write_text(content)
        print(f"Wrote Tsinghua debian sources to {target}")
else:
    if deb822.exists():
        backup(deb822)
        current = deb822.read_text()
        if tuna_host in current and "security.ubuntu.com" in current:
            print(f"{deb822} already points to Tsinghua; skipping rewrite")
        else:
            deb822.write_text(
                f"Types: deb\nURIs: {mirror}\n"
                f"Suites: {codename} {codename}-updates {codename}-backports\n"
                f"Components: {components}\nSigned-By: {keyring}\n\n"
                f"# Security updates stay on the official source: mirror sync delay can\n"
                f"# postpone security fixes (see https://{tuna_host}/help/ubuntu/).\n"
                f"Types: deb\nURIs: http://security.ubuntu.com/ubuntu/\n"
                f"Suites: {codename}-security\n"
                f"Components: {components}\nSigned-By: {keyring}\n"
            )
            print(f"Wrote Tsinghua ubuntu sources to {deb822}")
        if legacy.exists() and has_active_intranet_line(legacy.read_text()):
            comment_out_intranet_lines(legacy)
            print(f"Disabled intranet mirror entries in {legacy}")
    else:
        backup(legacy)
        current = legacy.read_text() if legacy.exists() else ""
        if tuna_host in current:
            print(f"{legacy} already points to Tsinghua; skipping rewrite")
        else:
            legacy.write_text(
                f"# Generated by ephemeral-devbox: Tsinghua mirrors (security stays official).\n"
                f"deb {mirror}/ {codename} {components}\n"
                f"deb {mirror}/ {codename}-updates {components}\n"
                f"deb {mirror}/ {codename}-backports {components}\n"
                f"deb http://security.ubuntu.com/ubuntu/ {codename}-security {components}\n"
            )
            print(f"Wrote Tsinghua ubuntu sources to {legacy}")

for extra in glob.glob(dropins):
    path = Path(extra)
    if path == deb822 or not path.is_file():
        continue
    if path.suffix not in (".list", ".sources"):
        continue
    if has_active_intranet_line(path.read_text()):
        comment_out_intranet_lines(path)
        print(f"Disabled intranet mirror entries in {path}")
PY
  apt-get update
}

tailscale_connected() {
  tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null
}

connect_tailscale() {
  CURRENT_STAGE="connecting Tailscale"
  # Starting the daemon here (not in install_tailscale) guarantees no
  # Tailscale routes are installed before this late step, even on machines
  # with persisted Tailscale state that would otherwise auto-reconnect.
  systemctl enable --now tailscaled
  if tailscale_connected; then
    log 'Tailscale is already connected; retaining its existing registration.'
    return
  fi

  require_value TS_AUTHKEY
  # A previous failed `tailscale up` can leave non-default flags behind.
  # This branch only runs while disconnected, so reset is safe and makes retries reliable.
  local -a up_args=(up --reset --auth-key="$TS_AUTHKEY" --hostname=ephemeral-devbox)
  if [[ -n "${TS_TAGS:-}" ]]; then
    up_args+=(--advertise-tags="$TS_TAGS")
  fi
  tailscale "${up_args[@]}"
  tailscale_connected || fail 'Tailscale did not reach the Running state.'
}

install_code_server() {
  CURRENT_STAGE="installing code-server"
  if ! command -v code-server >/dev/null 2>&1; then
    fetch_and_run_installer "installing code-server" https://code-server.dev/install.sh CODE_SERVER_INSTALL_SHA256
  fi
}

write_code_server_config() {
  CURRENT_STAGE="writing code-server configuration"
  install -d -m 700 "$CODE_SERVER_CONFIG_DIR"
  CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:-}" python3 - "$PROJECT_DIR/config/code-server.yaml.template" "$CODE_SERVER_CONFIG_DIR/config.yaml" <<'PY'
import json
import os
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text()
password = os.environ["CODE_SERVER_PASSWORD"]
if "\n" in password or "\r" in password:
    raise SystemExit("CODE_SERVER_PASSWORD must not contain a newline")
if "__CODE_SERVER_AUTH__" not in template or "__CODE_SERVER_PASSWORD__" not in template:
    raise SystemExit("code-server template placeholders are missing")
# JSON strings are valid YAML double-quoted scalars and preserve special characters safely.
config = template.replace("__CODE_SERVER_AUTH__", "password" if password else "none")
if password:
    config = config.replace("__CODE_SERVER_PASSWORD__", json.dumps(password))
else:
    config = config.replace("password: __CODE_SERVER_PASSWORD__\n", "")
Path(sys.argv[2]).write_text(config)
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

  local installed extension tmp_vsix
  installed=$(code-server --list-extensions 2>/dev/null || true)
  while IFS= read -r extension || [[ -n "$extension" ]]; do
    extension="${extension%$'\r'}"
    [[ -z "$extension" || "$extension" == \#* ]] && continue
    if [[ "$extension" == http://* || "$extension" == https://* ]]; then
      log "Installing code-server extension from VSIX URL: $extension"
      tmp_vsix="$(mktemp --suffix=.vsix)"
      if curl -fSL -o "$tmp_vsix" "$extension" && code-server --install-extension "$tmp_vsix"; then
        log "Installed code-server extension from VSIX URL: $extension"
      else
        warn "Failed to install code-server extension from VSIX URL: $extension (skipping)"
      fi
      rm -f "$tmp_vsix"
      continue
    fi
    if [[ $'\n'"$installed"$'\n' == *$'\n'"$extension"$'\n'* ]]; then
      log "code-server extension already installed: $extension"
      continue
    fi
    log "Installing code-server extension: $extension"
    if ! code-server --install-extension "$extension"; then
      warn "Failed to install code-server extension: $extension (skipping)"
      continue
    fi
    installed+=$'\n'"$extension"
  done < "$PROJECT_DIR/config/code-server-extensions.txt"
}

install_opencode() {
  CURRENT_STAGE="installing OpenCode"
  # The official installer commonly uses this directory before a new login shell is opened.
  export PATH="/root/.opencode/bin:$PATH"
  if ! command -v opencode >/dev/null 2>&1; then
    fetch_and_run_installer "installing OpenCode" https://opencode.ai/install OPENCODE_INSTALL_SHA256
  fi
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

install_grok() {
  CURRENT_STAGE="installing Grok Build"
  # The x.ai installer targets $HOME/.grok/bin (i.e. /root/.grok/bin as root)
  # and symlinks into /usr/local/bin when it is on PATH and writable.
  export PATH="/root/.grok/bin:/root/.local/bin:/usr/local/bin:$PATH"
  if ! command -v grok >/dev/null 2>&1; then
    if [[ -n "${GROK_VERSION:-}" ]]; then
      fetch_and_run_installer "installing Grok Build" https://x.ai/cli/install.sh GROK_INSTALL_SHA256 "$GROK_VERSION"
    else
      fetch_and_run_installer "installing Grok Build" https://x.ai/cli/install.sh GROK_INSTALL_SHA256
    fi
  fi
  GROK_BINARY="$(command -v grok || true)"
  [[ -n "$GROK_BINARY" ]] || fail 'Grok installation completed but grok is not on PATH.'
  GROK_BINARY="$(readlink -f "$GROK_BINARY")"
  export GROK_BINARY
}

write_grok_config() {
  CURRENT_STAGE="writing Grok configuration"
  require_value OPENCODE_GO_KEY
  install -d -m 700 "$GROK_CONFIG_DIR"
  OPENCODE_GO_KEY="$OPENCODE_GO_KEY" python3 - "$PROJECT_DIR/config/grok-config.toml.template" "$GROK_CONFIG_DIR/config.toml" <<'PY'
import os
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text()
key = os.environ["OPENCODE_GO_KEY"]
if "\n" in key or "\r" in key:
    raise SystemExit("OPENCODE_GO_KEY must not contain a newline")
if "__OPENCODE_GO_KEY__" not in template:
    raise SystemExit("Grok config template placeholder is missing")
Path(sys.argv[2]).write_text(template.replace("__OPENCODE_GO_KEY__", key))
PY
  chmod 600 "$GROK_CONFIG_DIR/config.toml"
}

write_opencode_go_relay() {
  CURRENT_STAGE="creating OpenCode Go relay service"
  command -v node >/dev/null 2>&1 || fail 'node is required for opencode-go-relay but is not on PATH.'
  install -m 755 "$PROJECT_DIR/config/opencode-go-relay.mjs.template" "$RELAY_SCRIPT"
  node --check "$RELAY_SCRIPT"
  install -m 644 "$PROJECT_DIR/config/opencode-go-relay.service.template" "$RELAY_SERVICE"
  systemctl daemon-reload
  systemctl enable --now opencode-go-relay
  systemctl is-active --quiet opencode-go-relay
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
  [[ -n "${GIT_SSH_PRIVATE_KEY:-}" ]] || return 0
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

OpenCode Go Relay:
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
  load_secrets_env
  require_root_and_supported_os
  log '[1/12] Installing packages'
  install_packages
  log '[2/12] Configuring external service DNS'
  configure_external_dns
  log '[3/12] Installing Tailscale (binary only; connection deferred to the end)'
  install_tailscale
  log '[4/12] Installing and configuring code-server'
  install_code_server
  write_code_server_config
  log '[5/12] Installing OpenCode'
  install_opencode
  log '[6/12] Configuring OpenCode'
  write_opencode_config
  write_opencode_web_env
  log '[7/12] Starting OpenCode Web'
  write_opencode_service
  log '[8/12] Installing Grok Build and starting OpenCode Go relay'
  install_grok
  write_grok_config
  write_opencode_go_relay
  log '[9/12] Configuring Git SSH and preparing workspace'
  configure_git_ssh
  prepare_workspace
  # Switch apt to public mirrors before connecting Tailscale: once connected,
  # Tailscale routes conflict with the Alibaba Cloud VPC intranet, dropping
  # intranet SSH and making the intranet apt mirror unreachable.
  log '[10/12] Switching apt sources to Tsinghua mirrors'
  switch_apt_to_tsinghua
  # Connect Tailscale as late as possible: once connected, Tailscale routes
  # conflict with the Alibaba Cloud VPC intranet and drop an intranet SSH
  # session, so all intranet-dependent work above must finish first.
  log '[11/12] Connecting Tailscale'
  connect_tailscale
  log '[12/12] Configuring Tailscale Serve and verifying services'
  configure_tailscale_serve
  systemctl is-active --quiet docker
  systemctl is-active --quiet tailscaled
  systemctl is-active --quiet code-server@root
  systemctl is-active --quiet opencode-web
  systemctl is-active --quiet opencode-go-relay
  print_summary
}

main "$@"
