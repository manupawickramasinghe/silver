# Rspamd Helm Chart

Rspamd spam/malware filtering engine with a Bayes classifier, metrics exporter, and optional ClamAV antivirus.

## Dependencies

This chart requires:
- Redis: for learning/caching backend
- Unbound: for DNS queries
- ClamAV: for virus scanning (optional, **off by default** — no ClamAV chart
  ships with Silver, so you must deploy one yourself and point
  `dependencies.clamav.host` at it)

Redis and Unbound hostnames default to `<release>-redis` / `<release>-unbound`,
derived from the release name. Set `dependencies.redis.host` /
`dependencies.unbound.host` only to point at an endpoint outside the release.

## Installation

Basic installation with all dependencies:

```bash
helm upgrade --install silver ./charts/silver \
  --set redis.enabled=true \
  --set unbound.enabled=true \
  --set rspamd.enabled=true \
  --set 'rspamd.webui.password=mypassword'
```

`rspamd.webui.password` is optional: leave it unset and the chart generates one
on first install and reuses it on every upgrade. It is **not** optional for
GitOps / `helm template | kubectl apply`, where `lookup` cannot read the cluster
and each render would emit a new random password.

## Configuration

Key values:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `replicaCount` | int | `1` | Number of replicas |
| `image.repository` | string | `rspamd/rspamd` | Image repository |
| `image.tag` | string | `4.1.1` | Image tag |
| `persistence.enabled` | bool | `true` | Enable persistent volume for state |
| `persistence.size` | string | `1Gi` | Persistent volume size |
| `dependencies.redis.host` | string | `` | Redis hostname (empty = `<release>-redis`) |
| `dependencies.redis.port` | int | `6379` | Redis port |
| `dependencies.unbound.host` | string | `` | Unbound hostname (empty = `<release>-unbound`) |
| `dependencies.unbound.port` | int | `53` | Unbound DNS port |
| `dependencies.clamav.host` | string | `` | ClamAV hostname (required when antivirus is enabled) |
| `dependencies.clamav.port` | int | `3310` | ClamAV port |
| `dependencies.strictInitChecks` | bool | `true` | Fail-fast on dependency unavailability |
| `dependencies.initCheckTimeout` | int | `60` | Init check timeout in seconds |
| `modules.antivirus.enabled` | bool | `false` | Enable antivirus scanning (needs your own ClamAV) |
| `modules.antivirus.clamav_action` | string | `add_header` | Action on virus: add_header, reject, discard |
| `modules.classifier_bayes.enabled` | bool | `true` | Enable Bayes spam classifier |
| `modules.classifier_bayes.backend` | string | `redis` | Backend for classifier storage |
| `modules.metrics_exporter.enabled` | bool | `true` | Enable Prometheus metrics export |
| `service.milter.port` | int | `11332` | SMTP milter port |
| `service.webui.port` | int | `11334` | Web UI port |
| `service.webui.enabled` | bool | `true` | Enable web UI service |
| `webui.password` | string | `` | Controller password (empty = generated, then reused) |
| `webui.enablePassword` | string | `` | Password for privileged actions (empty = same as `webui.password`) |
| `networkPolicy.enabled` | bool | `false` | Apply the NetworkPolicy |
| `networkPolicy.milterIngressFrom` | list | `[]` | Who may reach 11332 (empty = this release's Postfix) |
| `networkPolicy.webuiIngressFrom` | list | `[]` | Who may reach 11334 (empty = nobody; use port-forward) |
| `networkPolicy.allowExternalMaps` | bool | `true` | Allow egress for Rspamd map/fuzzy downloads |

## Override Dependency Hosts

For custom dependency endpoints:

```bash
helm upgrade --install silver ./charts/silver \
  --set rspamd.enabled=true \
  --set 'rspamd.dependencies.redis.host=custom-redis' \
  --set 'rspamd.dependencies.unbound.host=custom-unbound' \
  --set 'rspamd.dependencies.clamav.host=external-clamav'
```

## Web UI Access

Port-forward to rspamd web UI:

```bash
kubectl port-forward -n mail svc/rspamd 11334:11334
```

Then access `http://localhost:11334/` with the controller password:

```bash
kubectl get secret -n mail <release>-rspamd-webui \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

`port-forward` reaches the pod through the kubelet, so it works even with the
NetworkPolicy enabled — the policy ships no ingress rule for 11334 on purpose.
Grant one with `networkPolicy.webuiIngressFrom` if something in-cluster needs it.

## Testing

Run Helm test:

```bash
helm test silver -n mail
```

Verify milter connectivity from postfix:

```bash
kubectl exec -n mail -it <postfix-pod> -- nc -zv rspamd 11332
```

## Init Checks

If `dependencies.strictInitChecks=true`, rspamd will not start until:
- Redis is reachable on configured host:port
- Unbound DNS is responding on configured host:port

If init checks fail, inspect pod logs:

```bash
kubectl logs -n mail <rspamd-pod> -c check-redis
kubectl logs -n mail <rspamd-pod> -c check-unbound
```

## NetworkPolicy

Disabled by default (`networkPolicy.enabled=false`). When enabled it allows:

- ingress on 11332 from this release's Postfix pods
  (`app.kubernetes.io/name: postfix`) — and nothing else;
- ingress on 11334 only from `networkPolicy.webuiIngressFrom`, which is empty;
- egress to Redis, Unbound, cluster DNS, ClamAV (when antivirus is enabled), and
  the internet on 80/443 plus UDP 11335 for Rspamd's map and fuzzy downloads.

Verify the milter path after enabling it — if Postfix cannot reach 11332,
Postfix's `milter_default_action = accept` delivers every message **unfiltered**
and logs nothing:

```bash
kubectl exec -n mail -it <postfix-pod> -- nc -zv rspamd 11332
```

## Persistence

Rspamd state (learning data, UCL files, ML models) is stored in `/var/lib/rspamd` via `volumeClaimTemplates`. The PVC persists across pod restarts.

## Scaling

v1 supports single replica only (`replicaCount: 1`). Multi-replica support requires shared Redis + distributed learning (future scope).
