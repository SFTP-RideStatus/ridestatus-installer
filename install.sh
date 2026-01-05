#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Ride Status Installer
# Version: v2.0.0
# =============================================================================
INSTALLER_VERSION="v2.0.0"

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
  jq \
  openssl

# -----------------------------------------------------------------------------
# /opt/ridestatus layout + final log location
# -----------------------------------------------------------------------------
RIDESTATUS_ROOT="/opt/ridestatus"
CONFIG_DIR="${RIDESTATUS_ROOT}/config"
BACKUPS_DIR="${RIDESTATUS_ROOT}/backups"
LOG_DIR="${RIDESTATUS_ROOT}/logs"
BIN_DIR="${RIDESTATUS_ROOT}/bin"
SRC_DIR="${RIDESTATUS_ROOT}/src"

LOG_FILE="${LOG_DIR}/install.log"

sudo mkdir -p "$CONFIG_DIR" "$BACKUPS_DIR" "$LOG_DIR" "$BIN_DIR" "$SRC_DIR"
sudo chown -R sftp:sftp "$RIDESTATUS_ROOT"
sudo chmod 0755 "$RIDESTATUS_ROOT" "$CONFIG_DIR" "$BACKUPS_DIR" "$LOG_DIR" "$BIN_DIR" "$SRC_DIR"

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

if id -nG sftp | tr ' ' '\n' | grep -qx sudo; then
  echo "User 'sftp' is already in sudo group."
else
  echo "Adding 'sftp' to sudo group..."
  sudo usermod -aG sudo sftp
  echo "NOTE: Group membership changes typically require log out/in to take effect for new shells."
fi

SUDOERS_FILE="/etc/sudoers.d/ridestatus-sftp"
SUDOERS_LINE="sftp ALL=(ALL) NOPASSWD:ALL"

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

echo "Validating sudoers configuration..."
sudo visudo -cf /etc/sudoers >/dev/null
echo "Sudoers validation passed."

# -----------------------------------------------------------------------------
# SSH deploy key for GitHub access
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
echo "Add this key as a READ-ONLY Deploy Key to the required private repositories."
echo

# -----------------------------------------------------------------------------
# Installer components: Node-RED + Mosquitto + Ansible + MariaDB
# -----------------------------------------------------------------------------
echo "Installing Node-RED, Mosquitto, Ansible, MariaDB..."

sudo apt-get install -y \
  nodejs \
  npm \
  build-essential \
  python3 \
  mosquitto \
  mosquitto-clients \
  ansible \
  sshpass \
  mariadb-server \
  mariadb-client

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
# MariaDB configuration (local-only bind is recommended)
# -----------------------------------------------------------------------------
echo "Ensuring MariaDB is enabled and running..."
sudo systemctl enable mariadb
sudo systemctl restart mariadb

# Bind-address: keep local-only by default (safer, still works for local apps)
# Ubuntu packages already default to localhost in many cases; we enforce idempotently.
MARIADB_BIND_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
if sudo test -f "$MARIADB_BIND_FILE"; then
  if sudo grep -Eq '^\s*bind-address\s*=\s*127\.0\.0\.1\s*$' "$MARIADB_BIND_FILE"; then
    echo "MariaDB bind-address already set to 127.0.0.1"
  else
    echo "Setting MariaDB bind-address to 127.0.0.1 (local-only)..."
    sudo sed -i \
      -e 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' \
      "$MARIADB_BIND_FILE" || true
    # If no bind-address existed, add it under [mysqld]
    if ! sudo grep -Eq '^\s*bind-address\s*=' "$MARIADB_BIND_FILE"; then
      sudo awk '
        BEGIN{added=0}
        /^\[mysqld\]/{print; if(!added){print "bind-address = 127.0.0.1"; added=1; next}}
        {print}
        END{if(!added){print "\n[mysqld]\nbind-address = 127.0.0.1"}}
      ' "$MARIADB_BIND_FILE" | sudo tee "$MARIADB_BIND_FILE.tmp" >/dev/null
      sudo mv "$MARIADB_BIND_FILE.tmp" "$MARIADB_BIND_FILE"
    fi
    sudo systemctl restart mariadb
  fi
fi

# -----------------------------------------------------------------------------
# Database + users (fully automated; no manual SQL ever)
# -----------------------------------------------------------------------------
DB_NAME="ridestatus"
DB_APP_USER="ridestatus_app"
DB_MIGRATE_USER="ridestatus_migrate"
DB_ENV_FILE="${CONFIG_DIR}/db.env"

