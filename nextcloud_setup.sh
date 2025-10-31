#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO. Check $LOGFILE for details."' ERR

if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root (use sudo)." >&2
  exit 1
fi


#											NEXTCLOUD SETUP COMMANDS
#									 	    ★★★★★★★★★★★★★★★★


#						 			Nextcloud + Cloudflared AUTO INSTALLER
#				 				   *****************************************


#											Created by Rasel-Tech
#									Compatible with: Ubuntu 22.04 / 24.04
#									=====================================

																																												
# Features & Highlights:
#"""""""""""""”""""""""""""
# - Prompts for sensitive info at runtime:
#     * Nextcloud DB credentials (DB name, user, password)
#     * Nextcloud admin credentials (username & password)
#     * Cloudflare API token & Zone ID
#     * Optional admin email for certs/notifications
# - Headless Cloudflare Tunnel creation via API with manual fallback
# - DNS create/update: automatic CNAME for tunnel
# - Tunnel credentials JSON handling & systemd service creation
# - Apache2 + PHP 8.2-FPM + required PHP extensions
# - PHP memory & OPcache auto-tuning based on system RAM
# - Redis caching for Nextcloud
# - MariaDB installation & DB/user creation with RAM-based tuning
# - Nextcloud download, file permissions, headless OCC setup
# - Trusted domains, overwrite CLI URL, overwrite protocol/proxy settings
# - Self-signed origin certificate for HTTPS (optional, for Full strict TLS)
# - UFW firewall setup + SSH rate-limit + fail2ban configuration
# - Systemd service auto-restart for key services
# - Nextcloud cron job for www-data
# - Security cleanup: unsets sensitive variables at end
# - Final summary with service statuses & next steps
 																																												
# ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★ #
 																																												
# Safety Features:
#"""""""""""""""""""
# - 'set -euo pipefail' + IFS
# - Trap ERR to show line number
# - Checks for required commands (curl, jq, wget, unzip, git, openssl, etc.)
 																																												
# ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★ #



# *****************
# LOGGING helpers
# *****************

function log()  { echo -e "\e[1;32m[✔]\e[0m $1"; }
function warn() { echo -e "\e[1;33m[!]\e[0m $1"; }
function err()  { echo -e "\e[1;31m[✘]\e[0m $1"; exit 1; }

safe_systemctl() {
    if ! systemctl "$@"; then
        warn "systemctl failed: systemctl $* (exit: $?)"
        return 1
    fi
    return 0
}

log "Starting enhanced Nextcloud + Cloudflared installer for domain: ${DOMAIN}"


# Global Log Enable
# ******************

LOGFILE="/var/log/nextcloud-install.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== Nextcloud Installation Started at $(date) ====="


# ******************************
# CHECK REQUIRED COMMANDS
# (will install if missing later)
# ******************************

MISSING_CMDS=()

REQUIRED_CMDS=(curl jq wget unzip git apt-get systemctl openssl)

for c in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
        MISSING_CMDS+=("$c")
    fi
done

# Note:
# If apt is available, ensure jq, wget, unzip are installed later


# ******************************************
# PROMPTS — Sensitive info asked at runtime
# ******************************************

echo "⚙️  Starting interactive setup — please provide the following details."
echo "------------------------------------------------------------"

# 🏷️ Domain Configuration
# *************************

read -rp "🌐 Domain to use (e.g. cloud.example.com): " DOMAIN
: "${DOMAIN:?❌ Domain is required. Exiting.}"

# 🚇 Cloudflare Tunnel
# *********************

read -rp "🌀 Tunnel name [nextcloud-tunnel]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-nextcloud-tunnel}

# 👤 Nextcloud Admin Credentials
# *******************************

echo "------------------------------------------------------------"
echo "🔐 Nextcloud Admin Setup"
read -rp "👤 Admin username: " NEXTCLOUD_ADMIN_USER
read -rsp "🔑 Admin password: " NEXTCLOUD_ADMIN_PASS
echo ""

# 🗄️ Database Configuration
# **************************

echo "------------------------------------------------------------"
echo "💾 Nextcloud Database Setup"
read -rp "📘 Database name [nextcloud]: " NEXTCLOUD_DB
NEXTCLOUD_DB=${NEXTCLOUD_DB:-nextcloud}

read -rp "👤 Database user [nextclouduser]: " NEXTCLOUD_DB_USER
NEXTCLOUD_DB_USER=${NEXTCLOUD_DB_USER:-nextclouduser}

read -rsp "🔑 Database password (used for both root & Nextcloud user): " NEXTCLOUD_DB_PASS
echo ""
if [ -z "$NEXTCLOUD_DB_PASS" ]; then
  echo "❌ No database password provided. Exiting."
  exit 1
fi

# 📂 Data Directory
# *****************

read -rp "📁 Data directory [/mnt/nextcloud_data]: " DATA_DIR
DATA_DIR=${DATA_DIR:-/mnt/nextcloud_data}

# 📧 Admin Email (optional)
# **************************

read -rp "📧 Admin email for certs/notifications [leave blank to skip]: " EMAIL

# ☁️ Cloudflare API Access
# ************************

echo "------------------------------------------------------------"
echo "☁️  Provide Cloudflare API token with permissions:"
echo "   → Account: Tunnels (Edit)"
echo "   → Zone: DNS (Edit)"
read -rsp "🔑 CLOUDFLARE_API_TOKEN: " CLOUDFLARE_API_TOKEN
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    err "Cloudflare API token missing. Aborting."
fi
echo ""
read -rp "🌎 CLOUDFLARE_ZONE_ID (Zone ID of your domain): " CLOUDFLARE_ZONE_ID

CF_CHECK=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.success')

if [ "$CF_CHECK" != "true" ]; then
  err "❌ Cloudflare API token invalid or expired. Please check permissions."
fi

log "Cloudflare API token verified successfully."

echo "------------------------------------------------------------"
echo "✅ All credentials collected. Proceeding with setup..."
echo ""


# ********************************************
# VARIABLES — Default system paths & versions
# ********************************************

CLOUDFLARED_BIN=$(command -v cloudflared || echo /usr/local/bin/cloudflared)
CLOUDFLARED_SYSTEMD_SERVICE="/etc/systemd/system/cloudflared.service"
CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"
CREDENTIALS_DIR="/etc/cloudflared"

PHP_VERSION="8.2"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
APACHE_SERVICE="apache2"


