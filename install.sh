#!/usr/bin/env bash
set -euo pipefail

echo "RideStatus Installer v0"
echo "======================="

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

# Must not be root
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "ERROR: Do not run as root. Log in as 'sftp' and run the installer (it will use sudo)."
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

# Sudo check (allow password prompt)
echo "Checking sudo access..."
if ! sudo -v; then
  echo "ERROR: 'sftp' must have sudo privileges."
  exit 1
fi
echo "Sudo check passed."

# -----------------------------------------------------------------------------
# Disk check / optional auto-expand (LVM)
# -----------------------------------------------------------------------------
# README should recommend 60GB disk, but usable root size is typically ~57-58G.
# Allow >=55G to avoid false warnings due to OS overhead/rounding.
RECOMMENDED_ROOT_GB=55
ROOT_GB="$(df -BG --output=size / | tail -1 | tr -d ' G')"

if (( ROOT_GB < RECOMMENDED_ROOT_GB )); then
  echo "WARNING: Root filesystem is ${ROOT_GB}G. Recommended is ${RECOMMENDED_ROOT_GB}G+."
  echo "         (Installer README recommends a 60GB disk; usable root size may be slightly smaller.)"
  echo

  ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
  if [[ "$ROOT_SRC" == /dev/mapper/* ]]; then
    if command -v vgs >/dev/null 2>&1 && command -v lvs >/dev/null 2>&1; then
      VG_NAME="$(lvs --noheadings -o vg_name "$ROOT_SRC" 2>/dev/null | xargs || true)"
      VG_FREE_G="$(vgs --noheadings -o vg_free --units G --nosuffix "$VG_NAME" 2>/dev/null | xargs || true)"

      echo "Detected LVM root: $ROOT_SRC"
      echo "Volume Group: ${VG_NAME:-unknown} (free ~${VG_FREE_G:-unknown}G)"
      echo

      echo "To expand root to use all free space (after expanding the VM disk if needed):"
      echo "  sudo lvextend -l +100%FREE $ROOT_SRC"
      echo "  sudo resize2fs $ROOT_SRC"
      echo

      # If VG has essentially no free space, user must expand VM disk first.
      if [[ -z "${VG_FREE_G:-}" ]]; then
        echo "NOTE: Unable to determine free space in the Volume Group."
        echo "      If lvextend reports no free space, expand the VM disk first and re-run."
      else
        # Consider >0.1G as "free exists" to avoid float quirks.
        if awk "BEGIN{exit !(${VG_FREE_G} > 0.1)}"; then
          echo "Free space detected in the Volume Group; root can be expanded now."
        else
          echo "No free space detected in the Volume Group."
          echo "Expand the VM disk in the hypervisor first, then re-run (optionally with --auto-expand-root)."
        fi
      fi

      if [[ "$AUTO_EXPAND_ROOT" == "1" ]]; then
        echo
        echo "Auto-expanding root volume..."
        sudo lvextend -l +100%FREE "$ROOT_SRC"
        sudo resize2fs "$ROOT_SRC"
        NEW_ROOT_GB="$(df -BG --output=size / | tail -1 | tr -d ' G')"
        echo "Root filesystem is now ${NEW_ROOT_GB}G."
      else
        echo
        echo "Tip: Re-run with --auto-expand-root to expand automatically."
        echo "     Example (when running via curl|bash):"
        echo "       curl -sSL https://raw.githubusercontent.com/SFTP-RideStatus/ridestatus-installer/main/install.sh | bash -s -- --auto-expand-root"
      fi
    else
      echo "WARNING: LVM tools not found; cannot assist with root expansion."
    fi
  else
    echo "WARNING: Root filesystem does not appear to be on LVM; auto-expansion not supported."
  fi
fi

# -----------------------------------------------------------------------------
# Install minimal dependencies
# -----------------------------------------------------------------------------
echo "Installing base packages..."
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq

# -----------------------------------------------------------------------------
# SSH key generation for GitHub access
# -----------------------------------------------------------------------------
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

# Permissions (after key exists)
chmod 600 "$KEY_FILE"
chmod 644 "${KEY_FILE}.pub"

# GitHub host key (idempotent, avoid duplicates, avoid set -e failures)
: > "$SSH_DIR/known_hosts.tmp"
ssh-keyscan -H github.com 2>/dev/null | sort -u > "$SSH_DIR/known_hosts.tmp" || true
mv "$SSH_DIR/known_hosts.tmp" "$SSH_DIR/known_hosts"
chmod 600 "$SSH_DIR/known_hosts"

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
