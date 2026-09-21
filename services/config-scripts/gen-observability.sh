#!/bin/bash
set -e

# -------------------------------
# Base paths
# -------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="${PROJECT_ROOT}/.env"
SILVER_CONFIG="${PROJECT_ROOT}/silver-config"

# Grafana paths
GRAFANA_ALERTS_FILE="${SILVER_CONFIG}/grafana/provisioning/alerting/contact-points.yaml"
GRAFANA_CERTS_DIR="${SILVER_CONFIG}/grafana/certs"

# Certbot / Let's Encrypt paths
MAIL_DOMAIN=$(grep -m 1 '^\s*-\s*domain:' "${PROJECT_ROOT}/../conf/silver.yaml" | sed 's/.*domain:\s*//' | xargs)
LETSENCRYPT_DIR="${SILVER_CONFIG}/certbot/keys/etc/live/${MAIL_DOMAIN}"

# Grafana config
GRAFANA_CONFIG_FILE="${SILVER_CONFIG}/grafana/grafana.ini"
# Pristine, un-substituted source for grafana.ini (see "Update Grafana domain").
GRAFANA_CONFIG_TEMPLATE="${GRAFANA_CONFIG_FILE}.tmpl"

# Grafana runs as uid:gid 472:472 inside the container.
GRAFANA_UID_GID="472:472"

# -------------------------------
# Helpers
# -------------------------------

# chown a path to the Grafana container user.
#
# Changing ownership requires root, so escalate with sudo when we are not root
# (gen-thunder.sh does the same for the Thunder certificates). A failure here is
# reported but deliberately not fatal: `set -e` on a bare `chown` used to kill
# this script half way through, after the webhook URL had been written but
# before the TLS certificates were installed, leaving Grafana serving plain
# HTTP. Finishing the remaining steps and warning loudly is the safer outcome.
chown_grafana() {
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${GRAFANA_UID_GID}" "$@" && return 0
  elif command -v sudo >/dev/null 2>&1; then
    sudo chown "${GRAFANA_UID_GID}" "$@" && return 0
  fi
  echo "WARNING: could not chown to ${GRAFANA_UID_GID}: $*" >&2
  echo "         Grafana may be unable to read it. Re-run as root or fix manually." >&2
  return 0
}

# -------------------------------
# Load environment variables
# -------------------------------
echo "Loading environment variables..."
set -o allexport
source "${ENV_FILE}"
set +o allexport

if [[ -z "${GOOGLE_CHAT_WEBHOOK_URL}" ]]; then
  echo "ERROR: GOOGLE_CHAT_WEBHOOK_URL is not set in .env" >&2
  exit 1
fi

# -------------------------------
# Update Grafana contact points
# -------------------------------
echo "Updating Grafana contact-points.yaml..."

ESCAPED_URL="$(printf '%s\n' "${GOOGLE_CHAT_WEBHOOK_URL}" | sed 's/[&]/\\&/g')"
sed -i "s|^\([[:space:]]*url:\).*|\1 ${ESCAPED_URL}|" "${GRAFANA_ALERTS_FILE}"

# The contact points file embeds the Google Chat webhook URL, which is a bearer
# credential -- keep it out of reach of other local users.
chmod 640 "${GRAFANA_ALERTS_FILE}"
chown_grafana "${GRAFANA_ALERTS_FILE}"
echo "Done."

# -------------------------------
# Install Grafana TLS certificates
# -------------------------------
echo "Installing Grafana TLS certificates..."

mkdir -p "${GRAFANA_CERTS_DIR}"

# Remove anything an earlier run left behind before copying. `cp` writes into an
# existing destination rather than recreating it, which both preserves that
# file's old (possibly world-readable) mode and fails outright once the file is
# 0444 or owned by uid 472 -- the latter is why re-running this script used to
# error out at this point.
rm -f "${GRAFANA_CERTS_DIR}/grafana.crt" "${GRAFANA_CERTS_DIR}/grafana.key"

cp "${LETSENCRYPT_DIR}/fullchain.pem" "${GRAFANA_CERTS_DIR}/grafana.crt"

# Copy the TLS private key with a restrictive mode from the moment it is created.
# A plain `cp` creates the destination as 0666 & ~umask (0644 with the usual
# umask 022), so the key would be world-readable for the window between the copy
# and the chmod below -- and permanently if the script aborts in between.
(umask 077; cp "${LETSENCRYPT_DIR}/privkey.pem" "${GRAFANA_CERTS_DIR}/grafana.key")

# Set the modes before handing ownership over: after chowning to 472:472 the
# invoking user no longer owns the files, so an unprivileged chmod would fail.
chmod 440 "${GRAFANA_CERTS_DIR}/grafana.key"
chmod 444 "${GRAFANA_CERTS_DIR}/grafana.crt"

chown_grafana \
  "${GRAFANA_CERTS_DIR}/grafana.key" \
  "${GRAFANA_CERTS_DIR}/grafana.crt"

echo "Grafana TLS certificates installed successfully."

# -------------------------------
# Update Grafana domain (<MAIL_DOMAIN>)
# -------------------------------
echo "Updating Grafana domain in grafana.ini..."

if [[ -z "${MAIL_DOMAIN}" ]]; then
  echo "ERROR: No domain configured in silver.yaml. Cannot update Grafana domain." >&2
  exit 1
fi

if [[ ! -f "${GRAFANA_CONFIG_FILE}" ]]; then
  echo "ERROR: Grafana config not found at ${GRAFANA_CONFIG_FILE}" >&2
  exit 1
fi

# Render grafana.ini from a pristine template so this step is idempotent.
#
# The silver-config checkout ships grafana.ini containing the literal
# "<MAIL_DOMAIN>" placeholder. Substituting it in place with `sed -i` consumes
# the placeholder, so a re-run -- after this script aborted part way, or after
# the configured domain changed -- had nothing left to replace and silently left
# the old value behind. Snapshot the file as grafana.ini.tmpl the first time we
# see it, then regenerate grafana.ini from that template on every run.
if [[ ! -f "${GRAFANA_CONFIG_TEMPLATE}" ]]; then
  if ! grep -q '<MAIL_DOMAIN>' "${GRAFANA_CONFIG_FILE}"; then
    echo "WARNING: ${GRAFANA_CONFIG_FILE} has no <MAIL_DOMAIN> placeholder." >&2
    echo "         An older run of this script probably substituted it in place." >&2
    echo "         Restore it from silver-config before changing the domain." >&2
  fi
  cp "${GRAFANA_CONFIG_FILE}" "${GRAFANA_CONFIG_TEMPLATE}"
fi

# Render via a temporary file and rename into place. A previous run may have
# chowned grafana.ini to 472:472, which would make a direct `>` redirect fail;
# renaming only needs write access to the directory, and is atomic.
GRAFANA_CONFIG_TMP="$(mktemp "${GRAFANA_CONFIG_FILE}.XXXXXX")"
sed "s|<MAIL_DOMAIN>|${MAIL_DOMAIN}|g" "${GRAFANA_CONFIG_TEMPLATE}" > "${GRAFANA_CONFIG_TMP}"
chmod 644 "${GRAFANA_CONFIG_TMP}"
mv -f "${GRAFANA_CONFIG_TMP}" "${GRAFANA_CONFIG_FILE}"

chown_grafana "${GRAFANA_CONFIG_FILE}"

echo "Grafana domain updated to ${MAIL_DOMAIN}"