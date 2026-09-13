#!/usr/bin/env bash
# Fetch ephemeral-devbox and run its bootstrap without a manual clone.
# Pipe-friendly one-liner:
#   curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/main/remote-install.sh | sudo -E bash
# Pin a version for reproducibility (tag or commit SHA):
#   curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/<tag-or-sha>/remote-install.sh | sudo -E bash
#   export EPHEMERAL_DEVBOX_REF=<tag-or-sha>
#   curl -fsSL .../main/remote-install.sh | sudo -E bash
#
# Piping a script to bash trusts that ref tip on first use; prefer a tag/SHA
# you have reviewed. Secrets are never part of this loader: prepare
# secrets.env (see secrets.env.example) at $EPHEMERAL_DEVBOX_DIR/secrets.env
# before running, e.g. via scp, or export the variables in the environment.
set -Eeuo pipefail

REPO_URL="${EPHEMERAL_DEVBOX_REPO:-https://github.com/immane/ephemeral-devbox.git}"
REF="${EPHEMERAL_DEVBOX_REF:-main}"
DEST="${EPHEMERAL_DEVBOX_DIR:-/root/ephemeral-devbox}"
STAGED_SECRETS_BACKUP=""
CURRENT_STAGE="startup"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf 'ERROR: remote install failed during %s (line %s, exit %s)\n' "$CURRENT_STAGE" "$1" "$exit_code" >&2
  if [[ -n "$STAGED_SECRETS_BACKUP" && -f "$STAGED_SECRETS_BACKUP" && ! -f "$DEST/secrets.env" ]]; then
    mkdir -p "$DEST"
    cp "$STAGED_SECRETS_BACKUP" "$DEST/secrets.env"
    chmod 600 "$DEST/secrets.env"
    printf 'Restored the pre-staged secrets.env to %s; clean up %s manually.\n' "$DEST/secrets.env" "$STAGED_SECRETS_BACKUP" >&2
  fi
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
    # checkout -f below can discard tracked changes and untracked paths that
    # collide with files from the selected ref. The ignored secrets.env is the
    # only local file this loader deliberately permits.
    local local_changes
    local_changes="$(git -C "$DEST" status --porcelain --untracked-files=all --ignored=matching | grep -vE '^(\?\?|!!) secrets\.env$' || true)"
    [[ -z "$local_changes" ]] || fail "$DEST has local changes other than secrets.env; commit, stash, or remove them before updating."
  else
    if [[ -e "$DEST" ]]; then
      [[ -d "$DEST" ]] || fail "$DEST exists and is not a directory; refusing to overwrite it."
      local -a dest_entries
      shopt -s nullglob dotglob
      dest_entries=("$DEST"/*)
      shopt -u nullglob dotglob
      if ((${#dest_entries[@]} == 1)) && [[ "${dest_entries[0]}" == "$DEST/secrets.env" ]]; then
        # Tolerate a pre-staged secrets file: copy it aside (on_error restores
        # it if the clone fails), then put it back after cloning.
        log "Keeping pre-staged $DEST/secrets.env across the clone"
        local staged_secrets
        staged_secrets="$(mktemp)"
        cp "$DEST/secrets.env" "$staged_secrets"
        STAGED_SECRETS_BACKUP="$staged_secrets"
        rmdir "$DEST"
        log "Cloning $REPO_URL into $DEST"
        git clone "$REPO_URL" "$DEST"
        mv "$staged_secrets" "$DEST/secrets.env"
        STAGED_SECRETS_BACKUP=""
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
  # bootstrap.sh falls back to the inherited environment, so proceeding
  # without the file is fine when the required values are already exported.
  if [[ -n "${OPENCODE_GO_KEY:-}" ]]; then
    log 'No secrets.env; proceeding with the inherited environment (bootstrap validates the rest).'
    return 0
  fi
  cat >&2 <<EOF
ERROR: $DEST/secrets.env is missing and OPENCODE_GO_KEY is not exported.
Prepare the file first, for example:
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
