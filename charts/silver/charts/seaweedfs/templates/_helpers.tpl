{{/* Chart name, optionally overridden. */}}
{{- define "seaweedfs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Release-qualified name for owned objects (StatefulSet, Secret). */}}
{{- define "seaweedfs.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "seaweedfs.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Stable, release-independent Service name so Raven's vendored config resolves the
S3 endpoint. Defaults to the compose name `seaweedfs-s3`; override via
global.serviceNames.s3.
*/}}
{{- define "seaweedfs.serviceName" -}}
{{- (((.Values.global).serviceNames).s3) | default "seaweedfs-s3" }}
{{- end }}

{{- define "seaweedfs.secretName" -}}
{{- printf "%s-s3" (include "seaweedfs.fullname" .) }}
{{- end }}

{{- define "seaweedfs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "seaweedfs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "seaweedfs.labels" -}}
{{ include "seaweedfs.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Master HTTP/gRPC Service name. The master API is UNAUTHENTICATED — the identity
in s3-config.json only gates the S3 gateway — so it does NOT belong on the S3
Service alongside 8333. It gets its own headless Service, reached only by the
bucket-init Job and the helm test (`weed shell`).
*/}}
{{- define "seaweedfs.masterServiceName" -}}
{{- printf "%s-master" (include "seaweedfs.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resolve the S3 secretKey.

Priority:
  1. global.s3.secretKey / s3.secretKey — an operator-supplied key.
  2. The key already stored in this release's S3 Secret (via `lookup`), so
     `helm upgrade` never rotates a credential the running store is using.
  3. A freshly generated random key (first install only).

This used to DERIVE the key from the release name
(`printf "%s-silver-seaweedfs-s3" .Release.Name | sha256sum | trunc 40`). The
derivation was deliberate: raven needs the same key, and `lookup` cannot see a
Secret the same install has not applied yet, so recomputing it in both charts was
the only way a one-command `helm install` could agree on a value. The cost was
that every default install's S3 admin key — Admin/Read/Write over all mail
attachments — was computable offline by anyone from public information.

The fix breaks the "both sides compute it" requirement rather than the
derivation: the key is generated HERE, once, and raven no longer computes
anything. It reads this Secret with a secretKeyRef instead
(charts/silver/charts/raven/templates/_helpers.tpl + deployment.yaml), which
works on a fresh one-command install because the reference is resolved by the
kubelet at pod start, long after Helm has applied this Secret.

Reuse guard pattern mirrors charts/silver/templates/thunder-admin-secret.yaml.

⚠️  `lookup` returns nothing without a cluster connection, so `helm template` /
`--dry-run` emits a NEW random key on every render. Piping that into
`kubectl apply` against a live release rotates the S3 credential. Set
global.s3.secretKey explicitly for GitOps / render-then-apply workflows.
*/}}
{{- define "seaweedfs.secretKey" -}}
{{- $explicit := (((.Values.global).s3).secretKey) | default .Values.s3.secretKey -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "seaweedfs.secretName" .) -}}
{{- $data := dict -}}
{{- if $existing -}}
{{- $data = $existing.data | default dict -}}
{{- end -}}
{{- if index $data "secretKey" -}}
{{- index $data "secretKey" | b64dec -}}
{{- else -}}
{{- randAlphaNum 40 -}}
{{- end -}}
{{- end -}}
{{- end }}
