{{/* Chart name, overridable. */}}
{{- define "mast.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified release name. */}}
{{- define "mast.fullname" -}}
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

{{- define "mast.core.fullname" -}}
{{- printf "%s-core" (include "mast.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mast.edge.fullname" -}}
{{- printf "%s-edge" (include "mast.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mast.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "mast.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "mast.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mast.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mast.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mast.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "mast.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/*
Secret holding the auth headers, whether we render it or the user supplies it.
*/}}
{{- define "mast.authSecretName" -}}
{{- if .Values.auth.http.existingSecret }}
{{- .Values.auth.http.existingSecret }}
{{- else }}
{{- printf "%s-auth" (include "mast.fullname" .) }}
{{- end }}
{{- end }}

{{/*
The [auth] block, shared by every role that terminates MQTT. Headers are not
rendered here: they arrive as environment variables from a Secret so they
never sit in a ConfigMap.
*/}}
{{- define "mast.authConfig" -}}
[auth]
mode = {{ .Values.auth.mode | quote }}

[auth.http]
wire = {{ .Values.auth.http.wire | default "mast" | quote }}
authn_url = {{ .Values.auth.http.authnUrl | quote }}
authz_url = {{ .Values.auth.http.authzUrl | quote }}
timeout = {{ .Values.auth.http.timeout | quote }}
on_error = {{ .Values.auth.http.onError | quote }}
cache_ttl = {{ .Values.auth.http.cacheTtl | quote }}
cache_size = {{ .Values.auth.http.cacheSize }}

[tenant]
default = {{ .Values.auth.tenantDefault | quote }}
{{- end }}

{{/*
Route URLs for the core StatefulSet's full mesh. Each peer is addressed by
its stable pod DNS name, which is the reason core is a StatefulSet.
*/}}
{{- define "mast.coreRoutes" -}}
{{- $core := include "mast.core.fullname" . -}}
{{- $ns := .Release.Namespace -}}
{{- $routes := list -}}
{{- range $i := until (int .Values.core.replicas) -}}
{{- $routes = append $routes (printf "\"nats://%s-%d.%s.%s.svc:6222\"" $core $i $core $ns) -}}
{{- end -}}
{{ join ", " $routes }}
{{- end }}
