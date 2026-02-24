#!/bin/bash
set -ex 

echo "--- STARTING MOODLE FIX ---"



chown -R www-data:www-data /var/moodledata

# 2. Give the web folder to Moodle's user
chown -R www-data:www-data /var/www/moodle

# 3. Ensure they have the right permissions
chmod -R 775 /var/www/moodledata

# 2. Database Wait Loop
echo "Waiting for $MOODLE_DB_HOST..."
until mariadb-admin ping -h"$MOODLE_DB_HOST" --silent; do
    sleep 2
    echo "DB not ready..."
done

# 3. THE FIX: Run the CLI installer with EXPLICIT paths
# We use /var/moodledata (the one we mapped in Docker)
if [ ! -f "/var/www/moodle/config.php" ]; then
    
    
    sudo -u www-data php /var/www/moodle/admin/cli/install.php \
        --wwwroot="https://moodle.hippity.internal" \
        --dataroot="/var/moodledata" \
        --dbtype="mariadb" \
        --dbhost="$MOODLE_DB_HOST" \
        --dbname="$MOODLE_DB_NAME" \
        --dbuser="$MOODLE_DB_USER" \
        --dbpass="$MOODLE_DB_PASS" \
        --fullname="$MOODLE_FULLNAME" \
        --shortname="$MOODLE_SHORTNAME" \
        --adminuser="$MOODLE_ADMINUSER" \
        --adminpass="$MOODLE_ADMINPASS" \
        --non-interactive \
        --agree-license
    
    echo "CLI Install Finished."
fi

echo "Starting Apache..."
exec "$@"