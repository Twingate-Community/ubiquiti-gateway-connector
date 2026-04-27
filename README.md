# Twingate Connector for Ubiquiti Gateways

Deploy a [Twingate](https://www.twingate.com/) Connector on Ubiquiti Gateway devices using a lightweight systemd-nspawn container.

## Overview

Ubiquiti gateways (UDM Pro, UDM SE, UXG-Pro, UXG-Max, etc.) run a customized Linux environment that doesn't include a native container runtime. This project uses **systemd-nspawn** to bootstrap a minimal Debian container directly on the gateway, install the Twingate Connector inside it, and configure it to start automatically on boot.

The container filesystem is stored under `/data/custom/machines/`, which persists across UniFi OS firmware upgrades.

## Features

- **Automated setup** -- single script handles everything from container creation to Connector installation
- **Persistent across reboots** -- container data lives on the gateway's persistent `/data` partition
- **Auto-start on boot** -- enabled via `machinectl enable`
- **Host networking** -- no NAT, the Connector has full LAN access
- **Kernel compatibility** -- includes a fix for gateways without user namespace support
- **Flexible credentials** -- pass tokens via environment variables or enter them interactively

## Prerequisites

- A **Ubiquiti Gateway** (UDM Pro, UDM SE, UXG-Pro, UXG-Max, or similar) running UniFi OS 3.x or later
- **SSH access** to the gateway as root
- A **Twingate account** with access to the Admin Console
- **Internet connectivity** on the Gateway (for downloading packages and Twingate binaries)

### Generating Connector Tokens

1. Log in to the [Twingate Admin Console](https://www.twingate.com/)
2. Navigate to **Network > Connectors**
3. Click **Deploy Connector** and select **Manual**
4. Click **Generate New Tokens**
5. Copy the three values you'll need:
   - **Network name** (e.g., `mycompany` from `https://mycompany.twingate.com`)
   - **Access token**
   - **Refresh token**

## Quick Start

### Option 1: Interactive

```bash
curl -sSf https://raw.githubusercontent.com/Twingate-Community/ubiquiti-gateway-connector/main/setup.sh | sudo bash
```

The script will prompt for your container name, Twingate network name, access token, and refresh token.

### Option 2: Non-interactive

```bash
curl -sSf https://raw.githubusercontent.com/Twingate-Community/ubiquiti-gateway-connector/main/setup.sh | sudo TWINGATE_NETWORK="mycompany" TWINGATE_ACCESS_TOKEN="your-access-token" TWINGATE_REFRESH_TOKEN="your-refresh-token" bash
```

All three environment variables are required for non-interactive mode. You can also set `CONTAINER_NAME` to override the default (`twingate-connector`).

## What the Script Does

1. Checks for root privileges
2. Prompts for a container name. Defaults to `twingate-connector` (if interactive)
3. Prompts for Twingate credentials (or reads them from environment variables) (if interactive)
4. Validates that no existing container is already running
5. Installs host dependencies (`systemd-container`, `debootstrap`)
6. Bootstraps a Debian Bookworm container (~10 minutes on gateway hardware)
7. Configures the container (root password, DNS resolvers, hostname, systemd-networkd)
8. Creates the nspawn configuration with host networking and all capabilities
9. Starts the container and enables auto-start on boot
10. Installs the Twingate Connector inside the container using the [official Linux setup script](https://binaries.twingate.com/connector/setup.sh)
11. Applies a user namespace compatibility fix for kernels that don't support it
12. Verifies the Connector status and prints a summary

## Container Management

| Command | Description |
|---------|-------------|
| `machinectl status twingate-connector` | View container status |
| `machinectl shell twingate-connector` | Open a shell inside the container |
| `machinectl login twingate-connector` | Login to the container (password: `twingate`) |
| `machinectl stop twingate-connector` | Stop the container |
| `machinectl start twingate-connector` | Start the container |
| `machinectl disable twingate-connector` | Disable auto-start on boot |

## Key Paths

| Path | Description |
|------|-------------|
| `/data/custom/machines/twingate-connector` | Container root filesystem (persists across reboots) |
| `/var/lib/machines/twingate-connector` | Symlink to above (required by machinectl) |
| `/etc/systemd/nspawn/twingate-connector.nspawn` | Container configuration |

## Uninstall

To completely remove the Connector and container (swap `twingate-connector` for Connector name if using a custom name):

```bash
sudo machinectl disable twingate-connector
sudo machinectl stop twingate-connector
sudo rm -rf /data/custom/machines/twingate-connector
sudo rm -f /var/lib/machines/twingate-connector
sudo rm -f /etc/systemd/nspawn/twingate-connector.nspawn
```

## Security Considerations

- The container runs with **all capabilities** and **host networking**. This is required for the Connector to function as a network gateway.
- The container root password is set to `twingate`. The container is not network-accessible (no SSH server inside), so risk is minimal. Change it if desired via `machinectl shell`.
- Twingate tokens are stored inside the container at `/etc/twingate/connector.conf`, which is the standard Connector behavior.
- **User namespaces are disabled** (`PrivateUsers=off`) because most Ubiquiti gateway kernels lack user namespace support.
- The script uses `curl | bash` to run the official Twingate installer inside the container. This is the same installation method [documented by Twingate](https://www.twingate.com/docs/connectors-on-linux).

## Troubleshooting

### Container fails to start

```bash
machinectl status twingate-connector
journalctl -M twingate-connector -xe --no-pager
```

### Connector not connecting

1. Verify your credentials were entered correctly
2. Check DNS resolution inside the container:
   ```bash
   nsenter -t $(machinectl show twingate-connector -p Leader --value) -m -u -i -n -p -- curl -s https://binaries.twingate.com
   ```
3. Check Connector logs:
   ```bash
   nsenter -t $(machinectl show twingate-connector -p Leader --value) -m -u -i -n -p -- journalctl -u twingate-connector -n 50 --no-pager
   ```

### Container missing after firmware upgrade

The container data in `/data/custom/machines/` persists across firmware upgrades, but the symlink at `/var/lib/machines/` and the nspawn config at `/etc/systemd/nspawn/` may need to be recreated. Re-running the script will detect the existing container directory and prompt you before proceeding.

### debootstrap takes a long time

This is normal on Gateway hardware. Expect approximately 5-10 minutes depending on your internet connection and device.

## Repository Structure

```
ubiquiti-gateway-connector/
├── README.md
├── LICENSE
├── .gitignore
└── setup.sh
```

## Need Help?

- [Twingate Documentation](https://docs.twingate.com/)
- [Twingate Community (Reddit)](https://www.reddit.com/r/twingate/)
- [Report an Issue](https://github.com/Twingate-Community/ubiquiti-gateway-connector/issues)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
