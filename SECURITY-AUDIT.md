# Silver — Security and Correctness Audit

**Audited revision:** `cc54d66` (`main`)
**Date:** 2026-08-08
**Scope:** the whole repository — shell scripts, the Docker Compose deployment, the Helm umbrella chart and its subcharts, the Go metadata service, the Python load-test suite, and the generated Postfix/Dovecot/Rspamd/OpenDKIM configuration.

Every finding below was verified by reading the code at the audited revision. Line numbers refer to that revision and will drift as fixes land.

## How to read this

Findings are grouped by severity. Each carries a status:

- **Fixed** — a branch and PR exist. The PR is named in the entry.
- **Open** — verified, not yet fixed. Left deliberately; see *Deliberately deferred* below.

Severity reflects impact on a production mail deployment, not exploitability in isolation. A defect that silently disables spam filtering is rated High even though it grants no direct access, because the operator has no signal that protection is gone.

---

## Summary

| Severity | Count | Fixed | Open |
|---|---:|---:|---:|
| Critical | 7 | 7 | 0 |
| High | 20 | 14 | 6 |
| Medium | 22 | 3 | 19 |
| Low | 11 | 1 | 10 |
| **Total** | **60** | **25** | **35** |

Five of these (C-7, H-19, H-20, and the corrections to C-1, H-7 and H-12) were found *while fixing* the original findings, not during the audit pass. They are marked as such in place. C-7 in particular was hidden behind C-1: the render aborted before the broken result could be observed.

The five findings a reviewer should look at first:

1. **C-7** — Thunder's JWT issuer renders empty while raven validates against a real one, so every IMAP and SMTP login fails. Silent: pods start and lint passes.
2. **C-2** — Raven's internal LMTP port is published to the internet, bypassing all mail filtering.
3. **H-1** — the Rspamd NetworkPolicy selector matches no pod, so on Kubernetes every message is delivered unscanned, silently.
4. **C-6** — the S3 credentials protecting every mail attachment are either a public placeholder or derivable from the release name.
5. **C-1** — the documented Helm install command does not render at all.

A theme worth naming: the four most serious findings are all **silent**. Nothing crashes, nothing logs an error, and `helm lint` passes in every case. C-7 breaks all authentication, H-1 disables spam and antivirus filtering, C-6 leaves attachments world-readable — and a deployment exhibiting all three looks healthy. That is the property that makes them worth prioritising over the noisier items further down.

---

## Critical

### C-1 · The documented Helm install command fails to render
**Status:** Fixed — *fix: make the Helm install render and produce a coherent OAuth configuration*
`charts/silver/templates/domain-guard.yaml:38`, `charts/silver/values.yaml:216-217`

The `THUNDER_PUBLIC_URL` guard does not short-circuit on an empty value, unlike the two sibling guards at lines 25 and 30 which correctly do. `values.yaml` ships `value: ""` and `thunder.enabled` defaults to `true`, so the guard fires on the shipped default.

Reproduced verbatim from `charts/README.md:112-114`:

```
$ helm template silver charts/silver --set global.domain=example.com
Error: execution error at (silver/templates/domain-guard.yaml:39:8): thunder.setup.env
THUNDER_PUBLIC_URL () does not match global.domain (example.com). It must equal
thunder.configuration.server.publicUrl (https://example.com:8090), or the CONSOLE app
is registered with the wrong redirect URI.
```

Every install without an explicit `--set thunder.setup.env[1].value=...` is broken. The guard logic is otherwise sound and well-intentioned — this is a one-character-class omission in an otherwise careful design.

**Correction to the original framing.** This entry first described the fix as "restoring the one-command install". That was wrong, and fixing it surfaced C-7 below. The one-command install was never achievable: two of the three required values are consumed by the *vendored* Thunder subchart and Helm cannot template values files, so they must be passed as literals. The chart needs three inputs. What the fix actually delivers is that the failure is now honest and actionable, that the three-flag command both renders **and** produces a working OAuth configuration, and that `THUNDER_PUBLIC_URL` — the one value that *can* be derived — now is.

### C-7 · Thunder's JWT issuer is empty, so every OAuth login fails
**Status:** Fixed — *fix: make the Helm install render and produce a coherent OAuth configuration*
`charts/silver/values.yaml` (`thunder.configuration.server.publicUrl`, `thunder.configuration.gateClient.hostname`)

Found while fixing C-1, which was masking it — the render aborted before anyone could observe the result.

Both values ship as `""`. An empty string is a *set* value in Helm, so these override the subchart's own defaults rather than falling back to them. The rendered Thunder `deployment.yaml` ConfigMap therefore contains:

```yaml
server:
  public_url: ""
jwt:
  issuer: ""
```

while raven, in the same render, is configured with:

```yaml
oauth_issuer_url: "https://example.com:8090"
```

Raven validates tokens against an issuer Thunder never claims. Pods start, `helm lint` passes, certificates issue — and **every IMAP and SMTP login fails** on an issuer mismatch, with nothing in the chart output to suggest why. `values.yaml`'s own comment states the requirement ("Becomes the JWT issuer, so it must equal raven's oauth_issuer_url"); the guards simply skipped empty values.

This is precisely the failure mode `domain-guard.yaml`'s header comment says the file exists to prevent. Both values are now `required`, with error messages naming the exact flags. They cannot be derived and injected the way `THUNDER_PUBLIC_URL` was — that one reaches the setup job as container *env*, so `setup.secretEnv` → `secretKeyRef` works, whereas these are consumed as subchart *values* rendered into a ConfigMap via `toYaml`, where no injection point exists.

### C-2 · Raven's internal LMTP, SASL and socketmap ports are published to `0.0.0.0`
**Status:** Fixed — *fix: stop publishing internal Raven, metadata and S3 ports to the host*
`services/docker-compose.yaml:31-36`

```yaml
ports:
  - "24:24"        # LMTP
  - "12345:12345"  # SASL auth service
  - "9100:9100"    # socketmap
```

Port 24 is the LMTP endpoint Postfix delivers to *after* Rspamd, ClamAV and OpenDKIM have run. Anyone who can reach it can `LHLO` / `RCPT TO:<victim@domain>` / `DATA` and write arbitrary mail directly into any user's INBOX — no spam scoring, no antivirus, no DKIM/SPF/DMARC evaluation, no rate limiting, and an arbitrary `From:`.

