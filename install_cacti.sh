#!/bin/bash

# Ensure the script is run as root or with sudo
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root or with sudo." >&2
  exit 1
fi

# Your script logic here
echo "Running as root or with sudo. Proceeding..."

# Variables
DB_NAME="cacti"
DB_USER="cacti_user"
DB_PASS=$(openssl rand -base64 16) # Generate a secure random password
DB_HOST="localhost"
TIMEZONE=$(timedatectl show --property=Timezone --value) # Get the system timezone
LOG_FILE="/var/log/cacti_install.log"
RAM_MB=$(free -m | awk '/^Mem:/{print $2}') # Total RAM in MB
INNODB_BUFFER_POOL_SIZE_MB=$((RAM_MB * 70 / 100)) # Allocate 70% of total RAM for InnoDB Buffer Pool

# Logging setup
sudo mkdir -p /var/log && sudo touch ${LOG_FILE} && sudo chown $(whoami) ${LOG_FILE} && exec > >(tee -a ${LOG_FILE}) 2>&1
sudo chmod 600 ${LOG_FILE} # Restrict log file access
echo "Installation started at $(date)"

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Function to install PHP if not already installed
install_php() {
    if ! command -v php > /dev/null 2>&1; then
        echo "PHP is not installed. Installing PHP..."
        sudo apt update || handle_error "Failed to update packages"
        sudo apt install -y -qq php php-cli php-fpm php-mysql php-xml \
            php-gd php-snmp php-curl php-mbstring php-ldap php-zip \
            php-bcmath php-soap php-gmp php-intl || handle_error "Failed to install PHP"
    fi
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    echo "PHP version $PHP_VERSION is installed."
}

# Function to update PHP settings in all relevant ini files
update_php_settings() {
    local key=$1
    local value=$2

    # Locate all php.ini files
    PHP_INI_FILES=$(find /etc/php/ -name "php.ini")

    echo "Updating PHP settings: $key = $value"
    for ini_file in $PHP_INI_FILES; do
        if sudo grep -q "^$key" "$ini_file"; then
            sudo sed -i "s/^$key.*/$key = $value/" "$ini_file"
        else
            echo "$key = $value" | sudo tee -a "$ini_file"
        fi
        echo "Updated $key in $ini_file"
    done
}

# Update packages and install dependencies
echo "Updating packages and installing dependencies..."
sudo apt update && sudo apt upgrade -y -qq || handle_error "Failed to update packages"
sudo apt install -y -qq wget git apache2 mariadb-server ntp expect rrdtool fping || handle_error "Failed to install dependencies"
echo "Dependencies installed."

# Check and install PHP if necessary
install_php

# Configure PHP settings
echo "Configuring PHP settings..."
update_php_settings "memory_limit" "800M"
update_php_settings "max_execution_time" "300"
update_php_settings "collation_server" "utf8mb4_unicode_ci"
echo "date.timezone = ${TIMEZONE}" | sudo tee -a /etc/php/$PHP_VERSION/fpm/php.ini /etc/php/$PHP_VERSION/cli/php.ini
sudo systemctl restart php${PHP_VERSION}-fpm || handle_error "Failed to restart PHP-FPM"
sudo systemctl restart apache2 || handle_error "Failed to restart Apache"
echo "PHP settings applied and services restarted."

# Optimize MariaDB settings
echo "Optimizing MariaDB settings..."
sudo bash -c "cat > /etc/mysql/mariadb.conf.d/99-custom.cnf" <<EOL
[mysqld]
collation_server = utf8mb4_unicode_ci
character_set_server = utf8mb4
max_heap_table_size = 512M
tmp_table_size = 512M
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE_MB}M
innodb_doublewrite = OFF
innodb_log_file_size = 512M
innodb_flush_log_at_trx_commit = 1
query_cache_size = 64M
query_cache_limit = 16M
join_buffer_size = 256M
sort_buffer_size = 256M
read_buffer_size = 4M
read_rnd_buffer_size = 8M
EOL

