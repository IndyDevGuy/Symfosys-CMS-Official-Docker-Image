# =========================
# 1) BUILDER (compile PHP/PECL extensions)
# =========================
FROM php:8.5.3-fpm-alpine AS builder

ENV LUAJIT_LIB=/usr/lib
ENV LUAJIT_INC=/usr/include/luajit-2.1

ENV LD_PRELOAD=/usr/lib/preloadable_libiconv.so
RUN apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community gnu-libiconv

RUN apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    linux-headers \
    gcc g++ make cmake autoconf pkgconf musl-dev \
    icu-dev \
    libzip-dev \
    bzip2-dev \
    curl-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libxslt-dev \
    libxml2-dev \
    postgresql-dev \
    sqlite-dev \
    tidyhtml-dev

RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" \
    gd \
    pdo_mysql mysqli \
    pdo_sqlite \
    pgsql pdo_pgsql \
    exif \
    intl \
    xsl \
    soap \
    zip \
    tidy

RUN pecl install -o -f xdebug redis apcu \
 && docker-php-ext-enable xdebug redis apcu

RUN curl -sS https://getcomposer.org/installer | php -- \
      --install-dir=/usr/local/bin --filename=composer

RUN docker-php-source delete \
 && apk del --no-network .build-deps


# =========================
# 2) RUNTIME (lean image)
# =========================
FROM php:8.5.3-fpm-alpine

LABEL maintainer="Trey Ellis <contact@indydevguy.com>"

ENV php_conf=/usr/local/etc/php-fpm.conf
ENV fpm_conf=/usr/local/etc/php-fpm.d/www.conf
ENV php_vars=/usr/local/etc/php/conf.d/docker-vars.ini

ENV LUAJIT_LIB=/usr/lib
ENV LUAJIT_INC=/usr/include/luajit-2.1

ENV LD_PRELOAD=/usr/lib/preloadable_libiconv.so
RUN apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community gnu-libiconv

RUN apk add --no-cache \
    nginx \
    nginx-mod-http-lua \
    nginx-mod-devel-kit \
    supervisor \
    bash \
    curl \
    wget \
    openssh-client \
    git \
    docker-cli \
    tzdata \
    python3 \
    py3-pip \
    dialog \
    yarn \
    certbot \
    lua-resty-core \
    icu-libs \
    libzip \
    libpng \
    libjpeg-turbo \
    freetype \
    libxslt \
    libxml2 \
    libpq \
    sqlite-libs \
    tidyhtml

RUN addgroup www-data ping

# Copy compiled PHP extensions
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/bin/composer /usr/local/bin/composer

# IMPORTANT:
# Don't blindly copy all conf.d from builder if your repo/scripts also add INIs.
# Instead: copy only the docker-php-ext enable INIs we want.
COPY --from=builder /usr/local/etc/php/conf.d/docker-php-ext-*.ini /usr/local/etc/php/conf.d/

# Supervisor config
ADD conf/supervisord.conf /etc/supervisord.conf

# Nginx config
RUN rm -f /etc/nginx/nginx.conf
ADD conf/nginx.conf /etc/nginx/nginx.conf

# Nginx site conf
RUN mkdir -p /etc/nginx/sites-available/ \
    /etc/nginx/sites-enabled/ \
    /etc/nginx/ssl/ \
 && rm -rf /var/www/* \
 && mkdir -p /var/www/html/
ADD conf/nginx-site.conf /etc/nginx/sites-available/default.conf
ADD conf/nginx-site-ssl.conf /etc/nginx/sites-available/default-ssl.conf
RUN ln -sf /etc/nginx/sites-available/default.conf /etc/nginx/sites-enabled/default.conf

# PHP-FPM + php.ini tweaks (bulletproof listen fix)
RUN echo "cgi.fix_pathinfo=0" > ${php_vars} \
 && echo "upload_max_filesize = 100M"  >> ${php_vars} \
 && echo "post_max_size = 100M"        >> ${php_vars} \
 && echo "variables_order = \"EGPCS\"" >> ${php_vars} \
 && echo "memory_limit = 128M"         >> ${php_vars} \
 && sed -i \
    -e "s/;catch_workers_output\\s*=\\s*yes/catch_workers_output = yes/g" \
    -e "s/pm.max_children = 5/pm.max_children = 4/g" \
    -e "s/pm.start_servers = 2/pm.start_servers = 3/g" \
    -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g" \
    -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 4/g" \
    -e "s/;pm.max_requests = 500/pm.max_requests = 200/g" \
    -e "s/user = www-data/user = nginx/g" \
    -e "s/group = www-data/group = nginx/g" \
    -e "s/;listen.mode = 0660/listen.mode = 0666/g" \
    -e "s/;listen.owner = www-data/listen.owner = nginx/g" \
    -e "s/;listen.group = www-data/listen.group = nginx/g" \
    -e 's~^[;[:space:]]*listen[[:space:]]*=.*$~listen = /var/run/php-fpm.sock~' \
    -e "s/^;clear_env = no$/clear_env = no/" \
    ${fpm_conf} \
 # If listen still isn't present (some templates are weird), append it.
 && grep -qE '^[[:space:]]*listen[[:space:]]*=' ${fpm_conf} || echo "listen = /var/run/php-fpm.sock" >> ${fpm_conf} \
 && mkdir -p /var/run \
 && chown -R nginx:nginx /var/run \
 && cp /usr/local/etc/php/php.ini-development /usr/local/etc/php/php.ini \
 && sed -i -e "s/;opcache/opcache/g" /usr/local/etc/php/php.ini

# Scripts
ADD scripts/start.sh /start.sh
ADD scripts/pull /usr/bin/pull
ADD scripts/push /usr/bin/push
ADD scripts/letsencrypt-setup /usr/bin/letsencrypt-setup
ADD scripts/letsencrypt-renew /usr/bin/letsencrypt-renew
RUN chmod 755 /usr/bin/pull /usr/bin/push /usr/bin/letsencrypt-setup /usr/bin/letsencrypt-renew /start.sh

# App code
ADD src/ /var/www/html/
ADD errors/ /var/www/errors

EXPOSE 443 80
WORKDIR "/var/www/html"
CMD ["/start.sh"]
