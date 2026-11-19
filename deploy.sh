#!/usr/bin/env bash
# Production deploy script, run on the Hostinger server from the app folder.
# The GitHub Actions workflow (.github/workflows/deploy.yml) first uploads the
# built Vite assets to .deploy/build.tar.gz and resets the code to origin/main,
# then runs this script. To run it by hand:
#   ssh -p 65002 uXXXX@host "cd /path/to/app && git pull && bash deploy.sh"
set -euo pipefail

# Hostinger's default CLI php can be older than the site's; pick PHP >= 8.1.
# Override with:  PHP_BIN=/path/to/php bash deploy.sh
if [ -z "${PHP_BIN:-}" ]; then
    for candidate in /opt/alt/php83/usr/bin/php /opt/alt/php82/usr/bin/php /opt/alt/php81/usr/bin/php php; do
        if command -v "$candidate" >/dev/null 2>&1; then
            PHP_BIN="$candidate"
            break
        fi
    done
fi
COMPOSER_BIN="${COMPOSER_BIN:-$(command -v composer || true)}"
if [ -z "$COMPOSER_BIN" ]; then
    echo "composer not found; set COMPOSER_BIN=/path/to/composer" >&2
    exit 1
fi
echo "==> Using PHP: $PHP_BIN ($("$PHP_BIN" -r 'echo PHP_VERSION;'))"

echo "==> Entering maintenance mode"
"$PHP_BIN" artisan down --retry=60 || true

echo "==> Installing PHP dependencies"
COMPOSER_FLAGS=(--no-dev --prefer-dist --optimize-autoloader --no-interaction)
# lcobucci/jwt (via jwt-auth) lists ext-sodium, which some Hostinger CLI PHP
# builds lack. Sodium is only used for EdDSA/BLAKE2b tokens, not the default
# HS256, so skip the check only when the extension is missing.
if ! "$PHP_BIN" -m | grep -qi '^sodium$'; then
    echo "    ext-sodium missing in CLI PHP; ignoring that platform requirement"
    COMPOSER_FLAGS+=(--ignore-platform-req=ext-sodium)
fi
"$PHP_BIN" "$COMPOSER_BIN" install "${COMPOSER_FLAGS[@]}"

echo "==> Running database migrations"
"$PHP_BIN" artisan migrate --force

echo "==> Installing frontend assets"
# public/build is gitignored; the workflow uploads it as a tarball.
if [ -f .deploy/build.tar.gz ]; then
    rm -rf public/build.new public/build.old
    mkdir -p public/build.new
    tar -xzf .deploy/build.tar.gz -C public/build.new --strip-components=1
    if [ -d public/build ]; then mv public/build public/build.old; fi
    mv public/build.new public/build
    rm -rf public/build.old .deploy/build.tar.gz
    echo "    public/build replaced"
else
    echo "    no .deploy/build.tar.gz found; keeping the current public/build"
fi

echo "==> Rebuilding caches"
# Do NOT config:cache: the app calls env() at runtime (app/Classes/start.php,
# APP_ENV checks in controllers), which returns null once config is cached.
"$PHP_BIN" artisan optimize:clear
"$PHP_BIN" artisan view:cache
"$PHP_BIN" artisan storage:link --force || true

echo "==> Leaving maintenance mode"
"$PHP_BIN" artisan up

echo "==> Deployed $(git rev-parse --short HEAD) successfully"