Port 12345 is an unauthenticated credential-check oracle: password guessing at network speed with none of Postfix's anvil rate limiting. Port 9100 answers `user-exists`, `virtual-aliases` and `virtual-domains`, leaking the complete user and alias directory to anonymous callers.

All three are reachable between containers over the `mail-network` bridge and never needed host publication.

### C-3 · Thunder identity server defaults to `admin`/`admin`, and the password is written to logs
**Status:** Fixed — *fix: require an explicit Thunder admin password and stop logging it*
`scripts/thunder/01-default-resources.sh:180-181,209`; duplicated at `charts/silver/files/thunder-bootstrap/01-default-resources.sh`; `scripts/utils/thunder-auth.sh:112`; `services/.env.example`

```bash
ADMIN_PASSWORD="${THUNDER_ADMIN_PASSWORD:-admin}"
...
log_info "Password: ${ADMIN_PASSWORD}"
```

Thunder authenticates **every IMAP and SMTP login** in the stack and is published on port 8090. A user who follows the README without setting `THUNDER_ADMIN_PASSWORD` gets `admin`/`admin` holding the `system` permission (granted at lines 651-767). `services/.env.example` shipped `THUNDER_ADMIN_PASSWORD=admin` as a working sample value, so copying the example as documented produced a live default credential.

Line 209 additionally prints the password in cleartext to container stdout. `thunder-auth.sh:32` demonstrates that these logs are retained and machine-readable (`docker logs thunder-setup | grep ...`). Under Helm the password is a generated 32-character secret — and this line prints it into `kubectl logs` and every log shipper. Lines 1402-1404 already print username-only in the final summary, which shows the intent was there.

A related bug in the same code path made this harder to notice: the bootstrap JSON payload splices `${ADMIN_PASSWORD}` unquoted into a single-quoted string, so a password containing a space word-splits the payload and the API call fails. Bootstrap therefore broke *specifically* for operators who chose a strong password.

### C-4 · Metadata service API-key authentication fails open
**Status:** Fixed — *fix: fail closed when the metadata service API key is unset*
`services/metadata-service/main.go:245-249`

```go
if config.APIKey == "" {
    log.Println("Warning: API_KEY not configured, skipping authentication")
    next.ServeHTTP(w, r)
    return
}
```

`services/.env.example:34` ships `API_KEY=` empty and `dev/README.md:14` instructs the operator to copy it verbatim, so authentication is disabled on every fresh install — and the service was published on host port 8888. The key comparison at line 262 (`apiKey != config.APIKey`) was also non-constant-time.

### C-5 · Rspamd controller: default password `admin`, bound to all interfaces, and `enable_password` misconfigured
**Status:** Fixed — *fix: require an Rspamd controller password and repair the NetworkPolicy selector*
`scripts/utils/generate-rspamd-worker-controller.sh:22-29,49,58-59`; `charts/silver/charts/rspamd/values.yaml:92`

Three defects compounding:

```bash
if [ -z "$RSPAMD_PASSWORD" ]; then
  echo "Warning: RSPAMD_PASSWORD not set in .env, using default password 'admin'"
  RSPAMD_PASSWORD="admin"
fi
HASH=$(docker exec rspamd rspamadm pw --password "$RSPAMD_PASSWORD" 2>/dev/null)
...
bind_socket = "0.0.0.0:11334";
enable_password = true;
```

The silent `admin` fallback publishes the spam-filter admin console on all interfaces. The password is an `argv` element of `docker exec` and `rspamadm`, so `ps aux` exposes it on both host and container, and it lands in shell history. And `enable_password` — which is supposed to hold the hash guarding *privileged* actions (learn, fuzzy, config write) — is assigned the UCL boolean `true`, so those actions are not protected by the intended hash.

An attacker with controller access can whitelist themselves, retrain Bayes on inverted labels, disable filtering outright, and read scanned-message metadata.

On the Helm side, `webui.password: ""` gates both `secret-webui.yaml` and the `RSPAMD_PASSWORD` env, so the default deployment runs the controller with **no password at all** — while `templates/networkpolicy.yaml:22-26` explicitly allows port 11334 from `namespaceSelector: {}`, i.e. every namespace in the cluster.

### C-6 · S3 credentials for the mail-attachment store are public or derivable
**Status:** Fixed — *fix: generate real S3 credentials instead of shipping derivable defaults*
`scripts/service/start-silver.sh:97-106`; `services/config-scripts/gen-raven-conf.sh:35-45`; `charts/silver/charts/seaweedfs/templates/_helpers.tpl:47`; `charts/silver/charts/raven/templates/_helpers.tpl:58`

Two independent instances of the same class.

**Compose:** both `s3-config.json.example` and `.env.example` contain `your-access-key-here` / `your-secret-key-here`, with `"actions": ["Admin","Read","Write"]`, and both are `cp`'d verbatim into the live configuration on first run. Because the server side and the client side receive the *same* placeholder, the stack works perfectly — which is exactly why nobody notices. The `${S3_ACCESS_KEY:-raven}` fallbacks at `gen-raven-conf.sh:49-50` never fire, because the sourced `.env` has already set the variables to the placeholders.

**Helm:** the key is derived as `sha256("<release>-silver-seaweedfs-s3")[:40]`. With the documented release name `silver`, anyone can compute it offline from public information. `values.yaml:32-34` ships the override empty.

Worth noting in the chart's defence: the derivation is *deliberate and documented* — the comment above the `define` explains that `lookup` cannot see a Secret the same install has not yet applied, so raven needs to compute the identical key. The fix had to break that coupling (raven now reads the key via `secretKeyRef`) rather than simply substituting `randAlphaNum`, which would have broken one-command install.

---

## High

### H-1 · The Rspamd NetworkPolicy matches no pod, so mail is delivered unscanned
**Status:** Fixed — *fix: require an Rspamd controller password and repair the NetworkPolicy selector*
`charts/silver/charts/rspamd/templates/networkpolicy.yaml:16-18`

