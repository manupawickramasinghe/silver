#!/bin/bash
# -----------------------------------------------------------------------------
# Raven Configuration Generator
# Generates the raven.yaml and copies required certificates.
# -----------------------------------------------------------------------------

set -euo pipefail # Exit on error, undefined vars, or failed pipe

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"       # /root/silver/services
GEN_DIR="${ROOT_DIR}/silver-config/raven" # Base path

CONFIG_FILE="${ROOT_DIR}/../conf/silver.yaml"
OUTPUT_FILE="${GEN_DIR}/conf/raven.yaml"
DELIVERY_FILE="${GEN_DIR}/conf/delivery.yaml"
MAILS_DB_PATH="${GEN_DIR}/data/databases/shared.db"
SEAWEEDFS_ENV_FILE="${ROOT_DIR}/seaweedfs/.env"
SEAWEEDFS_S3_CONFIG="${ROOT_DIR}/seaweedfs/s3-config.json"

# --- Extract primary (first) domain from silver.yaml ---
# Look for the first domain entry under the domains list
MAIL_DOMAIN=$(grep -m 1 '^\s*-\s*domain:' "$CONFIG_FILE" | sed 's/.*domain:\s*//' | xargs)
MAIL_DOMAIN=${MAIL_DOMAIN:-example.local}

# -----------------------------------------------------------------------------
# SeaweedFS S3 credentials
#
# Two files must always carry the SAME access/secret pair:
#   seaweedfs/s3-config.json  - the S3 gateway's identity (server side)
#   seaweedfs/.env            - what Raven authenticates with (client side)
#
# They used to be seeded by copying the committed *.example files. Because BOTH
# sides got the same placeholder the stack worked perfectly, so nobody noticed
# that every default deployment shipped credentials published in this repo.
# They are now generated once, on first run, and never rotated automatically:
# rotating the gateway key out from under a populated store would lock Raven out
# of every attachment already written.
#
# NOTE: scripts/service/start-silver.sh performs the same first-run generation
# (it can run before this script). Keep the two blocks in sync.
# -----------------------------------------------------------------------------

# Emit $1 bytes of randomness as lowercase hex. Hex is deliberate: the value is
# embedded verbatim in JSON, YAML, a .env file and an awk program, and hex needs
# no escaping in any of them.
rand_hex() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "$1"
	else
		od -An -vtx1 -N "$1" /dev/urandom | tr -d ' \n'
	fi
}

# Write the S3 gateway identity from the current S3_ACCESS_KEY/S3_SECRET_KEY.
# Runs in a subshell so the restrictive umask does not leak to the rest of the
# script; the file holds a live secret.
write_s3_config_json() {
	(
		umask 077
		cat >"$SEAWEEDFS_S3_CONFIG" <<EOF
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
	)
}

write_s3_env_file() {
	(
		umask 077
		cat >"$SEAWEEDFS_ENV_FILE" <<EOF
# SeaweedFS S3 credentials - GENERATED, do not commit.
# Must stay identical to the credentials in s3-config.json.
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}

S3_ENDPOINT=${S3_ENDPOINT}
S3_REGION=${S3_REGION}
S3_BUCKET=${S3_BUCKET}
S3_TIMEOUT=${S3_TIMEOUT}
EOF
	)
}

