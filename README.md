# ephemeral-devbox

`ephemeral-devbox` bootstraps a disposable Ubuntu development machine for an Alibaba Cloud ECS spot instance. It uses scripts and Git as the durable source of truth rather than images, snapshots, a fixed public IP, or a fixed Tailscale IP.

## Quickstart

After providing secrets by either option below, this single command fetches the repository and runs bootstrap without a manual clone:

```bash
curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/main/remote-install.sh | sudo -E bash
```

`remote-install.sh` installs git when missing, clones (or updates a clean checkout of) the repository to `/root/ephemeral-devbox`, checks out the ref, refuses to overwrite a non-Git directory or a checkout with local changes other than the ignored `secrets.env`, requires `secrets.env` (or an exported `OPENCODE_GO_KEY`), and then execs `bootstrap.sh`. Two ways to provide secrets (pick one):

```bash
# Option A: stage the file before cloning (it is kept across the clone, mode 600)
mkdir -p /root/ephemeral-devbox
scp secrets.env root@<host>:/root/ephemeral-devbox/secrets.env
curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/main/remote-install.sh | sudo -E bash

# Option B: have root source a local file, then run the loader with those values
sudo bash -c 'set -a; . "$1"; set +a; curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/main/remote-install.sh | bash' bash "$PWD/secrets.env"
```

Option B works even when `secrets.env` is `root:root` with mode `600`, and does not depend on `sudo -E` preserving custom environment variables. The loader receives the sourced values, then `bootstrap.sh` falls back to that inherited environment because no `secrets.env` exists in its checkout.

Pin a reviewed version for reproducibility instead of tracking `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/<tag-or-sha>/remote-install.sh | sudo -E bash
export EPHEMERAL_DEVBOX_REF=<tag-or-sha>
curl -fsSL https://raw.githubusercontent.com/immane/ephemeral-devbox/main/remote-install.sh | sudo -E bash
```

(The `export` must precede the pipeline: prefixing `curl` would scope the variable to `curl` only, not to the shell running the loader.)

`EPHEMERAL_DEVBOX_REPO`, `EPHEMERAL_DEVBOX_REF` (branch, tag, or commit SHA), and `EPHEMERAL_DEVBOX_DIR` override the defaults. Piping to bash trusts that ref tip on first use; prefer a tag or SHA you have reviewed.

## Architecture

```
Tailnet device
    |
    +-- HTTPS 443  -> Tailscale Serve -> 127.0.0.1:8081 -> Nginx PWA proxy -> 127.0.0.1:8080 -> code-server
    |
    +-- HTTPS 8443 -> Tailscale Serve -> 127.0.0.1:4096 -> OpenCode Web

On the host itself (never exposed):

grok CLI (devbox) -> 127.0.0.1:8787 -> OpenCode Go relay -> opencode.ai
```

Both web services bind only to loopback. Nginx also binds only to `127.0.0.1:8081`; it wraps code-server with a standalone PWA manifest, a non-translucent black status bar, and a nearly transparent full-viewport layer that suppresses the iPadOS Web App status-bar gradient. Tailscale Serve publishes the services only inside the tailnet using the node's MagicDNS name, not its `100.x` address. SSH should likewise be used through Tailscale; do not open port 22, 8080, 8081, 4096, 8443, or 8787 to the public internet.

After apt packages are installed through the ECS DHCP DNS, bootstrap adds `/etc/systemd/resolved.conf.d/90-ephemeral-devbox-external.conf` (see `config/external-dns.conf.template`). It routes `tailscale.com`, `code-server.dev`, `opencode.ai`, `x.ai` (plus the installer fallback `storage.googleapis.com`), `github.com` (plus `githubusercontent.com` and `githubassets.com`), `npmjs.org`, the Tsinghua mirror (`mirrors.tuna.tsinghua.edu.cn`), and Ubuntu security (`security.ubuntu.com`) to `1.1.1.1` and `8.8.8.8`. It deliberately does not use `Domains=~.`, so Alibaba Ubuntu mirror domains keep using the ECS `100.100.2.x` DNS servers during the initial install.

The node hostname is always `ephemeral-devbox`. Create a reusable, ephemeral Tailscale auth key with a 90-day expiration. Each newly created ECS registers as a new ephemeral node and can be deleted when the ECS is destroyed. A normal reboot retains this ECS's local Tailscale state and reconnects automatically without registering a new node. If the previous registration was released, deleted, or expired while the machine was off, bootstrap persists the auth key to `/etc/ephemeral-devbox/tailscale-auth.env` (mode `600`, `root:root`) and installs the `ephemeral-devbox-tailscale-reconnect` service (runs at boot) plus timer (1 minute after boot, then every 5 minutes) to re-register as `ephemeral-devbox` and recreate the Serve routes automatically.