```yaml
- podSelector:
    matchLabels:
      app.kubernetes.io/name: smtp
```

Postfix pods are labelled `app.kubernetes.io/name: postfix` — `charts/silver/charts/postfix/templates/_helpers.tpl:38` derives it from `.Chart.Name`. **No pod in the release carries the label `smtp`.** So postfix → rspamd:11332 is dropped by the policy.

Because `main.cf` sets `milter_default_action = accept`, Postfix then accepts and delivers every message **completely unfiltered, logging nothing as an error**. Enabling Rspamd appears to work while providing no protection whatsoever.

The template also has no `{{- if .Values.networkPolicy.enabled }}` gate (unlike `opendkim/templates/networkpolicy.yaml:1`) and `networkPolicy` does not exist in the rspamd `values.yaml`, so the policy is unconditional. The chart's own helm test papers over the bug by applying the fake `smtp` label to the test pod (`templates/tests/test-rspamd.yaml:11`).

This is the most consequential silent-failure defect in the repository.

### H-2 · Command injection into the Postfix container via user-management arguments
**Status:** Fixed — *fix: close command and SQL injection in the user role management scripts*
`scripts/user/manage_roles.sh:88-93`, and the same shape at 107, 134, 146, 175, 238, 265, 291

```bash
local user_id=$(docker exec "$smtp_container" bash -c "
    sqlite3 /app/data/databases/shared.db \"
        SELECT u.id FROM users u ...
        WHERE u.username='${username}' AND d.domain='${domain}' ...
    \"" 2>/dev/null | tr -d '\n\r')
```

`$username` is expanded into a string handed to `bash -c` **inside the container**, where the inner shell re-parses it, so command substitution fires:

```
./manage_roles.sh list-user '$(cp /app/data/databases/shared.db /tmp/x)@example.com'
```

`parse_email:75` (`^(.+)@(.+)$`) accepts anything at all. A `"` escapes the sqlite argument; a `'` gives ordinary SQL injection.

### H-3 · Python code injection when removing users
**Status:** Fixed — *fix: close command and SQL injection in the user role management scripts*
`scripts/user/remove_test_users.sh:211-212`

```bash
ENCODED_FILTER=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${FILTER}'))")
```

`$EMAIL` is interpolated into a Python **source literal**. A `'` terminates the string; `'+__import__("os").system("...")+'` executes arbitrary code as the operator. In the fallback branch at line 145 the value comes straight out of the shared SQLite `users` table, which Thunder populates — including via self-registration — making this remotely reachable.

### H-4 · `local x=$(...) || return 1` never detects failure, and error text is interpolated into SQL
**Status:** Fixed — *fix: close command and SQL injection in the user role management scripts*
`scripts/user/manage_roles.sh:130-131,171-172`

`local` is itself a command and always exits 0, so it masks the command substitution's status and `|| return 1` is dead code. Compounding it, `get_user_id:96` writes its error message to **stdout**, so on failure the variable becomes the ANSI-coloured string `✗ User bob@x not found`, which is then interpolated as `WHERE user_id=✗ User bob@x not found`.

Concrete data loss: `manage_roles.sh transfer alice@x bob@x info@x` with a nonexistent `bob` successfully strips alice's assignment, then issues garbage SQL that does nothing, then hits the identical bug on the restore path at line 219. The role assignment is lost with no error shown.

### H-5 · Postfix offers SASL AUTH over cleartext
**Status:** Fixed — *fix: require TLS before SMTP AUTH and disable VRFY in the Helm chart*
`services/config-scripts/gen-postfix-conf.sh:71,125`

`smtpd_tls_security_level = may` together with `smtpd_sasl_auth_enable = yes` and **no `smtpd_tls_auth_only`** means Postfix advertises `AUTH PLAIN LOGIN` on unencrypted sessions on both 25 and 587. A client whose STARTTLS fails, or an active attacker stripping the STARTTLS advertisement from the EHLO response, sends the mailbox password in the clear. The generated `main.cf` has no submission-specific override at all.

(Opportunistic TLS on inbound port 25 is correct and was left unchanged — forcing encryption there would break MTA interoperability.)

### H-6 · Certbot container cannot start, so no certificate is ever issued or renewed
**Status:** Fixed — *fix: stop publishing internal Raven, metadata and S3 ports to the host* (mount) and *fix: build certbot arguments safely instead of by string concatenation* (entrypoint)
`services/docker-compose.yaml:202-205`; `services/certbot/scripts/entrypoint.sh:4,12`

Nothing mounts `/etc/certbot/silver.yaml`, but the entrypoint sets `CONFIG_FILE="/etc/certbot/silver.yaml"` and greps it at line 12. Under `set -e` the grep on a nonexistent file kills the container at startup. The `postfix` and `opendkim` services both correctly mount `../conf/silver.yaml`; certbot was simply missed.

Postfix only waits on `condition: service_started`, so it starts anyway and then fails to find `/etc/letsencrypt/live/<domain>/fullchain.pem`.

Separately, line 205 ends in a stray double quote — `- ./silver-config/certbot/keys/lib:/var/lib/letsencrypt"` — creating a bind mount whose host path literally ends in `"`.

### H-7 · Certbot arguments built by string concatenation allow flag injection
**Status:** Fixed — *fix: build certbot arguments safely instead of by string concatenation*
**Severity downgraded on evidence: robustness fix with a security edge, not an exploitable redirect.**
`services/certbot/scripts/entrypoint.sh:28-48`

`CERTBOT_CMD` is assembled as a string and expanded unquoted at `exec $CERTBOT_CMD`, so a `domain:` value in `silver.yaml` containing whitespace or a leading `-` splits into additional argv entries. Line 48's success message is unreachable dead code after `exec`.

**Correction.** This was originally rated High on the assumption that an injected `--server` would redirect ACME registration to an attacker-controlled endpoint. Tested against real certbot, it does not:

```
certbot: error: argument -d/--domains/--domain: expected one argument
```

The loop prefixes *every* token with `-d`, so an injected option lands in `-d`'s value slot, where argparse refuses option-like strings. On today's exact code the attack fails closed as a usage error.