# ************************************
# CONFIRMATION — Review & proceed
# ************************************

echo ""
echo "🧾 Please review your configuration:"
echo "------------------------------------------------------------"
echo "🌐 Domain:                $DOMAIN"
echo "🌀 Tunnel name:           $TUNNEL_NAME"
echo "👤 Admin user:            $NEXTCLOUD_ADMIN_USER"
echo "📘 Database name:         $NEXTCLOUD_DB"
echo "👤 Database user:         $NEXTCLOUD_DB_USER"
echo "📁 Data directory:        $DATA_DIR"
echo "📧 Admin email:           ${EMAIL:-[none]}"
echo "☁️  Cloudflare Zone ID:   $CLOUDFLARE_ZONE_ID"
echo "------------------------------------------------------------"
read -rp "✅ Continue with installation? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "❌ Installation aborted by user."
  exit 1
fi

echo "🚀 Proceeding with automated Nextcloud setup..."
echo ""


# ********************************
#1. System Update & Basic Packages
# ********************************

export DEBIAN_FRONTEND=noninteractive

apt update && apt full-upgrade -y
if [ -f /var/lib/apt/lists/lock ]; then
    rm -f /var/lib/apt/lists/lock
    log "Removed apt lock file."
fi

apt install -y \
    software-properties-common \
    curl wget vim git ufw lsb-release \
    apt-transport-https ca-certificates gnupg \
    openssl unzip fail2ban zip coreutils

# certbot (optional)

# (TIMEZONE) Set server timezone
# *******************************

read -p "Enter your server timezone (e.g. Asia/Riyadh, Asia/Dhaka, Europe/London): " TIMEZONE
TIMEZONE=${TIMEZONE:-UTC} # default if blank
timedatectl list-timezones | grep -i "${TIMEZONE}" || true
timedatectl set-timezone "$TIMEZONE"

timedatectl set-ntp true

log "NTP synchronization enabled."
log "Timezone set to: $(timedatectl show -p Timezone --value)"

# *******************************
#1.a Detect total system RAM early
# *******************************

# Dynamic swap setup
# ********************

TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

if [ "$TOTAL_RAM_MB" -lt 4096 ]; then
    if swapon --show | grep -q '/swapfile'; then
        log "Swapfile already exists — skipping creation."
    else
        SWAP_MB=$(( TOTAL_RAM_MB * 2 ))  # swap = 2x RAM
        log "Low RAM detected (${TOTAL_RAM_MB} MB). Creating ${SWAP_MB}MB swap file..."

        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "${SWAP_MB}M" /swapfile
        else
            log "fallocate not available, using dd fallback..."
            dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_MB status=progress
        fi

        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile

        # ✅ safer fstab update
        if [ -f /etc/fstab ]; then
            grep -qxF '/swapfile none swap sw 0 0' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        else
            echo "⚠️ /etc/fstab not found — skipping auto swap entry." >&2
        fi

        sysctl vm.swappiness=10
        sysctl vm.vfs_cache_pressure=50
        log "Swap file created and activated."
    fi
else
    log "Sufficient RAM detected (${TOTAL_RAM_MB} MB). No swap needed."
fi


# ****************************
# 1.b Prepare storage directory
# ****************************

log "Preparing storage directory: ${DATA_DIR}"

# Ensure data directory exists but do not modify fstab blindly
# *********************************************************

mkdir -p "${DATA_DIR}"
log "Data directory ensured at ${DATA_DIR} (fstab unchanged for safety)."
chown -R www-data:www-data "$DATA_DIR"
chmod -R 750 "$DATA_DIR"


# *****************
# 2. Install Apache2
# *****************

log "Installing Apache2..."

apt install -y apache2
a2dismod mpm_prefork || true
a2enmod mpm_event proxy_fcgi setenvif || true
a2enconf php${PHP_VERSION}-fpm || true
safe_systemctl enable --now apache2
safe_systemctl restart apache2
log "Apache tuned for PHP-FPM (mpm_event enabled)."

if ! systemctl is-active --quiet apache2; then
    warn "Apache2 failed to start, check: systemctl status apache2"
fi


ufw allow 'Apache Full' || true


# ******************************
# 3. Install PHP-FPM + extensions
# ******************************

log "Installing PHP ${PHP_VERSION} and extensions..."

add-apt-repository ppa:ondrej/php -y
apt update

apt install -y \
    php${PHP_VERSION}-fpm \
    php${PHP_VERSION}-cli \
    php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-gmp \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-imagick \
    php${PHP_VERSION}-apcu \
    php${PHP_VERSION}-redis \
    php${PHP_VERSION}-opcache

safe_systemctl enable --now php${PHP_VERSION}-fpm


# ****************************
# 3.a RAM Auto-Tuning for PHP
# ****************************

PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
OPCACHE_INI="/etc/php/${PHP_VERSION}/mods-available/opcache.ini"

# Auto-adjust PHP & OPcache memory limits based on total system RAM
# ******************************************************************

if [ "$TOTAL_RAM_MB" -le 4096 ]; then
    PHP_MEM="512M"
    OPCACHE_MEM=128
elif [ "$TOTAL_RAM_MB" -le 8192 ]; then
    PHP_MEM="1024M"
    OPCACHE_MEM=256
elif [ "$TOTAL_RAM_MB" -le 16384 ]; then
    PHP_MEM="2048M"
    OPCACHE_MEM=512
else
    PHP_MEM="4096M"
    OPCACHE_MEM=1024
fi

log "Setting PHP memory_limit=${PHP_MEM} and OPcache memory=${OPCACHE_MEM}M"

# Update PHP memory limit (handles spacing)
# ******************************************

sed -i "s/^\s*memory_limit\s*=.*/memory_limit = ${PHP_MEM}/" "$PHP_INI"

# Write new OPcache configuration
# ********************************

cat > "$OPCACHE_INI" <<EOF
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=${OPCACHE_MEM}
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.revalidate_freq=2
opcache.validate_timestamps=1
EOF

#Restart php to apply auto tuning
# ******************************

safe_systemctl restart php${PHP_VERSION}-fpm

# Improve PHP-FPM performance
# *******************************

