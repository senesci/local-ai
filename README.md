# local-ai

Ollama on an AMD RX 7600 (8 GB, ROCm) serving `qwen3.5:9b`, with a provisioning script for Debian.

## Contents

| File | Purpose |
|---|---|
| `docker-compose.yml` | Ollama (ROCm) with the API on `0.0.0.0:11434`; one-shot service pulls `qwen3.5:9b` |
| `setup.sh` | Installs Docker, sets up automatic apt and container updates, configures UFW, starts the stack |

## Requirements

- Debian 12 (bookworm) or 13 (trixie), amd64
- AMD RX 7600 (gfx1102)
- `non-free-firmware` enabled in apt sources (for `firmware-amd-graphics`)

## Usage

```bash
git clone https://github.com/senesci/local-ai
cd local-ai
sudo ./setup.sh
```

Restrict SSH and the Ollama API to a subnet:

```bash
sudo ALLOW_FROM=10.90.1.0/24 ./setup.sh
```

### Options

| Variable | Default | Description |
|---|---|---|
| `SSH_PORT` | `22` | Inbound SSH port |
| `OLLAMA_PORT` | `11434` | Inbound Ollama API port |
| `ALLOW_FROM` | `any` | Source CIDR allowed to reach SSH and Ollama |
| `INSTALL_DIR` | `/opt/local-ai` | Where the compose file is deployed |
| `APT_CRON` | `17 4 * * *` | apt upgrade schedule |
| `DOCKER_CRON` | `47 4 * * *` | Container update schedule |
| `SKIP_COMPOSE_UP` | `0` | `1` to skip starting the stack |

The script is idempotent; re-run it to change options.

## What `setup.sh` does

1. **Docker Engine** — removes conflicting packages, adds Docker's apt repository and installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, following the [official Debian guide](https://docs.docker.com/engine/install/debian/). Verifies with `hello-world`.
2. **GPU firmware** — installs `firmware-amd-graphics`. If `/dev/kfd` is missing afterwards, reboot.
3. **apt auto-updates** — `/etc/cron.d/apt-auto-update` runs `/usr/local/sbin/apt-auto-update` daily: `update`, `upgrade --with-new-pkgs` (existing config files kept), `autoremove`, `autoclean`. Log: `/var/log/apt-auto-update.log`. Docker Engine itself updates through this job.
4. **Container auto-updates** — `/etc/cron.d/docker-auto-update` runs `/usr/local/sbin/docker-auto-update` daily: `docker compose pull`, `docker compose up -d`, `docker image prune -f` in `INSTALL_DIR`. The `ollama-pull` service re-runs on each `up`, which also refreshes the model. Log: `/var/log/docker-auto-update.log`.
5. **UFW** — default deny incoming, outgoing and routed. Allowed:
   - In: SSH, Ollama API
   - Out: DNS (53), HTTP (80), HTTPS (443), NTP (123/udp), DHCP (67/udp)

   Outbound allows are the minimum required for apt, image pulls and model pulls. Without them, updates stop working.
6. **Stack** — copies `docker-compose.yml` to `INSTALL_DIR` and runs `docker compose up -d`.

## Firewall notes

- Docker-published ports bypass UFW's input rules ([Docker docs](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw)). With `ALLOW_FROM=any`, port 11434 is reachable from any network that can route to the host regardless of UFW.
- When `ALLOW_FROM` is set, the script adds rules to the `DOCKER-USER` chain via `/etc/ufw/after.rules` so the source restriction applies to the Ollama port.
- Container egress passes through the FORWARD chain, not OUTPUT. UFW's outgoing policy does not restrict containers.
- The Ollama API has no authentication.

## Verify

```bash
docker exec ollama ollama ps                      # PROCESSOR should be 100% GPU
curl http://<host>:11434/api/tags                 # from another machine
sudo ufw status verbose
tail /var/log/apt-auto-update.log /var/log/docker-auto-update.log
```

## Compose settings

Sized for 8 GB VRAM with `qwen3.5:9b` Q4_K_M:

- `HSA_OVERRIDE_GFX_VERSION=11.0.0` — RX 7600 is gfx1102, not on ROCm's official list
- `OLLAMA_CONTEXT_LENGTH=32768`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_FLASH_ATTENTION=1`
- `OLLAMA_NUM_PARALLEL=1` — parallel requests multiply KV cache size

If `ollama ps` shows CPU offload, lower `OLLAMA_CONTEXT_LENGTH` to `16384`.
