#!/bin/bash

# ============================================
#  Silver Mail - Manage Role Assignments
# ============================================
#
# This script allows you to:
# - Transfer role assignments from one user to another
# - Add a user to a role mailbox
# - Remove a user from a role mailbox
# - List all role assignments for a user or role
#

# -------------------------------
# Configuration
# -------------------------------
# Colors
CYAN="\033[0;36m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$(cd "${SCRIPT_DIR}/../../services" && pwd)"

# Shared database inside the SMTP container
DB_PATH="/app/data/databases/shared.db"

# -------------------------------
# Helper Functions
# -------------------------------

# Quote a value for use as an SQL string literal.
# SQLite escapes a single quote by doubling it, so a value quoted this way can
# never terminate its own literal and therefore cannot alter the statement.
# This is the ONLY place where untrusted data becomes part of an SQL string;
# every query below must pass its values through it.
sql_quote() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\'}"
}

# Run an SQL script against the shared database inside the SMTP container.
#
# The script is fed to sqlite3 on stdin and sqlite3 is executed directly rather
# than through `bash -c`. That matters: the previous form built a shell command
# string containing user-supplied text and handed it to a shell *inside the
# container*, which re-parsed it, so `$(...)`, backticks and quotes in an email
# address executed as commands there. With no inner shell and no argument
# interpolation there is nothing left to re-parse.
run_sql() {
	local smtp_container="$1"
	local sql="$2"

	printf '%s\n' "$sql" | docker exec -i "$smtp_container" sqlite3 "$DB_PATH"
}

show_usage() {
	echo -e "${CYAN}Usage:${NC}"
	echo -e "  ${GREEN}Transfer role from one user to another:${NC}"
	echo -e "    $0 transfer <source-user>@<domain> <target-user>@<domain> <role-name>@<domain>"
	echo ""
	echo -e "  ${GREEN}Add user to role:${NC}"
	echo -e "    $0 add <user>@<domain> <role-name>@<domain>"
	echo ""
	echo -e "  ${GREEN}Remove user from role:${NC}"
	echo -e "    $0 remove <user>@<domain> <role-name>@<domain>"
	echo ""
	echo -e "  ${GREEN}List assignments for a user:${NC}"
	echo -e "    $0 list-user <user>@<domain>"
	echo ""
	echo -e "  ${GREEN}List users assigned to a role:${NC}"
	echo -e "    $0 list-role <role-name>@<domain>"
	echo ""
	echo -e "  ${GREEN}List all role assignments:${NC}"
	echo -e "    $0 list-all"
	echo ""
	echo -e "${YELLOW}Examples:${NC}"
	echo -e "  $0 transfer alice@example.com bob@example.com info@example.com"
	echo -e "  $0 add charlie@example.com support@example.com"
	echo -e "  $0 remove alice@example.com sales@example.com"
	echo -e "  $0 list-user alice@example.com"
	echo -e "  $0 list-role info@example.com"
	exit 1
}

# Get SMTP container
# Errors go to stderr: this function is called through command substitution, so
# anything written to stdout ends up in the caller's variable.
get_smtp_container() {
	local smtp_container
	smtp_container=$(cd "${SERVICES_DIR}" && docker compose ps -q postfix 2>/dev/null)
	if [ -z "$smtp_container" ]; then
		echo -e "${RED}✗ SMTP container not found. Is Docker Compose running?${NC}" >&2
		return 1
	fi
	echo "$smtp_container"
}

# Parse email to get username and domain
# Returns non-zero on a bad address; `exit` would only leave the command
# substitution the caller runs this in, not the script.
parse_email() {
	local email="$1"
	local local_part domain_part

	if [[ ! "$email" =~ ^([^@]+)@([^@]+)$ ]]; then
		echo -e "${RED}✗ Invalid email format: $email${NC}" >&2
		return 1
	fi
	local_part="${BASH_REMATCH[1]}"
	domain_part="${BASH_REMATCH[2]}"

	# Defence in depth. Quoting below is what actually makes these values safe,
	# but a conservative charset means a hostile address is rejected outright
	# instead of relying on every future query getting its quoting right.
	if [[ ! "$local_part" =~ ^[A-Za-z0-9._%+-]+$ ]]; then
		echo -e "${RED}✗ Invalid characters in local part of address: $email${NC}" >&2
		return 1
	fi
	if [[ ! "$domain_part" =~ ^[A-Za-z0-9.-]+$ ]]; then
		echo -e "${RED}✗ Invalid characters in domain of address: $email${NC}" >&2
		return 1
	fi

	echo "$local_part $domain_part"
}