PHP_FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
sed -i -E "s/^;pm.max_children =.*/pm.max_children = 50/" "$PHP_FPM_POOL_CONF"
sed -i -E "s/^;pm.start_servers =.*/pm.start_servers = 10/" "$PHP_FPM_POOL_CONF"
sed -i -E "s/^;pm.max_spare_servers =.*/pm.max_spare_servers = 20/" "$PHP_FPM_POOL_CONF"
safe_systemctl restart php${PHP_VERSION}-fpm
log "PHP-FPM tuned for better performance."


# ****************************
# 4. Install and Configure Redis
# ****************************

log "Installing and configuring Redis..."

# Install Redis package
# ********************

apt install -y redis-server

# Enable and start Redis safely
# ****************************

safe_systemctl enable --now redis-server

# Configure Redis for Unix socket
# ******************************

REDIS_CONF="/etc/redis/redis.conf"
REDIS_SOCK="/var/run/redis/redis-server.sock"

log "Configuring Redis socket in $REDIS_CONF ..."

# Enable Redis Unix socket line (commented or not)
if grep -q "^#* *unixsocket " "$REDIS_CONF"; then
    sed -i "s|^#* *unixsocket .*|unixsocket ${REDIS_SOCK}|" "$REDIS_CONF"
else
    echo "unixsocket ${REDIS_SOCK}" >> "$REDIS_CONF"
fi

# Enable Redis socket permission line
# **********************************

if grep -q "^#* *unixsocketperm " "$REDIS_CONF"; then
    sed -i "s|^#* *unixsocketperm .*|unixsocketperm 770|" "$REDIS_CONF"
else
    echo "unixsocketperm 770" >> "$REDIS_CONF"
fi

# Grant Redis group access to www-data (for Nextcloud)
# ***************************************************

if ! id -nG www-data | grep -qw redis; then
    usermod -aG redis www-data || true
    log "Added www-data to redis group for socket access."
fi

# Restart Redis to apply configuration
# **********************************

safe_systemctl restart redis-server

# Detect Redis connection mode (socket or TCP fallback)
# ***************************************************

if [ -S "$REDIS_SOCK" ]; then
    REDIS_HOST="$REDIS_SOCK"
    REDIS_PORT=0
    log "✅ Using Redis Unix socket: $REDIS_SOCK"
else
    REDIS_HOST="127.0.0.1"
    REDIS_PORT=6379
    warn "⚠️ Redis socket not found. Falling back to TCP at ${REDIS_HOST}:${REDIS_PORT}"
fi

# Test Redis connectivity
# **********************

if ! redis-cli ping >/dev/null 2>&1; then
    err "❌ Redis failed to start or respond properly!"
else
    log "Redis is up and running."
fi


# ************************************
# 5. Install MariaDB and create DB/user
# ************************************

log "Installing MariaDB..."

apt install -y mariadb-server mariadb-client
safe_systemctl enable --now mariadb

log "Securing MariaDB (minimal non-interactive)..."

# Set root password to NEXTCLOUD_DB_PASS (user-provided)
# ********************************************************

if mysql -e "SELECT plugin FROM mysql.user WHERE User='root'" | grep -q 'unix_socket'; then
    mysql -e "UPDATE mysql.user SET plugin='mysql_native_password' WHERE User='root'; FLUSH PRIVILEGES;"
fi

if mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${NEXTCLOUD_DB_PASS}';"; then
    log "MariaDB root password set successfully."
else
    log "Fallback: resetting root password via unix_socket method..."
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEXTCLOUD_DB_PASS}'; FLUSH PRIVILEGES;" || \
    err "MariaDB root password set failed!"
fi

mysql -e "DELETE FROM mysql.user WHERE User='';" || true
mysql -e "DROP DATABASE IF EXISTS test;" || true
mysql -e "FLUSH PRIVILEGES;" || true

log "Creating Nextcloud database and user..."

mysql -e "CREATE DATABASE IF NOT EXISTS ${NEXTCLOUD_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${NEXTCLOUD_DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${NEXTCLOUD_DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${NEXTCLOUD_DB}.* TO '${NEXTCLOUD_DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"


# *********************************
# 5.a RAM Auto-Tuning for MariaDB
# *********************************

MYCNF="/etc/mysql/conf.d/99-nextcloud.cnf"
BUFFER_POOL_SIZE_MB=$((TOTAL_RAM_MB / 2))  # 50% of RAM

log "Setting MariaDB innodb_buffer_pool_size=${BUFFER_POOL_SIZE_MB}M"

# Tune MariaDB log size dynamically based on RAM
# ************************************************

if [ "$TOTAL_RAM_MB" -lt 2048 ]; then
    LOG_FILE_SIZE=128M
else
    LOG_FILE_SIZE=512M
fi

cat > "$MYCNF" <<EOF
[mysqld]
innodb_buffer_pool_size=${BUFFER_POOL_SIZE_MB}M
innodb_log_file_size=${LOG_FILE_SIZE}
max_connections=200
binlog_format=ROW
EOF

safe_systemctl restart mariadb
log "MariaDB tuning applied based on RAM."


# *******************************
# 6. Download & Install Nextcloud
# *******************************
log "Downloading Nextcloud..."

cd /tmp
wget -q https://download.nextcloud.com/server/releases/latest.zip
unzip -o latest.zip >/dev/null

# Replace any existing installation safely
# *************************************

rm -rf /var/www/html/nextcloud || true
mv -f nextcloud /var/www/html/nextcloud

# Set ownership and permissions
# ******************************

chown -R www-data:www-data /var/www/html/nextcloud
find /var/www/html/nextcloud/ -type d -exec chmod 750 {} \;
find /var/www/html/nextcloud/ -type f -exec chmod 640 {} \;


# *******************************************************
# 6.a Configure Apache for Nextcloud (HTTPS enabled later)
# *******************************************************

log "Configuring Apache virtual host..."

VHOST_CONF="/etc/apache2/sites-available/nextcloud.conf"

cat > "$VHOST_CONF" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html/nextcloud

    <Directory /var/www/html/nextcloud/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

# Enable necessary modules and site
# *********************************

a2ensite nextcloud.conf
a2enmod rewrite headers env dir mime ssl http2 proxy_fcgi setenvif
a2dissite 000-default.conf || true
a2enconf php${PHP_VERSION}-fpm || true

# Restart Apache to apply changes
# *******************************

safe_systemctl restart apache2


# ********************
# 7. Install cloudflared
# ********************

log "Installing cloudflared (Cloudflare Tunnel)..."

ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
else
  warn "Unknown architecture '${ARCH}'. Attempting amd64 binary as fallback."
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
fi

