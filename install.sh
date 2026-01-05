#!/usr/bin/env bash
set -euo pipefail

echo "RideStatus Installer v0"
echo "======================="

# Must not be root
if [[ "$EUID" -eq 0 ]]; then
  echo "ERROR: Do not run as root. Log in as 'sftp' and use sudo."
  exit 1
fi

# Must be sftp
if [[ "$(whoami)" != "sftp" ]]; then
  echo "ERROR: Installer must be run as user 'sftp'."
  exit 1
fi

# OS check
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  echo "ERROR: Ubuntu Server 24.04 LTS is required."
  exit 1
fi

echo "OS check passed."

# Sudo check
echo "Checking sudo access..."
if ! sudo -v; then
  echo "ERROR: 'sftp' must have sudo privileges."
  exit 1
fi

echo "Sudo check passed."

# Install minimal deps
echo "Installing base packages..."
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  git

# SSH key generation
SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Generating SSH key for GitHub access..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
else
  echo "SSH key already exists."
fi

echo
echo "=============================="
echo "ADD THIS SSH KEY TO GITHUB"
echo "=============================="
cat "${KEY_FILE}.pub"
echo
echo "Add this key as a READ-ONLY Deploy Key to the required private repositories."
echo "Then re-run this installer."
echo

echo "Installer v0 complete."
exit 0
