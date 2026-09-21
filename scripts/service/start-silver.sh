#!/bin/bash

# ============================================
#  Silver Mail Setup Wizard
# ============================================

# Colors
CYAN="\033[0;36m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Get the script directory (where init.sh is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Services directory contains docker-compose.yaml
SERVICES_DIR="$(cd "${SCRIPT_DIR}/../../services" && pwd)"
# Conf directory contains config files
CONF_DIR="$(cd "${SCRIPT_DIR}/../../conf" && pwd)"
CONFIG_FILE="${CONF_DIR}/silver.yaml"

# ASCII Banner
echo -e "${CYAN}"
cat <<'EOF'


   SSSSSSSSSSSSSSS   iiii  lllllll
 SS:::::::::::::::S i::::i l:::::l
S:::::SSSSSS::::::S  iiii  l:::::l
S:::::S     SSSSSSS        l:::::l
S:::::S            iiiiiii  l::::lvvvvvvv           vvvvvvv eeeeeeeeeeee    rrrrr   rrrrrrrrr
S:::::S            i::::i  l::::l v:::::v         v:::::vee::::::::::::ee  r::::rrr:::::::::r
 S::::SSSS          i::::i  l::::l  v:::::v       v:::::ve::::::eeeee:::::eer:::::::::::::::::r
  SS::::::SSSSS     i::::i  l::::l   v:::::v     v:::::ve::::::e     e:::::err::::::rrrrr::::::r
    SSS::::::::SS   i::::i  l::::l    v:::::v   v:::::v e:::::::eeeee::::::e r:::::r     r:::::r
       SSSSSS::::S  i::::i  l::::l     v:::::v v:::::v  e:::::::::::::::::e  r:::::r     rrrrrrr
            S:::::S i::::i  l::::l      v:::::v:::::v   e::::::eeeeeeeeeee   r:::::r
            S:::::S i::::i  l::::l       v:::::::::v    e:::::::e            r:::::r
SSSSSSS     S:::::Si::::::il::::::l       v:::::::v     e::::::::e           r:::::r
S::::::SSSSSS:::::Si::::::il::::::l        v:::::v       e::::::::eeeeeeee   r:::::r
S:::::::::::::::SS i::::::il::::::l         v:::v         ee:::::::::::::e   r:::::r
 SSSSSSSSSSSSSSS   iiiiiiiillllllll          vvv            eeeeeeeeeeeeee   rrrrrrr

EOF
echo -e "${NC}"

echo ""
echo -e " 🚀 ${GREEN}Welcome to Silver Mail System Setup${NC}"
echo "---------------------------------------------"

# ================================
# Step 1: Domain Configuration
# ================================
echo -e "\n${YELLOW}Step 1/3: Configure domain name${NC}"

# Extract primary (first) domain from the domains list in silver.yaml
MAIL_DOMAIN=$(grep -m 1 '^\s*-\s*domain:' "$CONFIG_FILE" | sed 's/.*domain:\s*//' | xargs)

# Validate if MAIL_DOMAIN is empty
if [ -z "$MAIL_DOMAIN" ]; then
	echo -e "${RED}Error: Domain name is not configured or is empty. Please set it in '$CONFIG_FILE'.${NC}"
	exit 1 # Exit the script with a failure status
else
	echo "Domain name found: $MAIL_DOMAIN"
	# ...continue with the rest of your script...
fi