curl -L -o /tmp/cloudflared.deb "$CF_URL"
dpkg -i /tmp/cloudflared.deb || apt -f install -y
rm -f /tmp/cloudflared.deb

# cloudflared installed path verify
# *******************************

CLOUDFLARED_BIN=$(command -v cloudflared || echo /usr/local/bin/cloudflared)
if [ ! -x "$CLOUDFLARED_BIN" ]; then
    err "cloudflared binary not found at $CLOUDFLARED_BIN"
fi

# DNS fallback setup (safe for systemd-resolved)
# ********************************************

log "Applying DNS fallback servers..."
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl dns eth0 1.1.1.1 9.9.9.9
    resolvectl domain eth0 "~."
    log "DNS set via systemd-resolved (Cloudflare + Quad9)."
else
    echo -e "nameserver 1.1.1.1\nnameserver 9.9.9.9" | tee /etc/resolv.conf >/dev/null
    log "DNS fallback applied directly (no systemd-resolved)."
fi


# **************************************************************
# 7.a Cloudflare Tunnel creation (Headless API preferred + manual fallback)
# **************************************************************

log "Preparing Cloudflare Tunnel '${TUNNEL_NAME}' for hostname ${DOMAIN}..."

mkdir -p "${CREDENTIALS_DIR}"
chown -R root:root "${CREDENTIALS_DIR}"
chmod 755 "${CREDENTIALS_DIR}"

# Helper: Cloudflare API call wrapper
# ***********************************

cf_api() {
  local method=$1 url=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl -s -X "$method" "https://api.cloudflare.com/client/v4${url}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${data}"
  else
    curl -s -X "$method" "https://api.cloudflare.com/client/v4${url}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}


# ***************************
# 7.b Get account ID from zone
# ***************************

log "Resolving Cloudflare account ID for zone ${CLOUDFLARE_ZONE_ID}..."
ZONE_INFO=$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}")
ACCOUNT_ID=$(echo "$ZONE_INFO" | jq -r '.result.account.id // empty')

if [ -z "$ACCOUNT_ID" ]; then
  warn "Could not resolve account ID from zone. Falling back to manual credential import."
  CF_API_OK=false
else
  CF_API_OK=true
  log "Found Cloudflare account ID: ${ACCOUNT_ID}"
fi

TUNNEL_ID=""
CREDENTIALS_JSON_PATH=""


# **********************************
# 7.c Attempt headless tunnel creation
# **********************************

if [ "$CF_API_OK" = true ]; then
  log "Checking if tunnel '${TUNNEL_NAME}' already exists..."
  EXISTING_TUNNEL=$(cf_api GET "/accounts/${ACCOUNT_ID}/tunnels?name=${TUNNEL_NAME}")
  TUNNEL_ID=$(echo "$EXISTING_TUNNEL" | jq -r '.result[0].id // empty')

  if [ -n "$TUNNEL_ID" ]; then
    log "Existing tunnel found: ${TUNNEL_ID} (skipping creation)."
  else
    log "No existing tunnel found. Creating a new one via Cloudflare API..."
    CREATE_RESP=$(cf_api POST "/accounts/${ACCOUNT_ID}/tunnels" "{\"name\":\"${TUNNEL_NAME}\"}")
    SUCCESS=$(echo "$CREATE_RESP" | jq -r '.success // false')
    if [ "$SUCCESS" = "true" ]; then
      TUNNEL_ID=$(echo "$CREATE_RESP" | jq -r '.result.id // empty')
if [ -z "$TUNNEL_ID" ]; then
  warn "❌ Cloudflare API did not return a valid tunnel ID. Falling back to manual mode."
  CF_API_OK=false
fi

      CRED_RESP=$(cf_api POST "/accounts/${ACCOUNT_ID}/tunnels/${TUNNEL_ID}/credentials")
      CRED_SUCCESS=$(echo "$CRED_RESP" | jq -r '.success // false')

      if [ "$CRED_SUCCESS" = "true" ]; then
        CREDENTIALS_JSON=$(echo "$CRED_RESP" | jq -c '.result')
        if [ -n "$CREDENTIALS_JSON" ] && [ "$CREDENTIALS_JSON" != "null" ]; then
          CREDENTIALS_JSON_PATH="${CREDENTIALS_DIR}/${TUNNEL_ID}.json"
          echo "$CREDENTIALS_JSON" > "${CREDENTIALS_JSON_PATH}"
          chmod 600 "${CREDENTIALS_JSON_PATH}"
          log "Credentials written to: ${CREDENTIALS_JSON_PATH}"
        else
          warn "API returned success but no credentials payload. Manual import may be required."
        fi
      else
        warn "Failed to generate credentials via API. Manual import required."
      fi
    else
      warn "Cloudflare API tunnel creation failed. Falling back to manual mode."
      warn "Cloudflare API might be rate-limited or credentials invalid. Try again later or use manual JSON import mode."
      CF_API_OK=false
    fi
  fi
fi


# **********************************************
# 7.d Manual fallback (Import Cloudflare Json File)
# **********************************************

if [ -z "${TUNNEL_ID}" ]; then
  warn "Headless API creation failed. Switching to manual fallback mode."
  echo ""
  echo "👉 You can either:"
  echo "   1) Provide full path to an existing credentials JSON file on this server"
  echo "   2) Or upload your credentials JSON from Windows to the server (e.g. /tmp) and press enter"
  echo ""

  read -rp "Enter full path to your credentials JSON file (leave empty to auto-scan common dirs): " IMPORT_FILE

# Preferred credentials destination
# ********************************

  mkdir -p "${CREDENTIALS_DIR}"
  chown root:root "${CREDENTIALS_DIR}"
  chmod 755 "${CREDENTIALS_DIR}"

# If user provided a path, validate & copy it
# ****************************************

  if [ -n "${IMPORT_FILE}" ]; then
    if [ ! -f "${IMPORT_FILE}" ]; then
      err "Provided file not found: ${IMPORT_FILE}"
    fi

# copy into credentials dir using a safe filename
# ********************************************

    BASENAME=$(basename "${IMPORT_FILE}")
    DEST="${CREDENTIALS_DIR}/${BASENAME}"
    cp -f "${IMPORT_FILE}" "${DEST}" || err "Failed to copy ${IMPORT_FILE} -> ${DEST}"
    CANDIDATE_FILES=("${DEST}")
  else