## Persistent Data

The server is disposable. Keep durable work in:

- Git repositories
- This repository's bootstrap scripts and configuration templates
- Your securely stored secrets

The server itself, local workspace, installed tools, and unpushed files are intentionally not preserved. Push important work before deleting an instance.

code-server editor preferences, keybindings, and extension IDs are recreated from `config/code-server-settings.json.template`, `config/code-server-keybindings.json.template`, and `config/code-server-extensions.txt`. The settings template selects the `Moss & Stone` color theme with `material-icon-theme` icons, and enables terminal images (`terminal.integrated.enableImages`) with GPU acceleration set to `auto`. The keybindings template keeps `cmd+c` as copy when Vim is active. The extensions file installs the OpenCode Go provider (via VSIX URL while it is absent from OpenVSX), `vscodevim.vim`, and the `tapetum`, `omi-theme`, and `atmospheres` theme packs. Existing extensions are skipped on rerun. Extension caches, workspace state, session data, and `globalStorage` are intentionally not retained.

## Requirements

- Ubuntu 24.04 or 26.04 LTS (Debian is also accepted by the OS guard)
- An ECS with outbound internet access during bootstrap
- A Tailscale tailnet with MagicDNS and HTTPS available
- A reusable, ephemeral Tailscale auth key
- An OpenCode Go API key

Tailscale Serve obtains a certificate for the node's tailnet DNS name. If this is the first HTTPS-enabled node, follow any approval prompt or policy requirement in the Tailscale admin console.

## Bootstrap

Clone this repository on the new ECS, then create the ignored secrets file:

```bash
git clone https://github.com/immane/ephemeral-devbox.git
cd ephemeral-devbox
cp secrets.env.example secrets.env
vim secrets.env
sudo chown root:root secrets.env
sudo chmod 600 secrets.env
sudo -E ./bootstrap.sh
```

`bootstrap.sh` automatically sources `secrets.env` from its own directory when the file exists, so there is no need to source it manually beforehand. Values in the file take precedence over the inherited environment. The file must be owned by root with mode `600` or `400`; bootstrap refuses to load it otherwise. Exported secrets are unexported before any third-party installer runs, so installer shells never inherit them.

Make scripts executable after a fresh clone if Git did not preserve their mode:

```bash
chmod +x bootstrap.sh reset-local.sh remote-install.sh
```

`bootstrap.sh` installs apt packages (including `kitty` for terminal image output via `kitty +kitten icat`), Docker, Tailscale, Nginx, code-server, OpenCode, and Grok Build. code-server, OpenCode Web, Grok Build, the relay, Git SSH credentials, and `/home/devbox/workspace` all run as the dedicated unprivileged `devbox` user. Nginx remains a root-managed loopback-only proxy that injects the standalone PWA, a non-translucent status bar, and a nearly transparent full-viewport layer to suppress the iPadOS Web App gradient; the packaged public port-80 site is disabled. Grok uses a relay-backed default model (`deepseek-flash` at `http://127.0.0.1:8787`, systemd service `opencode-go-relay`) with the `terminal` theme and `terminal_theme` feature enabled. The same MCP servers declared in `config/opencode.json.template` (filesystem, obsidian, github, sequential-thinking, agentmemory, duckduckgo, e2b-sandbox, firecrawl, playwright-browser, context7) are mirrored into `config/grok-config.toml.template`, because the relay proxies only LLM inference and never forwards MCP tools. Bootstrap stops any persisted Tailscale daemon before setup, clones the workspace, switches apt sources from the Alibaba Cloud intranet mirror to Tsinghua mirrors, and only then starts and connects Tailscale. This preserves the Alibaba VPC connection until all intranet-dependent work finishes. Original apt files are backed up once alongside the originals with an `.orig.ephemeral-devbox` suffix. Ubuntu normal suites come from `mirrors.tuna.tsinghua.edu.cn` while security updates stay on official `security.ubuntu.com`; Debian uses Tsinghua's Debian and Debian security mirrors. It is designed to be rerun safely. As this is a single-purpose disposable host, each run resets the node's Tailscale Serve configuration before recreating the two expected routes.

When Tailscale is disconnected, bootstrap uses `tailscale up --reset` before authenticating. This only clears stale local `tailscale up` flags left by a failed prior attempt; an already connected node is not re-registered.

