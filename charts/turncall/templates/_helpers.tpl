{{- define "turncall.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "turncall.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels for one component: (dict "ctx" $ "component" "api") */}}
{{- define "turncall.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "turncall.image" -}}
{{- $image := merge (dict) (.override | default dict) .ctx.Values.image -}}
{{- printf "%s:%s" $image.repository (default .ctx.Chart.AppVersion $image.tag) -}}
{{- end -}}

{{- define "turncall.secretName" -}}
{{- default (include "turncall.fullname" .) .Values.existingSecret -}}
{{- end -}}

{{/* secretEnv, with the bundled Postgres/Redis URLs under any it does not set. */}}
{{- define "turncall.secretEnv" -}}
{{- $env := dict -}}
{{- $full := include "turncall.fullname" . -}}
{{- with .Values.postgresql }}{{ if .enabled -}}
{{- $_ := set $env "DATABASE_URL" (printf "postgresql+asyncpg://%s:%s@%s-postgresql:5432/%s" .user (urlquery .password) $full .database) -}}
{{- end }}{{ end -}}
{{- if .Values.redis.enabled -}}
{{- $_ := set $env "REDIS_URL" (printf "redis://%s-redis:6379/0" $full) -}}
{{- end -}}
{{- toYaml (merge (deepCopy .Values.secretEnv) $env) -}}
{{- end -}}

{{- define "turncall.checkSecrets" -}}
{{- if not (or .Values.existingSecret .Values.secretEnv.DATABASE_URL .Values.postgresql.enabled) -}}
{{- fail "set secretEnv.DATABASE_URL, existingSecret naming a Secret that holds it, or postgresql.enabled" -}}
{{- end -}}
{{- end -}}

{{/* Pod-level settings every TurnCall process shares. */}}
{{- define "turncall.podSpec" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
# Service links would inject TURNCALL_* variables beside TURNCALL_ENV.
enableServiceLinks: false
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  # A fresh volume (localStorage) is root-owned; this makes it the app's.
  fsGroup: 10001
{{- end -}}

{{/* envFrom + the env every TurnCall container gets. */}}
{{- define "turncall.env" -}}
envFrom:
  - configMapRef:
      name: {{ include "turncall.fullname" . }}
  - secretRef:
      name: {{ include "turncall.secretName" . }}
{{- end -}}

{{/* Restart pods when their configuration changes. */}}
{{- define "turncall.configChecksum" -}}
checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
checksum/secret: {{ include (print .Template.BasePath "/secret.yaml") . | sha256sum }}
{{- end -}}

{{/*
Holds a worker until the bundled Postgres is migrated. There the API's init
container migrates, so the workers would otherwise start against no tables and
crash until it lands; with an external database the hook Job has migrated before
any pod starts, and this renders nothing.
*/}}
{{- define "turncall.waitForMigrations" -}}
{{- if and .Values.postgresql.enabled .Values.migrations.enabled }}
initContainers:
  - name: wait-for-migrations
    image: {{ include "turncall.image" (dict "ctx" .) }}
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    command: ["sh", "-c", "until alembic current 2>/dev/null | grep -q '(head)'; do sleep 3; done"]
    {{- include "turncall.env" . | nindent 4 }}
{{- end }}
{{- end -}}

{{- define "turncall.scheduling" -}}
{{- with .nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* ---- The builder (builder.enabled): builder-api, the console, Agent Backends ---- */}}

{{- define "builder.fullname" -}}
{{- printf "%s-builder" (include "turncall.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The builder's own name label, so its selectors stay its own. */}}
{{- define "builder.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: turncall-builder
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* (dict "ctx" $ "component" "api") */}}
{{- define "builder.selectorLabels" -}}
app.kubernetes.io/name: turncall-builder
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* (dict "ctx" $ "image" .Values.builder.api.image) */}}
{{- define "builder.image" -}}
{{- printf "%s:%s" .image.repository (default .ctx.Chart.AppVersion .image.tag) -}}
{{- end -}}

{{- define "builder.secretName" -}}
{{- default (include "builder.fullname" .) .Values.builder.existingSecret -}}
{{- end -}}

{{- define "builder.apiUrl" -}}
{{- printf "http://%s-api:8000" (include "builder.fullname" .) -}}
{{- end -}}

{{/* TurnCall's API, from inside the cluster: this release's own Service. */}}
{{- define "builder.turncallUrl" -}}
{{- printf "http://%s.%s.svc.cluster.local:%v" (include "turncall.fullname" .) .Release.Namespace .Values.api.service.port -}}
{{- end -}}

{{/* builder.secretEnv, with the bundled Postgres's `builder` database under a DATABASE_URL it does not set. */}}
{{- define "builder.secretEnv" -}}
{{- $env := dict -}}
{{- with .Values.postgresql }}{{ if .enabled -}}
{{- $_ := set $env "DATABASE_URL" (printf "postgresql://%s:%s@%s-postgresql:5432/builder" .user (urlquery .password) (include "turncall.fullname" $)) -}}
{{- end }}{{ end -}}
{{- toYaml (merge (deepCopy .Values.builder.secretEnv) $env) -}}
{{- end -}}

{{- define "builder.pullSecretNames" -}}
{{- $names := list -}}
{{- range .Values.imagePullSecrets }}{{ $names = append $names .name }}{{ end -}}
{{- join "," $names -}}
{{- end -}}

{{/* The public URL: publicBaseUrl, else the in-cluster tunnel's domain. */}}
{{- define "turncall.publicBaseUrl" -}}
{{- if .Values.publicBaseUrl -}}
{{- .Values.publicBaseUrl -}}
{{- else if and .Values.tunnel.enabled .Values.tunnel.domain -}}
{{- printf "https://%s" (.Values.tunnel.domain | trimPrefix "https://" | trimSuffix "/") -}}
{{- end -}}
{{- end -}}
