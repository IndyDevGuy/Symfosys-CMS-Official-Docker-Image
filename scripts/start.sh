#!/bin/bash

# Disable Strict Host checking for non interactive git clones

mkdir -p /root/.ssh
chmod 0700 /root/.sh
# Prevent config files from being filled to infinity by force of stop and restart the container 
echo "" > /root/.ssh/config
echo -e "Host *\n\tStrictHostKeyChecking no\n" >> /root/.ssh/config

if [[ "$GIT_USE_SSH" == "1" ]] ; then
  echo -e "Host *\n\tUser ${GIT_USERNAME}\n\n" >> /root/.ssh/config
fi

if [ -n "$SSH_KEY" ]; then
 echo "$SSH_KEY" > /root/.ssh/id_rsa.base64
 base64 -d /root/.ssh/id_rsa.base64 > /root/.ssh/id_rsa
 chmod 600 /root/.ssh/id_rsa
fi

# Set custom webroot
# shellcheck disable=SC2153
if [ -n "$WEBROOT" ]; then
 sed -i "s#root /var/www/html;#root ${WEBROOT};#g" /etc/nginx/sites-available/default.conf
else
 # shellcheck disable=SC2034
 webroot=/var/www/html
fi

# Enables 404 pages through php index
if [ -n "$PHP_CATCHALL" ]; then
 # shellcheck disable=SC2154
 sed -i "s#try_files $uri $uri/ =404;#try_files $uri $uri/ /index.php?$args;#g" /etc/nginx/sites-available/default.conf
fi


# Setup git variables
if [ -n "$GIT_EMAIL" ]; then
 git config --global user.email "$GIT_EMAIL"
fi
if [ -n "$GIT_NAME" ]; then
 git config --global user.name "$GIT_NAME"
 git config --global push.default simple
fi