Before starting code-server, bootstrap restores the tracked editor settings and keybindings, then installs each extension listed in `config/code-server-extensions.txt`. Existing extensions are skipped and a single failed install only warns and continues. To add an extension, append its marketplace ID or VSIX URL on a new line and rerun bootstrap.

## Secrets

`secrets.env` is ignored by Git. Set only the values you use:

```bash
export TS_AUTHKEY=''
export TS_TAGS='tag:dev'
export CODE_SERVER_PASSWORD=''
export OPENCODE_WEB_PASSWORD=''
export OPENCODE_WEB_USERNAME='opencode'
export OPENCODE_GO_KEY=''
export GIT_SSH_PRIVATE_KEY=''
export GIT_REPO='git@gitee.com:organization/project.git'
export GITHUB_PERSONAL_ACCESS_TOKEN=''
export E2B_API_KEY=''
export FIRECRAWL_API_KEY=''
# Optional: pin third-party installer scripts by SHA256.
# export TAILSCALE_INSTALL_SHA256=''
# export CODE_SERVER_INSTALL_SHA256=''
# export OPENCODE_INSTALL_SHA256=''
# export GROK_INSTALL_SHA256=''
# Optional: install a specific Grok Build version instead of latest stable.
# export GROK_VERSION=''
```

- `TS_AUTHKEY` is required only when the node is not already logged in to Tailscale. When provided, it is also persisted to `/etc/ephemeral-devbox/tailscale-auth.env` (mode `600`) so the boot/timer healing service can re-register the node after the previous registration was released, deleted, or expired. Rerunning bootstrap without it keeps the existing persisted key.
- `TS_TAGS` is optional. It is passed as `--advertise-tags` when set.
- `CODE_SERVER_PASSWORD` is optional. Leave it empty to rely on tailnet-only access; set it to additionally protect code-server with its built-in password prompt.
- `OPENCODE_GO_KEY` is required. It is also reused as the API key for the relay-backed model in the Grok configuration.
- `OPENCODE_WEB_PASSWORD` is optional. Leave it empty to rely on tailnet-only access; set it to additionally protect OpenCode Web with HTTP Basic Auth. `OPENCODE_WEB_USERNAME` defaults to `opencode`. When enabled, credentials are stored in an owner-only environment file, never in the systemd unit.
- `GIT_SSH_PRIVATE_KEY` is optional. It must be an unencrypted PEM or OpenSSH private key. Bootstrap normalizes CRLF and one-line literal `\n` values, validates it with `ssh-keygen`, and writes it to `/home/devbox/.ssh/id_ed25519` with restrictive permissions. A malformed existing key is backed up as `id_ed25519.invalid-<timestamp>` and replaced; a valid existing key is retained.
- `GIT_REPO` is optional. When it is set, the repository is cloned to `/home/devbox/workspace`; an existing checkout is left unchanged.
- `GITHUB_PERSONAL_ACCESS_TOKEN`, `E2B_API_KEY`, and `FIRECRAWL_API_KEY` are optional credentials for the github, e2b-sandbox, and firecrawl MCP servers. They are mirrored into both OpenCode (`opencode.json`) and Grok (`config.toml`); the remaining MCP servers (filesystem, obsidian, sequential-thinking, agentmemory, duckduckgo, playwright-browser, context7) need no keys.
- `TAILSCALE_INSTALL_SHA256`, `CODE_SERVER_INSTALL_SHA256`, `OPENCODE_INSTALL_SHA256`, and `GROK_INSTALL_SHA256` are optional installer pins. When set, bootstrap verifies the downloaded installer SHA256 before running it; when unset, the hash is logged and the installer runs unverified.
- `GROK_VERSION` is optional. When set, that exact Grok Build version is installed instead of latest stable.

Secrets are never embedded in templates, systemd units, README examples, or script logs. OpenCode keys are stored only in `/home/devbox/.config/opencode/opencode.json` with mode `0600`; the mirrored MCP keys plus the relay model key are stored in `/home/devbox/.grok/config.toml` with mode `0600`; OpenCode Web credentials are stored in `/home/devbox/.config/opencode/web.env` with mode `0600`.

## Access

At completion, bootstrap prints URLs built from the current MagicDNS name. Typical URLs are:

```text
https://ephemeral-devbox.<tailnet>.ts.net/
https://ephemeral-devbox.<tailnet>.ts.net:8443/
```

