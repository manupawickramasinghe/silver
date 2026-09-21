#!/bin/bash

# --- Sanity Checks & Configuration ---
set -euo pipefail

# Define constant paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# Extract primary (first) domain from the domains list in silver.yaml
readonly MAIL_DOMAIN=$(grep -m 1 '^\s*-\s*domain:' "${ROOT_DIR}/../conf/silver.yaml" | sed 's/.*domain:\s*//' | xargs)
readonly LETSENCRYPT_PATH="${ROOT_DIR}/silver-config/certbot/keys/etc/live/${MAIL_DOMAIN}"
readonly THUNDER_CERTS_PATH="${ROOT_DIR}/silver-config/thunder/certs"
readonly THUNDER_DEPLOYMENT_FILE="${ROOT_DIR}/silver-config/thunder/deployment.yaml"
readonly THUNDER_CONSOLE_CONFIG="${ROOT_DIR}/silver-config/thunder/console-config.js"
readonly THUNDER_GATE_CONFIG="${ROOT_DIR}/silver-config/thunder/gate-config.js"
readonly THUNDER_PORT="8090"

mkdir -p "${THUNDER_CERTS_PATH}"

# Remove anything an earlier run left behind before copying. `cp` writes into an
# existing destination rather than recreating it, which both preserves that
# file's old (possibly world-readable) mode and fails outright once the file is
# owned by uid 10001 from a previous run.
rm -f "${THUNDER_CERTS_PATH}/server.key" "${THUNDER_CERTS_PATH}/server.cert"

cp "${LETSENCRYPT_PATH}/fullchain.pem" "${THUNDER_CERTS_PATH}/server.cert"

# Copy the TLS private key with a restrictive mode from the moment it is created.
# A plain `cp` creates the destination as 0666 & ~umask (0644 with the usual
# umask 022), so the key would be world-readable for the window between the copy
# and the chmod below -- and permanently if the script aborts in between (the
# sudo call can prompt or fail, and `set -euo pipefail` aborts on failure).
(umask 077; cp "${LETSENCRYPT_PATH}/privkey.pem" "${THUNDER_CERTS_PATH}/server.key")

# Set the modes before handing ownership over: after `sudo chown` the invoking
# user no longer owns the files, so a subsequent unprivileged chmod would fail.
chmod 600 "${THUNDER_CERTS_PATH}/server.key"
chmod 644 "${THUNDER_CERTS_PATH}/server.cert"

# Set ownership to user ID 10001 (thunder user in container)
sudo chown 10001:10001 "${THUNDER_CERTS_PATH}/server.key" "${THUNDER_CERTS_PATH}/server.cert"

echo -e "Thunder certificates copied and permissions set"

# Update deployment.yaml with correct domain and port
if [[ -f "${THUNDER_DEPLOYMENT_FILE}" ]]; then
    echo -e "Updating Thunder deployment configuration..."
    
    # Create a temporary file for editing
    cp "${THUNDER_DEPLOYMENT_FILE}" "${THUNDER_DEPLOYMENT_FILE}.bak"
    
    # Update server.public_url
    sed -i'' -e "/^server:/,/^[^ ]/ s|public_url:.*|public_url: \"https://${MAIL_DOMAIN}:${THUNDER_PORT}\"|" "${THUNDER_DEPLOYMENT_FILE}"
    
    # Update gate_client.hostname
    sed -i'' -e "/^gate_client:/,/^[^ ]/ s|hostname:.*|hostname: \"${MAIL_DOMAIN}\"|" "${THUNDER_DEPLOYMENT_FILE}"
    
    # Update gate_client.port (if needed)
    sed -i'' -e "/^gate_client:/,/^[^ ]/ s|port:.*|port: ${THUNDER_PORT}|" "${THUNDER_DEPLOYMENT_FILE}"
    
    # Update cors.allowed_origins - replace any https://domain:port pattern
    sed -i'' -e "/^cors:/,/^[^ ]/ s|https://[^:\"]*:[0-9]*|https://${MAIL_DOMAIN}:${THUNDER_PORT}|g" "${THUNDER_DEPLOYMENT_FILE}"
    
    # Update passkey.allowed_origins - replace any https://domain:port pattern
    sed -i'' -e "/^passkey:/,/^[^ ]/ s|https://[^:\"]*:[0-9]*|https://${MAIL_DOMAIN}:${THUNDER_PORT}|g" "${THUNDER_DEPLOYMENT_FILE}"
    
    # Remove backup file
    rm -f "${THUNDER_DEPLOYMENT_FILE}.bak"
    
    echo -e "Thunder deployment configuration updated with domain: ${MAIL_DOMAIN} and port: ${THUNDER_PORT}"
else
    echo -e "Warning: Thunder deployment.yaml not found at ${THUNDER_DEPLOYMENT_FILE}"
fi

# Update console-config.js with correct domain and port
if [[ -f "${THUNDER_CONSOLE_CONFIG}" ]]; then
    echo -e "Updating Thunder console-config.js..."
    
    # Update public_url in console-config.js
    sed -i'' -e "s|public_url: 'https://[^']*'|public_url: 'https://${MAIL_DOMAIN}:${THUNDER_PORT}'|g" "${THUNDER_CONSOLE_CONFIG}"
    
    echo -e "Thunder console-config.js updated"
else
    echo -e "Warning: console-config.js not found at ${THUNDER_CONSOLE_CONFIG}"
fi

# Update gate-config.js with correct domain and port
if [[ -f "${THUNDER_GATE_CONFIG}" ]]; then
    echo -e "Updating Thunder gate-config.js..."
    
    # Update public_url in gate-config.js
    sed -i'' -e "s|public_url: 'https://[^']*'|public_url: 'https://${MAIL_DOMAIN}:${THUNDER_PORT}'|g" "${THUNDER_GATE_CONFIG}"
    
    echo -e "Thunder gate-config.js updated"
else
    echo -e "Warning: gate-config.js not found at ${THUNDER_GATE_CONFIG}"
fi