# Validate an email address without needing its parts
validate_email() {
	parse_email "$1" >/dev/null
}

# Get user ID
get_user_id() {
	local smtp_container="$1"
	local username="$2"
	local domain="$3"
	local user_id

	user_id=$(run_sql "$smtp_container" "
SELECT u.id
FROM users u
INNER JOIN domains d ON u.domain_id = d.id
WHERE u.username = $(sql_quote "$username")
  AND d.domain = $(sql_quote "$domain")
  AND u.enabled = 1;" 2>/dev/null | tr -d '\n\r')

	# A non-numeric result means the lookup failed rather than returned an id;
	# callers embed this value in later statements, so refuse anything else.
	if [[ ! "$user_id" =~ ^[0-9]+$ ]]; then
		echo -e "${RED}✗ User ${username}@${domain} not found${NC}" >&2
		return 1
	fi
	echo "$user_id"
}

# Get role mailbox ID
get_role_id() {
	local smtp_container="$1"
	local role_email="$2"
	local role_id

	role_id=$(run_sql "$smtp_container" "
SELECT id
FROM role_mailboxes
WHERE email = $(sql_quote "$role_email")
  AND enabled = 1;" 2>/dev/null | tr -d '\n\r')

	if [[ ! "$role_id" =~ ^[0-9]+$ ]]; then
		echo -e "${RED}✗ Role mailbox ${role_email} not found${NC}" >&2
		return 1
	fi
	echo "$role_id"
}

# Add user to role
add_user_to_role() {
	local smtp_container="$1"
	local user_email="$2"
	local role_email="$3"
	local parsed username domain user_id role_id exists

	# Each of these is declared first and assigned second. `local x=$(cmd)` always
	# reports the exit status of `local`, never of the substitution, so the
	# `|| return 1` on such a line is dead code.
	parsed=$(parse_email "$user_email") || return 1
	read -r username domain <<<"$parsed"
	validate_email "$role_email" || return 1

	echo -e "${YELLOW}Adding ${user_email} to role ${role_email}...${NC}"

	user_id=$(get_user_id "$smtp_container" "$username" "$domain") || return 1
	role_id=$(get_role_id "$smtp_container" "$role_email") || return 1

	# Check if already assigned
	# user_id / role_id are guaranteed numeric by their lookup functions.
	if ! exists=$(run_sql "$smtp_container" "
SELECT COUNT(*)
FROM user_role_assignments
WHERE user_id = ${user_id}
  AND role_mailbox_id = ${role_id}
  AND is_active = 1;"); then
		echo -e "${RED}✗ Failed to check existing assignments${NC}"
		return 1
	fi
	exists="${exists//[$'\n\r']/}"

	# A failed query must not be read as "already assigned" and reported as
	# success, so insist on a real count here.
	if [[ ! "$exists" =~ ^[0-9]+$ ]]; then
		echo -e "${RED}✗ Failed to check existing assignments${NC}"
		return 1
	fi

	if [ "$exists" != "0" ]; then
		echo -e "${YELLOW}⚠ User ${user_email} is already assigned to ${role_email}${NC}"
		return 0
	fi

	# Create new assignment
	if run_sql "$smtp_container" "
INSERT INTO user_role_assignments (user_id, role_mailbox_id, assigned_at, is_active)
VALUES (${user_id}, ${role_id}, datetime('now'), 1);"; then
		echo -e "${GREEN}✓ Successfully assigned ${user_email} to ${role_email}${NC}"
		return 0
	else
		echo -e "${RED}✗ Failed to assign user to role${NC}"
		return 1
	fi
}

# Remove user from role
remove_user_from_role() {
	local smtp_container="$1"
	local user_email="$2"
	local role_email="$3"
	local parsed username domain user_id role_id rows_affected

	parsed=$(parse_email "$user_email") || return 1
	read -r username domain <<<"$parsed"
	validate_email "$role_email" || return 1

	echo -e "${YELLOW}Removing ${user_email} from role ${role_email}...${NC}"

	user_id=$(get_user_id "$smtp_container" "$username" "$domain") || return 1
	role_id=$(get_role_id "$smtp_container" "$role_email") || return 1

	# Delete the assignment entry and report how many rows went with it.
	# changes() is per-connection, so it has to run in the same sqlite3
	# invocation as the DELETE; the previous code opened a second connection and
	# therefore always read back 0, reporting every successful removal as a
	# failure.
	if ! rows_affected=$(run_sql "$smtp_container" "
DELETE FROM user_role_assignments
WHERE user_id = ${user_id} AND role_mailbox_id = ${role_id};
SELECT changes();"); then
		echo -e "${RED}✗ Failed to remove ${user_email} from ${role_email}${NC}"
		return 1
	fi
	rows_affected="${rows_affected//[$'\n\r']/}"

	if [ "$rows_affected" != "0" ]; then
		echo -e "${GREEN}✓ Successfully removed ${user_email} from ${role_email}${NC}"
		return 0
	else
		echo -e "${YELLOW}⚠ User ${user_email} was not assigned to ${role_email}${NC}"
		return 1
	fi
}

# Transfer role from one user to another
transfer_role() {
	local smtp_container="$1"
	local source_email="$2"
	local target_email="$3"
	local role_email="$4"

	echo -e "${CYAN}========================================${NC}"
	echo -e "${CYAN}Transferring Role Assignment${NC}"
	echo -e "${CYAN}========================================${NC}"
	echo -e "Role: ${BLUE}${role_email}${NC}"
	echo -e "From: ${YELLOW}${source_email}${NC}"
	echo -e "To:   ${GREEN}${target_email}${NC}"
	echo ""

	# Remove from source user
	if remove_user_from_role "$smtp_container" "$source_email" "$role_email"; then
		# Add to target user
		if add_user_to_role "$smtp_container" "$target_email" "$role_email"; then
			echo ""
			echo -e "${GREEN}✓ Role successfully transferred!${NC}"
			return 0
		else
			echo -e "${RED}✗ Failed to add role to target user. Restoring source user...${NC}"
			# The restore is the last chance to avoid losing the assignment
			# altogether, so a failure here must be shouted about rather than
			# swallowed as it previously was.
			if add_user_to_role "$smtp_container" "$source_email" "$role_email"; then
				echo -e "${YELLOW}⚠ Transfer aborted; ${source_email} keeps ${role_email}${NC}"
			else
				echo -e "${RED}✗ Could not restore ${source_email}. The assignment to ${role_email} has been LOST and must be re-added manually.${NC}"
			fi
			return 1
		fi
	else
		return 1
	fi
}

# List assignments for a user
list_user_assignments() {
	local smtp_container="$1"
	local user_email="$2"
	local parsed username domain assignments

	parsed=$(parse_email "$user_email") || return 1
	read -r username domain <<<"$parsed"

	echo -e "${CYAN}========================================${NC}"
	echo -e "${CYAN}Role Assignments for: ${GREEN}${user_email}${NC}"
	echo -e "${CYAN}========================================${NC}"

	if ! assignments=$(run_sql "$smtp_container" "
SELECT '  • ' || r.email ||
       ' (assigned: ' || datetime(ura.assigned_at, 'localtime') || ')'
FROM user_role_assignments ura
INNER JOIN users u ON ura.user_id = u.id
INNER JOIN role_mailboxes r ON ura.role_mailbox_id = r.id
INNER JOIN domains d ON u.domain_id = d.id
WHERE u.username = $(sql_quote "$username")
  AND d.domain = $(sql_quote "$domain")
  AND ura.is_active = 1
ORDER BY r.email;"); then
		echo -e "${RED}✗ Failed to read role assignments${NC}"
		return 1
	fi

	# An empty result set is not an error, so it has to be checked separately;
	# testing $? after the query never reported "none found".
	if [ -z "$assignments" ]; then
		echo -e "${YELLOW}No role assignments found${NC}"
	else
		echo "$assignments"
	fi
}

# List users assigned to a role
list_role_users() {
	local smtp_container="$1"
	local role_email="$2"
	local members

	validate_email "$role_email" || return 1

	echo -e "${CYAN}========================================${NC}"
	echo -e "${CYAN}Users assigned to: ${GREEN}${role_email}${NC}"
	echo -e "${CYAN}========================================${NC}"

	if ! members=$(run_sql "$smtp_container" "
SELECT '  • ' || u.username || '@' || d.domain ||
       ' (assigned: ' || datetime(ura.assigned_at, 'localtime') || ')'
FROM user_role_assignments ura
INNER JOIN users u ON ura.user_id = u.id
INNER JOIN role_mailboxes r ON ura.role_mailbox_id = r.id
INNER JOIN domains d ON u.domain_id = d.id
WHERE r.email = $(sql_quote "$role_email")
  AND ura.is_active = 1
ORDER BY u.username;"); then
		echo -e "${RED}✗ Failed to read role members${NC}"
		return 1
	fi

	if [ -z "$members" ]; then
		echo -e "${YELLOW}No users assigned to this role${NC}"
	else
		echo "$members"
	fi
}

# List all role assignments
list_all_assignments() {
	local smtp_container="$1"
	local assignments

	echo -e "${CYAN}========================================${NC}"
	echo -e "${CYAN}All Role Assignments${NC}"
	echo -e "${CYAN}========================================${NC}"

	if ! assignments=$(run_sql "$smtp_container" "
SELECT '  • ' || u.username || '@' || d.domain || ' → ' || r.email
FROM user_role_assignments ura
INNER JOIN users u ON ura.user_id = u.id
INNER JOIN role_mailboxes r ON ura.role_mailbox_id = r.id
INNER JOIN domains d ON u.domain_id = d.id
WHERE ura.is_active = 1
ORDER BY d.domain, u.username, r.email;"); then
		echo -e "${RED}✗ Failed to read role assignments${NC}"
		return 1
	fi

	if [ -z "$assignments" ]; then
		echo -e "${YELLOW}No role assignments found${NC}"
	else
		echo "$assignments"
	fi
}

# -------------------------------
# Main Script
# -------------------------------

# Check arguments
if [ $# -lt 1 ]; then
	show_usage
fi

COMMAND="$1"
shift

# Get SMTP container
SMTP_CONTAINER=$(get_smtp_container) || exit 1

case "$COMMAND" in
transfer)
	if [ $# -ne 3 ]; then
		echo -e "${RED}✗ Transfer requires 3 arguments: source-user target-user role${NC}"
		show_usage
	fi
	transfer_role "$SMTP_CONTAINER" "$1" "$2" "$3"
	;;

add)
	if [ $# -ne 2 ]; then
		echo -e "${RED}✗ Add requires 2 arguments: user role${NC}"
		show_usage
	fi
	add_user_to_role "$SMTP_CONTAINER" "$1" "$2"
	;;

remove)
	if [ $# -ne 2 ]; then
		echo -e "${RED}✗ Remove requires 2 arguments: user role${NC}"
		show_usage
	fi
	remove_user_from_role "$SMTP_CONTAINER" "$1" "$2"
	;;

list-user)
	if [ $# -ne 1 ]; then
		echo -e "${RED}✗ List-user requires 1 argument: user email${NC}"
		show_usage
	fi
	list_user_assignments "$SMTP_CONTAINER" "$1"
	;;

list-role)
	if [ $# -ne 1 ]; then
		echo -e "${RED}✗ List-role requires 1 argument: role email${NC}"
		show_usage
	fi
	list_role_users "$SMTP_CONTAINER" "$1"
	;;

list-all)
	list_all_assignments "$SMTP_CONTAINER"
	;;

*)
	echo -e "${RED}✗ Unknown command: $COMMAND${NC}"
	show_usage
	;;
esac
