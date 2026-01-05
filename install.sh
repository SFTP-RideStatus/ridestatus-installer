#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Ride Status Installer
# Version: v1.1.1
# =============================================================================
INSTALLER_VERSION="v1.1.1"

# -----------------------------------------------------------------------------
# Early logging buffer (before sudo is available)
# -----------------------------------------------------------------------------
TMP_LOG_DIR="/tmp/ridestatus-installer"
TMP_LOG_FILE="${TMP_LOG_DIR}/install.log"
mkdir -p "$TMP_LOG_DIR"
exec > >(tee "$TMP_LOG_FILE") 2>&1

echo "RideStatus Installer ${INSTALLER_VERSION}"
echo "======================================"

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
AUTO_EXPAND_ROOT=0
for arg in "$@"; do
  case "$arg" in
    --auto-expand-root|-y|--yes) AUTO_EXPAND_ROOT=1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Safety checks
# -----------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "ERROR: Do not run as root. Log in as 'sftp' and run the installer."
  exit 1
fi

if [[ "$(whoami)" != "sftp" ]]; then
  echo "ERROR: Installer must be run as user 'sftp'."
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  echo "ERROR: Ubuntu Server 24.04 LTS is required."
  exit 1
fi
echo "OS check passed."

# We still need initial sudo ability to set up NOPASSWD.
# After this installer runs once, future runs won't prompt for a password.
echo "Checking sudo access (initial run may prompt for password)..."
if ! sudo -v; then
  echo "ERROR: 'sftp' must have sudo privileges."
  exit 1
fi
echo "Sudo check passed."

# -----------------------------------------------------------------------------
# Disk check / optional auto-expand (LVM)
# -----------------------------------------------------------------------------
RECOMMENDED_ROOT_GB=55
ROOT_GB="$(df -BG --output=size / | tail -1 | tr -d ' G')"

