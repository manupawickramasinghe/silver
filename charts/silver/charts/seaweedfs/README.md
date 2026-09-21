# seaweedfs subchart

Single-node [SeaweedFS](https://github.com/seaweedfs/seaweedfs) providing an
S3-compatible API for Raven attachment (blob) storage. Internal only — never
exposed publicly.

## What it creates

- **StatefulSet** running combined `weed server -s3` (master + volume + filer +
  S3 gateway in one process), with a PVC for `/data` via `volumeClaimTemplates`.
- **Service** named `seaweedfs-s3` (stable, from `global.serviceNames.s3`) —
  port `8333` (S3) **only**. Raven reads/writes attachments at
  `http://seaweedfs-s3:8333`.
- **Headless Service** `<release>-seaweedfs-master` — master HTTP (`9333`) and
  master gRPC (`19333`), used only by the bucket-init Job and `helm test`.
- **Secret** `<release>-seaweedfs-s3` holding `accessKey`, `secretKey`, and the
  rendered `s3-config.json`. Raven consumes the same Secret so credentials can't
  drift.
- **NetworkPolicy** (`networkPolicy.enabled`, off by default).
- **bucket-init Job** (post-install/upgrade hook) creating the
  `email-attachments` bucket. Idempotent; SeaweedFS also auto-creates on first
  PUT since the identity has `Admin`.

## Credentials

`s3.accessKey` is **pinned** (default `raven`) — it binds to `secretKey` inside
`s3-config.json`, so rotating one without the other breaks existing clients.
`s3.secretKey: ""` auto-generates a key once and preserves it across upgrades:
a `lookup` guard reads the key back out of the existing Secret. Set
`global.s3.secretKey` explicitly to pin your own.

The key is generated **here and only here**. Raven does not recompute it — it
reads this Secret with a `secretKeyRef` and substitutes the value into its config
in an init container (raven is configured by file, not by environment). Earlier
versions derived the key in both charts from the release name
(`sha256("<release>-silver-seaweedfs-s3")[:40]`) so a one-command install could
agree on it without a cross-chart lookup; that made the S3 admin key of every
default install computable offline by anyone. One-command install still works,
because a `secretKeyRef` is resolved by the kubelet at pod start — long after
Helm has applied this Secret — rather than at render time.

> ⚠️ `lookup` sees nothing without a cluster connection, so `helm template` /
> `--dry-run` emits a **new random key every render**. Set `global.s3.secretKey`
> explicitly for GitOps / `helm template | kubectl apply`, or each apply will
> rotate the credential. Same caveat as the Thunder admin password.

If you run raven without this subchart, set `global.s3.secretKey` (or point
`global.s3.secretName` at your own Secret) — otherwise raven's pod stops at
`CreateContainerConfigError` on the missing Secret.

## Network exposure

The SeaweedFS **master API has no authentication at all** — the identity in
`s3-config.json` gates the S3 gateway and nothing else. Anything that can reach
`:9333`/`:19333` can enumerate volumes and read or delete raw attachment blobs
without ever presenting the S3 credential.

Two mitigations:

1. The master ports are on their own headless Service, no longer on
   `seaweedfs-s3` alongside `8333`.
2. `networkPolicy.enabled=true` restricts `8333` to raven (plus
   `networkPolicy.allowedIngressFrom`) and everything else to this chart's own
   pods — the store, the bucket-init Job and the `helm test` Pod.

The policy is **off by default** to match the opendkim subchart, but you should
turn it on. Two things to check first: your CNI must enforce NetworkPolicy
(flannel does not), and `networkPolicy.clientPodName` must match the raven pod's
`app.kubernetes.io/name` label if you renamed that subchart.

The second rule deliberately does not narrow to `9333`/`19333`: `weed shell`
talks master gRPC and then dials the filer/volume gRPC ports directly on the
advertised pod IP, so a port-restricted rule would break bucket creation.

## Deployment mode — combined vs 4-role split

Default is **combined** mode (one pod). Note the reference
`services/docker-compose.seaweedfs.yaml` uses the **4-role split** (separate
master/volume/filer/s3 containers) — that split is the *proven* config;
combined mode is the lazy single-pod path and has known startup-ordering quirks
(filer/master race).

**Fallback trigger — switch to the 4-role split if:**
- the pod crash-loops on startup, or
- S3 / bucket operations fail against combined mode (the bucket-init Job or
  `helm test` keeps failing to reach the cluster).

The split is not implemented yet (`mode` values other than `combined` `fail`
the render). To add it, mirror the four services in the compose file as separate
containers in one pod (or separate StatefulSets) sharing the data PVC.

## Storage class

`persistence.storageClass: ""` uses the cluster default. Clusters **without** a
default StorageClass (OpenShift, some k3d setups) must set it, or the PVC stays
`Pending`.
