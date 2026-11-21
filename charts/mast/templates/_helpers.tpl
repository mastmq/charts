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

{{/*
The Service that carries what must never leave the cluster: the
unauthenticated internal listener, metrics (which also serves pprof) and the
NATS monitor. Named after the public Service it sits beside, so a
fullnameOverride that keeps the public name also predicts this one.
*/}}
{{- define "mast.internal.fullname" -}}
{{- if eq .Values.mode "standalone" }}
{{- printf "%s-internal" (include "mast.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-internal" (include "mast.edge.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Environment for every mast container: the pod's own name as the NATS server
name, then extraEnv.

Without a name every pod in a role falls back to the same "mast-core" or
"mast-edge". A core closes a route from a peer carrying its own name, and a
leaf connection under a name already attached evicts the previous one, so
edges knock each other off in turn. The pod name
is unique per role and, on a StatefulSet, stable across restarts, which is
what Raft wants. An extraEnv entry of the same name replaces it rather than
being appended as a duplicate, because a duplicated env name is rejected by
server-side apply.
*/}}
{{- define "mast.env" -}}
{{- $override := false }}
{{- range .Values.extraEnv }}
{{- if eq .name "MAST__NATS__NAME" }}
{{- $override = true }}
{{- end }}
{{- end }}
{{- if not $override }}
- name: MAST__NATS__NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
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
The [tracing] block, for the roles that have an MQTT side to trace. Rendered
only when tracing is on, so that a chart upgrade with it off leaves the
ConfigMap, and with it every edge, alone. An empty key is left out rather
than written as "", which mast would read the same way, so that the file
says only what was chosen.
*/}}
{{- define "mast.tracingConfig" -}}
{{- with .Values.tracing }}
{{- if .enabled }}
[tracing]
enabled = true
{{- with .endpoint }}
endpoint = {{ . | quote }}
{{- end }}
{{- with .sampler }}
sampler = {{ . | quote }}
{{- end }}
{{- with .samplerArg }}
sampler_arg = {{ . | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The [limits] block, for every role: an edge or the standalone pod enforces
the limits, and a core sizes the offline stream from the largest
offlineQueue, so both tiers must read the same block. Rendered only when a
value differs from mast's own default, for the same reason as [tracing]. A
tenant's entry writes only the fields it sets, because a field left out
means "keep the default", not zero.
*/}}
{{- define "mast.limitsConfig" -}}
{{- with .Values.limits }}
{{- if or (gt (int .maxConnections) 0) (gt (float64 .publishRate) 0.0) (gt (int .publishBurst) 0) (ne (int .offlineQueue) 100) (ne (toString .syncInterval) "2s") .tenants }}
[limits]
max_connections = {{ int .maxConnections }}
publish_rate = {{ float64 .publishRate }}
publish_burst = {{ int .publishBurst }}
offline_queue = {{ int .offlineQueue }}
sync_interval = {{ .syncInterval | quote }}
{{- range $id, $t := .tenants }}
{{- if not (regexMatch "^[A-Za-z0-9_-]+$" $id) }}{{ fail (printf "limits.tenants: %q is not a tenant id the chart can name; use letters, digits, - and _" $id) }}{{ end }}

[limits.tenants.{{ $id }}]
{{- if hasKey $t "maxConnections" }}
max_connections = {{ int $t.maxConnections }}
{{- end }}
{{- if hasKey $t "publishRate" }}
publish_rate = {{ float64 $t.publishRate }}
{{- end }}
{{- if hasKey $t "publishBurst" }}
publish_burst = {{ int $t.publishBurst }}
{{- end }}
{{- if hasKey $t "offlineQueue" }}
offline_queue = {{ int $t.offlineQueue }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The Secret holding the admin API's token, whether the user manages it or
the chart renders it from admin.token.
*/}}
{{- define "mast.adminSecretName" -}}
{{- if .Values.admin.existingSecret }}
{{- .Values.admin.existingSecret }}
{{- else }}
{{- printf "%s-admin" (include "mast.fullname" .) }}
{{- end }}
{{- end }}

{{/*
The [admin] block, for every role: any node answers for the whole cluster,
a core included. Rendered only when the API is on, for the same reason as
[tracing]. The token is a file from the Secret, never a value here.
*/}}
{{- define "mast.adminConfig" -}}
{{- with .Values.admin }}
{{- if .enabled }}
{{- if not (or .existingSecret .token) }}{{ fail "admin.enabled needs admin.existingSecret or admin.token: mast refuses to serve the API without a token" }}{{ end }}
{{- if has (int .port) (list 1883 4222 6222 7422 8222 (int $.Values.metrics.port) (int $.Values.edge.internalPort) (int $.Values.edge.wsPort)) }}{{ fail "admin.port collides with another port of the pod" }}{{ end }}
[admin]
addr = "0.0.0.0:{{ .port }}"
token_file = "/etc/mast/admin/{{ .secretKey }}"
gather = {{ .gather | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The admin token's mount and volume, for every role. A directory of its own
under /etc/mast, as the ConfigMap holds /etc/mast itself. Not optional: mast
refuses to start without the file, and a pod held in ContainerCreating with
an event naming the Secret says so more plainly than a crash loop.
*/}}
{{- define "mast.adminMount" -}}
{{- if .Values.admin.enabled }}
- name: admin
  mountPath: /etc/mast/admin
  readOnly: true
{{- end }}
{{- end }}

