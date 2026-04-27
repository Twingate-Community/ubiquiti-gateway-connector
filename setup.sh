#!/bin/bash
set -euo pipefail

# --- Constants ---
NSPAWN_CONF_DIR="/etc/systemd/nspawn"

# Note: This can and should be changed inside the container after setup
CONTAINER_PASSWORD="twingate"

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# --- Helper: run a command inside the running container via nsenter ---
# This replaces 'machinectl shell' which is unreliable in scripted contexts
# due to stale container-shell@N.service units.
container_exec() {
    local pid
    pid=$(machinectl show "$CONTAINER_NAME" -p Leader --value)
    nsenter -t "$pid" -m -u -i -n -p -- "$@"
}

# --- Credential gathering (before any system changes) ---
get_credential() {
    local var_name="$1"
    local prompt_text="$2"
    local value="${!var_name:-}"
    if [[ -z "$value" ]]; then
        if [[ -t 0 ]]; then
            read -rp "$prompt_text: " value
        fi
        if [[ -z "$value" ]]; then
            echo "Error: ${var_name} is required. Set it as an environment variable or run the script interactively." >&2
            exit 1
        fi
    fi
    echo "$value"
}

# --- Container name ---
DEFAULT_CONTAINER_NAME="twingate-connector"
if [[ -n "${CONTAINER_NAME:-}" ]]; then
    true
elif [[ -t 0 ]]; then
    echo ""
    echo "Existing Twingate containers on this host:"
    machinectl list --no-legend 2>/dev/null | grep "twingate" || echo "  (none)"
    echo ""
    read -rp "Enter a container name [${DEFAULT_CONTAINER_NAME}]: " CONTAINER_NAME
    CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
else
    CONTAINER_NAME="$DEFAULT_CONTAINER_NAME"
fi

# Validate: only allow alphanumeric, hyphens, and underscores
if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Container name may only contain letters, numbers, hyphens, and underscores." >&2
    exit 1
fi

# Derive paths from the chosen name
MACHINE_DIR="/data/custom/machines/${CONTAINER_NAME}"
MACHINES_LINK="/var/lib/machines/${CONTAINER_NAME}"
NSPAWN_CONF="${NSPAWN_CONF_DIR}/${CONTAINER_NAME}.nspawn"

echo "==> Container name: ${CONTAINER_NAME}"

TWINGATE_NETWORK=$(get_credential "TWINGATE_NETWORK" "Enter your Twingate network name (e.g., mycompany)")
TWINGATE_ACCESS_TOKEN=$(get_credential "TWINGATE_ACCESS_TOKEN" "Enter your Twingate access token")
TWINGATE_REFRESH_TOKEN=$(get_credential "TWINGATE_REFRESH_TOKEN" "Enter your Twingate refresh token")

# --- Pre-flight checks ---
if machinectl list --no-legend 2>/dev/null | grep -q "^${CONTAINER_NAME} "; then
    echo "Error: Container '${CONTAINER_NAME}' is already running."
    echo "To reinstall, first run:"
    echo "  machinectl disable ${CONTAINER_NAME}"
    echo "  machinectl stop ${CONTAINER_NAME}"
    echo "  rm -rf ${MACHINE_DIR} ${MACHINES_LINK} ${NSPAWN_CONF}"
    exit 1
fi

if [[ -d "$MACHINE_DIR" ]]; then
    echo "Warning: Directory ${MACHINE_DIR} already exists but container is not running."
    if [[ -t 0 ]]; then
        read -rp "Remove it and start fresh? [y/N]: " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            echo "Aborted."
            exit 1
        fi
    else
        echo "Non-interactive mode: removing stale directory and starting fresh."
    fi
    rm -rf "$MACHINE_DIR"
    rm -f "$MACHINES_LINK"
    rm -f "$NSPAWN_CONF"
fi

# --- Install host dependencies ---
echo "==> Installing host dependencies..."
apt-get update -qq
apt-get install -y -qq systemd-container debootstrap