# Auto-scan common locations for JSONs
# *************************************

    CANDIDATE_DIRS=("${CREDENTIALS_DIR}" "/root/.cloudflared" "$HOME/.cloudflared" "/home/${SUDO_USER:-root}/.cloudflared")
    CANDIDATE_FILES=()
    for d in "${CANDIDATE_DIRS[@]}"; do
      if [ -d "$d" ]; then
        for f in "$d"/*.json; do
          [ -e "$f" ] && CANDIDATE_FILES+=("$f")
        done
      fi
    done
  fi

# No candidates?
# ***************

  if [ ${#CANDIDATE_FILES[@]} -eq 0 ]; then
    err "No cloudflared credentials JSON found in ${CREDENTIALS_DIR} or common locations. Upload the JSON (scp/WinSCP) and re-run this script or provide its path now."
  fi

# If multiple candidates choose the most recently modified; otherwise the single one
# ****************************************************************

  if [ ${#CANDIDATE_FILES[@]} -gt 1 ]; then

# sort by mtime, newest first
# *************************

    CREDENTIALS_JSON_PATH=$(ls -1t "${CANDIDATE_FILES[@]}" 2>/dev/null | head -n1)
    warn "Multiple JSON files detected; using latest modified: ${CREDENTIALS_JSON_PATH}"
  else
    CREDENTIALS_JSON_PATH="${CANDIDATE_FILES[0]}"
  fi

# Ensure jq is available for parsing
# ********************************

  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found — attempting to install (apt-get)."
    apt-get update -y && apt-get install -y jq || warn "Could not install jq; JSON parsing may fail."
  fi

# Validate JSON and extract tunnel id
# **********************************

  if ! jq -e . >/dev/null 2>&1 <"${CREDENTIALS_JSON_PATH}"; then
    err "Selected file is not valid JSON: ${CREDENTIALS_JSON_PATH}"
  fi

  TUNNEL_ID=$(jq -r '.id // empty' "${CREDENTIALS_JSON_PATH}")
  if [ -z "$TUNNEL_ID" ]; then
    err "Could not extract Tunnel ID from ${CREDENTIALS_JSON_PATH}. Is this the correct cloudflared credentials JSON?"
  fi

 # Move/copy credentials into credentials dir with canonical name <tunnel-id>.json
# ***************************************************************

  FINAL_PATH="${CREDENTIALS_DIR}/${TUNNEL_ID}.json"
  if [ "${CREDENTIALS_JSON_PATH}" != "${FINAL_PATH}" ]; then
    cp -f "${CREDENTIALS_JSON_PATH}" "${FINAL_PATH}" || err "Failed to copy credentials to ${FINAL_PATH}"
  fi
  chown root:root "${FINAL_PATH}"
  chmod 600 "${FINAL_PATH}"
  CREDENTIALS_JSON_PATH="${FINAL_PATH}"

  log "Imported Cloudflare tunnel credentials to: ${CREDENTIALS_JSON_PATH}"
  log "Detected Tunnel ID: ${TUNNEL_ID}"
fi


# ********************************
# 7.e Create cloudflared config.yml
# ********************************

log "Writing cloudflared configuration to ${CLOUDFLARED_CONFIG}..."

cat > "${CLOUDFLARED_CONFIG}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDENTIALS_JSON_PATH}
ingress:
  - hostname: ${DOMAIN}
    service: https://localhost:443
    originRequest:
      noTLSVerify: false
  - service: http_status:404
EOF

chmod 640 "${CLOUDFLARED_CONFIG}"
chown root:root "${CLOUDFLARED_CONFIG}"

if [ ! -f "${CREDENTIALS_JSON_PATH}" ]; then
  warn "⚠ Credentials JSON for tunnel not found at ${CREDENTIALS_JSON_PATH}."
  warn "If created manually, ensure the credentials file exists and is owned by root."
fi

if grep -q "noTLSVerify: true" "${CLOUDFLARED_CONFIG}"; then
    warn "⚠ Cloudflare tunnel config disables TLS verification (noTLSVerify: true)."
    echo "   Make sure your origin cert is valid and Full (strict) mode is enabled in Cloudflare SSL/TLS settings."
fi


# *******************************************
# 7.f DNS Create/Update via Cloudflare API
# (CNAME => <TUNNEL_ID>.cfargotunnel.com)
# *******************************************

CF_TARGET="${TUNNEL_ID}.cfargotunnel.com"
log "Creating or updating DNS record: ${DOMAIN} → ${CF_TARGET} via Cloudflare API..."

# Check if DNS record already exists
# *********************************

DNS_CHECK=$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${DOMAIN}")
EXISTING_ID=$(echo "$DNS_CHECK" | jq -r '.result[0].id // empty' 2>/dev/null || true)

if [ -n "$EXISTING_ID" ]; then
  log "Existing DNS record found (ID: ${EXISTING_ID}). Updating record..."
  UPDATE_PAYLOAD=$(jq -n \
    --arg type "CNAME" \
    --arg name "${DOMAIN}" \
    --arg content "${CF_TARGET}" \
    --argjson proxied true \
    '{type:$type, name:$name, content:$content, ttl:120, proxied:$proxied}')

  UPDATE_RESP=$(cf_api PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${EXISTING_ID}" "${UPDATE_PAYLOAD}")

  if echo "$UPDATE_RESP" | jq -e '.success' >/dev/null 2>&1; then
    log "✅ DNS record updated successfully."
  else
    warn "⚠ DNS update failed."
    echo "$UPDATE_RESP" | jq '.' || true
  fi

else
  log "No existing DNS record found. Creating new CNAME..."
  CREATE_PAYLOAD=$(jq -n \
    --arg type "CNAME" \
    --arg name "${DOMAIN}" \
    --arg content "${CF_TARGET}" \
    --argjson proxied true \
    '{type:$type, name:$name, content:$content, ttl:120, proxied:$proxied}')

  CREATE_RESP=$(cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "${CREATE_PAYLOAD}")

# DNS API failed fallback guidance
# ********************************

if ! echo "$CREATE_RESP" | jq -e '.success' >/dev/null 2>&1 && \
   ! echo "$UPDATE_RESP" | jq -e '.success' >/dev/null 2>&1; then
    warn "⚠ DNS API failed. You may need to manually set CNAME:"
    echo "   ${DOMAIN} → ${CF_TARGET} in your Cloudflare dashboard."
fi
fi


# ***************************************************
# 7.g Create systemd Service for cloudflared and Enable
# ***************************************************

log "Creating systemd service for cloudflared..."

if [ ! -x "$CLOUDFLARED_BIN" ]; then
    err "❌ cloudflared binary not found at ${CLOUDFLARED_BIN}. Install failed or path incorrect."
fi

log "cloudflared binary verified at ${CLOUDFLARED_BIN}"

cat > "${CLOUDFLARED_SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${CLOUDFLARED_BIN} --config ${CLOUDFLARED_CONFIG} run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start service
# *******************************

safe_systemctl daemon-reload
safe_systemctl enable --now cloudflared

# Verify status briefly
# *******************

sleep 2
safe_systemctl status cloudflared --no-pager


# ********************************
# 8. Nextcloud Headless Installation
# ********************************

log "Running Nextcloud headless setup (auto install)..."

if [ ! -f "/var/www/html/nextcloud/config/config.php" ]; then
  sudo -u www-data php /var/www/html/nextcloud/occ maintenance:install \
    --database "mysql" \
    --database-name "${NEXTCLOUD_DB}" \
    --database-user "${NEXTCLOUD_DB_USER}" \
    --database-pass "${NEXTCLOUD_DB_PASS}" \
    --admin-user "${NEXTCLOUD_ADMIN_USER}" \
    --admin-pass "${NEXTCLOUD_ADMIN_PASS}" \
    --data-dir "${DATA_DIR}" \
    || err "Nextcloud installation failed!"
  
  log "Nextcloud auto-installation complete."
else
  log "Nextcloud already installed; skipping auto-install."
fi


# ***********************************
# 8.a Nextcloud Configuration Updates
# (Trusted Domains / Proxies / Redis)
# ***********************************

log "Updating Nextcloud configuration..."

# Run all OCC commands as www-data
OCC_CMD="sudo -u www-data php /var/www/html/nextcloud/occ"

CONFIG_FILE="/var/www/html/nextcloud/config/config.php"

if [ -f "$CONFIG_FILE" ]; then 

# Redis host fallback logic
# ***********************

    REDIS_SOCK=$(grep "^unixsocket " /etc/redis/redis.conf | awk '{print $2}')

    if [ -S "$REDIS_SOCK" ]; then
        REDIS_HOST="$REDIS_SOCK"
        REDIS_PORT=0
        log "Using Redis Unix socket: $REDIS_HOST"
    else
        REDIS_HOST="127.0.0.1"
        REDIS_PORT=6379
        warn "Redis socket not found. Falling back to TCP: $REDIS_HOST:$REDIS_PORT"
    fi

# Apply Redis settings
# **********************

    $OCC_CMD config:system:set redis \
      --value "{\"host\":\"${REDIS_HOST}\",\"port\":${REDIS_PORT},\"timeout\":1.5}" --type=json
    $OCC_CMD config:system:set memcache.locking --value="\\OC\\Memcache\\Redis" || true
    $OCC_CMD config:system:set memcache.local --value="\\OC\\Memcache\\APCu" || true

# Trusted domain and overwrite settings
# *************************************

    $OCC_CMD config:system:set trusted_domains 1 --value="${DOMAIN}" --force
    $OCC_CMD config:system:set overwrite.cli.url --value="https://${DOMAIN}" --force
    $OCC_CMD config:system:set overwritehost --value="${DOMAIN}" --force
    $OCC_CMD config:system:set overwriteprotocol --value="https" --force

    log "Nextcloud configuration updated successfully."
else
    warn "Nextcloud config file not found at $CONFIG_FILE. Skipping configuration updates."
fi

log "Nextcloud configuration update block completed."


# *****************************************************************
# 9. TLS - Create local self-signed origin cert (optional) & enable HTTPS vhost
# *****************************************************************

SSL_DIR="/etc/ssl/nextcloud"
mkdir -p "${SSL_DIR}"


# *******************************************
# 🚀 AUTO HTTPS via Cloudflare Origin CA API
# *******************************************
# This section can automatically issue a domain-specific
# Origin CA certificate from Cloudflare instead of self-signed one.

# Prerequisites:
#   - CLOUDFLARE_API_TOKEN with "SSL and Certificates: Edit" permission
#   - CLOUDFLARE_ZONE_ID defined earlier in the script

ORIGIN_KEY="${SSL_DIR}/nextcloud-origin.key"
ORIGIN_CSR="${SSL_DIR}/nextcloud-origin.csr"
ORIGIN_CERT="${SSL_DIR}/nextcloud-origin.crt"

# Generate private key & CSR
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$ORIGIN_KEY" \
    -out "$ORIGIN_CSR" \
    -subj "/CN=${DOMAIN}/O=Nextcloud Auto Origin"

# Encode CSR to base64 for API
CSR_B64=$(base64 -w 0 "$ORIGIN_CSR")

# Request certificate via Cloudflare Origin CA API
CERT_PAYLOAD=$(jq -n \
  --arg csr "$CSR_B64" \
  --argjson hostnames "[\"${DOMAIN}\"]" \
  '{"hostnames":$hostnames,"request_type":"origin-rsa","requested_validity":5475,"csr":$csr}')

CERT_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$CERT_PAYLOAD")

# Extract issued certificate
ORIGIN_CERT_B64=$(echo "$CERT_RESP" | jq -r '.result.certificate')
echo "$ORIGIN_CERT_B64" | base64 -d > "$ORIGIN_CERT"

chmod 600 "$ORIGIN_KEY" "$ORIGIN_CERT"

log "✅ Origin CA certificate issued via Cloudflare API."
log "Certificate saved at: $ORIGIN_CERT"


# ************************************
# 10. Apache HTTPS vhost configuration
# ************************************

VHOST_SSL_CONF="/etc/apache2/sites-available/nextcloud-ssl.conf"
cat > "${VHOST_SSL_CONF}" <<EOF
<VirtualHost *:443>
    ServerName ${DOMAIN}
    DocumentRoot /var/www/html/nextcloud

    SSLEngine on
    SSLCertificateFile ${ORIGIN_CERT}
    SSLCertificateKeyFile ${ORIGIN_KEY}

    Protocols h2 http/1.1
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"

    <Directory /var/www/html/nextcloud/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
    </Directory>

Header always set Referrer-Policy "no-referrer"
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_ssl_access.log combined
</VirtualHost>
EOF

a2ensite nextcloud-ssl.conf || true
a2enmod ssl || true
safe_systemctl restart apache2

warn "Note: Cloudflare Tunnel terminates TLS at the edge. Use the origin cert above for end-to-end encryption when 'Full (strict)' mode is enabled in Cloudflare SSL/TLS settings."


# ************************************************
# 11. Fail2ban + UFW firewall setup (SSH protection)
# ************************************************

log "Installing fail2ban and configuring UFW firewall..."

apt install -y fail2ban
safe_systemctl enable --now fail2ban


# ********************
# 11.a UFW basic rules
# ********************

ufw default deny incoming
ufw default allow outgoing

# Allow HTTP/HTTPS (needed for Cloudflared local binding)
# *******************************************************

ufw allow 80,443,22/tcp
ufw --force enable || true
ufw allow 127.0.0.1:443/tcp comment 'Cloudflared local port'
warn "Ensure Cloudflared can bind to local ports 443/80 if firewall is enabled."

# Allow SSH with rate limiting
# ***************************

ufw limit ssh


# *********************
# 11.b Fail2ban SSH jail
# *********************

JAIL_CONF="/etc/fail2ban/jail.d/nextcloud-ssh.conf"
if [ ! -f "$JAIL_CONF" ]; then
    cat > "$JAIL_CONF" <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF
    safe_systemctl restart fail2ban
    log "Fail2ban SSH jail configured and service restarted."
else
    log "Fail2ban SSH jail already exists; skipping."
fi

cat > /etc/fail2ban/filter.d/nextcloud.conf <<'EOF'
[Definition]
failregex = Login failed: '.*' \(Remote IP: '<HOST>'\)
ignoreregex =
EOF

cat > /etc/fail2ban/jail.d/nextcloud.conf <<'EOF'
[nextcloud]
enabled = true
filter = nextcloud
port = http,https
logpath = /var/www/html/nextcloud/data/nextcloud.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

safe_systemctl restart fail2ban

log "Fail2ban Nextcloud protection enabled."

# *******************************************
# 12. Services Restart & Systemd Restart Policies
# *******************************************

log "Configuring essential services for auto-start and restart policies..."

# Define all essential services
# *****************************
SERVICES=("apache2" "${PHP_FPM_SERVICE}" "mariadb" "redis-server" "fail2ban" "cloudflared")

for s in "${SERVICES[@]}"; do
    # Check if the service exists in systemd
    # *************************************
    if systemctl list-unit-files | grep -q "^${s}.service"; then
        log "Applying systemd policy for service: $s"

        # Safely enable and start the service
        # ***********************************
        safe_systemctl enable --now "$s" || warn "⚠️ Failed to enable/start $s"

        # Create systemd override directory (if missing)
        # *********************************************
        OVERRIDE_DIR="/etc/systemd/system/${s}.d"
        mkdir -p "$OVERRIDE_DIR" || warn "Could not create override directory for $s"

        # Apply restart policy & hardening (overwrite old if exists)
        # *********************************************************
        cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Service]
Restart=always
RestartSec=5

# Security Hardening
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/var/log /run /etc
EOF

    else
        warn "⚠️ Service $s not found — skipping systemd policy setup."
    fi
done

# Reload systemd daemon and restart services safely
# *************************************************
safe_systemctl daemon-reload
for s in "${SERVICES[@]}"; do
    systemctl restart "$s" 2>/dev/null || warn "⚠️ Could not restart $s"
done

log "✅ Systemd restart policies, security overrides, and auto-start configuration applied successfully."


# **********************************************
# 13. Nextcloud Cron Job Setup and Service Enable
# **********************************************

log "Setting up Nextcloud cron job for user: www-data..."

# Detect correct Nextcloud cron.php path
# **************************************
if [ -f "/var/snap/nextcloud/current/htdocs/cron.php" ]; then
    CRON_PATH="/var/snap/nextcloud/current/htdocs/cron.php"
elif [ -f "/var/www/html/nextcloud/cron.php" ]; then
    CRON_PATH="/var/www/html/nextcloud/cron.php"
else
    err "❌ Could not locate Nextcloud cron.php!"
fi

# Ensure the cron job is added once only
# **************************************
TMP_CRON="/tmp/current_cron"

# Backup existing cron entries (excluding old nextcloud line)
# ********************************************************
sudo -u www-data crontab -l 2>/dev/null | grep -v "$CRON_PATH" > "$TMP_CRON" || true

# Add fresh cron entry
# ********************
echo "*/5 * * * * php -f $CRON_PATH" >> "$TMP_CRON"

