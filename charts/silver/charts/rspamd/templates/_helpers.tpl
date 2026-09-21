{{/*
Expand the name of the chart.
*/}}
{{- define "rspamd.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rspamd.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rspamd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Stable Service name so Postfix resolves the rspamd milter (decoupled from the
release-prefixed fullname, matching raven's pattern). */}}
{{- define "rspamd.serviceName" -}}
{{- (((.Values.global).serviceNames).rspamd) | default "rspamd" -}}
{{- end }}

{{/* Headless governing Service for the StatefulSet. The regular Service is named
`rspamd` (release-independent, so vendored configs resolve) and is a normal
ClusterIP, which cannot give a StatefulSet stable per-pod DNS. This one can. */}}
{{- define "rspamd.headlessServiceName" -}}
{{- printf "%s-headless" (include "rspamd.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "rspamd.webuiSecretName" -}}
{{- printf "%s-webui" (include "rspamd.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Dependency hostnames.

These used to be hardcoded in values.yaml as `silver-redis` / `silver-unbound`,
which only resolved for a release literally named `silver`. Any other release
name left the strict init containers spinning until they timed out and exited 1,
so the pod never started. The sibling charts name their Services after their own
fullname helper, i.e. <release>-redis and <release>-unbound, so derive the same
thing from .Release.Name here. Values
files are not rendered as templates, so this cannot live in values.yaml — the
values keys stay as explicit overrides for out-of-cluster endpoints. */}}
{{- define "rspamd.redisHost" -}}
{{- .Values.dependencies.redis.host | default (printf "%s-redis" .Release.Name) -}}
{{- end }}

{{- define "rspamd.unboundHost" -}}
{{- .Values.dependencies.unbound.host | default (printf "%s-unbound" .Release.Name) -}}
{{- end }}

{{/* No chart in this repository creates a ClamAV Service, so there is no
defensible default: antivirus is off by default and turning it on requires
naming a reachable ClamAV. */}}
{{- define "rspamd.clamavHost" -}}
{{- required "rspamd.dependencies.clamav.host is required when rspamd.modules.antivirus.enabled is true (no ClamAV chart ships with Silver)" .Values.dependencies.clamav.host -}}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rspamd.labels" -}}
helm.sh/chart: {{ include "rspamd.chart" . }}
{{ include "rspamd.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rspamd.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rspamd.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "rspamd.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rspamd.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