# Dont pull code down if the .git folder exists
if [ ! -d "/var/www/html/.git" ]; then
 # Pull down code from git for our site!
 if [ -n "$GIT_REPO" ]; then
   # Remove the test index file if you are pulling in a git repo
   if [ -n "${REMOVE_FILES}" ] && [ "${REMOVE_FILES}" == 0 ]; then
     echo "skipping removal of files"
   else
     rm -Rf /var/www/html/*
   fi
   GIT_COMMAND='git clone '
   if [ -n "$GIT_BRANCH" ]; then
     GIT_COMMAND=${GIT_COMMAND}" -b ${GIT_BRANCH}"
   fi

   if [ -z "$GIT_USERNAME" ] && [ -z "$GIT_PERSONAL_TOKEN" ]; then
     GIT_COMMAND=${GIT_COMMAND}" ${GIT_REPO}"
   else
    if [[ "$GIT_USE_SSH" == "1" ]]; then
      GIT_COMMAND=${GIT_COMMAND}" ${GIT_REPO}"
    else
      GIT_COMMAND=${GIT_COMMAND}" https://${GIT_USERNAME}:${GIT_PERSONAL_TOKEN}@${GIT_REPO}"
    fi
   fi
   ${GIT_COMMAND} /var/www/html || exit 1
   if [ -n "$GIT_TAG" ]; then
     git checkout "${GIT_TAG}" || exit 1
   fi
   if [ -n "$GIT_COMMIT" ]; then
     git checkout "${GIT_COMMIT}" || exit 1
   fi
   if [ -z "$SKIP_CHOWN" ]; then
     chown -Rf nginx.nginx /var/www/html
   fi
 fi
fi

# Enable custom nginx config files if they exist
if [ -f /var/www/html/conf/nginx/nginx.conf ]; then
  cp /var/www/html/conf/nginx/nginx.conf /etc/nginx/nginx.conf
fi

if [ -f /var/www/html/conf/nginx/nginx-site.conf ]; then
  cp /var/www/html/conf/nginx/nginx-site.conf /etc/nginx/sites-available/default.conf
fi

if [ -f /var/www/html/conf/nginx/nginx-site-ssl.conf ]; then
  cp /var/www/html/conf/nginx/nginx-site-ssl.conf /etc/nginx/sites-available/default-ssl.conf
fi


# Prevent config files from being filled to infinity by force of stop and restart the container
lastlinephpconf="$(grep "." /usr/local/etc/php-fpm.conf | tail -1)"
if [[ $lastlinephpconf == *"php_flag[display_errors]"* ]]; then
 sed -i '$ d' /usr/local/etc/php-fpm.conf
fi

# Display PHP error's or not
if [[ "$ERRORS" != "1" ]] ; then
 echo "php_flag[display_errors] = off" >> /usr/local/etc/php-fpm.d/www.conf
else
 echo "php_flag[display_errors] = on" >> /usr/local/etc/php-fpm.d/www.conf
fi

# Display Version Details or not
if [[ "$HIDE_NGINX_HEADERS" == "0" ]] ; then
 sed -i "s/server_tokens off;/server_tokens on;/g" /etc/nginx/nginx.conf
else
 sed -i "s/expose_php = On/expose_php = Off/g" /usr/local/etc/php-fpm.conf
fi

# Pass real-ip to logs when behind ELB, etc
if [[ "$REAL_IP_HEADER" == "1" ]] ; then
 sed -i "s/#real_ip_header X-Forwarded-For;/real_ip_header X-Forwarded-For;/" /etc/nginx/sites-available/default.conf
 sed -i "s/#set_real_ip_from/set_real_ip_from/" /etc/nginx/sites-available/default.conf
 if [ -n "$REAL_IP_FROM" ]; then
  sed -i "s#172.16.0.0/12#$REAL_IP_FROM#" /etc/nginx/sites-available/default.conf
 fi
fi
# Do the same for SSL sites
if [ -f /etc/nginx/sites-available/default-ssl.conf ]; then
 if [[ "$REAL_IP_HEADER" == "1" ]] ; then
  sed -i "s/#real_ip_header X-Forwarded-For;/real_ip_header X-Forwarded-For;/" /etc/nginx/sites-available/default-ssl.conf
  sed -i "s/#set_real_ip_from/set_real_ip_from/" /etc/nginx/sites-available/default-ssl.conf
  if [ -n "$REAL_IP_FROM" ]; then
   sed -i "s#172.16.0.0/12#$REAL_IP_FROM#" /etc/nginx/sites-available/default-ssl.conf
  fi
 fi
fi

# Set the desired timezone
#echo "date.timezone=$(cat /etc/TZ)" > /usr/local/etc/php/conf.d/timezone.ini

# Display errors in docker logs
if [ -n "$PHP_ERRORS_STDERR" ]; then
  echo "log_errors = On" >> /usr/local/etc/php/conf.d/docker-vars.ini
  echo "error_log = /dev/stderr" >> /usr/local/etc/php/conf.d/docker-vars.ini
fi

# Increase the memory_limit
if [ -n "$PHP_MEM_LIMIT" ]; then
 sed -i "s/memory_limit = 128M/memory_limit = ${PHP_MEM_LIMIT}M/g" /usr/local/etc/php/conf.d/docker-vars.ini
fi

# Increase the post_max_size
if [ -n "$PHP_POST_MAX_SIZE" ]; then
 sed -i "s/post_max_size = 100M/post_max_size = ${PHP_POST_MAX_SIZE}M/g" /usr/local/etc/php/conf.d/docker-vars.ini
fi

# Increase the upload_max_filesize
if [ -n "$PHP_UPLOAD_MAX_FILESIZE" ]; then
 sed -i "s/upload_max_filesize = 100M/upload_max_filesize= ${PHP_UPLOAD_MAX_FILESIZE}M/g" /usr/local/etc/php/conf.d/docker-vars.ini
fi

# Enable xdebug
XdebugFile='/usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini'
if [[ "$ENABLE_XDEBUG" == "1" ]] ; then
  if [ -f $XdebugFile ]; then
  	echo "Xdebug enabled"
  else
  	echo "Enabling xdebug"
  	echo "If you get this error, you can safely ignore it: /usr/local/bin/docker-php-ext-enable: line 83: nm: not found"
  	# see https://github.com/docker-library/php/pull/420
    docker-php-ext-enable xdebug
    # see if file exists
    if [ -f $XdebugFile ]; then
        # See if file contains xdebug text.
        if grep -q xdebug.remote_enable "$XdebugFile"; then
            echo "Xdebug already enabled... skipping"
        else
            echo "zend_extension=$(find /usr/local/lib/php/extensions/ -name xdebug.so)" > $XdebugFile # Note, single arrow to overwrite file.
            {
              echo "xdebug.remote_enable=1 "
              "xdebug.remote_host=host.docker.internal"
              "xdebug.remote_log=/tmp/xdebug.log"
              "xdebug.remote_autostart=false "
            }  >> $XdebugFile
            # I use the xdebug chrome extension instead of using autostart
            # NOTE: xdebug.remote_host is not needed here if you set an environment variable in docker-compose like so `- XDEBUG_CONFIG=remote_host=192.168.111.27`.
            #       you also need to set an env var `- PHP_IDE_CONFIG=serverName=docker`
        fi
    fi
  fi
else
    if [ -f $XdebugFile ]; then
        echo "Disabling Xdebug"
      rm $XdebugFile
    fi
fi

# shellcheck disable=SC2153
if [ -n "$PUID" ]; then
  if [ -z "$PGID" ]; then
    PGID=${PUID}
  fi
  deluser nginx
  addgroup -g "${PGID}" nginx
  adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx -u "${PUID}" nginx
else
  if [ -z "$SKIP_CHOWN" ]; then
    chown -Rf nginx.nginx /var/www/html
  fi
fi

# Run custom scripts
if [[ "$RUN_SCRIPTS" == "1" ]] ; then
  if [ -d "/var/www/html/scripts/" ]; then
    # make scripts executable in case they aren't
    chmod -Rf 750 /var/www/html/scripts/*; sync;
    # run scripts in number order
    # shellcheck disable=SC2045
    for i in $(ls /var/www/html/scripts/); do /var/www/html/scripts/"$i" ; done
  else
    echo "Can't find script directory"
  fi
fi

if [ -d "/var/www/html/src/vendor/" ]; then
  echo "composer dependencies already installed, skipping installation.."
else
  echo "composer dependencies not found, starting installation.."

  echo "Checking for composer.json file..."
  if [ -f "/var/www/html/src/composer.json" ]; then
    echo "Found composer.json file, calling composer install"
    composer install --working-dir=/var/www/html/src
  fi

  #echo "Patching Eko/FeedBundle... making vendor/eko/feedbundle/Resources/config/command.xml"

  #echo "Creating folders for Eko/FeedBundle"
  #mkdir -p /var/www/html/src/vendor/eko/feedbundle/Resources/config

  #touch /var/www/html/src/vendor/eko/feedbundle/Resources/config/command.xml

  #if [ -e "/var/www/html/src/vendor/eko/feedbundle/Resources/config/command.xml" ]; then
  #  echo "created command.xml for Eko/FeedBundle..."
  #  printf '<?xml version="1.0" ?>\n <container xmlns="http://symfony.com/schema/dic/services" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://symfony.com/schema/dic/services http://symfony.com/schema/dic/services/services-1.0.xsd">\n <services>\n </services>\n </container>' > /var/www/html/src/vendor/eko/feedbundle/Resources/config/command.xml
  #fi

  cd /var/www/html/src || return

  #echo "creating .env file with your information.."
  #printf "APP_ENV=%s\n APP_SECRET=%s\n DATABASE_URL=mysql://%s:%s@%s:3306/%s?serverVersion=5.7" "$APPLICATION_ENV" "$APPLICATION_SECRET" "$DB_USERNAME" "$DB_PASSWORD" "$DB_HOST" "$DB_DATABASE" > /var/www/html/src/.env

  echo "Updating database..."
  php bin/console doctrine:schema:update --force

  echo "Fetching CKEditor..."
  php bin/console ckeditor:install

  echo "Installing bundled assets..."
  php bin/console assets:install public

  echo "Installing theme assets..."
  php bin/console idg_theme:theme:assets:install

  echo "Clearing Symfony cache..."
  php bin/console cache:clear

  if [ -n "$YARN" ]; then
      echo "Running yarn install..."
      yarn install
      echo "Running Webpack..."
      yarn encore dev
    else
      echo "Skipping yarn installation and webpack"
    fi

    echo "Symfony Initialization finished!"
  
fi


# Start supervisord and service
exec /usr/bin/supervisord -n -c /etc/supervisord.conf