# Apply new cron configuration
sudo -u www-data crontab "$TMP_CRON"
rm -f "$TMP_CRON"

log "✅ Nextcloud cron job configured: runs every 5 minutes -> $CRON_PATH"

# Enable and verify cloudflared and snapd (if applicable)
# *******************************************************
OPTIONAL_SERVICES=("snapd" "cloudflared")

for svc in "${OPTIONAL_SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${svc}"; then
        safe_systemctl enable --now "$svc" || warn "⚠️ Optional service $svc could not be started."
    else
        warn "ℹ️ Optional service $svc not found, skipping..."
    fi
done

log "✅ Optional services checked and started where available."
log "-----------------------------------------------------------"
log "Installation complete!"
log "📄 Check installation log at: $LOGFILE"
log "🌐 Visit your Nextcloud instance via your Cloudflare domain."
log "-----------------------------------------------------------"


# ******************************************************
# 14. Cloudflare Recommended: Strict SSL Setting Reminder
# ******************************************************

echo ""
echo "================================================================="
echo "🔒 IMPORTANT TLS NOTE:"
echo "- Cloudflare Tunnel terminates TLS at the Cloudflare Edge by default."
echo "- For **true end-to-end encryption**, enable **'Full (Strict)'** mode in Cloudflare SSL/TLS settings."
echo "- Use a **Cloudflare Origin CA certificate** or the local certificate generated earlier."
echo "================================================================="
echo ""