# Create/stash passwords once (idempotent)
gen_pw() { openssl rand -base64 32 | tr -d '\n'; }

if [[ -f "$DB_ENV_FILE" ]]; then
  echo "DB env already exists: $DB_ENV_FILE"
  # shellcheck disable=SC1090
  source "$DB_ENV_FILE"
else
  echo "Generating DB credentials..."
  DB_APP_PASS="$(gen_pw)"
  DB_MIGRATE_PASS="$(gen_pw)"
  cat > "$DB_ENV_FILE" <<EOF
# Managed by RideStatus installer (${INSTALLER_VERSION})
DB_NAME="${DB_NAME}"
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_APP_USER="${DB_APP_USER}"
DB_APP_PASS="${DB_APP_PASS}"
DB_MIGRATE_USER="${DB_MIGRATE_USER}"
DB_MIGRATE_PASS="${DB_MIGRATE_PASS}"
EOF
  chmod 0600 "$DB_ENV_FILE"
fi

# shellcheck disable=SC1090
source "$DB_ENV_FILE"

echo "Creating database and users (idempotent)..."
sudo mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_APP_USER}'@'localhost' IDENTIFIED BY '${DB_APP_PASS}';
CREATE USER IF NOT EXISTS '${DB_MIGRATE_USER}'@'localhost' IDENTIFIED BY '${DB_MIGRATE_PASS}';