It was still fixed, because the protection is an incidental side effect of the loop's shape rather than a control: any edit that appends a domain without a preceding `-d`, or reuses the pattern for another flag, makes it live with no warning — and config-controlled values already choose argv boundaries.

### H-8 · Raven runs as root with the Docker socket mounted
**Status:** Fixed — *fix: stop publishing internal Raven, metadata and S3 ports to the host*
`services/docker-compose.yaml:41,58`

```yaml
- /var/run/docker.sock:/var/run/docker.sock:ro
user: "0:0"
```

Raven is the internet-facing IMAP/LMTP/SASL daemon. Read-only socket access is still full Docker API access — `POST /containers/create` with `Binds: ["/:/host"]` is host root. Any parser bug in the most exposed component in the stack becomes an immediate host takeover.

The mount existed only so `thunder-auth.sh:32` could scrape `docker logs thunder-setup` for `DEVELOP_APP_ID`. The Helm chart already solves this properly by passing the value as configuration (`raven.thunder.applicationId`).

### H-9 · IMAP load tester disables certificate verification, then silently falls back to plaintext
**Status:** Fixed — *fix: verify TLS in the load testers and stop downgrading to plaintext IMAP*
`test/load/imap_tester.py:32-34,60`; `test/load/config.py:14-18`

```python
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
...
{"port": 143, "ssl": False, "starttls": False, "name": "IMAP Plain (Port 143)"}
```

`_connect_imap` walks `IMAP_CONFIGS` in order, so one transient failure on 993 downgrades to unverified STARTTLS and then to fully unencrypted IMAP, putting a real password on the wire (line 72) against a server whose identity was never checked. `MAIL_DOMAIN` points at the production host.

`smtp_tester.py:61-64` has the same class of problem: `server.starttls()` with no `context` uses the *unverified* stdlib context.

### H-10 · Rspamd chart hardcodes the release name, breaking any release not named `silver`
**Status:** Fixed — *fix: require an Rspamd controller password and repair the NetworkPolicy selector*
`charts/silver/charts/rspamd/values.yaml:65-73`

`dependencies.redis.host: silver-redis` and `dependencies.unbound.host: silver-unbound`, but the Services are `<release>-redis` / `<release>-unbound`. With `strictInitChecks: true`, `helm install mail ./charts/silver` leaves the `check-redis` / `check-unbound` init containers spinning for 60 s and exiting 1 — the pod never starts.

`dependencies.clamav.host: clamav-server` names a Service that **no chart in this repository creates**, while `modules.antivirus.enabled: true`.

### H-11 · Private keys are created world-readable, then chmod'd afterwards
**Status:** Fixed — *fix: create key material with restrictive permissions and keep credentials out of git*
`services/config-scripts/gen-thunder.sh:20-25`; `services/config-scripts/gen-observability.sh:54-61`

`cp` creates the destination at `0666 & ~umask`, typically `0644`, so the TLS private key is world-readable between the `cp` and the `chmod` — and permanently if the script dies in between. It can: the `sudo chown` at `gen-thunder.sh:24` can prompt or fail, and `set -euo pipefail` then aborts before the `chmod` runs.

### H-12 · Test-user credentials are written unprotected and are not gitignored
**Status:** Fixed — *fix: create key material with restrictive permissions and keep credentials out of git*
`scripts/user/create_test_users.sh:239-242,285`

100 plaintext mailbox passwords are written to `scripts/user/test_users/test_users_credentials.csv` at the default umask. No `.gitignore` rule matched that path — the existing rules cover `test/test_data/` only — so a single `git add -A` would commit them to a public repository.

**Correction:** this entry originally also claimed `test/load/test_data/users.csv` was unignored. It is not — a pre-existing `test/load/.gitignore` already covers it. Only the `scripts/user/test_users/` path was exposed. An ignore rule for the untracked `test/security/network_audit/` directory (packet captures of live mail traffic) was added at the same time.

This audit's own authoring hit the risk it describes: an unscoped `git add -A` staged both the packet captures and ten agent worktrees before being caught and reverted. The ignore rules now prevent the first half of that recurring.

### H-13 · Cloudflare API token passed as a command-line argument
**Status:** Fixed — *fix: create key material with restrictive permissions and keep credentials out of git*
`infra/bootstrap.sh:46-49`

The script does the hard part correctly — reads the token with `read -rsp`, masks it in output — and then hands it to `kubectl create secret --from-literal=api-token="$CF_TOKEN"`, where `ps auxww` exposes it to every local user for the duration of the call. A Cloudflare DNS-edit token permits full zone takeover.

### H-14 · S3 secret key embedded in an `awk` program argument
**Status:** Fixed — *fix: generate real S3 credentials instead of shipping derivable defaults*
`services/config-scripts/gen-raven-conf.sh:99-104`