# Secure unified log path
# ************************
if [ -f "$LOGFILE" ]; then
    chmod 600 "$LOGFILE" || warn "⚠️ Failed to set permissions for $LOGFILE"
    log "Installation log saved to $LOGFILE"
else
    warn "⚠️ Log file not found at $LOGFILE — skipping chmod."
fi


# ******************************************************
# 14.a Daily Cron Health Check (Nextcloud + Cloudflared)
# ******************************************************

log "Installing daily health check cron job..."

HEALTH_CRON="/etc/cron.daily/nextcloud_healthcheck"
HEALTH_LOG="/var/log/nextcloud_health.log"

cat > "$HEALTH_CRON" <<'EOF'
#!/bin/bash
LOGFILE="/var/log/nextcloud_health.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running Nextcloud & Cloudflared health check..." >> "$LOGFILE"

# Apache2 check
if ! systemctl is-active --quiet apache2; then
    systemctl restart apache2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Apache2 restarted." >> "$LOGFILE"
fi

# Cloudflared check
if ! systemctl is-active --quiet cloudflared; then
    systemctl restart cloudflared
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cloudflared restarted." >> "$LOGFILE"
fi

# Redis check (optional but recommended)
if ! systemctl is-active --quiet redis-server; then
    systemctl restart redis-server
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Redis restarted." >> "$LOGFILE"
fi

