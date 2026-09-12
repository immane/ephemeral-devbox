# ephemeral-devbox

`ephemeral-devbox` bootstraps a disposable Ubuntu development machine for an Alibaba Cloud ECS spot instance. It uses scripts and Git as the durable source of truth rather than images, snapshots, a fixed public IP, or a fixed Tailscale IP.

## Architecture

```
Tailnet device
    |
    +-- HTTPS 443  -> Tailscale Serve -> 127.0.0.1:8080 -> code-server
    |
    +-- HTTPS 8443 -> Tailscale Serve -> 127.0.0.1:4096 -> OpenCode Web
```

Both web services bind only to loopback. Tailscale Serve publishes them only inside the tailnet using the node's MagicDNS name, not its `100.x` address. SSH should likewise be used through Tailscale; do not open port 22, 8080, 4096, or 8443 to the public internet.

After apt packages are installed through the ECS DHCP DNS, bootstrap adds `/etc/systemd/resolved.conf.d/90-ephemeral-devbox-external.conf`. It routes only Tailscale, code-server, OpenCode, GitHub, and npm domains to `1.1.1.1` and `8.8.8.8`. It deliberately does not use `Domains=~.`, so Alibaba Ubuntu mirror domains keep using the ECS `100.100.2.x` DNS servers.

The node hostname is always `ephemeral-devbox`. Create a reusable, ephemeral Tailscale auth key with a 90-day expiration. Each newly created ECS registers as a new ephemeral node and can be deleted when the ECS is destroyed. A normal reboot retains this ECS's local Tailscale state and reconnects automatically without registering a new node.

## Persistent Data

The server is disposable. Keep durable work in:

- Git repositories
- This repository's bootstrap scripts and configuration templates
- Your securely stored secrets

The server itself, local workspace, installed tools, and unpushed files are intentionally not preserved. Push important work before deleting an instance.

code-server editor preferences, keybindings, and extension IDs are recreated from `config/code-server-settings.json.template`, `config/code-server-keybindings.json.template`, and `config/code-server-extensions.txt`. Extension caches, workspace state, session data, and `globalStorage` are intentionally not retained.

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
git clone <PRIVATE_REPO>
cd ephemeral-devbox
cp secrets.env.example secrets.env
vim secrets.env
source secrets.env
sudo -E ./bootstrap.sh
```

Make scripts executable after a fresh clone if Git did not preserve their mode:

```bash
chmod +x bootstrap.sh reset-local.sh
```

`bootstrap.sh` installs apt packages, Docker, Tailscale, code-server, and OpenCode. It writes root-only code-server and OpenCode configurations, starts both services, and creates two persistent Tailscale Serve routes. It is designed to be rerun safely. As this is a single-purpose disposable host, each run resets the node's Tailscale Serve configuration before recreating the two expected routes.

When Tailscale is disconnected, bootstrap uses `tailscale up --reset` before authenticating. This only clears stale local `tailscale up` flags left by a failed prior attempt; an already connected node is not re-registered.

Before starting code-server, bootstrap restores the tracked editor settings and keybindings, then installs each extension listed in `config/code-server-extensions.txt`. Existing extensions are skipped. To add an extension, append its marketplace ID on a new line and rerun bootstrap.

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
```

- `TS_AUTHKEY` is required only when the node is not already logged in to Tailscale.
- `TS_TAGS` is optional. It is passed as `--advertise-tags` when set.
- `CODE_SERVER_PASSWORD` is optional. Leave it empty to rely on tailnet-only access; set it to additionally protect code-server with its built-in password prompt.
- `OPENCODE_GO_KEY` is required.
- `OPENCODE_WEB_PASSWORD` is optional. Leave it empty to rely on tailnet-only access; set it to additionally protect OpenCode Web with HTTP Basic Auth. `OPENCODE_WEB_USERNAME` defaults to `opencode`. When enabled, credentials are stored in a root-only environment file, never in the systemd unit.
- `GIT_SSH_PRIVATE_KEY` is optional. When supplied and `/root/.ssh/id_ed25519` does not already exist, it is written with restrictive permissions. Existing keys are never overwritten.
- `GIT_REPO` is optional. When it is set, the repository is cloned to `/root/workspace`; an existing checkout is left unchanged.
- `GITHUB_PERSONAL_ACCESS_TOKEN`, `E2B_API_KEY`, and `FIRECRAWL_API_KEY` are optional credentials for the retained GitHub, E2B, and Firecrawl MCP servers.

Secrets are never embedded in templates, systemd units, README examples, or script logs. OpenCode and MCP keys are stored only in `/root/.config/opencode/opencode.json` with mode `0600`; OpenCode Web credentials are stored in `/root/.config/opencode/web.env` with mode `0600`.

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

1. Commit and push all work from `/root/workspace`.
2. Before releasing the ECS, run `sudo tailscale logout`. For an ephemeral node this immediately removes it from the tailnet and frees the `ephemeral-devbox` MagicDNS hostname, so the next instance does not become `ephemeral-devbox-1`.
3. Delete the ECS instance and any ephemeral disk you no longer need.
4. Create a new Ubuntu ECS when needed.
5. Repeat the bootstrap procedure with the same safely stored secrets.

Do not retain a custom image or a large snapshot. If you skip `tailscale logout`, the old ephemeral node is only removed after it goes offline, subject to Tailscale's normal cleanup timing; a stale `ephemeral-devbox` entry can force the replacement to use a suffixed hostname. A normal reboot does not need logout: the same ECS keeps its local Tailscale state and reconnects automatically.

## Local Reset Testing

Use `reset-local.sh` only on a test machine to test rebuilds:

```bash
sudo ./reset-local.sh
sudo ./reset-local.sh --force
```

It stops code-server and OpenCode Web, clears their generated configuration and code-server user data (including installed extensions), removes the external DNS drop-in, removes Tailscale Serve rules, and deletes `/root/workspace` after confirmation (or with `--force`). It deliberately does not uninstall packages; delete Tailscale login state; alter the Tailscale account or auth key; delete SSH keys; touch remote Git repositories; call Alibaba Cloud APIs; delete ECS instances/disks; or change security groups.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Tailscale cannot connect | Confirm `TS_AUTHKEY` is valid, reusable, ephemeral, and tag-authorized. Run `systemctl status tailscaled` and `tailscale status`. |
| Serve URL does not work | Confirm MagicDNS/HTTPS access and run `tailscale serve status`. Check tailnet ACLs. |
| code-server unavailable | Run `systemctl status code-server@root` and inspect `/root/.config/code-server/config.yaml` permissions. |
| OpenCode Web unavailable | Run `systemctl status opencode-web`; `journalctl -u opencode-web -e` shows runtime errors without exposing config values. |
| Git SSH clone fails | Confirm the private key can access the repository and that `ssh-keyscan` completed. Test `ssh -T git@github.com` or `ssh -T git@gitee.com`. |
| Bootstrap refuses workspace | Move or remove the non-Git `/root/workspace` directory rather than allowing the script to overwrite files. |
