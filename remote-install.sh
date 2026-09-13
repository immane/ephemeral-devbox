#!/usr/bin/env bash
# Fetch ephemeral-devbox and run its bootstrap without a manual clone.
# Pipe-friendly one-liner:
#   curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/main/remote-install.sh | sudo -E bash
# Pin a version for reproducibility (tag or commit SHA):
#   curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/<tag-or-sha>/remote-install.sh | sudo -E bash
#   EPHEMERAL_DEVBOX_REF=<tag-or-sha> curl -fsSL .../main/remote-install.sh | sudo -E bash
#
# Piping a script to bash trusts that ref tip on first use; prefer a tag/SHA
# you have reviewed. Secrets are never part of this loader: prepare
# secrets.env (see secrets.env.example) at $EPHEMERAL_DEVBOX_DIR/secrets.env
# before running, e.g. via scp, or export the variables in the environment.
set -Eeuo pipefail

REPO_URL="${EPHEMERAL_DEVBOX_REPO:-https://github.com/immane/ephemeral-devbox.git}"
REF="${EPHEMERAL_DEVBOX_REF:-main}"
DEST="${EPHEMERAL_DEVBOX_DIR:-/root/ephemeral-devbox}"
CURRENT_STAGE="startup"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf 'ERROR: remote install failed during %s (line %s, exit %s)\n' "$CURRENT_STAGE" "$1" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

require_root() {
  CURRENT_STAGE="system checks"
  [[ $EUID -eq 0 ]] || fail 'Run with sudo -E so required environment variables are preserved.'
}

ensure_git() {
  CURRENT_STAGE="ensuring git"
  command -v git >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || fail 'git is not installed and apt-get is unavailable to install it.'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git ca-certificates
}

clone_or_update() {
  CURRENT_STAGE="fetching ephemeral-devbox"
  if [[ -d "$DEST/.git" ]]; then
    log "Updating existing checkout at $DEST"
    git -C "$DEST" remote set-url origin "$REPO_URL"
    git -C "$DEST" fetch origin
  else
    if [[ -e "$DEST" ]]; then
      [[ -d "$DEST" ]] || fail "$DEST exists and is not a directory; refusing to overwrite it."
      local -a dest_entries
      shopt -s nullglob dotglob
      dest_entries=("$DEST"/*)
      shopt -u nullglob dotglob
      if ((${#dest_entries[@]} == 1)) && [[ "${dest_entries[0]}" == "$DEST/secrets.env" ]]; then
        # Tolerate a pre-staged secrets file: keep it across the clone.
        log "Keeping pre-staged $DEST/secrets.env across the clone"
        local staged_secrets
        staged_secrets="$(mktemp)"
        mv "$DEST/secrets.env" "$staged_secrets"
        rmdir "$DEST"
        log "Cloning $REPO_URL into $DEST"
        git clone "$REPO_URL" "$DEST"
        mv "$staged_secrets" "$DEST/secrets.env"
        chmod 600 "$DEST/secrets.env"
      else
        rmdir "$DEST" 2>/dev/null || fail "$DEST exists and is not a Git checkout; refusing to overwrite it."
        log "Cloning $REPO_URL into $DEST"
        git clone "$REPO_URL" "$DEST"
      fi
    else
      log "Cloning $REPO_URL into $DEST"
      git clone "$REPO_URL" "$DEST"
    fi
    git -C "$DEST" fetch origin
  fi
  if git -C "$DEST" show-ref --verify --quiet "refs/remotes/origin/$REF"; then
    # Branch tip: move the local branch to the fetched tip.
    git -C "$DEST" checkout -f -B "$REF" "origin/$REF"
  else
    # Tag or commit SHA: detached checkout.
    git -C "$DEST" checkout -f --detach "$REF"
  fi
  git -C "$DEST" rev-parse --verify HEAD
}

check_secrets() {
  CURRENT_STAGE="checking secrets"
  [[ -f "$DEST/secrets.env" ]] && return 0
  cat >&2 <<EOF
ERROR: $DEST/secrets.env is missing.
Prepare it first, for example:
  scp secrets.env root@<host>:$DEST/secrets.env
or copy $DEST/secrets.env.example to $DEST/secrets.env and fill in the values.
Alternatively, export the required variables in the environment before piping
this loader (they are preserved with sudo -E).
EOF
  return 1
}

main() {
  require_root
  ensure_git
  clone_or_update
  check_secrets
  chmod +x "$DEST/bootstrap.sh" "$DEST/reset-local.sh"
  log "Running $DEST/bootstrap.sh"
  exec bash "$DEST/bootstrap.sh"
}

main "$@"