# MariaDB check
if ! systemctl is-active --quiet mariadb; then
    systemctl restart mariadb
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MariaDB restarted." >> "$LOGFILE"
fi

# Nextcloud HTTP status check
DOMAIN_FILE="/etc/cloudflared/config.yml"
if [ -f "$DOMAIN_FILE" ]; then
    DOMAIN=$(grep 'hostname:' "$DOMAIN_FILE" | awk '{print $2}' | head -n1)
    NEXTCLOUD_URL="https://${DOMAIN}/status.php"
    if ! curl -fs "$NEXTCLOUD_URL" >/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Nextcloud seems unreachable at $NEXTCLOUD_URL" >> "$LOGFILE"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Cloudflared config.yml not found; skipping Nextcloud URL check." >> "$LOGFILE"
fi

# ================================================
# 📡 TELEGRAM ALERT (Optional Future Integration)
# ================================================
# Uncomment and configure the lines below to enable Telegram alerts:
#
# TELEGRAM_TOKEN="123456:ABC-YourBotToken"
# CHAT_ID="123456789"
#
# send_alert() {
#   local msg="$1"
#   curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
#        -d "chat_id=${CHAT_ID}" \
#        -d "text=${msg}" >/dev/null
# }
#
# Example integration:
# if ! systemctl is-active --quiet apache2; then
#     systemctl restart apache2
#     send_alert "⚠️ Apache2 restarted on $(hostname)"
# fi
#
# if ! curl -fs "$NEXTCLOUD_URL" >/dev/null; then
#     send_alert "❌ Nextcloud unreachable on $(hostname): $NEXTCLOUD_URL"
# fi
# ================================================
EOF

chmod +x "$HEALTH_CRON"
log "✅ Daily health check cron job installed at: $HEALTH_CRON"
log "Logs will be written to: $HEALTH_LOG"



# *****************************
# 15. Cleanup & Final Summary
# *****************************

# Security cleanup
# ****************
unset NEXTCLOUD_DB_PASS NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASS
unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE_ID EMAIL
unset CREATE_RESP CRED_RESP ZONE_INFO EXISTING_TUNNEL TUNNEL_ID
unset CREDENTIALS_JSON CREDENTIALS_JSON_PATH DNS_CHECK EXISTING_ID
unset UPDATE_RESP CREATE_PAYLOAD UPDATE_PAYLOAD IMPORT_FILE

log "🧹 Sensitive variables cleared from memory."

# Clean package cache
# ********************
apt clean
# apt autoremove -y   # optional, uncomment if you want cleanup

# ============================
# Final Summary & Information
# ============================
echo -e "\n\e[1;36m====================================================\e[0m"
log "INSTALL SCRIPT FINISHED — some manual checks may be required."
echo ""

echo "🌐 Access Nextcloud at: https://${DOMAIN} (via Cloudflare Tunnel or CNAME)"
echo ""
echo "🔎 Verify:"
echo " - Nextcloud trusted_domains includes ${DOMAIN} → (sudo -u www-data php occ config:system:get trusted_domains)"
echo " - Cloudflare DNS CNAME → ${DOMAIN} ➜ ${TUNNEL_ID}.cfargotunnel.com"
echo " - If API headless path failed: run"
echo "     cloudflared tunnel login && cloudflared tunnel route dns ${TUNNEL_NAME} ${DOMAIN}"
echo ""
echo "📁 Tunnel name: ${TUNNEL_NAME}"
echo "🆔 Tunnel ID: ${TUNNEL_ID}"
echo "💾 Data dir: ${DATA_DIR}"
echo "🗄️  Database: ${NEXTCLOUD_DB}, User: ${NEXTCLOUD_DB_USER}"
echo -e "\e[1;36m====================================================\e[0m"
echo ""

# ============================
# Final Service Status Check
# ============================

log "Running final service checks..."

# Detect PHP-FPM services
PHP_SERVICES=$(systemctl list-units --type=service --no-legend | grep php | awk '{print $1}')

# Verify Apache2 & MariaDB first
if systemctl is-active --quiet apache2 && systemctl is-active --quiet mariadb; then
    PHP_OK=true

    for svc in $PHP_SERVICES; do
        if ! systemctl is-active --quiet "$svc"; then
            warn "⚠️  $svc is not active."
            PHP_OK=false
        fi
    done

    if [ "$PHP_OK" = true ]; then
        log "✅ All PHP-FPM services are active."
    else
        log "⚠️  One or more PHP-FPM services may not be active."
    fi

    log "✅ Core services (Apache2 & MariaDB) are active — Installation successful!"
else
    log "⚠️  One or more core services (Apache2/MariaDB) are not active. Please review logs."
fi

# Show current service statuses
# *****************************
log "Service statuses:"
for s in apache2 mariadb redis-server cloudflared "$PHP_FPM_SERVICE"; do
    systemctl status "$s" --no-pager 2>/dev/null || warn "⚠️  $s status check failed."
done

echo -e "\e[1;36m====================================================\e[0m"
echo -e "\e[1;32m✅ Installation completed successfully!\e[0m"
echo ""

# ============================
# Reboot Recommendation
# ============================

echo -e "\e[1;33mIt is recommended to reboot once to finalize setup:\e[0m"
echo -e "\e[1;36msudo reboot\e[0m"
echo -e "\e[1;36m====================================================\e[0m"
echo ""