{{- define "mast.adminVolume" -}}
{{- if .Values.admin.enabled }}
- name: admin
  secret:
    secretName: {{ include "mast.adminSecretName" . }}
    items:
      - key: {{ .Values.admin.secretKey }}
        path: {{ .Values.admin.secretKey }}
{{- end }}
{{- end }}

{{/*
The admin container port, for every role.
*/}}
{{- define "mast.adminPort" -}}
{{- if .Values.admin.enabled }}
- name: admin
  containerPort: {{ .Values.admin.port }}
{{- end }}
{{- end }}

{{/*
envFrom for the roles with an MQTT side: the auth header Secret in http mode,
and the OTEL_* Secret when tracing is on. Both are optional, as a missing
Secret should cost the feature it configures, not the pod.
*/}}
{{- define "mast.envFrom" -}}
{{- if eq .Values.auth.mode "http" }}
- secretRef:
    name: {{ include "mast.authSecretName" . }}
    optional: true
{{- end }}
{{- if and .Values.tracing.enabled .Values.tracing.existingSecret }}
- secretRef:
    name: {{ .Values.tracing.existingSecret }}
    optional: true
{{- end }}
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

{{- if eq .Values.auth.mode "jwt" }}
{{- $j := .Values.auth.jwt }}
{{- if not $j.algorithms }}{{ fail "auth.jwt.algorithms is required in jwt mode" }}{{ end }}
{{- if not $j.keySecret }}{{ fail "auth.jwt.keySecret is required in jwt mode" }}{{ end }}
{{- if eq (empty $j.hmacSecretKey) (empty $j.publicKeyKey) }}{{ fail "set exactly one of auth.jwt.hmacSecretKey and auth.jwt.publicKeyKey" }}{{ end }}

[auth.jwt]
source = {{ $j.source | quote }}
vendor_prefix = {{ $j.vendorPrefix }}
algorithms = [{{ range $i, $a := $j.algorithms }}{{ if $i }}, {{ end }}{{ $a | quote }}{{ end }}]
{{- if $j.hmacSecretKey }}
hmac_secret_file = "/etc/mast/jwt/{{ $j.hmacSecretKey }}"
{{- else }}
public_key_file = "/etc/mast/jwt/{{ $j.publicKeyKey }}"
{{- end }}
tenant_claim = {{ $j.tenantClaim | quote }}
superuser_claim = {{ $j.superuserClaim | quote }}
{{- with $j.limitsClaim }}
limits_claim = {{ . | quote }}
{{- end }}
issuer = {{ $j.issuer | quote }}
audience = {{ $j.audience | quote }}
{{- end }}

[tenant]
default = {{ .Values.auth.tenantDefault | quote }}
{{- end }}

{{/*
Lines for the [mqtt] section when TLS is on. The kubernetes.io/tls Secret
type fixes the key names, so they are not configurable.
*/}}
{{- define "mast.tlsConfig" -}}
{{- if .Values.tls.secretName }}
tls_cert = "/etc/mast/tls/tls.crt"
tls_key = "/etc/mast/tls/tls.key"
{{- end }}
{{- end }}

{{/*
Mounts and volumes for the TLS and JWT Secrets, for every pod that
terminates MQTT. Separate directories under /etc/mast, because the config
ConfigMap is mounted at /etc/mast itself and a Secret cannot share it.
*/}}
{{- define "mast.secretMounts" -}}
{{- if .Values.tls.secretName }}
- name: tls
  mountPath: /etc/mast/tls
  readOnly: true
{{- end }}
{{- if eq .Values.auth.mode "jwt" }}
- name: jwt
  mountPath: /etc/mast/jwt
  readOnly: true
{{- end }}
{{- end }}

{{- define "mast.secretVolumes" -}}
{{- if .Values.tls.secretName }}
- name: tls
  secret:
    secretName: {{ .Values.tls.secretName }}
{{- end }}
{{- if eq .Values.auth.mode "jwt" }}
- name: jwt
  secret:
    secretName: {{ .Values.auth.jwt.keySecret }}
{{- end }}
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

{{/*
The [fabric] and [session] sections, shared by the roles that terminate
MQTT. A core runs no bridge, so neither applies to it.
*/}}
{{- define "mast.fabricConfig" -}}
[fabric]
durable_qos = {{ .Values.fabric.durableQoS }}
durable_max_age = {{ .Values.fabric.durableMaxAge | quote }}

[session]
expiry = {{ .Values.session.expiry | quote }}
{{- end }}

{{/*
PromQL label matchers for the series this release's ServiceMonitor scrapes.
The operator labels every scraped series with the namespace and the Service
it came through, so this matches exactly this release's pods and not another
release of the chart in the same namespace. In cluster mode the core and the
edges come through different Services.
*/}}
{{- define "mast.promSelector" -}}
{{- if eq .Values.mode "standalone" -}}
namespace="{{ .Release.Namespace }}", service="{{ include "mast.internal.fullname" . }}"
{{- else -}}
namespace="{{ .Release.Namespace }}", service=~"{{ include "mast.core.fullname" . }}|{{ include "mast.internal.fullname" . }}"
{{- end -}}
{{- end }}

{{/*
The Service that carries the queuer's metrics: the cores in a cluster, the
one node standalone. Edges register mast_queuer_away_sessions too and always
report zero, so a rule comparing queuers must not see them.
*/}}
{{- define "mast.promQueuerSelector" -}}
{{- if eq .Values.mode "standalone" -}}
namespace="{{ .Release.Namespace }}", service="{{ include "mast.internal.fullname" . }}"
{{- else -}}
namespace="{{ .Release.Namespace }}", service="{{ include "mast.core.fullname" . }}"
{{- end -}}
{{- end }}