if (( ROOT_GB < RECOMMENDED_ROOT_GB )); then
  echo "WARNING: Root filesystem is ${ROOT_GB}G (recommended >= ${RECOMMENDED_ROOT_GB}G)."

  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  if [[ "$ROOT_SRC" == /dev/mapper/* && "$AUTO_EXPAND_ROOT" == "1" ]]; then
    echo "Attempting LVM auto-expand..."
    sudo lvextend -l +100%FREE "$ROOT_SRC"
    sudo resize2fs "$ROOT_SRC"
    df -h /
  else
    echo "Re-run with --auto-expand-root to expand automatically."
  fi
fi

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------
echo "Installing base packages..."
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq

# -----------------------------------------------------------------------------
# Final log location
# -----------------------------------------------------------------------------
LOG_DIR="/opt/ridestatus/logs"
LOG_FILE="${LOG_DIR}/install.log"

sudo mkdir -p "$LOG_DIR"
sudo chown -R sftp:sftp /opt/ridestatus
sudo chmod 0755 /opt/ridestatus "$LOG_DIR"

# Append buffered log and switch to final log file
cat "$TMP_LOG_FILE" | tee -a "$LOG_FILE" >/dev/null
exec > >(tee -a "$LOG_FILE") 2>&1
rm -rf "$TMP_LOG_DIR"

echo "Logging to $LOG_FILE"
echo "Installer version: ${INSTALLER_VERSION}"

# -----------------------------------------------------------------------------
# Enforce passwordless sudo for sftp (NOPASSWD by default)
# -----------------------------------------------------------------------------
echo "Configuring passwordless sudo (NOPASSWD) for user 'sftp'..."

# Ensure sftp is in sudo group (harmless if already)
if id -nG sftp | tr ' ' '\n' | grep -qx sudo; then
  echo "User 'sftp' is already in sudo group."
else
  echo "Adding 'sftp' to sudo group..."
  sudo usermod -aG sudo sftp
  echo "NOTE: Group membership changes typically require log out/in to take effect for new shells."
fi

SUDOERS_FILE="/etc/sudoers.d/ridestatus-sftp"
SUDOERS_LINE="sftp ALL=(ALL) NOPASSWD:ALL"

# Write only if needed
if sudo test -f "$SUDOERS_FILE" && sudo grep -Fxq "$SUDOERS_LINE" "$SUDOERS_FILE"; then
  echo "NOPASSWD already configured in $SUDOERS_FILE"
else
  echo "Writing $SUDOERS_FILE"
  sudo tee "$SUDOERS_FILE" >/dev/null <<EOF
# Managed by RideStatus installer (${INSTALLER_VERSION})
# Passwordless sudo for unattended installs/upgrades
${SUDOERS_LINE}
EOF
  sudo chmod 0440 "$SUDOERS_FILE"
fi

# Validate sudoers configuration
echo "Validating sudoers configuration..."
sudo visudo -cf /etc/sudoers >/dev/null
echo "Sudoers validation passed."

# -----------------------------------------------------------------------------
# SSH deploy key
# -----------------------------------------------------------------------------
SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Generating SSH deploy key..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
fi

chmod 600 "$KEY_FILE"
chmod 644 "${KEY_FILE}.pub"

ssh-keyscan -H github.com 2>/dev/null | sort -u > "$SSH_DIR/known_hosts"
chmod 600 "$SSH_DIR/known_hosts"

echo
echo "=============================="
echo "GITHUB DEPLOY KEY"
echo "=============================="
cat "${KEY_FILE}.pub"
echo

# -----------------------------------------------------------------------------
# Installer v1 components
# -----------------------------------------------------------------------------
echo "Installing Node-RED, Mosquitto, Ansible..."

sudo apt-get install -y \
  nodejs \
  npm \
  build-essential \
  python3 \
  mosquitto \
  mosquitto-clients \
  ansible \
  sshpass

# -----------------------------------------------------------------------------
# Directory layout
# -----------------------------------------------------------------------------
sudo mkdir -p /opt/ridestatus/{config,backups,logs}
sudo chown -R sftp:sftp /opt/ridestatus
sudo chmod 0755 /opt/ridestatus /opt/ridestatus/{config,backups,logs}

# -----------------------------------------------------------------------------
# Mosquitto configuration (listen on all interfaces)
# -----------------------------------------------------------------------------
echo "Configuring Mosquitto (listen on all interfaces)..."
sudo tee /etc/mosquitto/conf.d/ridestatus.conf >/dev/null <<'EOF'
listener 1883 0.0.0.0
allow_anonymous true
EOF

sudo systemctl enable mosquitto
sudo systemctl restart mosquitto

# -----------------------------------------------------------------------------
# Node-RED installation
# -----------------------------------------------------------------------------
if ! command -v node-red >/dev/null 2>&1; then
  sudo npm install -g --unsafe-perm node-red
fi

NODE_RED_USERDIR="/home/sftp/.node-red"
mkdir -p "$NODE_RED_USERDIR"
chmod 0755 "$NODE_RED_USERDIR"

# -----------------------------------------------------------------------------
# Node-RED systemd service
# -----------------------------------------------------------------------------
sudo tee /etc/systemd/system/ridestatus-nodered.service >/dev/null <<'EOF'
[Unit]
Description=RideStatus Node-RED
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
User=sftp
Group=sftp
WorkingDirectory=/home/sftp
ExecStart=/usr/bin/env node-red -u /home/sftp/.node-red
Restart=on-failure
RestartSec=5
Environment=NODE_OPTIONS=--max-old-space-size=256

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ridestatus-nodered
sudo systemctl restart ridestatus-nodered

# -----------------------------------------------------------------------------
# Completion
# -----------------------------------------------------------------------------
IP_ADDR="$(hostname -I | awk '{print $1}')"

echo
echo "======================================"
echo "INSTALLER COMPLETE – ${INSTALLER_VERSION}"
echo "======================================"
echo "Node-RED URL: http://${IP_ADDR}:1880"
echo "Install log:  ${LOG_FILE}"
echo "Sudo mode:    NOPASSWD enabled for 'sftp'"
