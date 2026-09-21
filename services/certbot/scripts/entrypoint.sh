#!/bin/sh
set -eu

CONFIG_FILE="/etc/certbot/silver.yaml"

# A domain is accepted only if it is a plain dot-separated hostname. Anything
# else (whitespace, a leading "-", a URL, ...) is rejected, because the value
# is passed straight to certbot as an argument and a value such as
# "example.com --server https://attacker.example/acme" would otherwise turn
# into extra certbot flags.
is_valid_domain() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
}

echo "========================================="
echo "  Multi-Domain Certificate Request"
echo "========================================="
echo ""

# Fail with a readable message instead of a bare grep error further down.
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: config file not found at $CONFIG_FILE"
    echo "Mount the Silver configuration into the container, e.g."
    echo "  - ../conf/silver.yaml:/etc/certbot/silver.yaml:ro"
    exit 1
fi

# Extract ALL domains from the domains list in silver.yaml using grep/sed
DOMAINS=$(grep '^\s*-\s*domain:' "$CONFIG_FILE" | sed 's/.*domain:\s*//' | xargs)

if [ -z "$DOMAINS" ]; then
    echo "❌ Error: No domains found in $CONFIG_FILE"
    echo "Please check that $CONFIG_FILE contains domains in the correct format:"
    echo "domains:"
    echo "  - domain: example.com"
    exit 1
fi

# Get primary domain for email
PRIMARY_DOMAIN=$(echo "$DOMAINS" | awk '{print $1}')

echo "Domains to be covered by this certificate:"

# Build the certbot invocation in the positional parameters rather than in a
# single string. Every argument stays a distinct, quoted word, so a domain
# value can never be split into additional certbot flags. Positional
# parameters are used instead of a bash array because this image
# (certbot/certbot, Alpine based) only ships /bin/sh.
set -- certonly --standalone --non-interactive --agree-tos \
    --email "admin@${PRIMARY_DOMAIN}" \
    --key-type rsa --keep-until-expiring --expand

for domain in $DOMAINS; do
    if ! is_valid_domain "$domain"; then
        echo "❌ Error: invalid domain in $CONFIG_FILE: '$domain'"
        echo "Domains must look like 'example.com' or 'mail.example.com'."
        exit 1
    fi
    echo "  • $domain"
    set -- "$@" -d "$domain"
done

# Add the mail subdomain for the primary domain at the end
echo "  • mail.$PRIMARY_DOMAIN"
set -- "$@" -d "mail.$PRIMARY_DOMAIN"

echo ""
echo "Using HTTP-01 challenge (port 80 required)"
echo "Starting certificate request..."
echo "========================================="
echo ""

# Replace this shell with certbot so it runs as PID 1: this is a one-shot
# container, so certbot's exit status becomes the container's exit status and
# signals reach it directly. Nothing can run after this point, which is why the
# former "success" message below the exec has been removed - it was unreachable.
exec certbot "$@"