The entire awk source, with the secret inlined, becomes `argv[1]`, so `ps auxww` reads it. A key containing `"` or `\` also produces a syntactically invalid awk program; `set -euo pipefail` then aborts *after* `raven.yaml` was written, leaving `delivery.yaml` half-rewritten by the `mv` at line 158. (`awk -v` is not a fix — those values are equally visible in `ps`.)

### H-15 · SeaweedFS master API shares a Service with S3 and has no authentication
**Status:** Fixed — *fix: generate real S3 credentials instead of shipping derivable defaults*
`charts/silver/charts/seaweedfs/templates/service.yaml:19-27`

Ports 9333 and 19333 (master HTTP and gRPC) sit on the same Service as the S3 gateway. The master API has **no authentication** — `s3-config.json` only gates port 8333. Any pod in the cluster can enumerate volumes and read or delete raw attachment blobs, bypassing the S3 credential entirely. There is no NetworkPolicy for seaweedfs anywhere in the tree.

### H-16 · Raven and Postfix pods run as UID 0 with no capability restrictions
**Status:** Fixed — *fix: harden Raven and Postfix pod security contexts*
`charts/silver/charts/raven/values.yaml:20-23`; `charts/silver/charts/postfix/values.yaml:35-40`

No `allowPrivilegeEscalation: false`, no `capabilities.drop: [ALL]`, no `readOnlyRootFilesystem`, no `seccompProfile`. Postfix adds `NET_BIND_SERVICE` but never drops anything — as UID 0 the container already holds the full default capability set, so the `add` is cosmetic and the real grant is unbounded.

`rspamd`, `redis`, `opendkim` and `seaweedfs` all do this correctly, which is what makes raven and postfix stand out as gaps rather than a deliberate policy. Raven additionally takes `hostPort` 143/993, making it the most exposed workload in the cluster.

### H-17 · Every pod automounts a ServiceAccount token; three have no ServiceAccount at all
**Status:** Fixed — *fix: harden Raven and Postfix pod security contexts*

`automountServiceAccountToken` appears nowhere in the tree. Raven, Postfix and SeaweedFS declare no `serviceAccountName` and ship no `serviceaccount.yaml`, so they run under the namespace `default` SA with its token mounted at `/var/run/secrets/kubernetes.io/serviceaccount`. None of them talks to the Kubernetes API. Combined with H-16 this is a real escalation path.

*Positive finding:* there are **no** Roles or ClusterRoles anywhere in the tree, so there is no over-permissive RBAC to report.

### H-19 · `transfer` destroys a role assignment and reports that nothing happened
**Status:** Fixed — *fix: close command and SQL injection in the user role management scripts*
`scripts/user/manage_roles.sh` (`remove_user_from_role`)

Found while fixing H-2/H-4. Worse than H-4 described, and independent of it.

`remove_user_from_role` issues its `DELETE`, then reads `changes()` over a **second** `sqlite3` invocation. `changes()` is per-connection state, so the second connection always reports `0`. Every successful removal is therefore reported as "user was not assigned" — and `transfer_role` treats that as failure and aborts **before attempting the restore**. The `DELETE` has already committed.

Net effect: `manage_roles.sh transfer alice@x bob@x info@x` can leave the role with no members at all, while telling the operator nothing was changed. Reproduced against `origin/main`.

### H-20 · TLS private keys are left world-readable on any re-run
**Status:** Fixed — *fix: create key material with restrictive permissions and keep credentials out of git*
`services/config-scripts/gen-thunder.sh:20-25`, `services/config-scripts/gen-observability.sh:54-61`

Two additional defects found while fixing H-11, both of which defeat that fix on their own:

- **`chmod` runs after `chown`.** Once `sudo chown 10001:10001` succeeds, the invoking user no longer owns the file, so the following unprivileged `chmod 600` fails — and under `set -euo pipefail` the script aborts, leaving the key at whatever mode `cp` created.
- **`cp` onto an existing destination preserves the destination's mode.** A `(umask 077; cp …)` therefore does *not* repair a key that a previous run already created at `0644`. The destination has to be removed first.

The same `cp` behaviour also made both scripts non-re-runnable: `cp` opens the destination `O_WRONLY`, so once `grafana.crt` is `0444` or the Thunder certs are owned by uid 10001, the next run dies with `Permission denied`.

### H-18 · All service configuration is cloned from an unpinned personal repository at install time
**Status:** Open — see *Deliberately deferred*
`conf/silver.yaml:27`; `scripts/setup/setup.sh:22,92`

```yaml
config-url: "https://github.com/maneesha-xyz/silver-config"
```
```bash
git clone "${SILVER_CONFIG}" "${SERVICES_DIR}/silver-config"
```

No tag, no commit pin, no signature verification — and it is an individual's account rather than the `LSFLK` organisation. That repository supplies `postfix/master.cf`, all `rspamd/local.d`, `thunder/deployment.yaml`, `grafana/grafana.ini`, and the `clamav-exporter` **Dockerfile that is built and run** (compose lines 135-137). Whoever controls that account has arbitrary code execution on every Silver installation.

This is arguably the single highest-impact finding in the audit, but fixing it is an organisational decision (move the repository under `LSFLK`, pin to a signed tag), not a code change.

---

## Medium

### M-1 · Milters fail open — spam, antivirus and DKIM are bypassed when Rspamd or OpenDKIM is down
**Status:** Open
`services/config-scripts/gen-postfix-conf.sh:140-142`; `charts/silver/charts/postfix/files/postfix/main.cf:111-113`

`milter_default_action = accept` with no healthchecks on `rspamd` or `opendkim`, and Postfix only waiting on `service_started`. During the routine window where Rspamd/ClamAV are still loading signatures, every inbound message is accepted unscanned and every outbound message leaves **unsigned**, breaking DKIM/DMARC alignment at the recipient. Should be `tempfail`, paired with real healthchecks and `condition: service_healthy`.

### M-2 · OpenDKIM TrustedHosts grants signing rights to entire RFC1918 ranges
**Status:** Open
`services/config-scripts/gen-opendkim-conf.sh:65-76`

TrustedHosts entries are treated as internal — their mail gets *signed* rather than verified. The list includes `10.0.0.0/8`, `172.16.0.0/12`, and `echo "*.$DOMAIN"`. Any container or VM sharing the 172.16/12 bridge, and any host resolving to a subdomain of the domain, can have mail signed with the production DKIM key. `192.168.65.0/16` is also a malformed CIDR (host bits set in a /16; almost certainly meant `192.168.0.0/16`).

### M-3 · `disable_vrfy_command` missing from the Helm chart's `main.cf`
**Status:** Fixed — *fix: require TLS before SMTP AUTH and disable VRFY in the Helm chart*
`charts/silver/charts/postfix/files/postfix/main.cf`

The compose generator sets it (`gen-postfix-conf.sh:151`) but the chart does not, and Postfix defaults to `no`. Every Kubernetes deployment answered `VRFY <user>`, enumerating valid mailboxes for targeted phishing. A drift between the two deployment paths rather than a design decision.

### M-4 · Thunder admin console published on a LoadBalancer with no source restriction
**Status:** Fixed — *fix: make the documented Helm install render, and issue one multi-SAN certificate*
`charts/silver/templates/thunder-lb.yaml:22`

Port 8090 serves the OAuth issuer and JWKS — which must be public — *and* the CONSOLE admin UI plus the management REST API (`/users`, `/organization-units`, `/applications`). No `loadBalancerSourceRanges`, no NetworkPolicy, rendered unconditionally whenever `thunder.enabled`.

### M-5 · `global.tls.domains` creates N single-name certificates instead of one multi-SAN certificate
**Status:** Fixed — *fix: make the documented Helm install render, and issue one multi-SAN certificate*
`charts/silver/templates/certificate.yaml:2-19`

Documented at `values.yaml:53` and `charts/README.md:83-85` as "override only to add extra SANs"; it does the opposite. Using it as documented stops `mail-<domain>-tls` from being created, and `postfix-deployment.yaml:105` mounts that Secret — the pod hangs in `ContainerCreating`. It also multiplies ACME issuance against the 5-per-week limit that the adjacent comment is explicitly trying to protect.

### M-6 · `values-prod.yaml` cannot install and would select staging certificates
**Status:** Fixed — *fix: make the documented Helm install render, and issue one multi-SAN certificate*
`charts/silver/values-prod.yaml`

Fifteen lines of opendkim settings. No `global.domain` (→ `required` abort), no `global.tls.issuer` (→ inherits `le-staging`, i.e. untrusted certificates on a public mail server, which per the chart's own comment at `values.yaml:47-48` breaks raven's JWKS fetch and mail-client OAuth), no `s3.secretKey`, and literal `example.com` / `your-storage-class` placeholders. `values-dev.yaml` and `values-local.yaml` are complete and coherent.

### M-7 · Load tester rate-limit detection reports genuine failures as passes
**Status:** Fixed — *fix: verify TLS in the load testers and stop downgrading to plaintext IMAP*
`test/load/smtp_tester.py:50-52`

`'421' in str(exception).lower()` substring-matches the entire stringified exception, so any error text containing `421` — a message ID, a byte offset, a nested response code — is reported to Locust with `exception=None`, i.e. as a **passing request**. A real outage can produce a green load-test run.

### M-8 · Failed IMAP logins are retried against every transport
**Status:** Fixed — *fix: verify TLS in the load testers and stop downgrading to plaintext IMAP*
`test/load/imap_tester.py:75-86,106-117`

A wrong password is caught by the broad `except Exception` and the connector moves to the next config, so every task produces three failed authentications. At Locust concurrency that is thousands of bad logins per minute from one IP — which fail2ban or Postfix anvil will correctly treat as a brute-force attack.

### M-9 · `TIMEOUT` is defined but never applied
**Status:** Fixed — *fix: verify TLS in the load testers and stop downgrading to plaintext IMAP*
`test/load/config.py:20`

Neither `smtplib.SMTP(...)` nor `imaplib.IMAP4_SSL(...)` receives a `timeout=`, so a stalled server hangs Locust workers on the OS default (~2 hours) instead of failing the request.

### M-10 · cAdvisor runs privileged with the host root filesystem mounted
**Status:** Fixed — *fix: stop publishing internal Raven, metadata and S3 ports to the host*
`services/docker-compose.yaml:270-277`

`privileged: true` grants all capabilities and disables seccomp and AppArmor, with `/:/rootfs:ro` and `/var/lib/docker/:/var/lib/docker:ro` mounted, on `mail-network` alongside the internet-facing services. `node-exporter` similarly mounts `/` and uses `pid: host`.

### M-11 · Grafana admin credentials default to empty
**Status:** Fixed — *fix: stop publishing internal Raven, metadata and S3 ports to the host* (host binding)
`services/.env.example:12-13`; `services/docker-compose.yaml:336-337,346-347`

`GF_SECURITY_ADMIN_PASSWORD=` overrides Grafana's built-in default with an *empty string* rather than leaving it unset, on a dashboard that renders mail-flow metrics and Postfix logs via Loki, published on `0.0.0.0:3000`. The host binding is fixed; making the variables mandatory in `.env.example` remains open.

### M-12 · Unpinned floating image tags throughout
**Status:** Partially fixed — compose images pinned in *fix: stop publishing internal Raven, metadata and S3 ports to the host*; chart images in *fix: harden Raven and Postfix pod security contexts*

`ghcr.io/lsflk/raven:latest`, `rspamd/rspamd:latest`, `chrislusf/seaweedfs:latest` and eight others in compose; `raven/Chart.yaml:7` and `seaweedfs/Chart.yaml:7` both `appVersion: "latest"` with `pullPolicy: Always`. Two identical deployments a week apart produce different mail servers and rollback is impossible.

`opendkim` pins `tag: main` — a floating branch tag — paired with `pullPolicy: IfNotPresent`, the worst combination: nodes cache the first `main` they pull and never see updates, so different nodes run different code. **Open.**

Also open: `services/smtp/Dockerfile:25`, `services/dkim/Dockerfile:19` and `services/certbot/Dockerfile:9` all `wget .../releases/latest/download/yq_linux_amd64` with no checksum or signature verification.

### M-13 · `start-silver.sh` rewrites the host's `/etc/hosts`
**Status:** Open
`scripts/service/start-silver.sh:78-86`

```bash
sudo sed -i "/^[^#]*[[:space:]]${MAIL_DOMAIN}\(...\)/s/.../127.0.0.1   ${MAIL_DOMAIN}/" /etc/hosts
```

Two distinct failures. A line such as `127.0.1.1 myhostname example.com` is rewritten to `127.0.0.1   example.com`, destroying `myhostname` — which breaks `sudo` name resolution on many Debian and Ubuntu systems. And the `grep` guard matches commented lines while the `sed` address `^[^#]*` refuses them, so the script takes the "update" branch, changes nothing, and never adds the entry.

`stop-silver.sh` does not undo the change. A "start" script mutating host system state with `sudo` is questionable regardless.

### M-14 · `cleanup-docker.sh` destroys every Docker volume and image on the machine
**Status:** Open
`scripts/service/cleanup-docker.sh:55-71`

```bash
VOLUMES=$(docker volume ls -q)
docker volume rm $VOLUMES
IMAGES=$(docker images -q)
docker rmi -f $IMAGES
```

Neither list is scoped to the compose project. A developer answering `y` to "remove ALL Docker volumes and images" from inside this repository loses unrelated projects' databases and every cached image on the host — irreversible for volumes. Should be `docker compose down -v --rmi local`, or filtered by `label=com.docker.compose.project=silver`.

### M-15 · `persistence.enabled: false` is silently ignored
**Status:** Open
`charts/silver/charts/unbound/templates/statefulset.yaml:63`; `charts/silver/charts/rspamd/templates/statefulset.yaml:158`

Both `volumeClaimTemplates` blocks are unconditional; neither template ever reads the flag its own README documents. On a cluster with no default StorageClass, `--set unbound.persistence.enabled=false` does not help — the PVC is created regardless and the pod stays `Pending` forever. `opendkim/templates/workload.yaml:13,112-118` shows the correct pattern.

### M-16 · StatefulSet `serviceName` points at Services that are never created
**Status:** Partially fixed — rspamd in *fix: require an Rspamd controller password and repair the NetworkPolicy selector*
`charts/silver/charts/opendkim/templates/workload.yaml:8`; `charts/silver/charts/rspamd/templates/statefulset.yaml:8`

`serviceName: silver-opendkim` / `silver-rspamd`, but the only Services created are named `opendkim` and `rspamd`. No headless governing Service exists, so stable per-pod DNS never resolves — the primary reason to use a StatefulSet. Harmless at `replicas: 1`, breaks on any scale-out.

The same name confusion makes two helm tests always fail (`tests/test-rspamd.yaml:23`, `opendkim/templates/tests/test-connection.yaml:13`) and one README instruction wrong (`rspamd/README.md:70`). **opendkim remains open.**

### M-17 · `global.imagePullSecrets` reaches only two of seven subcharts
**Status:** Open
`charts/silver/values.yaml:36`

Only `postfix/templates/postfix-deployment.yaml:23` and `opendkim/templates/workload.yaml:45` read `.Values.global.imagePullSecrets`. Raven, redis, rspamd, seaweedfs and unbound each read a *local* `.Values.imagePullSecrets` that the umbrella never populates. With images in a private registry, setting the documented global knob leaves five workloads in `ImagePullBackOff`.

### M-18 · No resource requests or limits on postfix, opendkim, or the bucket-init Job
**Status:** Fixed for postfix — *fix: harden Raven and Postfix pod security contexts*
`charts/silver/charts/postfix/values.yaml:31`; `charts/silver/charts/opendkim/values.yaml:37`; `charts/silver/charts/seaweedfs/templates/job-bucket-init.yaml:24-27`

`postfix-deployment.yaml:77` wraps the block in `{{- with }}`, so the `{}` default produces no `resources` key at all → QoS class `BestEffort` → under node memory pressure the kubelet evicts **Postfix**, holder of the inbound mail queue, first, while raven, rspamd, redis, unbound and seaweedfs all survive. **opendkim and the Job remain open.**

### M-19 · No PodDisruptionBudgets, and NetworkPolicies for one workload of eight
**Status:** Open

`PodDisruptionBudget` appears nowhere. NetworkPolicy exists only in `rspamd` (unconditional and broken — H-1) and `opendkim` (disabled by default). Unprotected and reachable from any pod in the cluster: raven's SASL port 12345 and socketmap 9100, postfix 25/587, seaweedfs 8333/9333/19333, redis 6379, Thunder 8090.

Raven's socketmap is an unauthenticated user-enumeration oracle for any workload in the cluster; port 12345 is an unauthenticated SASL verifier usable for offline password guessing.

### M-20 · `gen-configs.sh` runs seven generators with no error propagation
**Status:** Open
`services/config-scripts/gen-configs.sh:1-12`

No `set -e`, no `||` checks. If `gen-certbot-certs.sh` fails — the user answers `n`, DNS TXT is missing, certbot is rate-limited — `gen-thunder.sh:20` then copies a nonexistent `fullchain.pem` and dies, but `gen-raven-conf.sh` and `gen-observability.sh` still run and write configs pointing at certificates that do not exist. `scripts/setup/setup.sh:100` then prints `✓ Setup completed successfully!` regardless.

### M-21 · `gen-observability.sh` aborts halfway, leaving Grafana without TLS
**Status:** Fixed — *fix: create key material with restrictive permissions and keep credentials out of git*
`services/config-scripts/gen-observability.sh:44,57-59,83`

Uses plain `chown` where its sibling `gen-thunder.sh:24` uses `sudo chown`. Run as a normal user the `chown` fails and `set -e` kills the script *after* the webhook URL was written but *before* the TLS certificates are installed and before `grafana.ini` gets its domain substituted. Non-idempotent too: the `<MAIL_DOMAIN>` placeholder is consumed on the first run.

### M-22 · Unquoted expansions in DKIM key generation can leave a private key at 0644
**Status:** Open
`services/dkim/scripts/entrypoint.sh:47,50,52-54`

Every path is unquoted. A `dkim-selector:` or `domain:` value containing whitespace makes `mkdir -p` create several directories, `[ ! -f a b c ]` fail with "too many arguments" (→ `set -e` kills the container), and `chmod 600` apply to the wrong path — leaving a freshly generated **DKIM private key world-readable**. `$DKIM_KEY_SIZE` is passed unvalidated to `-b`.

---

## Low

### L-1 · `02-sample-resources.sh` has no shebang but is mode 0755
**Status:** Open — `scripts/thunder/02-sample-resources.sh:1`
The first line is `set -e`. Executed directly this gets `ENOEXEC` and the calling shell falls back to `/bin/sh`; under dash, `${BASH_SOURCE[0]:-$0}`, `[[ -f ... ]]`, `read -r -d ''` and `${RESPONSE: -3}` all break. Failure mode is a confusing `Bad substitution` mid-bootstrap. Its sibling `01-default-resources.sh` has a shebang.

### L-2 · Duplicated Thunder bootstrap scripts with no CI guard
**Status:** Open — `scripts/thunder/create-bootstrap-configmap.sh:6-8`
The script states the ConfigMap is built "directly from the canonical scripts here, so they are never duplicated into the chart", yet `charts/silver/files/thunder-bootstrap/01-default-resources.sh` and `02-sample-resources.sh` are byte-identical copies. They match today; the first fix applied to one path silently leaves the other vulnerable. C-3 had to be applied to both copies by hand.

### L-3 · `readonly VAR=$(cmd)` swallows the command's exit status
**Status:** Open — `scripts/setup/setup.sh:22,58`; `services/config-scripts/gen-postfix-conf.sh:17`; `gen-thunder.sh:10`
`readonly` and `declare` always return 0, so even with `set -euo pipefail` a missing `conf/silver.yaml` yields an empty variable rather than an abort. `gen-postfix-conf.sh` then writes a `main.cf` with `smtpd_tls_cert_file = /etc/letsencrypt/live//fullchain.pem` and an empty `mydomain`, and Postfix refuses to start. `setup.sh:92` does `git clone "" services/silver-config`.

### L-4 · `unbound.configuration` is referenced but does not exist in values
**Status:** Open — `charts/silver/charts/unbound/templates/configmap.yaml:1`
Gated on `.Values.configuration`, which the chart's `values.yaml` never defines, so the ConfigMap never renders — and `statefulset.yaml:48-50` mounts only the `cache` volume, so even if it did render nothing would consume it. An operator hardening the resolver gets a ConfigMap that is silently ignored. Since rspamd points its DNS at this resolver, DNSSEC settings intended for SPF/DKIM/DMARC lookups are not applied.

### L-5 · `unbound.service.protocol` is a dead value
**Status:** Open — `charts/silver/charts/unbound/values.yaml:37`
Declares `protocol: UDP`, but `service.yaml:14-21` hardcodes both a TCP and a UDP port and never reads it.

### L-6 · `thunder-admin-secret` is a Helm hook, so `helm uninstall` leaves the credential behind
**Status:** Open — `charts/silver/templates/thunder-admin-secret.yaml:63-69`
`helm.sh/hook: pre-install,pre-upgrade` means the resource is not part of the release manifest, so `helm uninstall silver` deletes the Thunder PVC and pods but strands `silver-thunder-admin` in the namespace. On a later reinstall the `lookup` at line 43 silently adopts the stale password against a freshly-bootstrapped, empty Thunder database.

### L-7 · `charts/README.md` documents a workflow the chart no longer implements
**Status:** Open
Four separate drifts: version `0.32.0` documented vs `0.33.0` pinned in `Chart.yaml:40`; a "required before install" bootstrap ConfigMap step that the chart now renders automatically; a `kubectl create secret generic thunder-admin-credentials` instruction for a Secret the chart creates itself (and whose template *hard-fails the render* if a consumer names a different one); and a claim that certificates include a `*.mail.yourdomain.com` wildcard when `certificate.yaml:18-19` emits exactly one non-wildcard `dnsName`. Following the README verbatim creates two orphaned objects.

### L-8 · Unpinned third-party scanner cloned over a pinned submodule and executed
**Status:** Open — `test/security/tls/tls_security_test.sh:67-71`
`test/security/tls/testssl.sh` is already a gitlink (mode `160000`, commit `932c91f6…`), so the repository pins a version — and this code `git clone --depth 1`s `HEAD` of the default branch over it and runs it. Whatever is on that branch at run time executes with the operator's privileges.

### L-9 · Postfix runs unsupervised behind `sleep infinity`
**Status:** Open — `services/smtp/scripts/entrypoint.sh:39,68-71`
`service postfix start` daemonizes and PID 1 becomes `sleep infinity`. If the Postfix master dies the container stays "running" forever, Docker's restart policy never fires, and mail silently stops being accepted with no health signal. The same file `chmod 644`s the shared user/domain/role database on a bind-mounted volume, making it readable by every uid sharing that mount and on the host.

### L-10 · `set -e` neutered by a pipeline subshell, and multi-domain DKIM lookup is wrong
**Status:** Open — `scripts/utils/get-dkim.sh:2,86,91`
The `while` loop runs in a subshell of a pipeline, so nothing inside can abort the script. The selector lookup greps the whole file for `domain:\s*$DOMAIN`, so with two domains configured `grep -A2` returns two `dkim-selector:` lines and the selector becomes a two-line value, producing a bogus "DKIM key not found" for every domain. `$DOMAIN` is also used unescaped as a regex.

### L-11 · OAuth example registers a portless, path-exact loopback redirect URI
**Status:** Open — `docs/thunderbird-oauth-example/manifest.json:16`; `scripts/thunder/02-sample-resources.sh:121-123`
PKCE and `publicClient` / `tokenEndpointAuthMethod: none` are correctly set, so the flow itself is sound. But RFC 8252 loopback clients bind an *ephemeral* port, so an exact-match server rejects the callback while a prefix-matching server would let any local application claim the redirect. Should register `http://127.0.0.1` and document that the port must be ignored per RFC 8252 §7.3.

---

## Deliberately deferred

Six High-severity findings and most Medium/Low items are recorded but not fixed in this round. The reasoning:

- **H-18 (unpinned `silver-config` repository)** — the highest-impact finding in the audit, but the fix is organisational: move the repository under the `LSFLK` organisation and pin installs to a signed tag. A code change alone would give false assurance.
- **M-1 (`milter_default_action = accept`)** — the correct value is `tempfail`, but flipping it without first adding real healthchecks to Rspamd and OpenDKIM would convert a silent security failure into a visible mail outage. Healthchecks first, then the flip.
- **M-14 (`cleanup-docker.sh`)** and **M-13 (`/etc/hosts` rewriting)** — both mutate state outside the project. Worth fixing, but they change developer workflow and deserve a maintainer decision rather than an unsolicited patch.
- **Remaining Medium/Low** — mostly Helm reliability and hygiene. They are real, but bundling ~35 more changes into this review round would bury the six Critical fixes that need careful scrutiny.

## What was verified, and what was not

Verification was **static**: `helm lint` and `helm template` against the rendered manifests, `shellcheck` and `bash -n`, `postconf` parsing of the generated Postfix configuration, `go vet` / `go build`, Python compilation and linting, `docker compose config`, and targeted container-based tests proving specific injection vectors are closed.

Not exercised: no Kubernetes cluster was available, so `helm install`, `lookup`-based Secret reuse across upgrades, and NetworkPolicy enforcement were not tested against a live API server. The Compose stack was not brought up end-to-end — it requires public DNS, a routable IP, and Let's Encrypt issuance. Mail flow, DKIM signing and IMAP delivery were therefore not tested against a running deployment.

Anyone accepting these changes should run a full deployment in a staging environment before production.