# Restart MariaDB
sudo systemctl restart mariadb || handle_error "Failed to restart MariaDB"
echo "MariaDB settings optimized."

# Install Cacti
echo "Cloning Cacti from GitHub..."
CACTI_DIR="/var/www/html/cacti"

if [ -d "$CACTI_DIR" ]; then
    echo "Cacti directory already exists. Skipping Git clone..."
else
    cd /var/www/html || handle_error "Failed to change directory to /var/www/html"
    sudo git clone https://github.com/Cacti/cacti.git cacti || handle_error "Failed to clone Cacti repository"
fi

cd "$CACTI_DIR" || handle_error "Failed to change directory to Cacti"

# Ask user to select the database schema file
USER_HOME=$(eval echo "~${SUDO_USER}")
echo "Select the database schema to import:"
echo "Listing available .sql files in the SUDO_USER's home directory: $USER_HOME"

# List all .sql files in the SUDO_USER's home directory
shopt -s nullglob
SQL_FILES=("$USER_HOME"/*.sql)
shopt -u nullglob

if [ ${#SQL_FILES[@]} -eq 0 ]; then
    echo "No .sql files found in the SUDO_USER's home directory."
else
    for idx in "${!SQL_FILES[@]}"; do
        echo "$((idx + 1)). ${SQL_FILES[$idx]}"
    done
fi

while true; do
    echo
    echo "Please choose one of the following options:"
    echo "- Enter 'default' to use the default schema (cacti.sql)."
    echo "- Enter the number corresponding to a file listed above."
    echo "- Specify the path to a custom schema file."
    echo "- Type 'exit' to quit."

    read -rp "Your choice: " schema_choice

    if [[ "${schema_choice}" == "default" || -z "${schema_choice}" ]]; then
        DB_SCHEMA="/var/www/html/cacti/cacti.sql"
    elif [[ "${schema_choice}" == "exit" ]]; then
        echo "Exiting the script as requested."
        exit 0
    elif [[ "${schema_choice}" =~ ^[0-9]+$ ]] && [ "${schema_choice}" -ge 1 ] && [ "${schema_choice}" -le "${#SQL_FILES[@]}" ]; then
        DB_SCHEMA="${SQL_FILES[$((schema_choice - 1))]}"
    else
        DB_SCHEMA="${schema_choice}"
    fi

    # Verify that the selected schema file exists
    if [ -f "${DB_SCHEMA}" ]; then
        echo "Using schema file: ${DB_SCHEMA}"
        break
    else
        echo "Error: The schema file '${DB_SCHEMA}' does not exist. Please try again."
    fi
done


# Check if the database already exists and prompt the user to recreate it
echo "Creating Cacti database and user..."
DB_EXISTS=$(sudo mysql -u root -e "SHOW DATABASES LIKE '${DB_NAME}';" | grep "${DB_NAME}")
if [ "$DB_EXISTS" ]; then
    read -rp "The database '${DB_NAME}' already exists. Do you want to drop it and recreate a fresh one? [y/N]: " recreate_db_choice
    if [[ "${recreate_db_choice}" =~ ^[Yy]$ ]]; then
        sudo mysql -u root <<EOF
DROP DATABASE ${DB_NAME};
CREATE DATABASE ${DB_NAME};
EOF
        [ $? -ne 0 ] && handle_error "Failed to drop and recreate the database"
        echo "Database recreated."
        sudo mysql -u root ${DB_NAME} < "${DB_SCHEMA}" || handle_error "Failed to import database schema"
        echo "Database schema imported."
    else
        echo "Skipping database recreation."
    fi
else
    sudo mysql -u root <<EOF
CREATE DATABASE ${DB_NAME};
EOF
    [ $? -ne 0 ] && handle_error "Failed to create the database"
    echo "Database created."
    sudo mysql -u root ${DB_NAME} < "${DB_SCHEMA}" || handle_error "Failed to import database schema"
    echo "Database schema imported."
fi

# Create the database user and grant privileges
sudo mysql -u root <<EOF
CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_HOST}';
FLUSH PRIVILEGES;
EOF
[ $? -ne 0 ] && handle_error "Failed to create database user or grant privileges"

# Populate MySQL TimeZone database
echo "Populating MySQL TimeZone database..."
sudo mysql_tzinfo_to_sql /usr/share/zoneinfo | sudo mysql -u root -D mysql || handle_error "Failed to populate MySQL TimeZone database"
echo "MySQL TimeZone database populated."

# Grant SELECT access to the TimeZone table for the Cacti user
echo "Granting SELECT access on time_zone_name to ${DB_USER}..."
sudo mysql -u root <<EOF
GRANT SELECT ON mysql.time_zone_name TO '${DB_USER}'@'${DB_HOST}';
FLUSH PRIVILEGES;
EOF
[ $? -ne 0 ] && handle_error "Failed to grant SELECT access to the time_zone_name table"
echo "Permissions granted."

# Enable required PHP modules
echo "Enabling required PHP modules..."
sudo a2enmod rewrite
sudo systemctl restart apache2 || handle_error "Apache restart failed"
echo "PHP modules enabled."

# Set up Cacti log directory
sudo mkdir -p /var/www/html/log
sudo chown -R www-data:www-data /var/www/html/log
sudo chmod -R 755 /var/www/html/log

# Set up Cacti log directory specifically under Cacti directory
if [ ! -d "/var/www/html/cacti/log" ]; then
    sudo mkdir -p /var/www/html/cacti/log
fi
sudo chown -R www-data:www-data /var/www/html/cacti/log
sudo chmod -R 755 /var/www/html/cacti/log

# Create the cacti.log file if it doesn't exist and update ownership and permissions
if [ ! -f "/var/www/html/cacti/log/cacti.log" ]; then
    sudo touch /var/www/html/cacti/log/cacti.log
fi
sudo chown www-data:www-data /var/www/html/cacti/log/cacti.log
sudo chmod 644 /var/www/html/cacti/log/cacti.log


# Set up Cacti's config file
echo "Setting up Cacti config file..."
sudo cp /var/www/html/cacti/include/config.php.dist /var/www/html/cacti/include/config.php
sudo sed -i "s#^\(\$database_default *= *\).*#\1'${DB_NAME}';#" /var/www/html/cacti/include/config.php
sudo sed -i "s#^\(\$database_username *= *\).*#\1'${DB_USER}';#" /var/www/html/cacti/include/config.php
sudo sed -i "s#^\(\$database_password *= *\).*#\1'${DB_PASS}';#" /var/www/html/cacti/include/config.php
sudo sed -i "s#^\(\$database_hostname *= *\).*#\1'${DB_HOST}';#" /var/www/html/cacti/include/config.php
sudo sed -i "s#^\(\$url_path *= *\).*#\1'/';#" /var/www/html/cacti/include/config.php
sudo chmod 640 /var/www/html/cacti/include/config.php
sudo chown -R www-data:www-data /var/www/html/cacti/
echo "Cacti config file updated."

# Configure Apache VirtualHost for Cacti
echo "Configuring Apache VirtualHost for Cacti..."
echo "<VirtualHost *:80>
    ErrorLog /var/www/html/log/cacti_error.log
    CustomLog /var/www/html/log/cacti_access.log combined
    DocumentRoot /var/www/html/cacti
    ServerName localhost
    <Directory /var/www/html/cacti>
        Options Indexes FollowSymLinks MultiViews
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>" | sudo tee /etc/apache2/sites-available/cacti.conf

# Enable the new site, disable default, and restart Apache
sudo a2dissite 000-default.conf
sudo a2ensite cacti.conf
sudo systemctl restart apache2 || handle_error "Apache failed to restart with the new configuration"
echo "Apache configured."

# Poller selection menu
echo "Choose Cacti poller type:"
echo "1) Cron Poller (1-minute interval)"
echo "2) Install Cactid and Spine"
read -rp "Enter choice [1 or 2]: " poller_choice

case $poller_choice in
    1)
        echo "Setting up Cron poller..."
        sudo -u www-data touch /var/www/html/cacti/poller.log && sudo chown www-data:www-data /var/www/html/cacti/poller.log
        (crontab -l 2>/dev/null; echo "* * * * * php /var/www/html/cacti/poller.php > /var/www/html/cacti/poller.log 2>&1") | crontab - || handle_error "Failed to set up Cron poller"
        echo "Cron poller set up at 1-minute intervals."
        ;;
    2)
        echo "Installing Cactid and Spine..."

        # Install Cactid
        echo "Setting up Cactid poller..."
        CACTID_SERVICE_PATH="/var/www/html/cacti/service/cactid.service"
        SYSTEMD_SERVICE_PATH="/etc/systemd/system/cactid.service"
        SYSCONFIG_PATH="/etc/sysconfig/cactid"

        if [ -f "${CACTID_SERVICE_PATH}" ]; then
            if [ ! -d "/etc/sysconfig" ]; then
                sudo mkdir -p "/etc/sysconfig" || handle_error "Failed to create /etc/sysconfig directory"
            fi

            # Update User and Group in cactid.service file
            APACHE_USER=$(ps -eo user,comm | grep apache2 | head -n 1 | awk '{print $1}')
            APACHE_GROUP=$(id -gn $APACHE_USER)
            sudo sed -i "s/^User=.*/User=$APACHE_USER/" "$CACTID_SERVICE_PATH"
            sudo sed -i "s/^Group=.*/Group=$APACHE_GROUP/" "$CACTID_SERVICE_PATH"
            echo "Updated User and Group in cactid.service to $APACHE_USER:$APACHE_GROUP"

            # Copy cactid.service to systemd directory
            sudo cp "$CACTID_SERVICE_PATH" "$SYSTEMD_SERVICE_PATH" || handle_error "Failed to copy cactid.service to systemd directory"
            echo "Copied cactid.service to $SYSTEMD_SERVICE_PATH"

            sudo touch "${SYSCONFIG_PATH}" || handle_error "Failed to create /etc/sysconfig/cactid"
            sudo systemctl enable cactid || handle_error "Failed to enable cactid service"
            sudo systemctl start cactid || handle_error "Failed to start cactid service"
            sudo systemctl status cactid || handle_error "Cactid service is not running properly"
            echo "Cactid service installed and running."
        else
            handle_error "Cactid service file not found at ${CACTID_SERVICE_PATH}"
        fi

        # Install Spine
        echo "Installing Spine poller..."
        cd /tmp || handle_error "Failed to change to /tmp directory"
        sudo apt install -y -qq help2man build-essential autoconf automake libtool pkg-config libmariadb-dev libsnmp-dev || handle_error "Failed to install build tools and dependencies"
        sudo git clone https://github.com/Cacti/spine.git || handle_error "Failed to clone Spine repository"
        cd spine || handle_error "Failed to change directory to spine"
        ./bootstrap && ./configure && make && sudo make install || handle_error "Failed to build and install Spine"
        echo "Spine poller installed."
        echo 'export PATH=$PATH:/usr/local/spine/bin' | sudo tee /etc/profile.d/spine.sh
        sudo chmod +x /etc/profile.d/spine.sh
        source /etc/profile.d/spine.sh

        echo "Cactid and Spine installed successfully."
        ;;
    *)
        handle_error "Invalid choice. Exiting."
        ;;
esac

echo "Cacti installation complete! Access Cacti at http://localhost"
echo "Database Name: ${DB_NAME}"
echo "Database User: ${DB_USER}"
echo "Database Password: ${DB_PASS}"