Use the first for code-server and the second for OpenCode Web. The exact MagicDNS suffix varies by tailnet; inspect it with:

```bash
tailscale serve status
tailscale status --json | jq -r '.Self.DNSName'
```

SSH from another tailnet device using MagicDNS:

```bash
ssh root@ephemeral-devbox.<tailnet>.ts.net
```

Use an SSH key, ACLs, and Tailscale SSH according to your tailnet policy. This project does not alter public firewall rules or cloud security groups.

## Destroy And Recreate

1. Commit and push all work from `/home/devbox/workspace`.
2. Before releasing the ECS, run `sudo tailscale logout`. For an ephemeral node this immediately removes it from the tailnet and frees the `ephemeral-devbox` MagicDNS hostname, so the next instance does not become `ephemeral-devbox-1`.
3. Delete the ECS instance and any ephemeral disk you no longer need.
4. Create a new Ubuntu ECS when needed.
5. Repeat the bootstrap procedure with the same safely stored secrets.

Do not retain a custom image or a large snapshot. If you skip `tailscale logout`, the old ephemeral node is only removed after it goes offline, subject to Tailscale's normal cleanup timing; a stale `ephemeral-devbox` entry can force the replacement to use a suffixed hostname. A normal reboot does not need logout: the same ECS keeps its local Tailscale state and reconnects automatically. If the old node was already gone, the reconnect service/timer re-registers it on boot (and retries every 5 minutes) as long as the persisted key is still valid; check with `systemctl status ephemeral-devbox-tailscale-reconnect.service` and `systemctl status ephemeral-devbox-tailscale-reconnect.timer`.

## Local Reset Testing

Use `reset-local.sh` only on a test machine to test rebuilds:

```bash
sudo ./reset-local.sh
sudo ./reset-local.sh --force
```

It stops code-server, Nginx, OpenCode Web, and the OpenCode Go relay; removes the generated code-server PWA proxy and manifest; clears the `devbox` generated configuration and code-server user data (including installed extensions); removes `/home/devbox/.grok` (configuration and the installed Grok binary); restores original apt sources from `.orig.ephemeral-devbox` backups when present and removes generated apt sources tracked by `.created.ephemeral-devbox` markers; removes the external DNS drop-in, removes Tailscale Serve rules, and deletes `/home/devbox/workspace` after confirmation (or with `--force`). It deliberately does not uninstall packages; delete Tailscale login state; alter the Tailscale account or auth key; delete SSH keys; touch remote Git repositories; call Alibaba Cloud APIs; delete ECS instances/disks; or change security groups.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Tailscale cannot connect | Confirm `TS_AUTHKEY` is valid, reusable, ephemeral, and tag-authorized. Run `systemctl status tailscaled` and `tailscale status`. If the node was released while offline, the healing unit retries automatically: `systemctl status ephemeral-devbox-tailscale-reconnect.service`, `journalctl -u ephemeral-devbox-tailscale-reconnect -e` (key never logged), and `sudo stat -c '%a %u %g' /etc/ephemeral-devbox/tailscale-auth.env` ownership/mode check (must be `600 0 0`). |
| Serve URL does not work | Confirm MagicDNS/HTTPS access and run `tailscale serve status`. Check tailnet ACLs. |
| code-server unavailable | Run `systemctl status code-server@devbox` and inspect `/home/devbox/.config/code-server/config.yaml` permissions. |
| OpenCode Web unavailable | Run `systemctl status opencode-web`; `journalctl -u opencode-web -e` shows runtime errors without exposing config values. |
| OpenCode Go relay unavailable | Run `systemctl status opencode-go-relay`; `journalctl -u opencode-go-relay -e` shows relay errors. Confirm node is installed and port 8787 is listening with `ss -ltnp | grep 8787`. |
| Grok model call fails | Confirm the relay is running and `/home/devbox/.grok/config.toml` points at `http://127.0.0.1:8787/v1`. Test the relay directly with `curl http://127.0.0.1:8787/v1/models`. |
| Git SSH clone fails | Check `sudo -u devbox ssh-keygen -y -f /home/devbox/.ssh/id_ed25519`; if it fails, inspect any `id_ed25519.invalid-*` backup and correct `GIT_SSH_PRIVATE_KEY`. Then confirm repository access as the service user: `sudo -u devbox ssh -T git@github.com` or `sudo -u devbox ssh -T git@gitee.com`. |
| Bootstrap refuses workspace | Move or remove the non-Git `/home/devbox/workspace` directory rather than allowing the script to overwrite files. |