if [ -f "$SEAWEEDFS_ENV_FILE" ]; then
	set -a # automatically export all variables
	# shellcheck source=/dev/null
	source "$SEAWEEDFS_ENV_FILE"
	set +a
	echo "✅ Loaded SeaweedFS credentials from $SEAWEEDFS_ENV_FILE"

	# Non-credential settings may legitimately be absent from an older .env.
	S3_ENDPOINT=${S3_ENDPOINT:-http://seaweedfs-s3:8333}
	S3_REGION=${S3_REGION:-us-east-1}
	S3_BUCKET=${S3_BUCKET:-email-attachments}
	S3_TIMEOUT=${S3_TIMEOUT:-30}

	# The credentials themselves have no safe default - a guessable fallback is
	# exactly the bug this replaces.
	if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ]; then
		echo "   ❌ Error: S3_ACCESS_KEY / S3_SECRET_KEY are missing from $SEAWEEDFS_ENV_FILE."
		echo "      Delete both $SEAWEEDFS_ENV_FILE and $SEAWEEDFS_S3_CONFIG to have a"
		echo "      fresh pair generated (this discards access to already-stored attachments)."
		exit 1
	fi

	# Deployments seeded from the old *.example files are running on credentials
	# that are public in this repository. Refuse to regenerate config around them.
	case "${S3_ACCESS_KEY}${S3_SECRET_KEY}" in
	*your-access-key-here* | *your-secret-key-here* | *REPLACE-ME-GENERATED-ON-FIRST-RUN*)
		echo "   ❌ Error: $SEAWEEDFS_ENV_FILE still holds the placeholder credentials from"
		echo "      .env.example. Those values are published in this repository and grant"
		echo "      Admin/Read/Write on the attachment store to anyone who has read it."
		echo "      Rotate them: put the SAME new accessKey/secretKey in both"
		echo "      $SEAWEEDFS_ENV_FILE and $SEAWEEDFS_S3_CONFIG, then restart SeaweedFS and Raven."
		exit 1
		;;
	esac

	# .env is the source of truth; regenerate the gateway identity only if it is
	# missing, so the two can never drift apart.
	if [ ! -f "$SEAWEEDFS_S3_CONFIG" ]; then
		echo "   ℹ️ $SEAWEEDFS_S3_CONFIG missing - recreating it from the .env credentials"
		write_s3_config_json
	fi
elif [ -f "$SEAWEEDFS_S3_CONFIG" ]; then
	# The gateway identity exists but the client credentials do not. Generating a
	# new pair here would silently lock Raven out of the existing store, so stop.
	echo "❌ Error: $SEAWEEDFS_S3_CONFIG exists but $SEAWEEDFS_ENV_FILE is missing."
	echo "   Recreate the .env with the SAME accessKey/secretKey as s3-config.json"
	echo "   (or delete both files to start over with a fresh, empty attachment store)."
	exit 1
else
	echo "🔐 Generating SeaweedFS S3 credentials (first run)..."
	S3_ACCESS_KEY="$(rand_hex 12)"
	S3_SECRET_KEY="$(rand_hex 32)"
	S3_ENDPOINT="http://seaweedfs-s3:8333"
	S3_REGION="us-east-1"
	S3_BUCKET="email-attachments"
	S3_TIMEOUT="30"
	write_s3_env_file
	write_s3_config_json
	echo "   ✅ Wrote $SEAWEEDFS_ENV_FILE and $SEAWEEDFS_S3_CONFIG (mode 0600)"
fi

