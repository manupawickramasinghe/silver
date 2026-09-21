#!/bin/bash
#
# Generates services/silver-config/rspamd/worker-controller.inc, the Rspamd
# controller (web UI) worker configuration.
#
# The controller is not "just a dashboard": it is Rspamd's full admin API. Whoever
# holds its credentials can whitelist senders, retrain the Bayes classifier,
# rewrite the running configuration and read metadata about scanned messages.
# Everything below exists so that it is never reachable without a real password.

# No `set -u`: this script sources an operator-supplied .env, and an unset
# reference in there should not be fatal. Unset variables of our own are handled
# explicitly below.
set -eo pipefail

# Container that runs Rspamd, and the hostname it answers to on the compose
# network. Both are pinned in services/docker-compose.yaml (container_name /
# hostname: rspamd); overridable for non-default deployments.
RSPAMD_CONTAINER="${RSPAMD_CONTAINER:-rspamd}"
RSPAMD_HOSTNAME="${RSPAMD_HOSTNAME:-rspamd}"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="${SCRIPT_DIR}/../../services"
CONFIG_DIR="${SERVICES_DIR}/silver-config/rspamd"

# Load .env if it exists, using safer 'source' approach
if [ -f "${SCRIPT_DIR}/../.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../.env"
  set +a
elif [ -f "${SERVICES_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SERVICES_DIR}/.env"
  set +a
fi

# --- Credentials -------------------------------------------------------------

# Hard failure, no default. This script used to fall back to the password
# "admin" with only a warning, which meant a stack deployed by anyone who
# skipped a step in the docs shipped an internet-guessable admin credential on
# the spam filter. A failed run is strictly better than that.
: "${RSPAMD_PASSWORD:?must be set in services/.env (see services/.env.example) before running this script}"

# Rspamd's controller has two independent credentials:
#
#   password        - read-only access: web UI, stats, history.
#   enable_password - privileged actions: learn spam/ham, fuzzy add/delete,
#                     writing configuration back to disk.
#
# This script previously wrote `enable_password = true;`. In UCL that is the
# boolean true, not a hash, so the privileged actions were not guarded by the
# intended secret at all. Both keys must hold a hash.
#
# Rspamd's documentation recommends a *separate* secret for enable_password, so
# RSPAMD_ENABLE_PASSWORD is honoured when set. When it is not set we reuse the
# read-only hash: that is the same trust model as a single-admin deployment and,
# unlike `true`, it still puts a real hash in front of every privileged action.
# The choice is reported on stdout so it is never silent.
RSPAMD_ENABLE_PASSWORD="${RSPAMD_ENABLE_PASSWORD:-}"

# --- Hashing -----------------------------------------------------------------

# Hash a password using the rspamadm shipped inside the running container.
#
# The secret is handed over on stdin and read into a shell variable inside the
# container, so it is never an argv element of `docker exec`. That keeps it out
# of the host's process table (readable by every local user via `ps aux`) and
# out of the invoking shell's history.
#
# The final hop still uses `rspamadm pw -p`. `rspamadm pw` will only read a
# passphrase interactively from a TTY, and because readpassphrase(3) disables
# echo with TCSAFLUSH it *discards* anything piped in ahead of the prompt.
# Verified against rspamd/rspamd:4.1.4: piping the password to `rspamadm pw -e`
# prints "Invalid password", and wrapping it in script(1) to fake a TTY only
# works if the write is delayed until after the prompt, which is a race.
# Residual exposure is therefore the argv of a short-lived rspamadm process in
# Rspamd's own PID namespace, visible only to someone who can already exec into
# that container.
hash_password() {
  printf '%s' "$1" | docker exec -i "$RSPAMD_CONTAINER" \
    sh -c 'pw=$(cat); exec rspamadm pw -e -q -p "$pw"'
}

# Rspamd hashes look like $<pbkdf-id>$<salt>$<key>, both parts base32. Checking
# the shape means a broken/empty rspamadm invocation fails here instead of
# writing a config whose password field silently matches nothing.
is_rspamd_hash() {
  [[ "$1" =~ ^\$[0-9]+\$[a-z0-9]+\$[a-z0-9]+$ ]]
}

echo "Generating Rspamd password hash..."
if ! HASH="$(hash_password "$RSPAMD_PASSWORD")" || ! is_rspamd_hash "$HASH"; then
  echo "Error: could not generate a password hash. Is the '${RSPAMD_CONTAINER}' container running?" >&2
  exit 1
fi

if [ -n "$RSPAMD_ENABLE_PASSWORD" ]; then
  if ! ENABLE_HASH="$(hash_password "$RSPAMD_ENABLE_PASSWORD")" || ! is_rspamd_hash "$ENABLE_HASH"; then
    echo "Error: could not hash RSPAMD_ENABLE_PASSWORD." >&2
    exit 1
  fi
  ENABLE_NOTE="separate RSPAMD_ENABLE_PASSWORD"
else
  ENABLE_HASH="$HASH"
  ENABLE_NOTE="same as RSPAMD_PASSWORD - set RSPAMD_ENABLE_PASSWORD in .env to separate them"
fi

# --- Write the config --------------------------------------------------------

mkdir -p "$CONFIG_DIR"

FILE="$CONFIG_DIR/worker-controller.inc"

# Bind the controller to the container's own compose-network address rather than
# 0.0.0.0. Docker writes an /etc/hosts entry for the container hostname pointing
# at its network IP, so this resolves without depending on the embedded DNS
# server. Verified against rspamd/rspamd:4.1.4: the controller then listens on
# <container-ip>:11334 only.
#
# Note: the `11334:11334` host port publish is being removed from
# services/docker-compose.yaml on a separate branch. This change is independent
# of that one - while the publish is still in place Docker's proxy forwards to
# the container IP, so the UI keeps working either way.
CONTROLLER_BIND="${RSPAMD_CONTROLLER_BIND:-${RSPAMD_HOSTNAME}:11334}"

cat > "$FILE" <<EOF
# Controller worker configuration - GENERATED by
# scripts/utils/generate-rspamd-worker-controller.sh, do not edit by hand.
#
# Bound to the compose-network interface only, not 0.0.0.0.
bind_socket = "${CONTROLLER_BIND}";

# Single controller worker
count = 1;

# Read-only access (web UI, stats, history). Hash of RSPAMD_PASSWORD from .env.
password = "$HASH";

# Privileged access (learn spam/ham, fuzzy add/delete, config write). Must be a
# hash - a bare \`true\` here leaves these actions unprotected.
enable_password = "$ENABLE_HASH";
EOF

# Readable by the container's unprivileged rspamd user. The file holds only
# PBKDF hashes, no plaintext. Do not tighten to 0600: the bind mount preserves
# host ownership, so a mode the in-container user cannot read makes Rspamd skip
# this file entirely and fall back to its built-in controller defaults - which
# is exactly the unauthenticated state this script exists to prevent.
chmod 644 "$FILE"

echo "✓ Created $FILE"
echo "  - Controller bound to: ${CONTROLLER_BIND} (compose network only)"
echo "  - Read-only password:  RSPAMD_PASSWORD from .env"
echo "  - Enable password:     ${ENABLE_NOTE}"
echo "  - Web UI is no longer served on every interface. Publish it loopback-only in"
echo "    docker-compose.yaml (127.0.0.1:11334:11334) and tunnel in:"
echo "      ssh -L 11334:localhost:11334 <host>   # then http://localhost:11334/"

# Restart Rspamd container
echo ""
echo "Restarting Rspamd..."
(cd "$SERVICES_DIR" && docker compose restart rspamd)

echo ""
echo "✓ Done! You can now access the Rspamd web UI with your password."