# --- Bootstrap container ---
echo "==> Bootstrapping Debian Bookworm container (this may take ~10 minutes)..."
mkdir -p "$(dirname "$MACHINE_DIR")"
DEBIAN_FRONTEND=noninteractive debootstrap --include=systemd,dbus,curl,ca-certificates bookworm "$MACHINE_DIR"

# --- Pre-boot container configuration ---
echo "==> Configuring container..."
systemd-nspawn -D "$MACHINE_DIR" bash -c "echo 'root:${CONTAINER_PASSWORD}' | chpasswd"
systemd-nspawn -D "$MACHINE_DIR" systemctl enable systemd-networkd

cat > "${MACHINE_DIR}/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "$CONTAINER_NAME" > "${MACHINE_DIR}/etc/hostname"

# --- Host configuration ---
echo "==> Creating symlink for machinectl..."
mkdir -p /var/lib/machines
ln -sf "$MACHINE_DIR" "$MACHINES_LINK"

echo "==> Creating nspawn configuration..."
mkdir -p "$NSPAWN_CONF_DIR"
cat > "$NSPAWN_CONF" <<EOF
[Exec]
Boot=on
Capability=all
ResolvConf=off
PrivateUsers=off

[Network]
Private=off
VirtualEthernet=off
EOF

# --- Start container ---
echo "==> Starting container..."
machinectl start "$CONTAINER_NAME"

echo "==> Waiting for container to boot..."
for i in $(seq 1 30); do
    if container_exec /bin/true 2>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Error: Container failed to boot within 30 seconds." >&2
        exit 1
    fi
    sleep 1
done

machinectl enable "$CONTAINER_NAME"
echo "==> Container started and enabled for auto-start on boot."

# --- Install Twingate connector inside container ---
echo "==> Installing Twingate connector inside container..."
container_exec /bin/bash -c "\
    export DEBIAN_FRONTEND=noninteractive && \
    export TWINGATE_NETWORK='${TWINGATE_NETWORK}' && \
    export TWINGATE_ACCESS_TOKEN='${TWINGATE_ACCESS_TOKEN}' && \
    export TWINGATE_REFRESH_TOKEN='${TWINGATE_REFRESH_TOKEN}' && \
    export TWINGATE_LABEL_DEPLOYED_BY='ubiquiti' && \
    curl -sSf https://binaries.twingate.com/connector/setup.sh | bash"

# --- Fix user namespacing for kernels that don't support it ---
echo "==> Applying user namespace compatibility fix..."
container_exec /bin/bash -c "\
    mkdir -p /etc/systemd/system/twingate-connector.service.d && \
    cat > /etc/systemd/system/twingate-connector.service.d/no-userns.conf <<'OVERRIDE'
[Service]
DynamicUser=no
PrivateUsers=no
User=root
Group=root
OVERRIDE
    systemctl daemon-reload && \
    systemctl restart twingate-connector"

# --- Verify and print summary ---
echo "==> Verifying Twingate connector status..."
sleep 3
container_exec systemctl status twingate-connector --no-pager || true

echo ""
echo "============================================"
echo "  Twingate connector setup complete!"
echo "============================================"
echo ""
echo "Container name:  ${CONTAINER_NAME}"
echo "Container root:  ${MACHINE_DIR}"
echo "nspawn config:   ${NSPAWN_CONF}"
echo "Root password:   ${CONTAINER_PASSWORD}"
echo ""
echo "Useful commands:"
echo "  machinectl status ${CONTAINER_NAME}    # Container status"
echo "  machinectl shell ${CONTAINER_NAME}     # Shell into container"
echo "  machinectl login ${CONTAINER_NAME}     # Login (password: ${CONTAINER_PASSWORD})"
echo "  machinectl stop ${CONTAINER_NAME}      # Stop container"
echo "  machinectl start ${CONTAINER_NAME}     # Start container"
echo ""