# The credentials are interpolated into JSON/YAML without escaping. Hex-generated
# values are always safe; a hand-edited one might not be.
case "${S3_ACCESS_KEY}${S3_SECRET_KEY}" in
*[\"\\]*)
	echo "❌ Error: S3 credentials must not contain '\"' or '\\' - they are embedded"
	echo "   verbatim in JSON and YAML. Please choose different credentials."
	exit 1
	;;
esac

# awk reads these from ENVIRON below; exporting keeps the secret out of argv.
export S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_REGION S3_BUCKET S3_TIMEOUT

# --- Certificate paths ---
LETSENCRYPT_PATH="${ROOT_DIR}/silver-config/certbot/keys/etc/live/${MAIL_DOMAIN}"
RAVEN_CERT_PATH="${ROOT_DIR}/silver-config/raven/certs"

# --- Prepare directories ---
mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$MAILS_DB_PATH")" "$RAVEN_CERT_PATH"

# --- Generate raven.yaml ---
# Written to a temp file and moved into place so a failure part-way through
# cannot leave Raven with a truncated config. umask 077 because the file embeds
# the S3 secret key.
trap 'rm -f "${OUTPUT_FILE}.tmp" "${DELIVERY_FILE}.tmp"' EXIT

(
	umask 077
	cat >"${OUTPUT_FILE}.tmp" <<EOF
domain: ${MAIL_DOMAIN}
auth_server_url: https://thunder:8090/auth/credentials/authenticate

# OAUTHBEARER Token Validation (RFC 7628)
# Required when enabling AUTH=OAUTHBEARER for IMAP/SASL.
oauth_issuer_url: "https://${MAIL_DOMAIN}:8090"
oauth_jwks_url: "https://${MAIL_DOMAIN}:8090/oauth2/jwks"
oauth_audience:
  - "EMAIL_APP"
oauth_clock_skew_seconds: 60

# S3-Compatible Blob Storage Configuration
blob_storage:
  enabled: true
  endpoint: "${S3_ENDPOINT}"
  region: "${S3_REGION}"
  bucket: "${S3_BUCKET}"
  access_key: "${S3_ACCESS_KEY}"
  secret_key: "${S3_SECRET_KEY}"
  timeout: ${S3_TIMEOUT}  # seconds
EOF
)
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

echo "✅ Generated: $OUTPUT_FILE (domain: ${MAIL_DOMAIN})"

if [ -f "$DELIVERY_FILE" ]; then
	echo "ℹ️ Updating blob_storage section in delivery.yaml"

	# The awk program is a CONSTANT string: the credentials are read from the
	# environment via ENVIRON, never interpolated into the program text. Inlining
	# them made the secret key part of awk's argv (visible to any local user
	# running `ps auxww` while this runs), and a credential containing a quote or
	# backslash produced a syntactically invalid program - which, under
	# `set -euo pipefail`, aborted after raven.yaml had already been rewritten.
	# `awk -v` is not an alternative here; -v assignments are equally visible.
	#
	# umask 077 for the temp file: like raven.yaml it embeds the S3 secret key.
	(
	umask 077
	awk '
	BEGIN { skip=0; inserted=0 }

	function print_blob_storage() {
		print "# S3-Compatible Blob Storage Configuration"
		print "blob_storage:"
		print "  enabled: true"
		print "  endpoint: \"" ENVIRON["S3_ENDPOINT"] "\""
		print "  region: \"" ENVIRON["S3_REGION"] "\""
		print "  bucket: \"" ENVIRON["S3_BUCKET"] "\""
		print "  access_key: \"" ENVIRON["S3_ACCESS_KEY"] "\""
		print "  secret_key: \"" ENVIRON["S3_SECRET_KEY"] "\""
		print "  timeout: " ENVIRON["S3_TIMEOUT"]
	}

	# Replace existing blob_storage section in-place when found.
	/^[[:space:]]*# S3-Compatible Blob Storage Configuration[[:space:]]*$/ {
		if (!inserted) {
			print_blob_storage()
			inserted=1
		}
		skip=1
		next
	}

	/^[[:space:]]*blob_storage:[[:space:]]*$/ {
		if (!inserted) {
			print_blob_storage()
			inserted=1
		}
		skip=1
		next
	}

	skip {
		if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]*($|#)/) {
			key=$0
			sub(/:.*/, "", key)
			if (key != "blob_storage") {
				skip=0
				print
				next
			}
		}

		if ($0 ~ /^#/ && $0 !~ /^# S3-Compatible Blob Storage Configuration[[:space:]]*$/) {
			skip=0
			print
			next
		}

		next
	}

	{ print }

	END {
		if (!inserted) {
			if (NR > 0) {
				print ""
			}
			print_blob_storage()
		}
	}
	' "$DELIVERY_FILE" >"${DELIVERY_FILE}.tmp"
	)

	mv "${DELIVERY_FILE}.tmp" "$DELIVERY_FILE"
	echo "✅ blob_storage section updated in delivery.yaml"
else
	echo "⚠️ Warning: delivery.yaml not found at $DELIVERY_FILE"
fi

# --- Create shared.db if not exists ---
if [ ! -f "$MAILS_DB_PATH" ]; then
	touch "$MAILS_DB_PATH"
	echo "✅ Created: empty shared.db at $MAILS_DB_PATH"
else
	echo "ℹ️ shared.db already exists at $MAILS_DB_PATH (not overwritten)"
fi

# --- Copy certificates ---
if [ -f "${LETSENCRYPT_PATH}/fullchain.pem" ] && [ -f "${LETSENCRYPT_PATH}/privkey.pem" ]; then
	cp "${LETSENCRYPT_PATH}/fullchain.pem" "${RAVEN_CERT_PATH}/fullchain.pem"
	cp "${LETSENCRYPT_PATH}/privkey.pem" "${RAVEN_CERT_PATH}/privkey.pem"
	echo "✅ Copied Raven certificates for domain: ${MAIL_DOMAIN}"
else
	echo "⚠️ Warning: Certificates not found in ${LETSENCRYPT_PATH}"
	echo "   Skipped copying Raven certificates."
fi

echo "✅ Raven configuration successfully generated."
