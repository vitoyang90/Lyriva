FROM composer:2 AS composer
FROM php:8.3-cli
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip git \
    && rm -rf /var/lib/apt/lists/*
COPY --from=composer /usr/bin/composer /usr/local/bin/composer
WORKDIR /app
# Pin the upstream implementation so builds do not silently track main.
RUN curl --fail --show-error --location https://github.com/akashrchandran/spotify-lyrics-api/archive/e158b96b854778d8ff51a3c9544ebb4f68b64907.tar.gz \
    | tar -xz --strip-components=1 \
    && composer install --no-dev --no-interaction --prefer-dist --no-scripts --no-plugins
COPY harden.php /tmp/harden.php
RUN php /tmp/harden.php
COPY router.php /app/router.php
RUN useradd --create-home lyrics
USER lyrics
EXPOSE 8080
CMD ["php", "-S", "0.0.0.0:8080", "router.php"]