if ! [[ "$MAIL_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
	echo -e "${RED}✗ Warning: '${MAIL_DOMAIN}' does not look like a valid domain name.${NC}"
	exit 1
fi

# ================================
# Step 2: Ensure ${MAIL_DOMAIN} points to 127.0.0.1 in /etc/hosts
# ================================
echo -e "\n${YELLOW}Step 2/3: Updating ${MAIL_DOMAIN} mapping in /etc/hosts${NC}"

if grep -q "[[:space:]]${MAIL_DOMAIN}" /etc/hosts; then
	# Replace existing entry
	sudo sed -i "/^[^#]*[[:space:]]${MAIL_DOMAIN}\([[:space:]]\|$\)/s/^.*[[:space:]]${MAIL_DOMAIN}\([[:space:]]\|$\).*/127.0.0.1   ${MAIL_DOMAIN}/" /etc/hosts
	echo -e "${GREEN}✓ Updated existing ${MAIL_DOMAIN} entry to 127.0.0.1${NC}"
else
	# Add new if not present
	echo "127.0.0.1   ${MAIL_DOMAIN}" | sudo tee -a /etc/hosts >/dev/null
	echo -e "${GREEN}✓ Added ${MAIL_DOMAIN} entry to /etc/hosts${NC}"
fi

# ================================
# Step 3: Docker Setup
# ================================
echo -e "\n${YELLOW}Step 3/3: Starting Docker services${NC}"

# ------------------------------------------------------------------
# SeaweedFS S3 credentials
#
# Two files must always carry the SAME access/secret pair:
#   seaweedfs/s3-config.json  - the S3 gateway's identity (server side)
#   seaweedfs/.env            - what Raven authenticates with (client side)
#
# These used to be seeded by copying the committed *.example files. Because BOTH
# sides received the same placeholder the stack worked perfectly, so nobody
# noticed that every default deployment's mail-attachment store accepted
# credentials published in this repository. They are now generated on first run
# and never rotated automatically: rotating the gateway key out from under a
# populated store would lock Raven out of every attachment already written.
#
# NOTE: services/config-scripts/gen-raven-conf.sh performs the same first-run
# generation (it runs earlier, from setup.sh). Keep the two blocks in sync.
# ------------------------------------------------------------------
SEAWEEDFS_CONFIG="${SERVICES_DIR}/seaweedfs/s3-config.json"
SEAWEEDFS_ENV="${SERVICES_DIR}/seaweedfs/.env"

# Emit $1 bytes of randomness as lowercase hex. Hex is deliberate: the value is
# embedded verbatim in JSON, YAML and a .env file, and needs no escaping in any
# of them.
rand_hex() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "$1"
	else
		od -An -vtx1 -N "$1" /dev/urandom | tr -d ' \n'
	fi
}

if [ -f "$SEAWEEDFS_CONFIG" ] && [ -f "$SEAWEEDFS_ENV" ]; then
	# Deployments seeded from the old *.example files run on credentials that are
	# public in this repository.
	if grep -q 'your-access-key-here\|your-secret-key-here\|REPLACE-ME-GENERATED-ON-FIRST-RUN' "$SEAWEEDFS_CONFIG" "$SEAWEEDFS_ENV"; then
		echo -e "${RED}✗ SeaweedFS is still configured with the placeholder credentials from the"
		echo "  committed *.example files. Those values are public in this repository and"
		echo "  grant Admin/Read/Write on the attachment store to anyone who has read it."
		echo "  Rotate them: put the SAME new accessKey/secretKey in both"
		echo -e "  ${SEAWEEDFS_CONFIG} and ${SEAWEEDFS_ENV}, then restart SeaweedFS and Raven.${NC}"
		exit 1
	fi
	echo -e "${GREEN}  ✓ Using existing SeaweedFS S3 credentials${NC}"
elif [ -f "$SEAWEEDFS_CONFIG" ] || [ -f "$SEAWEEDFS_ENV" ]; then
	# Only one side exists. Generating a fresh pair would either lock Raven out of
	# the existing store or hand it credentials the gateway does not know, so stop
	# rather than guess which file is authoritative.
	echo -e "${RED}✗ SeaweedFS S3 configuration is incomplete:"
	echo "    s3-config.json: $([ -f "$SEAWEEDFS_CONFIG" ] && echo present || echo MISSING)"
	echo "    .env:           $([ -f "$SEAWEEDFS_ENV" ] && echo present || echo MISSING)"
	echo "  Both files must exist and carry the SAME accessKey/secretKey. Recreate the"
	echo -e "  missing one, or delete both to start over with a fresh attachment store.${NC}"
	exit 1
else
	echo "  - SeaweedFS S3 credentials not found. Generating a new pair..."
	S3_ACCESS_KEY="$(rand_hex 12)"
	S3_SECRET_KEY="$(rand_hex 32)"

	# Subshell so the restrictive umask does not leak; both files hold a live secret.
	(
		umask 077
		cat >"$SEAWEEDFS_CONFIG" <<EOF
{
  "identities": [
    {
      "name": "raven",
      "credentials": [
        {
          "accessKey": "${S3_ACCESS_KEY}",
          "secretKey": "${S3_SECRET_KEY}"
        }
      ],
      "actions": [
        "Admin",
        "Read",
        "Write"
      ]
    }
  ]
}
EOF
		cat >"$SEAWEEDFS_ENV" <<EOF
# SeaweedFS S3 credentials - GENERATED, do not commit.
# Must stay identical to the credentials in s3-config.json.
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}

S3_ENDPOINT=http://seaweedfs-s3:8333
S3_REGION=us-east-1
S3_BUCKET=email-attachments
S3_TIMEOUT=30
EOF
	)
	unset S3_ACCESS_KEY S3_SECRET_KEY
	echo -e "${GREEN}  ✓ Generated SeaweedFS S3 credentials in ${SEAWEEDFS_CONFIG} and ${SEAWEEDFS_ENV} (mode 0600)${NC}"
	echo -e "${YELLOW}  ⚠ Raven's config is generated from these values - re-run scripts/setup/setup.sh"
	echo -e "    (or services/config-scripts/gen-raven-conf.sh) if Raven was configured earlier.${NC}"
fi

# Start SeaweedFS services first
echo "  - Starting SeaweedFS blob storage..."
(cd "${SERVICES_DIR}" && docker compose -f docker-compose.seaweedfs.yaml up -d)
if [ $? -ne 0 ]; then
	echo -e "${RED}✗ SeaweedFS docker compose failed. Please check the logs.${NC}"
	exit 1
fi
echo -e "${GREEN}  ✓ SeaweedFS services started${NC}"

# Start main Silver mail services
echo "  - Starting Silver mail services..."
(cd "${SERVICES_DIR}" && docker compose up -d)
if [ $? -ne 0 ]; then
	echo -e "${RED}✗ Docker compose failed. Please check the logs.${NC}"
	exit 1
fi
echo -e "${GREEN}  ✓ Silver mail services started${NC}"

# ================================
# Public DKIM Key Instructions
# ================================
chmod +x "${SCRIPT_DIR}/../utils/get-dkim.sh"
(cd "${SCRIPT_DIR}/../utils" && ./get-dkim.sh)

# ================================
# Generate RSPAMD worker-controller.inc
# ================================

chmod +x "${SCRIPT_DIR}/../utils/generate-rspamd-worker-controller.sh"
(cd "${SCRIPT_DIR}/../utils" && ./generate-rspamd-worker-controller.sh)