-- App user: normal read/write operations
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE TEMPORARY TABLES, LOCK TABLES
  ON \`${DB_NAME}\`.*
  TO '${DB_APP_USER}'@'localhost';

-- Migrate user: schema ownership/migrations
GRANT ALL PRIVILEGES
  ON \`${DB_NAME}\`.*
  TO '${DB_MIGRATE_USER}'@'localhost';

FLUSH PRIVILEGES;
SQL

echo "DB setup complete: ${DB_NAME}"
echo "DB credentials file: ${DB_ENV_FILE}"

# -----------------------------------------------------------------------------
# Migration runner (SQL-file based, deterministic)
# -----------------------------------------------------------------------------
# Convention:
#   /opt/ridestatus/src/ridestatus-server/migrations/*.sql
# Applied migrations recorded in ridestatus.schema_migrations (filename + applied_at).
MIGRATE_SCRIPT="${BIN_DIR}/ridestatus-migrate.sh"
sudo tee "$MIGRATE_SCRIPT" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

RIDESTATUS_ROOT="/opt/ridestatus"
CONFIG_DIR="${RIDESTATUS_ROOT}/config"
DB_ENV_FILE="${CONFIG_DIR}/db.env"

if [[ ! -f "$DB_ENV_FILE" ]]; then
  echo "ERROR: Missing DB env file: $DB_ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$DB_ENV_FILE"

MIGRATIONS_DIR="${RIDESTATUS_ROOT}/src/ridestatus-server/migrations"
if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  echo "No migrations directory found at: $MIGRATIONS_DIR"
  echo "Skipping migrations."
  exit 0
fi

echo "Running migrations from: $MIGRATIONS_DIR"

mysql_cmd=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_MIGRATE_USER" "-p${DB_MIGRATE_PASS}" "$DB_NAME")

# Ensure tracking table exists
"${mysql_cmd[@]}" <<SQL
CREATE TABLE IF NOT EXISTS schema_migrations (
  filename VARCHAR(255) PRIMARY KEY,
  applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
SQL

shopt -s nullglob
mapfile -t files < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort)
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "No *.sql migration files found. Skipping."
  exit 0
fi

for f in "${files[@]}"; do
  already="$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM schema_migrations WHERE filename='${f}'")"
  if [[ "$already" == "1" ]]; then
    echo "Already applied: $f"
    continue
  fi

  echo "Applying: $f"
  "${mysql_cmd[@]}" < "${MIGRATIONS_DIR}/${f}"
  "${mysql_cmd[@]}" -e "INSERT INTO schema_migrations (filename) VALUES ('${f}')"
done

echo "Migrations complete."
EOF
sudo chmod 0755 "$MIGRATE_SCRIPT"
sudo chown sftp:sftp "$MIGRATE_SCRIPT"

sudo tee /etc/systemd/system/ridestatus-migrate.service >/dev/null <<EOF
[Unit]
Description=RideStatus DB Migration Runner
After=network.target mariadb.service
Wants=mariadb.service

[Service]
Type=oneshot
User=sftp
Group=sftp
ExecStart=${MIGRATE_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ridestatus-migrate
sudo systemctl restart ridestatus-migrate || true

# -----------------------------------------------------------------------------
# Node-RED: install + stable credentialSecret
# -----------------------------------------------------------------------------
if ! command -v node-red >/dev/null 2>&1; then
  echo "Installing Node-RED via npm (global)..."
  sudo npm install -g --unsafe-perm node-red
fi

NODE_RED_USERDIR="/home/sftp/.node-red"
mkdir -p "$NODE_RED_USERDIR"
chmod 0755 "$NODE_RED_USERDIR"

# Stable credential secret (no hand edits, deterministic per park)
NR_SECRET_FILE="${CONFIG_DIR}/nodered_credential_secret"
if [[ -f "$NR_SECRET_FILE" ]]; then
  echo "Node-RED credentialSecret already exists: $NR_SECRET_FILE"
else
  echo "Generating Node-RED credentialSecret..."
  umask 077
  openssl rand -hex 32 > "$NR_SECRET_FILE"
  chmod 0600 "$NR_SECRET_FILE"
fi

NR_SETTINGS_FILE="${NODE_RED_USERDIR}/settings.js"
if [[ -f "$NR_SETTINGS_FILE" ]]; then
  if grep -q "credentialSecret" "$NR_SETTINGS_FILE"; then
    echo "Node-RED settings already has credentialSecret."
  else
    echo "Injecting credentialSecret into existing settings.js..."
    secret="$(cat "$NR_SECRET_FILE")"
    # Insert after module.exports = { line
    perl -0777 -i -pe "s/module\.exports\s*=\s*\{\n/module.exports = {\\n    credentialSecret: '${secret}',\\n/; " "$NR_SETTINGS_FILE"
  fi
else
  echo "Creating Node-RED settings.js with credentialSecret..."
  secret="$(cat "$NR_SECRET_FILE")"
  cat > "$NR_SETTINGS_FILE" <<EOF
/**
 * RideStatus managed settings.js
 * Managed by installer ${INSTALLER_VERSION}
 */
module.exports = {
    credentialSecret: '${secret}',
};
EOF
  chown sftp:sftp "$NR_SETTINGS_FILE"
  chmod 0644 "$NR_SETTINGS_FILE"
fi

# -----------------------------------------------------------------------------
# Clone private repos using deploy key (read-only)
# -----------------------------------------------------------------------------
echo "Cloning private repos into ${SRC_DIR}..."

GITHUB_ORG="SFTP-RideStatus"
REPOS=(
  "ridestatus-server"
  "ridestatus-ride"
  "ridestatus-deploy"
)

GIT_SSH_COMMAND="ssh -i ${KEY_FILE} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"

for repo in "${REPOS[@]}"; do
  dest="${SRC_DIR}/${repo}"
  url="git@github.com:${GITHUB_ORG}/${repo}.git"

  if [[ -d "${dest}/.git" ]]; then
    echo "Updating ${repo}..."
    (cd "$dest" && GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git fetch --all --prune && GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git checkout -q main && GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git pull -q --ff-only) \
      || echo "WARNING: Could not update ${repo} (deploy key missing from repo, or branch not 'main')."
  else
    echo "Cloning ${repo}..."
    (cd "$SRC_DIR" && GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone "$url" "$dest") \
      || echo "WARNING: Could not clone ${repo} (deploy key missing from repo, or repo not accessible)."
  fi
done

# -----------------------------------------------------------------------------
# Node-RED systemd service (ensure dependencies: mosquitto + mariadb + migrate)
# -----------------------------------------------------------------------------
echo "Configuring systemd service: ridestatus-nodered.service"

sudo tee /etc/systemd/system/ridestatus-nodered.service >/dev/null <<'EOF'
[Unit]
Description=RideStatus Node-RED
After=network.target mosquitto.service mariadb.service ridestatus-migrate.service
Wants=mosquitto.service mariadb.service ridestatus-migrate.service

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
IP_ADDR="$(hostname -I | awk '{print $1}' || true)"
if [[ -z "${IP_ADDR:-}" ]]; then IP_ADDR="127.0.0.1"; fi

echo
echo "======================================"
echo "INSTALLER COMPLETE – ${INSTALLER_VERSION}"
echo "======================================"
echo "Node-RED URL: http://${IP_ADDR}:1880"
echo "MQTT Broker:  mqtt://${IP_ADDR}:1883"
echo "Install log:  ${LOG_FILE}"
echo "DB env:       ${DB_ENV_FILE}"
echo "Repos:        ${SRC_DIR}"
echo "Sudo mode:    NOPASSWD enabled for 'sftp'"
