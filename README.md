# local-ai

Ollama on an AMD RX 7600 (8 GB, ROCm) serving `qwen3.5:9b`, with a provisioning script for Debian.

## Contents

| File | Purpose |
|---|---|
| `docker-compose.yml` | Ollama (ROCm) with the API on `0.0.0.0:11434` |
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
| `CONTAINER_EGRESS_ALLOW` | *(empty)* | Space-separated CIDRs containers may connect to |
| `MODEL` | `qwen3.5:9b` | Model pulled during setup |
| `INSTALL_DIR` | `/opt/local-ai` | Where the compose file is deployed |
| `APT_CRON` | `17 4 * * *` | apt upgrade schedule |
| `DOCKER_CRON` | `47 4 * * *` | Container update schedule |
| `SKIP_COMPOSE_UP` | `0` | `1` to skip starting the stack and pulling the model |

The script is idempotent; re-run it to change options.

## What `setup.sh` does

1. **Docker Engine** — removes conflicting packages, adds Docker's apt repository and installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, following the [official Debian guide](https://docs.docker.com/engine/install/debian/). Verifies with `hello-world`.
2. **GPU firmware** — installs `firmware-amd-graphics`. If `/dev/kfd` is missing afterwards, reboot.
3. **apt auto-updates** — `/etc/cron.d/apt-auto-update` runs `/usr/local/sbin/apt-auto-update` daily: `update`, `upgrade --with-new-pkgs` (existing config files kept), `autoremove`, `autoclean`. Log: `/var/log/apt-auto-update.log`. Docker Engine itself updates through this job.
4. **Container auto-updates** — `/etc/cron.d/docker-auto-update` runs `/usr/local/sbin/docker-auto-update` daily: `docker compose pull`, `docker compose up -d`, `docker image prune -f` in `INSTALL_DIR`. Image pulls are done by the Docker daemon on the host, so they are unaffected by the container egress block. Models are not updated automatically. Log: `/var/log/docker-auto-update.log`.
5. **UFW** — default deny incoming, outgoing and routed.
   - Host in: SSH, Ollama API
   - Host out: DNS (53), HTTP (80), HTTPS (443), NTP (123/udp), DHCP (67/udp). Required for apt and image pulls.
   - Containers: no outbound connections. See below.
6. **Stack** — copies `docker-compose.yml` to `INSTALL_DIR`, runs `docker compose up -d`, then pulls `MODEL` with `local-ai-pull-model`.

## Container isolation

Container traffic is routed (FORWARD chain), and Docker accepts it before UFW's routed policy is checked. The script therefore puts container policy in the `DOCKER-USER` chain, via `/etc/ufw/after.rules` and `after6.rules`, which UFW loads on start:

| Traffic | Result |
|---|---|
| Replies to inbound API requests | allowed |
| Inbound to the Ollama port from outside `ALLOW_FROM` | dropped (published ports bypass UFW INPUT) |
| Container to container on Docker bridges | allowed |
| Container to `CONTAINER_EGRESS_ALLOW` destinations | allowed |
| Any other new connection from a container (LAN or internet) | dropped, logged as `[DOCKER-EGRESS-DROP]` (rate-limited) |

This applies to every container on the host, not only Ollama. Other stacks deployed here (e.g. Open WebUI) get no outbound access unless their destinations are in `CONTAINER_EGRESS_ALLOW`.

### Pulling models

Ollama downloads models from inside its container, which the block prevents. `local-ai-pull-model` inserts temporary rules allowing the `ollama` container HTTPS and DNS, runs the pull, and removes the rules on exit (including on failure or Ctrl-C):

```bash
sudo local-ai-pull-model qwen3.5:9b
```

Check for drops: `sudo journalctl -k | grep DOCKER-EGRESS-DROP`

The Ollama API has no authentication.

## Verify

```bash
docker exec ollama ollama ps                      # PROCESSOR should be 100% GPU
curl http://<host>:11434/api/tags                 # from another machine
sudo ufw status verbose
tail /var/log/apt-auto-update.log /var/log/docker-auto-update.log
sudo iptables -L DOCKER-USER -nv                 # container egress rules
docker exec ollama sh -c 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"' || echo blocked
```

## Compose settings

Sized for 8 GB VRAM with `qwen3.5:9b` Q4_K_M:

- `HSA_OVERRIDE_GFX_VERSION=11.0.0` — RX 7600 is gfx1102, not on ROCm's official list
- `OLLAMA_CONTEXT_LENGTH=32768`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_FLASH_ATTENTION=1`
- `OLLAMA_NUM_PARALLEL=1` — parallel requests multiply KV cache size

If `ollama ps` shows CPU offload, lower `OLLAMA_CONTEXT_LENGTH` to `16384`.
